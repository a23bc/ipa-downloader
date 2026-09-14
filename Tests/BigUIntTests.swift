import XCTest
@testable import IPADownloader

final class BigUIntTests: XCTestCase {
    func testAdditionSmall() {
        XCTAssertEqual((BigUInt(3) + BigUInt(5)), BigUInt(8))
        XCTAssertEqual((BigUInt(UInt64(0xFFFFFFFF) + 1) + BigUInt(1)),
                       BigUInt(limbs: [0x00000001, 0x00000001]))
    }

    func testSubtractionSmall() {
        XCTAssertEqual((BigUInt(10) - BigUInt(3)), BigUInt(7))
    }

    func testMultiplication() {
        XCTAssertEqual((BigUInt(6) * BigUInt(7)), BigUInt(42))
        XCTAssertEqual((BigUInt(1_000_000) * BigUInt(1_000_000)), BigUInt(1_000_000_000_000))
    }

    func testModulo() {
        XCTAssertEqual(BigUInt(10).mod(BigUInt(7)), BigUInt(3))
        XCTAssertEqual(BigUInt(21).mod(BigUInt(7)), BigUInt(0))
    }

    func testPowMod() {
        // 2^10 mod 17 = 1024 mod 17 = 4
        XCTAssertEqual(BigUInt(2).powMod(BigUInt(10), BigUInt(17)), BigUInt(4))
    }

    func testBigEndianRoundTrip() {
        let original = BigUInt(bigEndian: Data([0x01, 0x00, 0x00, 0x00])) // 16777216
        XCTAssertEqual(original, BigUInt(16777216))
        let bytes = original.bigEndianData()
        XCTAssertEqual(bytes, Data([0x01, 0x00, 0x00, 0x00]))
    }

    func testModInverse() {
        // 3 * x ≡ 1 (mod 11)  →  x = 4
        XCTAssertEqual(BigUInt(3).modInverse(BigUInt(11)), BigUInt(4))
    }
}

final class CryptoTests: XCTestCase {
    func testSHA256KnownVector() {
        let digest = Crypto.sha256(Data("hello".utf8))
        XCTAssertEqual(digest.map { String(format: "%02x", $0) }.joined(),
                       "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    func testHMACSHA1KnownVector() {
        let mac = Crypto.hmacSHA1(key: Data("key".utf8), msg: Data("The quick brown fox jumps over the lazy dog".utf8))
        XCTAssertEqual(mac.map { String(format: "%02x", $0) }.joined(),
                       "de7c9b85b8b78aa6bc8a7a36f70a90701c9db4d9")
    }

    func testPBKDF2() {
        let derived = Crypto.pbkdf2HMACSHA1(password: Data("password".utf8),
                                            salt: Data("salt".utf8),
                                            iterations: 1,
                                            keyLength: 20)
        XCTAssertNotNil(derived)
        XCTAssertEqual(derived?.count, 20)
    }
}
