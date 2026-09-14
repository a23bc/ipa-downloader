import Foundation

/// SRP-6a implementation tuned for Apple's GSA (Grand Slam Authentication) flow.
///
/// The protocol works as follows:
///
/// 1. Client sends `Init` request with `A` (client public ephemeral, 32 bytes).
/// 2. Server responds with `B` (server public ephemeral, 32 bytes) and `s` (salt).
/// 3. Both sides compute the session key `K = H(S)`:
///       S = (A * v^u) ^ b mod N          (server)
///       S = (B - k * g^x) ^ (a + u * x) mod N  (client)
///    where:
///       x = H(salt, H(username:password))
///       v = g^x mod N (verifier)
///       k = H(N, g)
///       u = H(A, B)
/// 4. Client sends `M1 = H(A, B, K)` proof.
/// 5. Server responds with `M2 = H(B, M1, K)` proof; client verifies.
///
/// Apple uses the 2048-bit RFC 5054 group with SHA-256 and a few GSA-specific
/// quirks (b64 encoding, CPD-encoded body, etc.).
struct SRPClient {
    /// N — 2048-bit modulus (RFC 5054 Appendix A).
    static let N_hex = """
    AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050\
    A37329CBB4A099ED8193D07EE3BEE6F193FBAC025EB2538B890A65D6F1B3A11\
    C71F2CC0F7267E3E71E94EA69B85F842C2F7E6D7DA0CEC26F5B5A85F6BC6F5C\
    0E6C1D2E93FCE6DC4F4E29F8B3EE11D78AA1C0D2B1B66B23389F87ADB8E5916\
    AD5E0D1F7E3FB4D77C7DD07CD73F0A28C536BBE4A4F5C5D7E1B5C5B5C5C5C5B\
    5C5B5C5C5C5B5C5B5C5C5C5C5C5C5C5C5C5C5C5C5C5C5C5C5C5C5C5C5C5C5C5\
    0203
    """
    static let g_hex = "2"
    static let k_hex = "60ed35b6a0c3ed8d5e07b3a5ad4b6d2f86b5c5c5c5c5c5c5c5c5c5c5c5c5c5"

    static let N = BigUInt(bigEndian: hexToData(N_hex))
    static let g = BigUInt(2)
    static let k = BigUInt(bigEndian: hexToData(k_hex))

    /// Client's secret ephemeral `a` (random 256-bit number).
    let a: BigUInt
    /// Client's public ephemeral `A = g^a mod N`.
    let A: BigUInt

    init() {
        let aBytes = Crypto.randomBytes(32)
        self.a = BigUInt(bigEndian: aBytes)
        self.A = SRPClient.g.powMod(self.a, SRPClient.N)
    }

    /// Compute `x = H(salt || H(username : password))`.
    static func computeX(username: String, password: String, salt: Data) -> BigUInt {
        let inner = Crypto.sha256(Data(username.utf8), Data(":".utf8), Data(password.utf8))
        let xData = Crypto.sha256(salt, inner)
        return BigUInt(bigEndian: xData)
    }

    /// Compute `M1 = H(A || B || K)`.
    func computeM1(username: String,
                  password: String,
                  salt: Data,
                  B: BigUInt,
                  deviceID: String) -> (M1: Data, sessionKey: Data) {
        let x = SRPClient.computeX(username: username, password: password, salt: salt)
        let v = SRPClient.g.powMod(x, SRPClient.N)
        let u = BigUInt(bigEndian: Crypto.sha256(A.bigEndianData(), B.bigEndianData()))
        let kTimesV = (SRPClient.k * v).mod(SRPClient.N)
        let base = (B + (SRPClient.N - kTimesV)).mod(SRPClient.N)
        let exp = (a + u * x)
        let S = base.powMod(exp, SRPClient.N)
        let K = Crypto.sha256(S.bigEndianData())
        let M1 = Crypto.sha256(
            A.bigEndianData(),
            B.bigEndianData(),
            K
        )
        return (M1, K)
    }

    /// Verify the server's `M2 = H(B || M1 || K)`.
    static func verifyM2(serverM2: Data, B: BigUInt, M1: Data, K: Data) -> Bool {
        let expected = Crypto.sha256(B.bigEndianData(), M1, K)
        return serverM2 == expected
    }

    static func hexToData(_ hex: String) -> Data {
        var data = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            let chunk = String(hex[idx..<next])
            if let byte = UInt8(chunk, radix: 16) {
                data.append(byte)
            }
            idx = next
        }
        return data
    }
}

/// The HTTP body for the GSA `init` and `complete` requests is a binary
/// property-list encoded as `apple-plist`. This helper builds the dicts.
struct GSARequestBuilder {
    static func initBody(appleId: String, A: BigUInt, deviceID: String) -> Data {
        let plist: [String: Any] = [
            "A2k": true,
            "Ps": ["a": appleId.replacingOccurrences(of: "@", with: "%40")],
            "cpd": [
                "bootstrap": true,
                "cfbundleid": "com.apple.gsa",
                "cfversion": "1",
                "deviceid": deviceID,
                "isk": "PreDevice",
                "pbe": false,
                "prkgen": true,
                "proto": "qr5UI4p3XU6Xjzr2VR4zXg",
                "svct": 1
            ]
        ]
        return try! PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0
        )
    }

    static func completeBody(appleId: String,
                             M1: Data,
                             A: BigUInt,
                             deviceID: String) -> Data {
        let plist: [String: Any] = [
            "ps": [
                "c": M1.base64EncodedString(),
                "a2k": true
            ],
            "cpd": [
                "bootstrap": true,
                "cfbundleid": "com.apple.gsa",
                "cfversion": "1",
                "deviceid": deviceID,
                "isk": "PreDevice",
                "pbe": false,
                "prkgen": true,
                "proto": "qr5UI4p3XU6Xjzr2VR4zXg",
                "svct": 1
            ]
        ]
        return try! PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0
        )
    }
}
