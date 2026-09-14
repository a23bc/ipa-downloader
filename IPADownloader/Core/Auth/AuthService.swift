import Foundation
import CommonCrypto

/// High-level authentication service implementing ipatool v1.x's iTunes Store
/// `authenticate` flow.
///
/// This is the verified protocol from ipatool v1.0.0–v1.1.4 (Swift sources):
///
/// 1. POST XML plist to `https://p25-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate?guid=<GUID>`
/// 2. Headers: ONLY `User-Agent: Configurator/2.15 ...` + `Content-Type: application/x-www-form-urlencoded`
///    (yes, the body is XML plist but Content-Type lies — this is ipatool's quirk
///     that Apple's edge CDN expects. Sending `application/x-apple-plist` → 404/500.)
///    Do NOT send anisette headers on this request.
/// 3. Body keys (all strings):
///    - appleId, attempt="4" (first try) or "2" (with 2FA), createSession="true",
///      guid=<same as URL>, password, rmp="0", why="signIn"
/// 4. On `failureType=1` (codeRequired): retry with host `p71-`, attempt="2",
///    password+code appended.
/// 5. On `-5000` (invalidCredentials, intermittent): retry same request once.
/// 6. Success: extract `dsPersonId` (DSID) + `passwordToken` + `accountInfo`.
@MainActor
final class AuthService: ObservableObject {
    enum State: Equatable {
        case idle
        case authenticating
        case awaiting2FA
        case authenticated
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var account: AppleAccount?

    private let storage = KeychainStore.shared

    init() {
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
        state = .authenticating
        do {
            try await performLogin(appleId: appleId, password: password, twoFACode: nil)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func performLogin(appleId: String,
                              password: String,
                              twoFACode: String?) async throws {
        // GUID = stable 12-char uppercase hex (fake MAC address).
        // Derive from a persisted UUID so it's stable across launches.
        let guid = Self.loadOrCreateGUID()

        // First attempt: host p25-, attempt="4", password only.
        // Second attempt (2FA): host p71-, attempt="2", password+code.
        let prefix = twoFACode == nil ? "p25" : "p71"
        let attempt = twoFACode == nil ? "4" : "2"
        let fullPassword = twoFACode.map { password + $0 } ?? password

        let urlString = "https://\(prefix)-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate?guid=\(guid)"
        guard let url = URL(string: urlString) else {
            throw AuthError.invalidResponse("Invalid URL: \(urlString)")
        }

        let body = Self.buildAuthenticateBody(
            appleId: appleId,
            attempt: attempt,
            guid: guid,
            password: fullPassword
        )

        // ipatool sends ONLY these two headers. Do NOT add anisette headers —
        // they belong on a different request flow entirely. Adding them here
        // causes Apple's edge CDN to return random 204/301/403/404/500 errors.
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Configurator/2.15 (Macintosh; OS X 11.0.0; 16G29) AppleWebKit/2603.3.8",
                     forHTTPHeaderField: "User-Agent")
        // CRITICAL: Content-Type is x-www-form-urlencoded even though body is XML plist.
        // Apple's edge CDN inspects this header before parsing the body.
        req.setValue("application/x-www-form-urlencoded",
                     forHTTPHeaderField: "Content-Type")
        // Leave Accept / Accept-Encoding / Accept-Language to URLSession defaults.
        req.httpBody = body
        req.timeoutInterval = 30

        // Apple intermittently returns -5000 invalidCredentials on first hit.
        // ipatool retries the identical request once before failing.
        var lastErr: Error?
        for attempt in 1...2 {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                try parseResponse(data: data, resp: resp, appleId: appleId,
                                  password: password, guid: guid)
                return
            } catch let err as AuthError where err.isCodeRequired() {
                // 2FA needed — switch to awaiting2FA state.
                self.account = AppleAccount(appleId: appleId, password: password, guid: guid)
                self.state = .awaiting2FA
                return
            } catch let err as AuthError where err.isInvalidCredentials() {
                lastErr = err
                if attempt == 2 { break }
                // Wait briefly then retry once.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            } catch {
                throw error
            }
        }
        throw lastErr ?? AuthError.invalidResponse("Unknown error")
    }

    /// Parse the iTunes Store /authenticate XML plist response.
    private func parseResponse(data: Data,
                                resp: URLResponse,
                                appleId: String,
                                password: String,
                                guid: String) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw AuthError.invalidResponse("non-HTTP response")
        }
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any] else {
            let bodyPreview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary \(data.count) bytes>"
            throw AuthError.invalidResponse("""
                HTTP \(http.statusCode), response was not a plist.
                Content-Type: \(http.value(forHTTPHeaderField: "Content-Type") ?? "<none>")
                Body preview: \(bodyPreview)
                """)
        }

        // Check for 2FA requirement (failureType=1, customerMessage contains
        // "verification code" or similar).
        if let failureType = plist["failureType"] as? String,
           failureType == "1" {
            throw AuthError.codeRequired
        }
        // Some responses use int.
        if let failureType = plist["failureType"] as? Int,
           failureType == 1 {
            throw AuthError.codeRequired
        }

        // Other failures.
        if let failureType = plist["failureType"] as? String, !failureType.isEmpty,
           failureType != "0" {
            let customerMsg = (plist["customerMessage"] as? String) ?? ""
            let mmeMsg = (plist["mmeErrorMessage"] as? String) ?? ""
            // -5000 = intermittent invalidCredentials (handled by caller retry).
            if failureType == "-5000" {
                throw AuthError.invalidCredentials
            }
            throw AuthError.invalidResponse("""
                Login failed: failureType=\(failureType)
                \(customerMsg)
                \(mmeMsg)
                """)
        }
        if let failureType = plist["failureType"] as? Int, failureType != 0 {
            let customerMsg = (plist["customerMessage"] as? String) ?? ""
            if failureType == -5000 {
                throw AuthError.invalidCredentials
            }
            throw AuthError.invalidResponse("""
                Login failed: failureType=\(failureType)
                \(customerMsg)
                """)
        }

        // Success path.
        guard let dsid = plist["dsPersonId"] as? String else {
            throw AuthError.invalidResponse("""
                Login response did not contain dsPersonId.
                Plist keys: \(plist.keys.sorted())
                Full plist: \(plist)
                """)
        }

        let passToken = plist["passwordToken"] as? String
        let accountInfo = plist["accountInfo"] as? [String: Any]
        let firstName = (accountInfo?["address"] as? [String: Any])?["firstName"] as? String
        let lastName = (accountInfo?["address"] as? [String: Any])?["lastName"] as? String

        let acct = AppleAccount(
            appleId: appleId,
            password: password,
            firstName: firstName,
            lastName: lastName,
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
        guard let account = account else {
            state = .failed("No account in progress")
            return
        }
        do {
            try await performLogin(appleId: account.appleId,
                                   password: account.password ?? "",
                                   twoFACode: code.replacingOccurrences(of: " ", with: ""))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func logout() {
        account = nil
        state = .idle
        storage.deleteAccount()
    }

    // MARK: - GUID persistence

    /// Load or create a stable 12-char uppercase hex GUID (fake MAC address).
    /// Persisted in UserDefaults so Apple sees the same "device" across launches.
    private static let guidKey = "auth.guid"
    static func loadOrCreateGUID() -> String {
        if let existing = UserDefaults.standard.string(forKey: guidKey) {
            return existing
        }
        // Generate 6 random bytes, format as 12 uppercase hex chars.
        var bytes = [UInt8](repeating: 0, count: 6)
        _ = SecRandomCopyBytes(kSecRandomDefault, 6, &bytes)
        let guid = bytes.map { String(format: "%02X", $0) }.joined()
        UserDefaults.standard.set(guid, forKey: guidKey)
        return guid
    }

    /// Build the XML plist body for /authenticate.
    /// All values are strings (per ipatool).
    static func buildAuthenticateBody(appleId: String,
                                       attempt: String,
                                       guid: String,
                                       password: String) -> Data {
        let escapedAppleId = Self.escapeXML(appleId)
        let escapedPassword = Self.escapeXML(password)
        let plist: [String: String] = [
            "appleId":       escapedAppleId,
            "attempt":       attempt,
            "createSession": "true",
            "guid":          guid,
            "password":      escapedPassword,
            "rmp":           "0",
            "why":           "signIn"
        ]
        // Serialize as XML plist.
        return (try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
    }

    private static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    enum AuthError: Error, LocalizedError {
        case invalidResponse(String)
        case codeRequired
        case invalidCredentials

        var errorDescription: String? {
            switch self {
            case .invalidResponse(let msg): return msg
            case .codeRequired: return "Two-factor authentication required."
            case .invalidCredentials: return "Invalid credentials (Apple returned -5000)."
            }
        }

        func isCodeRequired() -> Bool {
            if case .codeRequired = self { return true }
            return false
        }
        func isInvalidCredentials() -> Bool {
            if case .invalidCredentials = self { return true }
            return false
        }
    }
}
