import Foundation

/// Minimal PNG encoder (8-bit RGB or RGBA, zlib "stored" blocks): no image library needed on any platform.
public enum PNGWriter {
    public static func encode(rgba: [UInt8], width: Int, height: Int, keepAlpha: Bool) -> Data {
        let channels = keepAlpha ? 4 : 3
        var raw = [UInt8]()
        raw.reserveCapacity((width * channels + 1) * height)
        for y in 0..<height {
            raw.append(0) // filter: none
            for x in 0..<width {
                let i = (y * width + x) * 4
                raw.append(rgba[i]); raw.append(rgba[i + 1]); raw.append(rgba[i + 2])
                if keepAlpha { raw.append(rgba[i + 3]) }
            }
        }
        var z: [UInt8] = [0x78, 0x01]
        var pos = 0
        repeat {
            let n = min(65535, raw.count - pos)
            let last: UInt8 = pos + n >= raw.count ? 1 : 0
            z += [last, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
            z += raw[pos..<(pos + n)]
            pos += n
        } while pos < raw.count
        var a: UInt32 = 1, b: UInt32 = 0
        for v in raw { a = (a + UInt32(v)) % 65521; b = (b + a) % 65521 }
        z += be32((b << 16) | a)

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        func chunk(_ type: String, _ body: [UInt8]) {
            png.append(contentsOf: be32(UInt32(body.count)))
            let t = Array(type.utf8)
            png.append(contentsOf: t)
            png.append(contentsOf: body)
            png.append(contentsOf: be32(crc32(t + body)))
        }
        chunk("IHDR", be32(UInt32(width)) + be32(UInt32(height)) + [8, keepAlpha ? 6 : 2, 0, 0, 0])
        chunk("IDAT", z)
        chunk("IEND", [])
        return png
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
