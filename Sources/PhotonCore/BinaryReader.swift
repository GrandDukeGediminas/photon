import Foundation

/// Little-endian reader with the engine's lenient semantics: reading past the end yields 0
/// and does not advance (docs/re/01 §3.1).
struct BinaryReader {
    let data: Data
    private(set) var offset: Int

    init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    var remaining: Int { data.count - offset }

    mutating func i32() -> Int32 {
        guard remaining >= 4 else { offset = data.count; return 0 }
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) }
        offset += 4
        return Int32(littleEndian: v)
    }

    mutating func u32() -> UInt32 { UInt32(bitPattern: i32()) }

    mutating func f32() -> Float {
        Float(bitPattern: u32())
    }

    /// NUL-terminated string. A missing terminator consumes to the end.
    mutating func cString() -> String {
        let start = offset
        let end = data[(data.startIndex + start)...].firstIndex(of: 0).map { $0 - data.startIndex } ?? data.count
        offset = min(end + 1, data.count)
        return String(decoding: data[(data.startIndex + start)..<(data.startIndex + end)], as: UTF8.self)
    }

    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, count <= remaining else { return nil }
        let slice = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
        offset += count
        return slice
    }
}
