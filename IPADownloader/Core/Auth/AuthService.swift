import Foundation
import CommonCrypto

/// High-level authentication service implementing ipatool v1.x's iTunes Store
/// `authenticate` flow.
///
/// Flow (much simpler than GSA/SRP — no crypto, no ActionSignature):
///
/// 1. Fetch anisette headers from local sidecar server.
/// 2. POST a simple XML plist to `/WebObjects/MZFinance.woa/wa/authenticate`
///    with body:
///       appleId, attempt=1, guid, password, rmp=0, why=signIn
/// 3. Apple responds with one of:
///    - Success: plist containing `directory-services-id` (DSID), `passwordToken`,
///      `accountInfo`, and a `mki` (machine key identifier) for subsequent
///      purchase requests.
///    - 2FA required: `messageType = "2FARequired"` — request security code.
///    - Failure: `failureType` + `mmeErrorMessage`.
///
/// 4. If 2FA, submit the 6-digit code to the same endpoint with `why=sendCode`.
///
/// Reference: github.com/majd/ipatool (v1.x — before SAP was added in v2.x).
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

    private let anisette = AnisetteHeadersProvider.shared
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
            try await performLogin(appleId: appleId, password: password)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func performLogin(appleId: String, password: String) async throws {
        // Step 1: Fetch anisette headers.
        let anisetteHeaders = try await anisette.fetchHeaders()

        // guid = a fake MAC address (uppercase hex, 12 chars). ipatool uses
        // the device's actual MAC; on iOS we don't have that, so we derive
        // a stable one from the X-Mme-Device-Id UUID.
        let deviceID = anisetteHeaders["X-Mme-Device-Id"] ?? UUID().uuidString
        let guid = Self.deriveGUID(from: deviceID)

        // Step 2: POST to /authenticate
        let body = Self.buildAuthenticateBody(
            appleId: appleId,
            password: password,
            guid: guid
        )
        var headers = anisetteHeaders
        headers["Content-Type"] = "application/x-apple-plist"
        headers["Accept"] = "*/*"
        headers["Accept-Language"] = "en-us"
        headers["User-Agent"] = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"

        var req = URLRequest(url: URL(string: "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate")!)
        req.httpMethod = "POST"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        req.timeoutInterval = 30

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw AuthError.invalidResponse("non-HTTP response")
        }

        // Parse the plist response.
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any] else {
            let bodyPreview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary \(data.count) bytes>"
            throw AuthError.invalidResponse("""
                HTTP \(http.statusCode), response was not a plist.
                Content-Type: \(http.value(forHTTPHeaderField: "Content-Type") ?? "<none>")
                Body preview: \(bodyPreview)
                """)
        }

        // Check for 2FA requirement.
        if let messageType = plist["messageType"] as? String,
           messageType.lowercased().contains("2fa") || messageType.lowercased().contains("secondary") {
            // Persist partial account; will complete after 2FA.
            self.account = AppleAccount(appleId: appleId, password: password, guid: guid)
            self.state = .awaiting2FA
            return
        }

        // Check for explicit failure.
        if let failureType = plist["failureType"] as? String, !failureType.isEmpty {
            let msg = (plist["mmeErrorMessage"] as? String)
                   ?? (plist["errorMessage"] as? String)
                   ?? failureType
            throw AuthError.invalidResponse("""
                Login failed: \(failureType)
                \(msg)
                """)
        }

        // Success path: extract DSID + token.
        guard let dsid = (plist["directory-services-id"] as? String)
                       ?? ((plist["accountInfo"] as? [String: Any])?["directory-services-id"] as? String) else {
            // Dump the entire plist so we can see what Apple returned.
            throw AuthError.invalidResponse("""
                Login response did not contain DSID.
                Plist keys: \(plist.keys.sorted())
                Full plist: \(plist)
                """)
        }

        let passToken = (plist["passwordToken"] as? String)
                     ?? ((plist["accountInfo"] as? [String: Any])?["passwordToken"] as? String)
        let firstName = (plist["accountInfo"] as? [String: Any])?["firstName"] as? String
        let lastName = (plist["accountInfo"] as? [String: Any])?["lastName"] as? String
        let storeFront = (plist["accountInfo"] as? [String: Any])?["storeFront"] as? String

        let acct = AppleAccount(
            appleId: appleId,
            password: password,
            firstName: firstName,
            lastName: lastName,
            dsid: dsid,
            guid: guid,
            passToken: passToken,
            storeFront: storeFront,
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
                                   password: (account.password ?? "") + code.replacingOccurrences(of: " ", with: ""))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func logout() {
        account = nil
        state = .idle
        storage.deleteAccount()
    }

    // MARK: - Helpers

    /// Derive a 12-char uppercase hex GUID (fake MAC address) from a UUID string.
    /// This must be stable across launches so Apple sees the same "device".
    static func deriveGUID(from uuidString: String) -> String {
        let stripped = uuidString.replacingOccurrences(of: "-", with: "")
        // Take the first 12 hex chars, uppercase.
        return String(stripped.prefix(12)).uppercased()
    }

    /// Build the XML plist body for `/authenticate`.
    /// ipatool v1.x uses 6 top-level string keys.
    static func buildAuthenticateBody(appleId: String, password: String, guid: String) -> Data {
        let escapedAppleId = appleId
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        let escapedPassword = password
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>appleId</key><string>\(escapedAppleId)</string>
            <key>attempt</key><string>1</string>
            <key>guid</key><string>\(guid)</string>
            <key>password</key><string>\(escapedPassword)</string>
            <key>rmp</key><string>0</string>
            <key>why</key><string>signIn</string>
        </dict>
        </plist>
        """
        return xml.data(using: .utf8) ?? Data()
    }

    enum AuthError: Error, LocalizedError {
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse(let msg): return msg
            }
        }
    }
}
