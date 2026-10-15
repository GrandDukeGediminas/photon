import Foundation

/// `JsonMerge(base, override)` (docs/re/03 §1, 0x140153200).
///
/// Objects merge recursively, `null` override entries keep the base value (so `"textures": [null, "x"]`
/// keeps texture 0), arrays merge element-wise, scalars replace.
public func jsonMerge(_ base: Any?, _ override: Any?) -> Any? {
    if let ovr = override as? [String: Any] {
        guard var result = base as? [String: Any] else {
            return ovr.filter { !($0.value is NSNull) }
        }
        for (k, v) in ovr where !(v is NSNull) {
            result[k] = jsonMerge(result[k], v)
        }
        return result
    }
    if let ovr = override as? [Any] {
        guard var result = base as? [Any] else {
            return ovr.map { $0 is NSNull ? NSNull() : $0 }
        }
        for (i, v) in ovr.enumerated() where !(v is NSNull) {
            if i < result.count { result[i] = jsonMerge(result[i], v) ?? v }
            else {
                while result.count < i { result.append(NSNull()) }
                result.append(v)
            }
        }
        return result
    }
    return override ?? base
}

/// The wallpaper's user properties (project.json `general.properties`, name → value).
/// Set while a scene loads; bindings resolve against it (docs/re/04 §1).
public enum UserProperties {
    nonisolated(unsafe) public static var current: [String: Any] = [:]
    /// Property name → declared `type` (`color`, `slider`, …), for SceneScript `engine.userProperties`.
    nonisolated(unsafe) public static var types: [String: String] = [:]

    /// Loads `general.properties` values from a project.json object.
    public static func load(project: [String: Any]) -> [String: Any] {
        let props = ((project["general"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
        var out: [String: Any] = [:]
        types = [:]
        for (name, p) in props {
            if let obj = p as? [String: Any], let v = obj["value"] { out[name] = v }
            if let obj = p as? [String: Any], let t = obj["type"] as? String { types[name] = t }
        }
        // Debugging/testing: PHOTON_PROP_<name>=<json value> overrides a property.
        for (k, v) in ProcessInfo.processInfo.environment where k.hasPrefix("PHOTON_PROP_") {
            let name = String(k.dropFirst("PHOTON_PROP_".count))
            out[name] = (try? JSONSerialization.jsonObject(with: Data(v.utf8), options: [.fragmentsAllowed])) ?? v
        }
        return out
    }
}

/// A bindable value: plain JSON, or `{"value": default, "user": binding?, "animation"…, "script"…}`.
///
/// Binding records come from `Value_LoadDynamic` 0x1401a4db0: `user` as a string, or as an object whose `name` is a
/// string (a non-string `condition` is stored as ""). User values are pushed into bindings by
/// `UserProps_Apply` 0x1401731d0 (loop 0x14017337b–0x140173401, docs/re/04 §1.1):
/// - empty condition → the field's own JSON loader gets the raw user value;
/// - non-empty condition → only if the value's JSON type is null/int/uint/real/string/bool (≤ 5):
///   `Json::Value(asString(value) == condition)`; an array or object value writes nothing.
/// A binding whose property is missing (or has no `value`) is never written, so the inline `value` stays.
public func unwrapUserValue(_ v: Any?) -> Any? {
    guard let obj = v as? [String: Any], obj["value"] != nil || obj["user"] != nil else { return v }
    switch obj["user"] {
    case let name as String:
        if let uv = UserProperties.current[name] { return uv }
    case let b as [String: Any]:
        if let name = b["name"] as? String, let uv = UserProperties.current[name] {
            let cond = (b["condition"] as? String) ?? ""
            if cond.isEmpty { return uv }
            guard let s = jsonAsString(uv) else { break }
            return NSNumber(value: s == cond)
        }
    default:
        break
    }
    return obj["value"]
}

/// jsoncpp 1.9 `Value::asString` as linked into the engine (0x140085cc0): null → "", int/uint → decimal,
/// real → `valueToString(d, useSpecialFloats: false, precision: 17, significantDigits)` (0x140089c60),
/// string → itself, bool → "true"/"false". Arrays and objects throw in jsoncpp; nil here.
public func jsonAsString(_ v: Any) -> String? {
    switch v {
    case is NSNull: return ""
    case let s as String: return s
    case let n as NSNumber:
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
        switch n.objCType.pointee {
        case 0x64, 0x66: return jsoncppRealToString(n.doubleValue)                 // 'd', 'f'
        case 0x51, 0x4c, 0x49, 0x53, 0x43: return String(n.uint64Value)            // unsigned
        default: return String(n.int64Value)
        }
    default: return nil
    }
}

/// `valueToString(double)` 0x140089c60: "%.17g", ',' → '.', then ".0" if there is no '.' and no 'e'.
/// Non-finite values print as JSON-compatible "null" / "1e+9999" / "-1e+9999".
public func jsoncppRealToString(_ d: Double) -> String {
    if d.isNaN { return "null" }
    if d.isInfinite { return d < 0 ? "-1e+9999" : "1e+9999" }
    var s = String(format: "%.17g", d).replacingOccurrences(of: ",", with: ".")
    if !s.contains(".") && !s.contains("e") { s += ".0" }
    return s
}

public func jsonFloats(_ v: Any?) -> [Float] {
    switch unwrapUserValue(v) {
    case let n as NSNumber: return [n.floatValue]
    case let s as String: return s.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Float($0) }
    case let a as [Any]: return a.compactMap { ($0 as? NSNumber)?.floatValue }
    default: return []
    }
}

/// Bool fields accept only JSON booleans (bool-bit loader, docs/re/04 §0). A binding whose user value
/// is not a bool (e.g. a colour bound to `visible`) leaves the inline `value`.
public func jsonBool(_ v: Any?, default def: Bool) -> Bool {
    func asBool(_ x: Any?) -> Bool? {
        guard let n = x as? NSNumber else { return nil }
        return CFGetTypeID(n) == CFBooleanGetTypeID() ? n.boolValue : nil
    }
    if let b = asBool(unwrapUserValue(v)) { return b }
    if let obj = v as? [String: Any], let b = asBool(obj["value"]) { return b }
    if let b = asBool(v) { return b }
    return def
}
