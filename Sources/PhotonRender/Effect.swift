import Foundation
import PhotonCore

/// An effect instance on a layer (docs/re/03 §3).
final class Effect {
    struct FBO {
        var name: String
        var format: Int
        var scale: Int
        var width: Int?
        var height: Int?
        var fit: Int?
        var clear: [Float]?
        var unique: Bool
        var repeatUVs: Bool
        var target: RenderTarget?
    }

    enum Command { case draw, copy, swap }

    struct Pass {
        var command: Command
        var material: Material?
        var target: Int // fbo index or -1
        var source: Int
        var compose: Bool
        var binds: [(fbo: Int, index: Int)]
        var rebindAfter = true // flags bit2
        /// Index of this pass in the effect JSON (passes failing their conditions are dropped), for
        /// SceneScript bindings on `effects/N/passes/P/constantshadervalues`.
        var jsonIndex = -1
    }

    let id: Int
    var visible: Bool
    /// Index in the layer's `effects` JSON array (set by the layer; effects that fail to load are skipped).
    var jsonIndex = -1
    /// Effect name for `layer.getEffect(name)` / `effect.name` (instance `name`).
    var name = ""
    var passes: [Pass] = []
    var fbos: [FBO] = []
    var composeCount = 0
    var lastNormalPass = -1
    var readsFrameBuffer = false
    /// `functions` (Effect_Load 0x1401e8248–0x1401e8931): name → indices of the listed fbos. Only `"action": "clear"`
    /// entries are kept; an fbo name that matches no fbo of this effect (exact compare) is dropped.
    var functions: [String: [Int]] = [:]

    init?(path: String, instance: [String: Any], id: Int, scene: SceneResources) {
        guard let json = scene.fs.readJSON(path) as? [String: Any] else {
            NSLog("photon: Failed loading effect: %@", path)
            return nil
        }
        self.id = id
        // The name is the reflected property 0x120, set only by Props_ApplyJson over the instance JSON (0x1401e7341);
        // Effect_Load never reads the effect file's own "name" (its only "name" reads are fbos and binds).
        name = (instance["name"] as? String) ?? ""
        visible = jsonBool(instance["visible"], default: true)
        let combos = (instance["combos"] as? [String: Any]) ?? [:]

        for f in (json["fbos"] as? [[String: Any]]) ?? [] {
            guard Self.conditionsPass(f["conditions"], combos), let name = f["name"] as? String, let format = f["format"] as? String else { continue }
            fbos.append(FBO(name: name, format: Self.formatCode(format, hdr: scene.hdr), scale: max((f["scale"] as? NSNumber)?.intValue ?? 1, 1),
                            width: (f["width"] as? NSNumber)?.intValue, height: (f["height"] as? NSNumber)?.intValue,
                            fit: (f["fit"] as? NSNumber)?.intValue,
                            clear: (f["clear"] as? String).map { s in
                                var c = s.split(separator: " ").compactMap { Float($0) }
                                while c.count < 4 { c.append(0) }
                                return c
                            },
                            unique: (f["unique"] as? Bool) ?? false, repeatUVs: (f["uvs"] as? String) == "repeat"))
        }
        func fboIndex(_ name: Any?) -> Int {
            guard let n = name as? String else { return -1 }
            return fbos.firstIndex(where: { $0.name == n }) ?? -1
        }
        let overrides = instance["passes"] as? [Any]
        for (i, p) in ((json["passes"] as? [[String: Any]]) ?? []).enumerated() {
            guard Self.conditionsPass(p["conditions"], combos) else { continue }
            let command: Command = (p["command"] as? String) == "copy" ? .copy : (p["command"] as? String) == "swap" ? .swap : .draw
            var material: Material?
            if let m = p["material"] as? String {
                let ovr = (overrides != nil && i < overrides!.count) ? overrides![i] : nil
                material = scene.material(m, override: ovr is NSNull ? nil : ovr)
                if material?.readsFrameBuffer == true { readsFrameBuffer = true }
            }
            var binds: [(Int, Int)] = []
            for b in (p["bind"] as? [[String: Any]]) ?? [] {
                guard b["name"] is String, let idx = (b["index"] as? NSNumber)?.intValue, Self.conditionsPass(b["conditions"], combos) else { continue }
                binds.append((fboIndex(b["name"]), idx))
            }
            let compose = (p["compose"] as? Bool) ?? false
            if compose { composeCount += 1 }
            passes.append(Pass(command: command, material: material, target: fboIndex(p["target"]), source: fboIndex(p["source"]),
                               compose: compose, binds: binds, jsonIndex: i))
        }
        if let fns = json["functions"] as? [String: Any] {
            for (fname, v) in fns {
                guard let f = v as? [String: Any], (f["action"] as? String) == "clear", let list = f["fbos"] as? [Any] else { continue }
                functions[fname] = list.compactMap { ($0 as? String).flatMap { n in n.isEmpty ? nil : fbos.firstIndex(where: { $0.name == n }) } }
            }
        }
        // bit2: after a targeted pass, re-bind the chain target when the next normal pass has no target.
        let normal = passes.indices.filter { passes[$0].command == .draw }
        for (k, i) in normal.enumerated() {
            if k + 1 < normal.count { passes[i].rebindAfter = passes[normal[k + 1]].target < 0 }
        }
        lastNormalPass = normal.last ?? -1
    }

    /// `executeMaterialFunction(name)` (0x1401ee3a0): for the first function with that name, the loop runs once per listed
    /// fbo but indexes the effect's fbo array with the loop counter (`fbos + i*0x50`, 0x1401ee440–0x1401ee451), so it
    /// clears fbos 0..<count, not the listed ones. Each clear binds the fbo's target, sets its `clear` colour (0 when
    /// the fbo has none) and clears colour only (renderer vt+0x118 / vt+0x120(1, 0)).
    func functionClears(_ name: String) -> [(RenderTarget, [Float])] {
        guard let list = functions[name] else { return [] }
        return (0..<min(list.count, fbos.count)).compactMap { i in fbos[i].target.map { ($0, fbos[i].clear ?? [0, 0, 0, 0]) } }
    }

    /// `Conditions_Eval` (0x1401e63b0, docs/re/03 §5): `conditions` must be a JSON array, otherwise it passes. Every
    /// object element and every key in it must hold (AND); non-object elements are skipped. `have` = the instance
    /// combo with exactly that key (int/uint, real truncated, anything else 0). A number member compares `have ==`;
    /// an object member reads `value` (asInt for numbers, else 0) and `op`: "ge"/"gt"/"le"/"lt", any other op or
    /// none means `==`. Members of any other JSON type (bool, string, null, array) are ignored.
    static func conditionsPass(_ c: Any?, _ combos: [String: Any]) -> Bool {
        guard let list = c as? [Any] else { return true }
        func int(_ x: Any?) -> Int32? {
            guard let n = x as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            if CFNumberIsFloatType(n) { let d = n.doubleValue; return d.isFinite && abs(d) < 2147483648 ? Int32(d.rounded(.towardZero)) : Int32.min }
            return Int32(truncatingIfNeeded: n.int64Value)
        }
        for case let cond as [String: Any] in list {
            var ok = true
            for (k, v) in cond {
                let have = int(combos[k]) ?? 0
                if let want = int(v) {
                    ok = ok && have == want
                } else if let obj = v as? [String: Any] {
                    let want = int(obj["value"]) ?? 0
                    switch obj["op"] as? String {
                    case "ge": ok = ok && have >= want
                    case "gt": ok = ok && have > want
                    case "le": ok = ok && have <= want
                    case "lt": ok = ok && have < want
                    default: ok = ok && have == want
                    }
                }
            }
            if !ok { return false }
        }
        return true
    }

    /// `Format_FromName` (0x1401e53a0); backbuffer formats depend on HDR.
    static func formatCode(_ name: String, hdr: Bool = false) -> Int {
        switch name {
        case "rgba8888": return 0
        case "rgb888": return 1
        case "rgb565": return 2
        case "dxt5": return 4
        case "dxt3": return 6
        case "dxt1": return 7
        case "rg88": return 8
        case "r8": return 9
        case "rg1616f": return 0xA
        case "r16f": return 0xB
        case "bc7": return 0xC
        case "rgba1010102": return 0xD
        case "rgba16161616f": return 0xE
        case "rgb161616f": return 0xF
        case "rgba16161616": return 0x11
        case "rgb161616": return 0x12
        case "rgba16161616S": return 0x13
        case "rgb161616S": return 0x14
        case "rgba8888s": return 0x15
        case "rgba_backbuffer": return hdr ? 0xE : 0
        case "rgb_backbuffer": return hdr ? 0xF : 1
        default: return 0
        }
    }
}
