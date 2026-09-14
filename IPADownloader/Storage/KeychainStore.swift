import Foundation
import Security

/// Keychain-backed storage for the Apple ID account, password, and passToken.
/// All persisted data lives in `kSecClassGenericPassword` keyed by `account`.
final class KeychainStore {
    static let shared = KeychainStore()

    private let service = "app.ipatool.downloader"
    private let accountKey = "current-account"
    private let passwordKeyPrefix = "password-"
    private let tokenKeyPrefix = "token-"

    // MARK: - Account

    func saveAccount(_ account: StoredAccount) {
        if let data = try? JSONEncoder().encode(account) {
            write(key: accountKey, data: data)
        }
    }

    func loadAccount() -> StoredAccount? {
        guard let data = read(key: accountKey) else { return nil }
        return try? JSONDecoder().decode(StoredAccount.self, from: data)
    }

    func deleteAccount() {
        delete(key: accountKey)
    }

    // MARK: - Password / Token

    func savePassword(_ password: String, for appleId: String) {
        write(key: passwordKeyPrefix + appleId, data: Data(password.utf8))
    }

    func loadPassword(for appleId: String) -> String? {
        guard let data = read(key: passwordKeyPrefix + appleId) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func savePassToken(_ token: String, for appleId: String) {
        write(key: tokenKeyPrefix + appleId, data: Data(token.utf8))
    }

    func loadPassToken(for appleId: String) -> String? {
        guard let data = read(key: tokenKeyPrefix + appleId) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Core

    private func write(key: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    private func read(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        SecItemCopyMatching(query as CFDictionary, &item)
        return item as? Data
    }

    private func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
