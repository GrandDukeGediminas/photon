import Foundation

/// The reflected-property JSON loaders, exactly as the engine runs them (docs/re/loader-keys.md §1, docs/re/04 §0).
///
/// Each loader first applies the plain JSON value, then, for an object value (`{"value": …, "user": …}`), its
/// `value` member with the same rule; a user binding later writes the user value through the same loader
/// (`UserProps_Apply` 0x1401731d0). A value of the wrong JSON type leaves the field unchanged, so the default (or the
/// inline `value`) survives. In particular `null` is **not** a number: the float loader 0x1401a4b00 tests
/// `tag − 1 ≤ 2` unsigned (0x1401a4b17–0x1401a4b26), so `"bloomstrength": null` keeps 2.0.
public enum EngineValue {
    static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }
    static func isReal(_ n: NSNumber) -> Bool {
        let t = n.objCType.pointee
        return t == 0x64 || t == 0x66 // 'd', 'f'
    }

    /// Float loader 0x1401a4b00: int / uint / real → value (`Json_AsFloat` 0x140086220); anything else unchanged.
    public static func floatStep(_ v: Any?, _ cur: Float) -> Float {
        guard let n = v as? NSNumber, !isBool(n) else { return cur }
        return n.floatValue
    }

    /// Int loader 0x1401a4930: int / uint → low 32 bits, real → `cvttsd2si` (0x1401a4962; out of range → INT_MIN).
    public static func intStep(_ v: Any?, _ cur: Int) -> Int {
        guard let n = v as? NSNumber, !isBool(n) else { return cur }
        if isReal(n) {
            let d = n.doubleValue
            guard d.isFinite, d > -2147483649, d < 2147483648 else { return Int(Int32.min) }
            return Int(Int32(d.rounded(.towardZero)))
        }
        return Int(Int32(truncatingIfNeeded: n.int64Value))
    }

    /// Vector loaders 0x1401a3fc0 (vec2) / 0x1401a4230 (vec3): a string zeroes the field, then reads `atof` of the
    /// first token and of each token after a run of spaces (only ' ' separates; a missing token stays 0); a number
    /// fills every component (0x1401a436c–0x1401a4380); anything else unchanged.
    public static func vecStep(_ v: Any?, _ cur: [Float], count: Int) -> [Float] {
        if let n = v as? NSNumber, !isBool(n) { return Array(repeating: n.floatValue, count: count) }
        guard let s = v as? String else { return cur }
        var out = [Float](repeating: 0, count: count)
        let b = Array(s.utf8)
        var i = 0
        for k in 0..<count {
            if k > 0 {
                // skip the rest of the previous token, then require at least one space
                while i < b.count && b[i] != 0x20 { i += 1 }
                var spaces = false
                while i < b.count && b[i] == 0x20 { i += 1; spaces = true }
                guard spaces, i < b.count else { break }
            } else if b.isEmpty { break }
            out[k] = Float(atofPrefix(b, i))
        }
        return out
    }

    /// C `atof` on the bytes from `i`: leading whitespace, the longest valid decimal prefix, else 0.
    static func atofPrefix(_ b: [UInt8], _ start: Int) -> Double {
        let tail = String(decoding: b[start...], as: UTF8.self)
        return tail.withCString { strtod($0, nil) }
    }

    /// String loader 0x1401a4bc0: strings only.
    public static func stringStep(_ v: Any?, _ cur: String) -> String { (v as? String) ?? cur }

    /// Bool-bit loaders (e.g. 0x14019b4e0): JSON booleans only.
    public static func boolStep(_ v: Any?, _ cur: Bool) -> Bool {
        guard let n = v as? NSNumber, isBool(n) else { return cur }
        return n.boolValue
    }

    /// The user value a binding writes (`UserProps_Apply` 0x1401731d0), or nil when the binding does not resolve.
    public static func userValue(_ obj: [String: Any]) -> Any? {
        switch obj["user"] {
        case let name as String:
            return UserProperties.current[name]
        case let b as [String: Any]:
            guard let name = b["name"] as? String, let uv = UserProperties.current[name] else { return nil }
            let cond = (b["condition"] as? String) ?? ""
            if cond.isEmpty { return uv }
            guard let s = jsonAsString(uv) else { return nil }   // arrays/objects: nothing is written
            return NSNumber(value: s == cond)
        default:
            return nil
        }
    }

    /// Plain value, then `value`, then the user binding, each through `step`.
    public static func bindable<T>(_ v: Any?, _ def: T, _ step: (Any?, T) -> T) -> T {
        guard let obj = v as? [String: Any] else { return step(v, def) }
        var cur = step(obj["value"], def)
        if let u = userValue(obj) { cur = step(u, cur) }
        return cur
    }

    public static func float(_ v: Any?, default d: Float) -> Float { bindable(v, d, floatStep) }
    public static func int(_ v: Any?, default d: Int) -> Int { bindable(v, d, intStep) }
    public static func string(_ v: Any?, default d: String) -> String { bindable(v, d, stringStep) }
    public static func bool(_ v: Any?, default d: Bool) -> Bool { bindable(v, d, boolStep) }
    public static func vec2(_ v: Any?, default d: SIMD2<Float>) -> SIMD2<Float> {
        let a = bindable(v, [d.x, d.y]) { vecStep($0, $1, count: 2) }
        return SIMD2(a[0], a[1])
    }
    public static func vec3(_ v: Any?, default d: SIMD3<Float>) -> SIMD3<Float> {
        let a = bindable(v, [d.x, d.y, d.z]) { vecStep($0, $1, count: 3) }
        return SIMD3(a[0], a[1], a[2])
    }
}

extension EngineValue {
    /// True for a JSON boolean (NSNumber from JSONSerialization).
    public static func isBoolPublic(_ n: NSNumber) -> Bool { isBool(n) }
}
