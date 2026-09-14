import Foundation

/// Minimal big-unsigned-integer used only for the SRP-6a math inside Apple's
/// GSA authentication flow. Not a general-purpose BigInt — it implements only
/// the operations needed (`mod`, `+`, `*`, `pow mod`, inverse mod) and uses a
/// `UInt32` little-endian limb representation.
///
/// 2048-bit SRP groups (the only ones Apple uses today) cost ~64 limbs per
/// number; a single `pow` is ~2k modular multiplications, which is fast
/// enough (< 200ms on an iPhone 8) since the entire computation runs once per
/// authentication.
struct BigUInt {
    /// Limbs, little-endian: `limbs[0]` is the least-significant 32 bits.
    /// Trailing zero limbs are stripped on construction.
    private(set) var limbs: [UInt32]

    init(_ limbs: [UInt32]) {
        var l = limbs
        while l.count > 1 && l.last == 0 { l.removeLast() }
        self.limbs = l
    }

    init(_ value: UInt32) { self.init([value]) }
    init(_ value: UInt64) {
        self.init([UInt32(value & 0xFFFFFFFF), UInt32(value >> 32)])
    }

    /// Initialize from a big-endian `Data` buffer (the conventional format for
    /// SRP parameters exchanged on the wire).
    init(bigEndian data: Data) {
        // Strip leading zero bytes (used as sign byte in many ASN.1 encodings).
        var bytes = Array(data)
        while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
        // Pad to multiple of 4.
        while bytes.count % 4 != 0 { bytes.insert(0, at: 0) }
        var limbs: [UInt32] = []
        limbs.reserveCapacity(bytes.count / 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let v = (UInt32(bytes[i])     << 24)
                   | (UInt32(bytes[i + 1]) << 16)
                   | (UInt32(bytes[i + 2]) << 8)
                   |  UInt32(bytes[i + 3])
            limbs.append(v)
        }
        self.init(limbs.reversed())
    }

    /// Big-endian `Data` representation (what gets sent over the wire).
    func bigEndianData(strippingLeadingZeros: Bool = false) -> Data {
        if limbs.isEmpty { return Data([0]) }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(limbs.count * 4)
        for limb in limbs.reversed() {
            bytes.append(UInt8((limb >> 24) & 0xFF))
            bytes.append(UInt8((limb >> 16) & 0xFF))
            bytes.append(UInt8((limb >> 8) & 0xFF))
            bytes.append(UInt8(limb & 0xFF))
        }
        var out = bytes
        if strippingLeadingZeros {
            while out.count > 1 && out.first == 0 { out.removeFirst() }
        }
        return Data(out)
    }

    var isZero: Bool { limbs.count == 1 && limbs[0] == 0 }
    var bitWidth: Int { limbs.count * 32 }

    // MARK: - Comparison

    static func == (lhs: BigUInt, rhs: BigUInt) -> Bool { lhs.limbs == rhs.limbs }
    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count
        }
        for i in (0..<lhs.limbs.count).reversed() {
            if lhs.limbs[i] != rhs.limbs[i] { return lhs.limbs[i] < rhs.limbs[i] }
        }
        return false
    }
    static func > (lhs: BigUInt, rhs: BigUInt) -> Bool { rhs < lhs }
    static func >= (lhs: BigUInt, rhs: BigUInt) -> Bool { !(lhs < rhs) }
    static func <= (lhs: BigUInt, rhs: BigUInt) -> Bool { !(rhs < lhs) }

    // MARK: - Addition / Subtraction

    static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        let n = max(lhs.limbs.count, rhs.limbs.count)
        var result = [UInt32](repeating: 0, count: n)
        var carry: UInt64 = 0
        for i in 0..<n {
            let a = i < lhs.limbs.count ? UInt64(lhs.limbs[i]) : 0
            let b = i < rhs.limbs.count ? UInt64(rhs.limbs[i]) : 0
            let sum = a + b + carry
            result[i] = UInt32(sum & 0xFFFFFFFF)
            carry = sum >> 32
        }
        if carry > 0 { result.append(UInt32(carry)) }
        return BigUInt(result)
    }

    static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        precondition(lhs >= rhs, "BigUInt: subtraction would be negative")
        var result = [UInt32](repeating: 0, count: lhs.limbs.count)
        var borrow: Int64 = 0
        for i in 0..<lhs.limbs.count {
            let a = Int64(lhs.limbs[i])
            let b = i < rhs.limbs.count ? Int64(rhs.limbs[i]) : 0
            var diff = a - b - borrow
            if diff < 0 {
                diff += 1 << 32
                borrow = 1
            } else {
                borrow = 0
            }
            result[i] = UInt32(diff & 0xFFFFFFFF)
        }
        return BigUInt(result)
    }

    // MARK: - Multiplication

    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        if lhs.isZero || rhs.isZero { return BigUInt(0) }
        var result = [UInt32](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        for i in 0..<lhs.limbs.count {
            var carry: UInt64 = 0
            let a = UInt64(lhs.limbs[i])
            for j in 0..<rhs.limbs.count {
                let b = UInt64(rhs.limbs[j])
                let cur = UInt64(result[i + j]) + a * b + carry
                result[i + j] = UInt32(cur & 0xFFFFFFFF)
                carry = cur >> 32
            }
            if carry > 0 { result[i + rhs.limbs.count] += UInt32(carry) }
        }
        return BigUInt(result)
    }

    // MARK: - Bit shifts

    static func << (lhs: BigUInt, rhs: Int) -> BigUInt {
        precondition(rhs >= 0)
        if rhs == 0 { return lhs }
        let limbShift = rhs / 32
        let bitShift = rhs % 32
        var newLimbs = [UInt32](repeating: 0, count: limbShift)
        if bitShift == 0 {
            newLimbs.append(contentsOf: lhs.limbs)
        } else {
            var carry: UInt32 = 0
            for limb in lhs.limbs {
                let v = UInt64(limb) << bitShift
                newLimbs.append(UInt32(v & 0xFFFFFFFF) | carry)
                carry = UInt32(v >> 32)
            }
            if carry > 0 { newLimbs.append(carry) }
        }
        return BigUInt(newLimbs)
    }

    static func >> (lhs: BigUInt, rhs: Int) -> BigUInt {
        precondition(rhs >= 0)
        if rhs == 0 { return lhs }
        let limbShift = rhs / 32
        let bitShift = rhs % 32
        if limbShift >= lhs.limbs.count { return BigUInt(0) }
        var newLimbs = Array(lhs.limbs[limbShift...])
        if bitShift != 0 {
            var carry: UInt32 = 0
            for i in (0..<newLimbs.count).reversed() {
                let v = newLimbs[i]
                newLimbs[i] = (v >> bitShift) | carry
                carry = v << (32 - bitShift)
            }
        }
        return BigUInt(newLimbs)
    }

    // MARK: - Modulo

    /// `self % m` using bit-by-bit long division. O(bitWidth^2) — fine for 2048 bits.
    func mod(_ m: BigUInt) -> BigUInt {
        precondition(!m.isZero)
        if self < m { return self }
        var r = BigUInt(0)
        for i in (0..<bitWidth).reversed() {
            r = r << 1
            if bit(at: i) { r = r + BigUInt(1) }
            if r >= m { r = r - m }
        }
        return r
    }

    /// Bit at position `i` (LSB is bit 0).
    private func bit(at i: Int) -> Bool {
        let limb = i / 32
        let off = i % 32
        if limb >= limbs.count { return false }
        return (limbs[limb] >> off) & 1 == 1
    }

    // MARK: - Modular exponentiation & inverse

    /// `self^exp mod m` via square-and-multiply.
    func powMod(_ exp: BigUInt, _ m: BigUInt) -> BigUInt {
        var result = BigUInt(1)
        var base = self.mod(m)
        var e = exp
        let one = BigUInt(1)
        while e > BigUInt(0) {
            if (e.limbs[0] & 1) == 1 {
                result = (result * base).mod(m)
            }
            e = e >> 1
            if e > BigUInt(0) {
                base = (base * base).mod(m)
            }
        }
        return result
    }

    /// Modular inverse via extended Euclidean algorithm.
    /// Returns `x` such that `self * x ≡ 1 (mod m)`.
    func modInverse(_ m: BigUInt) -> BigUInt? {
        // Extended GCD with signed magnitudes.
        var (old_r, r) = (self.mod(m), m)
        var (old_s, s): (BigInt, BigInt) = (BigInt(sign: .plus, magnitude: BigUInt(1)),
                                            BigInt(sign: .plus, magnitude: BigUInt(0)))
        while !r.isZero {
            let q = old_r.div(r)
            (old_r, r) = (r, old_r - q * r)
            (old_s, s) = (s, old_s - BigInt(sign: .plus, magnitude: q) * s)
        }
        if old_r != BigUInt(1) { return nil }
        if old_s.sign == .minus {
            // Add m to make positive.
            return (BigInt(sign: .plus, magnitude: m) + old_s).magnitude
        }
        return old_s.magnitude.mod(m)
    }

    /// Truncated quotient `self / divisor` (we never need the remainder here
    /// since `mod` already produces it; this is only used inside `modInverse`).
    fileprivate func div(_ divisor: BigUInt) -> BigUInt {
        precondition(!divisor.isZero)
        if self < divisor { return BigUInt(0) }
        var q = BigUInt(0)
        var r = BigUInt(0)
        for i in (0..<bitWidth).reversed() {
            r = r << 1
            if bit(at: i) { r = r + BigUInt(1) }
            if r >= divisor {
                r = r - divisor
                // Set bit i in q.
                let limb = i / 32
                let off = i % 32
                while q.limbs.count <= limb { q.limbs.append(0) }
                q.limbs[limb] |= UInt32(1 << off)
            }
        }
        return BigUInt(q.limbs)
    }
}

/// Signed wrapper around `BigUInt` — only used internally by `modInverse`.
fileprivate struct BigInt: Equatable {
    enum Sign { case plus, minus }
    var sign: Sign
    var magnitude: BigUInt

    static func + (lhs: BigInt, rhs: BigInt) -> BigInt {
        if lhs.sign == rhs.sign {
            return BigInt(sign: lhs.sign, magnitude: lhs.magnitude + rhs.magnitude)
        }
        if lhs.magnitude >= rhs.magnitude {
            return BigInt(sign: lhs.sign, magnitude: lhs.magnitude - rhs.magnitude)
        }
        return BigInt(sign: rhs.sign, magnitude: rhs.magnitude - lhs.magnitude)
    }

    static func - (lhs: BigInt, rhs: BigInt) -> BigInt {
        let negRhs = BigInt(sign: rhs.sign == .plus ? .minus : .plus, magnitude: rhs.magnitude)
        return lhs + negRhs
    }

    static func * (lhs: BigInt, rhs: BigInt) -> BigInt {
        BigInt(sign: lhs.sign == rhs.sign ? .plus : .minus,
               magnitude: lhs.magnitude * rhs.magnitude)
    }
}
