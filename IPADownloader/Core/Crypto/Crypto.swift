import Foundation
import CryptoKit
import CommonCrypto

/// Cryptographic helpers used by the SRP-6a client (Apple's GSA auth flow).
/// All functions here are pure / stateless so they're trivially testable.

enum Crypto {
    /// SHA-256 of the concatenated input bytes.
    static func sha256(_ data: Data...) -> Data {
        var hasher = SHA256()
        for chunk in data { hasher.update(data: chunk) }
        return Data(hasher.finalize())
    }

    /// SHA-1 of the concatenated input bytes (one-shot).
    static func sha1(_ data: Data...) -> Data {
        var ctx = CC_SHA1_CTX()
        CC_SHA1_Init(&ctx)
        for d in data {
            d.withUnsafeBytes { _ = CC_SHA1_Update(&ctx, $0.baseAddress, CC_LONG(d.count)) }
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        _ = CC_SHA1_Final(&digest, &ctx)
        return Data(digest)
    }

    /// HMAC-SHA-256(key, msg).
    static func hmacSHA256(key: Data, msg: Data) -> Data {
        let hmac = HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key))
        return Data(hmac)
    }

    /// HMAC-SHA-1(key, msg).
    static func hmacSHA1(key: Data, msg: Data) -> Data {
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        key.withUnsafeBytes { keyPtr in
            msg.withUnsafeBytes { msgPtr in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1),
                       keyPtr.baseAddress, key.count,
                       msgPtr.baseAddress, msg.count,
                       &mac)
            }
        }
        return Data(mac)
    }

    /// PBKDF2-HMAC-SHA1(password, salt, iterations, dkLen) — Apple's GSA flow
    /// uses HMAC-SHA1 regardless of the SHA-256 used elsewhere in the protocol.
    static func pbkdf2HMACSHA1(password: Data,
                               salt: Data,
                               iterations: UInt32,
                               keyLength: Int) -> Data? {
        var derived = [UInt8](repeating: 0, count: keyLength)
        let status = password.withUnsafeBytes { passwordPtr -> Int32 in
            salt.withUnsafeBytes { saltPtr -> Int32 in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                    password.count,
                    saltPtr.baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    iterations,
                    &derived,
                    keyLength
                )
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(derived)
    }

    /// Random bytes from the system CSPRNG.
    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    /// Hex string representation of `Data`.
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
