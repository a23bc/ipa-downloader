import Foundation

/// Authenticated Apple ID account information.
struct AppleAccount: Codable, Equatable {
    /// The Apple ID email address.
    var appleId: String
    /// The first name extracted from the directory services profile.
    var firstName: String?
    /// The last name extracted from the directory services profile.
    var lastName: String?
    /// The DSID (Directory Services Identifier), e.g. `1234567890`.
    var dsid: String?
    /// The GUID returned by `authenticate` after SRP succeeds.
    var guid: String?
    /// The `passToken` returned after a successful login; reused for token-based auth.
    var passToken: String?
    /// The store front identifier, e.g. `143441-19,29`. Determines region pricing.
    var storeFront: String?
    /// The country code of the store front (e.g. `US`, `CN`).
    var storeFrontCountry: String?
    /// The password (kept in memory only; never persisted to disk).
    var password: String?
    /// Whether 2FA has been completed for this account.
    var twoFactorVerified: Bool

    init(appleId: String,
         password: String? = nil,
         firstName: String? = nil,
         lastName: String? = nil,
         dsid: String? = nil,
         guid: String? = nil,
         passToken: String? = nil,
         storeFront: String? = nil,
         storeFrontCountry: String? = nil,
         twoFactorVerified: Bool = false) {
        self.appleId = appleId
        self.password = password
        self.firstName = firstName
        self.lastName = lastName
        self.dsid = dsid
        self.guid = guid
        self.passToken = passToken
        self.storeFront = storeFront
        self.storeFrontCountry = storeFrontCountry
        self.twoFactorVerified = twoFactorVerified
    }

    var displayName: String {
        let parts = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        return parts.isEmpty ? appleId : parts
    }

    var isFullyAuthenticated: Bool {
        guid != nil && (passToken != nil || twoFactorVerified)
    }
}

/// Persistable form of `AppleAccount` for Keychain storage.
/// `password` and `passToken` are stored separately inside Keychain; everything
/// else goes into UserDefaults.
struct StoredAccount: Codable, Equatable {
    var appleId: String
    var firstName: String?
    var lastName: String?
    var dsid: String?
    var guid: String?
    var storeFront: String?
    var storeFrontCountry: String?
    var twoFactorVerified: Bool
}
