import Foundation

/// A mounted `scene.pkg` (docs/re/01 §1, `sub_140276700`).
///
/// Layout: u32-prefixed version string ("PKGV0001"…"PKGV0024"), u32 entry count, then
/// `{u32 nameLen, name, u32 offset, u32 size}` entries. Offsets are relative to the end of the table.
public final class PackageFile {
    public struct Entry {
        public let offset: Int
        public let size: Int
    }

    public enum Error: Swift.Error {
        case unreadable(URL)
        case unsupportedVersion(String)
    }

    public static let maxVersion = 24

    public let url: URL
    public let version: String
    /// Keys are lower-cased; lookups are case-insensitive.
    public private(set) var entries: [String: Entry] = [:]
    private let data: Data

    public init(url: URL) throws {
        self.url = url
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw Error.unreadable(url) }
        self.data = data
        var r = BinaryReader(data)

        let verLen = Int(r.u32())
        // The engine reads at most 8 bytes; longer strings come back empty and are not consumed.
        version = verLen <= 8 ? String(decoding: r.bytes(verLen) ?? Data(), as: UTF8.self) : ""
        if version.count > 4, let n = Int(version.dropFirst(4)), n > Self.maxVersion {
            throw Error.unsupportedVersion(version)
        }

        let count = Int(r.u32())
        var raw: [(String, Int, Int)] = []
        raw.reserveCapacity(count)
        for _ in 0..<count {
            let len = Int(r.u32())
            let name = len > 0x800 ? "" : String(decoding: r.bytes(len) ?? Data(), as: UTF8.self)
            let off = Int(r.u32()), size = Int(r.u32())
            raw.append((name.lowercased(), off, size))
        }
        let base = r.offset
        for (name, off, size) in raw {
            entries[name] = Entry(offset: base + off, size: size)
        }
    }

    /// Returns the entry's bytes, or nil if absent or zero-sized (which falls through to disk).
    public func read(_ path: String) -> Data? {
        guard let e = entries[path.lowercased()], e.size > 0, e.offset + e.size <= data.count else { return nil }
        return data.subdata(in: e.offset..<(e.offset + e.size))
    }
}
