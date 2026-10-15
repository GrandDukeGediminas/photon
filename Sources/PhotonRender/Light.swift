import Foundation
import PhotonCore
import simd

/// A light object (`"light": "lpoint" | "lspot" | "ltube" | "ldirectional"`), docs/re/06 §6.
/// Property reflection 0x14025da80: type +0x2c0 (enum table 0x14025e853: lpoint 0, lspot 1, ltube 2, ldirectional 3),
/// flags +0x2c4 (castshadow / usecookie / castvolumetrics), color +0x2cc, controlpoint +0x2d8, intensity +0x2e4,
/// radius +0x2e8, exponent +0x2ec, innercone +0x2f0, outercone +0x2f4, density +0x2f8, volumetricsexponent +0x2fc.
final class LightObject: SceneObject {
    enum Kind: Int { case point = 0, spot = 1, tube = 2, directional = 3 }

    /// Type +0x2c0; scripts can change it (`light`, change callback 0x14025c610 drops the cached light resources).
    var kind: Kind?
    var color = SIMD3<Float>(1, 1, 1)
    var intensity: Float = 1
    // Defaults from the light ctor (0x140190494–0x1401904e4): radius 1, exponent 2, innercone 20, outercone 30,
    // density 2, volumetricsexponent 1, cascadedistance 3 / 10 / 100, lightsourcesize 0.
    var radius: Float = 1
    var exponent: Float = 2
    var innerCone: Float = 20
    var outerCone: Float = 30
    var controlPoint = SIMD3<Float>(0, 0, 0)
    var density: Float = 2
    var volumetricsExponent: Float = 1
    var lightSourceSize: Float = 0
    /// `cascadedistance0..2` (+0x300..+0x308), ctor defaults 3 / 10 / 100.
    var cascadeDistances = SIMD3<Float>(3, 10, 100)
    /// Flags +0x2c4: bit 0 `castshadow`, bit 1 `usecookie`, bit 2 `castvolumetrics`.
    var castShadow = false
    var useCookie = false
    var castVolumetrics = false
    /// Light +0x330 texture name (only with `usecookie`).
    var cookieName: String?
    /// Light +0x310: the light's atlas rectangle (x/W, y/H, s/W, s/H), set after packing (0x140196114).
    var shadowAtlasTransform = SIMD4<Float>(0, 0, 1, 1)
    /// `"light": "point"` (type 5): the legacy 2D light behind g_LightsPosition / g_LightsColorRadius /
    /// g_LightsColorPremultiplied, written each frame by `LegacyLight_Update` 0x14025d1f0 (light vt+0x48).
    var legacyPoint: Bool { (json["light"] as? String) == "point" }
    /// Light +0x2c8: at creation the lowest of 0…3 not used by a light already in the scene's light list (S+0x1e0),
    /// 0 when all four are taken (`Scene_CreateObject` 0x1401903ce–0x140190457). Every light type takes a slot.
    var legacySlot = 0

    override init(json: [String: Any], id: Int) {
        switch json["light"] as? String {
        case "lpoint": kind = .point
        case "lspot": kind = .spot
        case "ltube": kind = .tube
        case "ldirectional": kind = .directional
        default: kind = nil // "point" maps to 5 in the table and is skipped by the light pass
        }
        super.init(json: json, id: id)
        if let c = Self.vec3(json["color"]) { color = c }
        if let v = jsonFloats(json["intensity"]).first { intensity = v }
        if let v = jsonFloats(json["radius"]).first { radius = v }
        if let v = jsonFloats(json["exponent"]).first { exponent = v }
        if let v = jsonFloats(json["innercone"]).first { innerCone = v }
        if let v = jsonFloats(json["outercone"]).first { outerCone = v }
        if let v = Self.vec3(json["controlpoint"]) { controlPoint = v }
        if let v = jsonFloats(json["density"]).first { density = v }
        if let v = jsonFloats(json["volumetricsexponent"]).first { volumetricsExponent = v }
        if let v = jsonFloats(json["lightsourcesize"]).first { lightSourceSize = v }
        for (k, key) in ["cascadedistance0", "cascadedistance1", "cascadedistance2"].enumerated() {
            if let v = jsonFloats(json[key]).first { cascadeDistances[k] = v }
        }
        castShadow = jsonBool(json["castshadow"], default: false)
        useCookie = jsonBool(json["usecookie"], default: false)
        // Light load 0x14025d080: with `usecookie`, a non-empty string `cookie` names the cookie texture (light +0x330,
        // texture manager 0x14014cf90); otherwise `cookie/flashlight1`.
        if useCookie { cookieName = (json["cookie"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "cookie/flashlight1" }
        castVolumetrics = jsonBool(json["castvolumetrics"], default: false)
        for key in ["color", "intensity", "radius", "exponent", "innercone", "outercone", "density", "volumetricsexponent"] {
            if let a = PropertyAnimation(json: json[key]) { animations[key] = a }
        }
    }

    override func apply(_ key: String, _ v: [Float]) {
        switch key {
        case "color": if v.count >= 3 { color = SIMD3(v[0], v[1], v[2]) }
        case "intensity": if let f = v.first { intensity = f }
        case "radius": if let f = v.first { radius = f }
        case "exponent": if let f = v.first { exponent = f }
        case "innercone": if let f = v.first { innerCone = f }
        case "outercone": if let f = v.first { outerCone = f }
        case "density": if let f = v.first { density = f }
        case "volumetricsexponent": if let f = v.first { volumetricsExponent = f }
        default: super.apply(key, v)
        }
    }

    /// vt+0x68 (0x14025d330): a light is only "visible" to the draw list when it casts volumetrics.
    var drawsVolumetrics: Bool { effectiveVisible && castVolumetrics && kind != nil }

    /// vt+0x50 (0x14025d300): `castvolumetrics` → scene volumetrics renderer (S+0x1510 vt+0x28 = 0x140196ce0).
    override func render(_ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer) {
        guard drawsVolumetrics else { return }
        scene.volumetrics.renderLight(self, ctx, frame, scene)
    }
}

/// Legacy light uniforms (built-in IDs 0x5d–0x5f). Context defaults (ctor 0x14017ce13–0x14017d68f): position (0, 100, 0)
/// and colour/radius (0, 0, 0, 1) for each of the four slots. Each frame `LegacyLight_Update` 0x14025d1f0 runs for every
/// type-5 light with slot ≤ 3, in scene order: visible (own bit and every ancestor) → C+0x1258[slot] = (color·intensity,
/// radius), else (0, 0, 0, 1); always C+0x1228[slot] = the world translation. Upload (`ShaderProgram_FillConstants`
/// 0x1400d9973 / 0x1400d99b1 / 0x1400d9aa8): ColorRadius = the four vec4s; ColorPremultiplied[i] (i < 3) =
/// (L_i.rgb · r_i², L_3.rgb[i] · r_3²); Position[i] = (xyz, 0).
enum LegacyLights {
    static func uniforms(_ lights: [LightObject]) -> [String: UniformValue] {
        var cr = [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 1), count: 4)
        var pos = [SIMD3<Float>](repeating: SIMD3(0, 100, 0), count: 4)
        for l in lights where l.legacyPoint && (0...3).contains(l.legacySlot) {
            let c = l.color * l.intensity
            cr[l.legacySlot] = l.effectiveVisible ? SIMD4(c.x, c.y, c.z, l.radius) : SIMD4(0, 0, 0, 1)
            let w = l.world
            pos[l.legacySlot] = SIMD3(w.columns.3.x, w.columns.3.y, w.columns.3.z)
        }
        var pre: [Float] = []
        for i in 0..<3 {
            let r2 = cr[i].w * cr[i].w, r3 = cr[3].w * cr[3].w
            pre += [cr[i].x * r2, cr[i].y * r2, cr[i].z * r2, cr[3][i] * r3]
        }
        return [
            "g_LightsColorRadius": .floats(cr.flatMap { [$0.x, $0.y, $0.z, $0.w] }),
            "g_LightsColorPremultiplied": .floats(pre),
            "g_LightsPosition": .floats(pos.flatMap { [$0.x, $0.y, $0.z] }),
        ]
    }
}

/// The scene's light uniforms for one frame (`g_bufLights`, b3), filled like `Lights_Update` 0x140190c80.
/// Each type takes at most its `lightconfig` count, in scene order. The engine first sorts the list (0x140186990,
/// key = dot(light position, a camera vector)), which only matters when there are more lights than slots.
/// Within a type, lights with `castshadow` (when shadows are enabled) fill the first slots (the point branch picks one
/// of two write pointers by `castshadow && C+0x1ac`, 0x1401932a3–0x1401932c0), matching the shadowed-first blocks of
/// `#require LightingV1`. A shadowed point light also gets a shadow record while `pointshadow` slots remain
/// (0x14019331d–0x140193521): `g_LFeature_ShadowPointProjection[i]` = light +0x320, and
/// `g_LFeature_ShadowPointProjectionTransform[i]` = its atlas rectangle, written after packing.
struct LightBuffer {
    var uniforms: [String: UniformValue] = [:]
    var shadowRecords: [ShadowMaps.Record] = []

    init(lights: [LightObject], config: UInt32, shadowQuality: Int = 0, ortho: Bool = false,
         eye: SIMD3<Float> = .zero, viewForward: SIMD3<Float> = SIMD3(0, 0, -1)) {
        var limit = [Int(config & 0xf), Int((config >> 4) & 0xf), Int((config >> 8) & 0xf), Int((config >> 12) & 0xf)]
        let pointShadowSlots = Int((config >> 24) & 3)
        var pointShadowLeft = pointShadowSlots
        let pointCount = limit[0]
        var point = [[Float]](repeating: [Float](repeating: 0, count: 4 * pointCount), count: 2)
        var nextShadowed = 0, nextPlain = pointShadowSlots
        // Spots (0x140192dbf): one write pointer per kind k = castshadow (with shadows on) | usecookie·2. Kind 3 starts at
        // slot 0, kind 2 after spotshadowcookie, kind 1 after spotcookie, kind 0 after spotshadow (0x140190f2f–0x140190f70),
        // the same runs LightingV1 emits. Only the total spot count is checked, as in the engine.
        let spotCount = limit[1]
        var spot = [[Float]](repeating: [Float](repeating: 0, count: 4 * spotCount), count: 4)
        let ssc = Int((config >> 20) & 3), sc = Int((config >> 18) & 3), ss = Int((config >> 16) & 3)
        var spotNext = [ssc + sc + ss, ssc + sc, ssc, 0]
        // Feature slots (g_LFeature_ShadowProjection / …Transform): kind 3 from 0, kind 2 from ssc, kind 1 from ssc + sc,
        // directional cascades after (0x140190fb8–0x14019105c); `C+0xd98` = the total, decremented per feature.
        let featureTotal = ssc + sc + ss + 3 * Int((config >> 22) & 3)
        var featureLeft = featureTotal
        // Index = kind, the same pointer table as the engine's: [0] = directional cascades (plain spots never take one).
        var featureNext = [ssc + sc + ss, ssc + sc, ssc, 0]
        var spotFeatures = [Float](repeating: 0, count: 16 * featureTotal)
        var tube: [[Float]] = [[], [], []]
        // Directionals (0x14019111d): shadowed ones (shadows on, castshadow) fill the first `directionalshadow` slots.
        let dirCount = limit[3], dirShadow = Int((config >> 22) & 3)
        var directional = [[Float](repeating: 0, count: 4 * dirCount), [Float](repeating: 0, count: 3 * dirCount)]
        var dirNext = [dirShadow, 0]
        var featureProj: [Float] = []
        let deg: Float = 0.0174533
        // `Lights_SortForBuffer` 0x140186990 (called at 0x140191063 with C+0x160): records {type +0x2c0, flags +0x2c4 & 3,
        // key = dot(local origin +0x128, g_ViewForward), light}, std::sort (0x14019f360, comparator inlined, e.g.
        // 0x1401a3210): type ascending, then flags descending (shadow+cookie first), then key ascending. It decides which
        // lights get the limited slots when a type has more lights than `lightconfig` allows.
        func flagBits(_ l: LightObject) -> Int { (l.castShadow ? 1 : 0) | (l.useCookie ? 2 : 0) }
        let sorted = lights.enumerated().sorted { a, b in
            let ta = a.element.kind?.rawValue ?? 5, tb = b.element.kind?.rawValue ?? 5
            if ta != tb { return ta < tb }
            let fa = flagBits(a.element), fb = flagBits(b.element)
            if fa != fb { return fa > fb }
            let ka = simd_dot(a.element.origin, viewForward), kb = simd_dot(b.element.origin, viewForward)
            if ka != kb { return ka < kb }
            return a.offset < b.offset
        }.map(\.element)
        for light in sorted where light.effectiveVisible {
            guard let kind = light.kind, limit[kind.rawValue] > 0 else { continue }
            limit[kind.rawValue] -= 1
            let world = light.world
            // Engine rows of the world matrix = columns here: row 3 = translation, row 0 = local X axis.
            let pos = SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
            let axisX = SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z)
            let rgb = light.color * light.intensity
            switch kind {
            case .point: // 0x14019325f
                let shadowed = shadowQuality != 0 && light.castShadow
                let slot: Int
                if shadowed { slot = nextShadowed; nextShadowed += 1 } else { slot = nextPlain; nextPlain += 1 }
                if slot < pointCount {
                    point[0].replaceSubrange(slot * 4..<slot * 4 + 4, with: [rgb.x, rgb.y, rgb.z, light.radius])
                    point[1].replaceSubrange(slot * 4..<slot * 4 + 4, with: [pos.x, pos.y, pos.z, light.exponent])
                }
                if shadowed && pointShadowLeft > 0 {
                    let pointFeature = pointShadowSlots - pointShadowLeft
                    pointShadowLeft -= 1
                    let proj = ShadowMaps.pointProjection(light, quality: shadowQuality, ortho: ortho)
                    featureProj += ShadowMaps.pointProjectionInfo(proj)
                    shadowRecords.append(.init(light: light, size: ShadowMaps.tileSize(shadowQuality), point: true,
                                               projection: proj, feature: pointFeature))
                }
            case .spot: // 0x140192dbf
                let shadowed = shadowQuality != 0 && light.castShadow
                let kind = (shadowed ? 1 : 0) | (light.useCookie ? 2 : 0)
                let slot = spotNext[kind]; spotNext[kind] += 1
                if slot < spotCount {
                    spot[0].replaceSubrange(slot * 4..<slot * 4 + 4, with: [rgb.x, rgb.y, rgb.z, light.radius])
                    spot[1].replaceSubrange(slot * 4..<slot * 4 + 4, with: [pos.x, pos.y, pos.z, cos(light.innerCone * deg)])
                    spot[2].replaceSubrange(slot * 4..<slot * 4 + 4, with: [axisX.x, axisX.y, axisX.z, cos(light.outerCone * deg)])
                    spot[3].replaceSubrange(slot * 4..<slot * 4 + 4, with: [light.exponent, 0, 0, 0])
                }
                // 0x140192f04: every spot with `usecookie` that got a slot sets the frame's `_alias_lightCookie`; the last wins.
                if light.useCookie { cookieLight = light }
                // 0x140192f12–0x14019315d: shadowed or cookie spots take a feature slot while any are left: +0x338
                // (0x14025d420) goes to g_LFeature_ShadowProjection; shadowed ones also get an atlas record whose
                // transform slot is the same index.
                if (shadowed || light.useCookie) && featureLeft > 0 {
                    featureLeft -= 1
                    let f = featureNext[kind]; featureNext[kind] += 1
                    let vp = ShadowMaps.spotViewProjection(light, ortho: ortho)
                    if f < featureTotal {
                        for r in 0..<4 { for c in 0..<4 { spotFeatures[f * 16 + r * 4 + c] = vp[c][r] } }
                    }
                    if shadowed {
                        shadowRecords.append(.init(light: light, size: ShadowMaps.tileSize(shadowQuality), point: false,
                                                   projection: vp, feature: f))
                    }
                }
            case .tube: // 0x140192a19; OriginB = ((controlpoint, 1) × world).xyz, w 0 (0x140192aa6–0x140192da8)
                let b4 = world * SIMD4(light.controlPoint, 1)
                tube[0] += [rgb.x, rgb.y, rgb.z, light.radius]
                tube[1] += [pos.x, pos.y, pos.z, light.exponent]
                tube[2] += [b4.x, b4.y, b4.z] // float3 member
            case .directional: // 0x14019111d: Color = (rgb·intensity, 1), Direction = −(row 0), w 0
                let shadowed = shadowQuality != 0 && light.castShadow
                let slot = dirNext[shadowed ? 1 : 0]; dirNext[shadowed ? 1 : 0] += 1
                if slot < dirCount {
                    directional[0].replaceSubrange(slot * 4..<slot * 4 + 4, with: [rgb.x, rgb.y, rgb.z, 1])
                    directional[1].replaceSubrange(slot * 3..<slot * 3 + 3, with: [-axisX.x, -axisX.y, -axisX.z]) // float3 member
                }
                // 0x14019122b–0x140192a0e: a shadowed directional light takes one feature count and writes three cascade
                // matrices (and three atlas records) at the directional feature pointer.
                if shadowed && featureLeft > 0 {
                    featureLeft -= 1
                    let mats = ShadowMaps.cascadeViewProjections(light, tile: ShadowMaps.tileSize(shadowQuality), ortho: ortho,
                                                                  eye: eye, viewForward: viewForward)
                    for m in mats {
                        let f = featureNext[0]; featureNext[0] += 1
                        if f < featureTotal {
                            for r in 0..<4 { for c in 0..<4 { spotFeatures[f * 16 + r * 4 + c] = m[c][r] } }
                        }
                        shadowRecords.append(.init(light: light, size: ShadowMaps.tileSize(shadowQuality), point: false,
                                                   projection: m, feature: f))
                    }
                }
            }
        }
        func set(_ name: String, _ v: [Float]) { if !v.isEmpty { uniforms[name] = .floats(v) } }
        set("g_LPoint_Color", point[0]); set("g_LPoint_Origin", point[1])
        set("g_LSpot_Color", spot[0]); set("g_LSpot_Origin", spot[1]); set("g_LSpot_Direction", spot[2]); set("g_LSpot_Exponent", spot[3])
        set("g_LTube_Color", tube[0]); set("g_LTube_OriginA", tube[1]); set("g_LTube_OriginB", tube[2])
        set("g_LDirectional_Color", directional[0]); set("g_LDirectional_Direction", directional[1])
        set("g_LFeature_ShadowPointProjection", featureProj)
        set("g_LFeature_ShadowProjection", spotFeatures)
        featureCount = featureTotal
    }

    /// The spot whose cookie is `_alias_lightCookie` this frame (`Lights_Update` C+0x1220 cache, 0x14019359b–0x1401935d8).
    var cookieLight: LightObject?
    /// Size of g_LFeature_ShadowProjection / …Transform.
    var featureCount = 0

    /// Writes each packed record's atlas transform into its feature slot and light +0x310 (0x1401960f3–0x140196114).
    mutating func setShadowTransforms(_ records: [ShadowMaps.Record], _ maps: ShadowMaps) {
        guard !records.isEmpty else { return }
        var t = [Float](repeating: 0, count: 4 * records.filter(\.point).count)
        var ft = [Float](repeating: 0, count: 4 * featureCount)
        for r in records {
            let v = maps.transform(r)
            if r.point {
                t.replaceSubrange(r.feature * 4..<r.feature * 4 + 4, with: [v.x, v.y, v.z, v.w])
            } else if r.feature < featureCount {
                ft.replaceSubrange(r.feature * 4..<r.feature * 4 + 4, with: [v.x, v.y, v.z, v.w])
            }
            r.light.shadowAtlasTransform = v
        }
        if !t.isEmpty { uniforms["g_LFeature_ShadowPointProjectionTransform"] = .floats(t) }
        if !ft.isEmpty { uniforms["g_LFeature_ShadowProjectionTransform"] = .floats(ft) }
    }
}
