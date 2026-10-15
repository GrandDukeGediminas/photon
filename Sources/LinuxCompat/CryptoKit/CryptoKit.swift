// Linux stand-in for Apple's CryptoKit (docs/linux-port.md §4): SHA-256 only, the hash photon2 keys its shader and
// video caches with. Plain FIPS 180-4; digests are identical to CryptoKit's.

import Foundation

public struct SHA256Digest: Sequence, Hashable, CustomStringConvertible {
    public let bytes: [UInt8]
    public static let byteCount = 32
    public func makeIterator() -> IndexingIterator<[UInt8]> { bytes.makeIterator() }
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R { try bytes.withUnsafeBytes(body) }
    public var description: String { "SHA256 digest: " + bytes.map { String(format: "%02x", $0) }.joined() }
}

public struct SHA256 {
    public typealias Digest = SHA256Digest
    public static let byteCount = 32
    public static let blockByteCount = 64

    private var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    public init() {}

    public static func hash<D: DataProtocol>(data: D) -> SHA256Digest {
        var s = SHA256()
        s.update(data: data)
        return s.finalize()
    }

    public mutating func update<D: DataProtocol>(data: D) {
        for region in data.regions { region.withUnsafeBytes { update(bufferPointer: $0) } }
    }

    public mutating func update(bufferPointer raw: UnsafeRawBufferPointer) {
        length &+= UInt64(raw.count)
        var i = 0
        if !buffer.isEmpty {
            let take = min(64 - buffer.count, raw.count)
            buffer.append(contentsOf: raw[0..<take])
            i = take
            if buffer.count == 64 {
                buffer.withUnsafeBytes { block($0.baseAddress!) }
                buffer.removeAll(keepingCapacity: true)
            }
        }
        while i + 64 <= raw.count {
            block(raw.baseAddress! + i)
            i += 64
        }
        if i < raw.count { buffer.append(contentsOf: raw[i..<raw.count]) }
    }

    public func finalize() -> SHA256Digest {
        var s = self
        let bits = s.length &* 8
        var pad: [UInt8] = [0x80]
        let rem = (s.buffer.count + 1) % 64
        pad += [UInt8](repeating: 0, count: rem <= 56 ? 56 - rem : 120 - rem)
        for k in (0..<8).reversed() { pad.append(UInt8(truncatingIfNeeded: bits >> (UInt64(k) * 8))) }
        let len = s.length
        pad.withUnsafeBytes { s.update(bufferPointer: $0) }
        s.length = len
        var out: [UInt8] = []
        out.reserveCapacity(32)
        for w in s.h { out += [UInt8(w >> 24), UInt8(truncatingIfNeeded: w >> 16), UInt8(truncatingIfNeeded: w >> 8), UInt8(truncatingIfNeeded: w)] }
        return SHA256Digest(bytes: out)
    }

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private mutating func block(_ p: UnsafeRawPointer) {
        @inline(__always) func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for t in 0..<16 {
            let b = p + t * 4
            w[t] = UInt32(b.load(as: UInt8.self)) << 24 | UInt32((b + 1).load(as: UInt8.self)) << 16
                | UInt32((b + 2).load(as: UInt8.self)) << 8 | UInt32((b + 3).load(as: UInt8.self))
        }
        for t in 16..<64 {
            let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
            let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
            w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for t in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ s1 &+ ch &+ Self.k[t] &+ w[t]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
    }
}
