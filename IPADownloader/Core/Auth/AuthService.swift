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
        do {
            try await performSRPLogin(appleId: appleId, password: password)
        } catch {
            state = .failed(error.localizedDescription)
        }
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
        let initReq = URLRequest(url: URL(string: "https://gsa.apple.com/grandslam/GsService2")!)
            .appendingHeaders(initHeaders)
            .withBody(initBody, method: "POST")
        let (initData, _) = try await URLSession.shared.data(for: initReq)

        // Parse Init response to extract `sp` (salt) and `B`.
        guard let plist = try PropertyListSerialization.propertyList(
            from: initData, options: [], format: nil) as? [String: Any],
              let sp = plist["sp"] as? String,
              let saltData = Data(base64Encoded: sp),
              let B64 = plist["B"] as? String,
              let BData = Data(base64Encoded: B64) else {
            throw AuthError.invalidInitResponse
        }
        let B = BigUInt(bigEndian: BData)

        // Step 4: Compute M1.
        let (M1, K) = srp.computeM1(
            username: appleId,
            password: password,
            salt: saltData,
            B: B,
            deviceID: deviceID
        )

        // Step 5: Send Complete request.
        let completeBody = GSARequestBuilder.completeBody(
            appleId: appleId, M1: M1, A: srp.A, deviceID: deviceID
        )
        var completeHeaders = anisetteHeaders
        completeHeaders["Content-Type"] = "application/x-apple-plist"
        let completeReq = URLRequest(url: URL(string: "https://gsa.apple.com/grandslam/GsService2")!)
            .appendingHeaders(completeHeaders)
            .withBody(completeBody, method: "POST")
        let (completeData, completeResp) = try await URLSession.shared.data(for: completeReq)

        guard let completePlist = try PropertyListSerialization.propertyList(
            from: completeData, options: [], format: nil) as? [String: Any] else {
            throw AuthError.invalidCompleteResponse
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
            throw AuthError.invalidCompleteResponse
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
            throw AuthError.invalidCompleteResponse
        }

        // Parse SPD for GUID / DSID / passToken.
        // SPD is a binary plist embedded in the encrypted blob.
        guard let spdPlist = try? PropertyListSerialization.propertyList(
            from: decryptedSPD, options: [], format: nil) as? [String: Any] else {
            throw AuthError.invalidCompleteResponse
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
        case invalidInitResponse
        case invalidCompleteResponse
        case invalid2FAResponse

        var errorDescription: String? {
            switch self {
            case .invalidInitResponse: return "Server returned invalid SRP init response"
            case .invalidCompleteResponse: return "Server returned invalid auth-complete response"
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
