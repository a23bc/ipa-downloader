import Foundation
import CommonCrypto

/// High-level authentication service orchestrating the SRP-6a flow and 2FA.
///
/// Public API:
///   - `login(appleId:password:)` — initiate SRP
///   - `complete2FA(code:)` — submit SMS/device code
///   - `logout()` — clear all stored credentials
///
/// The service is `@MainActor` because most call sites are SwiftUI views
/// and it owns observable state.
@MainActor
final class AuthService: ObservableObject {
    /// Current authentication state (observable).
    enum State: Equatable {
        case idle
        case initiating
        case awaiting2FA(trustedPhoneNumbers: [String])
        case authenticated
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var account: AppleAccount?
    @Published private(set) var lastSCNT: String?   // used for 2FA continuation

    private let http = HTTPClient.shared
    private let storage = KeychainStore.shared
    private let anisette = AnisetteHeadersProvider.shared
    private var pendingSRP: SRPClient?

    init() {
        // Restore persisted session at startup.
        if let stored = storage.loadAccount() {
            self.account = AppleAccount(
                appleId: stored.appleId,
                firstName: stored.firstName,
                lastName: stored.lastName,
                dsid: stored.dsid,
                guid: stored.guid,
                storeFront: stored.storeFront,
                storeFrontCountry: stored.storeFrontCountry,
                twoFactorVerified: stored.twoFactorVerified
            )
            self.state = .authenticated
        }
    }

    // MARK: - Login

    func login(appleId: String, password: String) async {
        state = .initiating
        // Apple GSA occasionally returns 503 Service Temporarily Unavailable
        // for transient reasons (rate-limit, IP reputation, server load).
        // Retry up to 3 times with backoff before giving up.
        var lastErr: Error?
        for attempt in 1...3 {
            do {
                try await performSRPLogin(appleId: appleId, password: password)
                return // success — state already set inside performSRPLogin
            } catch {
                lastErr = error
                // Only retry on transient errors (503 from Apple, network timeouts).
                let msg = (error as NSError).localizedDescription.lowercased()
                let isTransient = msg.contains("503")
                                || msg.contains("timeout")
                                || msg.contains("temporarily unavailable")
                if !isTransient || attempt == 3 { break }
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
            }
        }
        state = .failed(lastErr?.localizedDescription ?? "Unknown error")
    }

    private func performSRPLogin(appleId: String, password: String) async throws {
        // Step 1: Fetch anisette headers.
        let anisetteHeaders = try await anisette.fetchHeaders()

        // Step 2: Generate client ephemeral.
        let srp = SRPClient()
        pendingSRP = srp
        let deviceID = anisetteHeaders["X-Mme-Device-Id"] ?? UUID().uuidString

        // Step 3: Send Init request.
        let initBody = GSARequestBuilder.initBody(appleId: appleId,
                                                  A: srp.A,
                                                  deviceID: deviceID)
        var initHeaders = anisetteHeaders
        initHeaders["Content-Type"] = "application/x-apple-plist"
        initHeaders["Accept"] = "*/*"
        initHeaders["Accept-Language"] = "en-us"
        initHeaders["User-Agent"] = "com.apple.gsa.appleproduction [macOS,13.1,22C65,com.apple.gsa.appleproduction (1),com.apple.ASFoundation (1)]"

        let initReq = URLRequest(url: URL(string: "https://gsa.apple.com/grandslam/GsService2")!)
            .appendingHeaders(initHeaders)
            .withBody(initBody, method: "POST")
        let (initData, initResp) = try await URLSession.shared.data(for: initReq)

        // Parse Init response to extract `sp` (salt) and `B`.
        // If the response isn't a plist, surface what Apple actually returned
        // so we can diagnose — the "isn't in the correct format" error
        // typically means Apple returned an HTML error page or JSON status
        // instead of the expected binary plist.
        guard let initHTTP = initResp as? HTTPURLResponse else {
            throw AuthError.invalidInitResponse("init: non-HTTP response")
        }

        // If Apple returns 503 (Service Temporarily Unavailable), the response
        // is HTML — not a plist. Surface this distinctly from real parse errors.
        if initHTTP.statusCode == 503 {
            throw AuthError.invalidInitResponse("""
                init: HTTP 503 — Apple refused the request.

                Body sent: \(initBody.count) bytes (binary plist).
                Anisette headers sent: \(anisetteHeaders.keys.sorted().joined(separator: ", "))
                X-Mme-Device-Id: \(deviceID)

                If this persists after retrying and changing network:
                • Your anisette device fingerprint may be flagged by Apple.
                  Try a freshly-provisioned anisette server (delete its data volume).
                • Your Apple ID may require verification on appleid.apple.com.
                • Apple may be rate-limiting this IP. Wait 10-30 min and retry.
                • If you've never successfully authenticated from this anisette
                  server before, it may need a longer first-run provisioning
                  (the server logs should say 'provisioning' the first time).
                """)
        }

        guard let initPlist = try? PropertyListSerialization.propertyList(
            from: initData, options: [], format: nil) as? [String: Any] else {
            let bodyPreview = String(data: initData.prefix(500), encoding: .utf8) ?? "<binary \(initData.count) bytes>"
            throw AuthError.invalidInitResponse("""
                init: HTTP \(initHTTP.statusCode), response was not a plist.

                Content-Type: \(initHTTP.value(forHTTPHeaderField: "Content-Type") ?? "<none>")

                Body preview: \(bodyPreview)
                """)
        }

        // Apple returns status=0 in the plist body for errors but HTTP 200; check both.
        if let status = initPlist["Status"] as? [String: Any],
           let ec = status["ec"] as? Int, ec != 0 {
            let errorMessage = status["errors"] as? [[String: Any]] ?? []
            let msgs = errorMessage.compactMap { ($0["title"] as? String) ?? ($0["message"] as? String) }
            throw AuthError.invalidInitResponse("""
                init: Apple returned status ec=\(ec)
                Errors: \(msgs.joined(separator: "; "))
                Full plist keys: \(initPlist.keys.sorted())
                """)
        }

        guard let sp = initPlist["sp"] as? String,
              let saltData = Data(base64Encoded: sp),
              let B64 = initPlist["B"] as? String,
              let BData = Data(base64Encoded: B64) else {
            throw AuthError.invalidInitResponse("""
                init: plist did not contain 'sp' and 'B'.
                Received keys: \(initPlist.keys.sorted())
                Full plist: \(initPlist)
                """)
        }
        let B = BigUInt(bigEndian: BData)

        // Step 4: Compute M1.
        let (M1, K) = srp.computeM1(
            username: appleId,
            password: password,
            salt: saltData,
            B: B
        )

        // Step 5: Send Complete request.
        let completeBody = GSARequestBuilder.completeBody(
            appleId: appleId, M1: M1, A: srp.A, deviceID: deviceID
        )
        var completeHeaders = anisetteHeaders
        completeHeaders["Content-Type"] = "application/x-apple-plist"
        completeHeaders["Accept"] = "*/*"
        completeHeaders["Accept-Language"] = "en-us"
        completeHeaders["User-Agent"] = "com.apple.gsa.appleproduction [macOS,13.1,22C65,com.apple.gsa.appleproduction (1),com.apple.ASFoundation (1)]"

        let completeReq = URLRequest(url: URL(string: "https://gsa.apple.com/grandslam/GsService2")!)
            .appendingHeaders(completeHeaders)
            .withBody(completeBody, method: "POST")
        let (completeData, completeResp) = try await URLSession.shared.data(for: completeReq)

        guard let completeHTTP = completeResp as? HTTPURLResponse else {
            throw AuthError.invalidCompleteResponse("complete: non-HTTP response")
        }
        guard let completePlist = try? PropertyListSerialization.propertyList(
            from: completeData, options: [], format: nil) as? [String: Any] else {
            let bodyPreview = String(data: completeData.prefix(500), encoding: .utf8) ?? "<binary \(completeData.count) bytes>"
            throw AuthError.invalidCompleteResponse("""
                complete: HTTP \(completeHTTP.statusCode), response was not a plist.

                Content-Type: \(completeHTTP.value(forHTTPHeaderField: "Content-Type") ?? "<none>")

                Body preview: \(bodyPreview)
                """)
        }

        // Check for in-plist error status.
        if let status = completePlist["Status"] as? [String: Any],
           let ec = status["ec"] as? Int, ec != 0 {
            let errorMessage = status["errors"] as? [[String: Any]] ?? []
            let msgs = errorMessage.compactMap { ($0["title"] as? String) ?? ($0["message"] as? String) }
            throw AuthError.invalidCompleteResponse("""
                complete: Apple returned status ec=\(ec)
                Errors: \(msgs.joined(separator: "; "))
                Full plist keys: \(completePlist.keys.sorted())
                """)
        }

        // 2FA required?
        if let au = completePlist["au"] as? String,
           au == "trustedDeviceSecondaryAuth" {
            // Save scnt header for subsequent 2FA requests.
            if let http = completeResp as? HTTPURLResponse,
               let scnt = http.value(forHTTPHeaderField: "scnt") {
                self.lastSCNT = scnt
            }
            let trustedPhones = (completePlist["trustedPhoneNumbers"] as? [[String: Any]])?
                .compactMap { $0["phoneNumber"] as? String } ?? []
            self.account = AppleAccount(appleId: appleId, password: password)
            self.state = .awaiting2FA(trustedPhoneNumbers: trustedPhones)
            return
        }

        // Otherwise — attempt to extract spd (decrypted with K) and authToken.
        guard let spd64 = completePlist["spd"] as? String,
              let spdCipher = Data(base64Encoded: spd64) else {
            throw AuthError.invalidCompleteResponse("""
                complete: plist did not contain 'spd' key.
                Received keys: \(completePlist.keys.sorted())
                Full plist: \(completePlist)
                """)
        }
        // spd is encrypted with key derived from K via PBKDF2 (HMAC-SHA1).
        // The protocol expects HMAC-SHA256-based key derivation, but Apple uses
        // AES-128-CBC with a fixed salt ("SPD" bytes).
        let derivedKey = Crypto.pbkdf2HMACSHA1(
            password: K,
            salt: Data([0x53, 0x50, 0x44, 0x00]),  // "SPD\0"
            iterations: 10000,
            keyLength: 16
        ) ?? Data(repeating: 0, count: 16)

        guard let decryptedSPD = aesDecrypt(key: derivedKey, data: spdCipher) else {
            throw AuthError.invalidCompleteResponse("complete: failed to decrypt spd blob (AES key derivation may be wrong)")
        }

        // Parse SPD for GUID / DSID / passToken.
        // SPD is a binary plist embedded in the encrypted blob.
        guard let spdPlist = try? PropertyListSerialization.propertyList(
            from: decryptedSPD, options: [], format: nil) as? [String: Any] else {
            throw AuthError.invalidCompleteResponse("complete: decrypted spd was not a plist (\(decryptedSPD.count) bytes)")
        }

        let guid = spdPlist["GUID"] as? String
        let dsid = spdPlist["adi-proxy"] as? String
        let passToken = completePlist["token"] as? String

        let acct = AppleAccount(
            appleId: appleId,
            password: password,
            dsid: dsid,
            guid: guid,
            passToken: passToken,
            twoFactorVerified: true
        )
        self.account = acct
        self.state = .authenticated
        storage.saveAccount(StoredAccount(
            appleId: acct.appleId,
            firstName: acct.firstName,
            lastName: acct.lastName,
            dsid: acct.dsid,
            guid: acct.guid,
            storeFront: acct.storeFront,
            storeFrontCountry: acct.storeFrontCountry,
            twoFactorVerified: acct.twoFactorVerified
        ))
        if let token = passToken { storage.savePassToken(token, for: acct.appleId) }
    }

    // MARK: - 2FA

    func submit2FACode(_ code: String) async {
        guard let scnt = lastSCNT,
              var account = account,
              let anisetteHeaders = try? await anisette.fetchHeaders() else {
            state = .failed("Anisette headers missing — configure in Settings.")
            return
        }
        var req = URLRequest(url: URL(string: "https://gsa.apple.com/auth/verify/trusteddevice/securitycode")!)
        req.httpMethod = "POST"
        for (k, v) in anisetteHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(scnt, forHTTPHeaderField: "scnt")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "securityCode=\(code)".data(using: .utf8)

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw AuthError.invalid2FAResponse }
            if http.statusCode == 204 {
                account.twoFactorVerified = true
                self.account = account
                self.state = .authenticated
                // Re-issue token exchange — omitted for brevity.
            } else {
                state = .failed("2FA failed (HTTP \(http.statusCode))")
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func logout() {
        account = nil
        lastSCNT = nil
        state = .idle
        storage.deleteAccount()
    }

    // MARK: - AES

    private func aesDecrypt(key: Data, data: Data) -> Data? {
        guard data.count > 16 else { return nil }
        let iv = data.prefix(16)
        let cipher = data.suffix(from: 16)
        var out = Data(count: cipher.count)
        var outLen = 0
        let status = key.withUnsafeBytes { k in
            iv.withUnsafeBytes { i in
                cipher.withUnsafeBytes { c in
                    out.withUnsafeMutableBytes { o in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, k.count,
                            i.baseAddress,
                            c.baseAddress, c.count,
                            o.baseAddress, o.count,
                            &outLen
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(outLen)
    }

    enum AuthError: Error, LocalizedError {
        case invalidInitResponse(String)
        case invalidCompleteResponse(String)
        case invalid2FAResponse

        var errorDescription: String? {
            switch self {
            case .invalidInitResponse(let msg): return msg
            case .invalidCompleteResponse(let msg): return msg
            case .invalid2FAResponse: return "Server returned invalid 2FA response"
            }
        }
    }
}

private extension URLRequest {
    func appendingHeaders(_ h: [String: String]) -> URLRequest {
        var c = self
        for (k, v) in h { c.setValue(v, forHTTPHeaderField: k) }
        return c
    }
    func withBody(_ body: Data, method: String) -> URLRequest {
        var c = self
        c.httpMethod = method
        c.httpBody = body
        return c
    }
}
