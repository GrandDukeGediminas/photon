import Foundation

/// The engine's JSON reader (`JsonParse` 0x140017840, 61 callers: materials, effects, models, particles, scene, project
/// and shader annotation JSON). It is jsoncpp 1.9's `CharReaderBuilder` with `collectComments`, `allowComments` and
/// `allowTrailingCommas` set (0x1400178de, 0x1400179af, 0x140017a83), the other settings at their defaults
/// (`setDefaults` 0x140091ef0): `strictRoot`, `allowDroppedNullPlaceholders`, `allowNumericKeys`, `allowSingleQuotes`,
/// `failIfExtra`, `rejectDupKeys` and `allowSpecialFloats` off, `skipBom` on, `stackLimit` 256 (0x140092307).
///
/// So, unlike `JSONSerialization`, the engine accepts `//` and `/* */` comments, a comma before `]` or `}`, a UTF-8 BOM,
/// raw control characters inside strings (jsoncpp's `decodeString` copies them) and anything after the root value.
/// `parseEngineJSON` rewrites those into strict JSON and hands the result to `JSONSerialization`.
public func parseEngineJSON(_ data: Data) -> Any? {
    if let v = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { return v }
    guard let clean = EngineJSON.normalize(data) else { return nil }
    return try? JSONSerialization.jsonObject(with: clean, options: [.fragmentsAllowed])
}

public enum EngineJSON {
    /// Strips a BOM and comments, drops trailing commas, escapes raw control characters in strings and cuts the text
    /// after the first complete root value. Returns nil when no root value is found.
    public static func normalize(_ data: Data) -> Data? {
        var b = [UInt8](data)
        if b.count >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF { b.removeFirst(3) }
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        var depth = 0
        var started = false
        // Index in `out` of a comma that may turn out to be trailing (only whitespace/comments since).
        var pendingComma: Int?
        func finished() -> Bool { started && depth == 0 }
        while i < b.count {
            let c = b[i]
            if c == 0x22 { // string
                pendingComma = nil
                out.append(c); i += 1
                while i < b.count {
                    let s = b[i]
                    if s == 0x5C, i + 1 < b.count { out.append(s); out.append(b[i + 1]); i += 2; continue }
                    if s == 0x22 { out.append(s); i += 1; break }
                    if s < 0x20 {
                        switch s {
                        case 0x0A: out += Array("\\n".utf8)
                        case 0x0D: out += Array("\\r".utf8)
                        case 0x09: out += Array("\\t".utf8)
                        default: out += Array(String(format: "\\u%04x", s).utf8)
                        }
                        i += 1; continue
                    }
                    out.append(s); i += 1
                }
                if !started { started = true }
                if finished() { break }
                continue
            }
            if c == 0x2F, i + 1 < b.count, b[i + 1] == 0x2F { // // comment
                while i < b.count && b[i] != 0x0A && b[i] != 0x0D { i += 1 }
                continue
            }
            if c == 0x2F, i + 1 < b.count, b[i + 1] == 0x2A { // /* comment */
                i += 2
                while i + 1 < b.count && !(b[i] == 0x2A && b[i + 1] == 0x2F) { i += 1 }
                i = min(i + 2, b.count)
                continue
            }
            switch c {
            case 0x20, 0x09, 0x0A, 0x0D:
                out.append(c); i += 1; continue
            case 0x2C: // ,
                pendingComma = out.count
                out.append(c); i += 1; continue
            case 0x5D, 0x7D: // ] }
                if let p = pendingComma { out[p] = 0x20 }
                pendingComma = nil
                depth -= 1
                out.append(c); i += 1
                if finished() { i = b.count }
                continue
            case 0x5B, 0x7B: // [ {
                pendingComma = nil
                depth += 1; started = true
                out.append(c); i += 1; continue
            default:
                pendingComma = nil
                // A bare scalar root (number, true, false, null) ends at the next separator.
                if !started && depth == 0 {
                    while i < b.count, ![0x20, 0x09, 0x0A, 0x0D, 0x2F].contains(b[i]) { out.append(b[i]); i += 1 }
                    started = true
                    i = b.count
                    continue
                }
                out.append(c); i += 1
            }
        }
        return started ? Data(out) : nil
    }
}
