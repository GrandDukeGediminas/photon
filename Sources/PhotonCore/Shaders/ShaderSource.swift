import Foundation

/// Loads shader stage sources through the VFS and scans their metadata (docs/re/02 §1, §3.1, §4.1).
public final class ShaderSourceLoader {
    public struct SamplerInfo {
        public var slot: Int
        public var defaultTexture: String?
        public var combo: String?
        public var materialKey: String?
        public var formatCombo = false
        public var componentCombos: [String] = []
    }

    public struct ComboDecl {
        public let name: String
        public let defaultValue: Int
    }

    /// A user-settable value uniform: `uniform float g_X; // {"material": "key", "default": …}`.
    public struct ValueUniform {
        public var name: String
        public var materialKey: String
        public var defaultValue: String
        public var components: Int
        public var isColor: Bool
        /// `"conversion": "rad2deg"` (record flag 0x20, sub_1401636a0 0x140163cc2). The value is stored and uploaded in
        /// radians; the material's reflected property gets descriptor flag 4 (0x14015544e), so scripts see degrees.
        public var degrees: Bool = false
    }

    /// Per-shader metadata from the include-expanded .vert and .frag.
    public struct Info {
        public var combos: [ComboDecl] = []
        public var samplers: [Int: SamplerInfo] = [:]
        public var values: [String: ValueUniform] = [:] // keyed by uniform name
        /// `// [PASS] shadow <shader>` (0x14016de18–0x14016df0f): the program the shadow-caster pass uses instead of
        /// `shadowcaster` (Material_Apply 0x140156202–0x1401562b4). The last such line wins (string move-assign).
        public var shadowPass: String?
        public init() {}
    }

    let fs: AssetFileSystem
    private var fileCache: [String: String] = [:]
    private var infoCache: [String: Info] = [:]

    public init(fs: AssetFileSystem) { self.fs = fs }

    /// `sub_140162100`: `#include "x"` at column 0 pulls in `shaders/x` once per top-level stage file.
    /// The include line itself becomes an empty line.
    public func load(stage path: String) -> String? {
        var visited = Set<String>()
        return expand(path, visited: &visited)
    }

    private func expand(_ path: String, visited: inout Set<String>) -> String? {
        guard let text = readText(path) else { return nil }
        var out = ""
        out.reserveCapacity(text.count + 256)
        for line in Self.lines(text) {
            if line.hasPrefix("#include") {
                let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
                if parts.count >= 3 {
                    let inc = String(parts[1])
                    if !visited.contains(inc) {
                        visited.insert(inc)
                        out += expand("shaders/" + inc, visited: &visited) ?? ""
                    }
                }
                out += "\n"
            } else {
                out += line
                out += "\n"
            }
        }
        return out
    }

    private func readText(_ path: String) -> String? {
        if let hit = fileCache[path] { return hit }
        guard let data = fs.read(path) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        fileCache[path] = text
        return text
    }

    /// Splits on \n, \r or \r\n like std::getline over a normalised stream.
    static func lines(_ text: String) -> [Substring] {
        var result: [Substring] = []
        var start = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\n" || c == "\r" || c == "\r\n" {
                result.append(text[start..<i])
                start = text.index(after: i)
            }
            i = text.index(after: i)
        }
        if start < text.endIndex { result.append(text[start...]) }
        return result
    }

    /// `sub_14016ce60`: `// [COMBO] {json}` lines and `uniform samplerX g_TextureN // {json}` lines.
    public func info(shader name: String) -> Info {
        if let hit = infoCache[name] { return hit }
        var info = Info()
        for ext in ["vert", "frag"] {
            guard let src = load(stage: "shaders/\(name).\(ext)") else { continue }
            for raw in Self.lines(src) {
                let line = raw.drop(while: { $0 == " " || $0 == "\t" })
                if line.hasPrefix("// [PASS]") {
                    // After `PASS]`: skip blanks, require "shadow" (6-char compare), skip [A-Za-z0-9_.-], skip blanks; the
                    // rest of the line is the shader name.
                    var rest = line.dropFirst("// [PASS]".count).drop(while: { $0 == " " || $0 == "\t" })
                    guard rest.hasPrefix("shadow") else { continue }
                    rest = rest.drop(while: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." })
                    rest = rest.drop(while: { $0 == " " || $0 == "\t" })
                    info.shadowPass = String(rest).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                } else if line.hasPrefix("// [COMBO]") {
                    let json = line.dropFirst("// [COMBO]".count)
                    guard let obj = Self.parseJSON(json), let combo = obj["combo"] as? String else { continue }
                    // `default` is used only when jsoncpp can convert it to int (number or bool, real in int range);
                    // a string such as "1" is not convertible and gives 0 (isConvertibleTo 0x1400886e0 at 0x14016dd15).
                    var def = 0
                    if let n = obj["default"] as? NSNumber {
                        let d = n.doubleValue
                        if d.isFinite && d >= -2147483648 && d <= 2147483647 { def = Int(d.rounded(.towardZero)) }
                    }
                    // The declarations go into a map keyed by name (find-or-insert 0x14016e5e0, then the default is
                    // assigned, 0x14016dd6f), so a repeated combo keeps its first position and the LAST default
                    // (.vert is scanned before .frag).
                    if let i = info.combos.firstIndex(where: { $0.name == combo }) {
                        info.combos[i] = ComboDecl(name: combo, defaultValue: def)
                        continue
                    }
                    info.combos.append(ComboDecl(name: combo, defaultValue: def))
                } else if raw.hasPrefix("uniform"), let m = Self.samplerRegex.firstMatch(in: String(raw)) {
                    let slot = Int(m[2]) ?? 0
                    var s = info.samplers[slot] ?? SamplerInfo(slot: slot)
                    if let range = raw.range(of: "//"), let obj = Self.parseJSON(raw[range.upperBound...]) {
                        s.defaultTexture = obj["default"] as? String
                        s.combo = obj["combo"] as? String
                        s.materialKey = obj["material"] as? String
                        s.formatCombo = (obj["formatcombo"] as? Bool) ?? false
                        s.componentCombos = ((obj["components"] as? [[String: Any]]) ?? []).compactMap { $0["combo"] as? String }
                    }
                    info.samplers[slot] = s
                } else if raw.hasPrefix("uniform"), !raw.contains("sampler"), let v = Self.valueUniform(String(raw)) {
                    if info.values[v.name] == nil { info.values[v.name] = v }
                }
            }
        }
        infoCache[name] = info
        return info
    }

    /// `sub_1401636a0`: name is the word before the first `;`; components from the first of vec3/vec4/vec2 in the line.
    static func valueUniform(_ line: String) -> ValueUniform? {
        guard let c = line.range(of: "//"), let json = parseJSON(line[c.upperBound...]),
              let key = json["material"] as? String, let semi = line.firstIndex(of: ";") else { return nil }
        let decl = line[..<semi]
        guard let space = decl.lastIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
        let name = String(decl[decl.index(after: space)...])
        var def = ""
        switch json["default"] {
        case let s as String: def = s
        case let n as NSNumber: def = n.stringValue
        default: break
        }
        let comps = line.contains("vec3") ? 3 : line.contains("vec4") ? 4 : line.contains("vec2") ? 2 : 1
        return ValueUniform(name: name, materialKey: key, defaultValue: def, components: comps,
                            isColor: (json["type"] as? String) == "color" && comps == 3,
                            degrees: (json["conversion"] as? String) == "rad2deg")
    }

    static let samplerRegex = Regex(#"^uniform[\s]+(sampler[\w]*)[\s]+g_Texture([\d]+)"#)

    static func parseJSON<S: StringProtocol>(_ s: S) -> [String: Any]? {
        guard let data = String(s).data(using: .utf8) else { return nil }
        return parseEngineJSON(data) as? [String: Any]
    }
}

/// Small NSRegularExpression wrapper returning capture groups as strings.
struct Regex {
    let re: NSRegularExpression
    init(_ pattern: String) { re = try! NSRegularExpression(pattern: pattern) }

    func firstMatch(in s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    func firstRange(in s: String) -> NSRange? {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))?.range
    }
}
