import Foundation
import PhotonCore
import simd

/// Script writes to reflected properties that change engine state beyond the field itself (docs/re/script-api.md,
/// session 7 script2). Each case names the engine reader that makes the write visible; values that photon keeps only
/// for read-back still go to the per-object store (the caller stores them after this returns).
extension SceneScriptEngine {
    /// Applies a write to an object property that `setObject` does not model directly. Returns true when the value is
    /// now held by a model field (the caller then does not need the store for read-back, but keeps it anyway).
    @discardableResult
    func applyReflected(_ o: SceneObject, _ name: String, _ v: SVal) -> Bool {
        // Object base (table 0x1404e8250, registered by 0x1401e0530).
        switch name {
        case "name":
            // +0x1d8; name lookups (getLayer, the 0xa08 resolver 0x1816372d0) read it.
            if let s = Self.str(v) { o.objectName = s }
            return true
        case "sortorder":
            // +0x124, read by the customsortorder comparator 0x140186980 every SceneGraph_DrawList 0x14018aac0.
            if let f = Self.num(v) { o.sortOrder = Int(f) }
            return true
        case "solid":
            // +0x120 bit 13: Scene_HitTest 0x140189e10 skips objects without it (0x14018a02d).
            if let b = Self.bool(v) { o.solid = b }
            return true
        case "disablepropagation":
            // +0x120 bit 14: Scene_HitTest stops below a hit object that has it (0x14018a86f).
            if let b = Self.bool(v) { o.disablePropagation = b }
            return true
        case "perspective" where o is ImageLayer || o is TextObject || o is ModelObject:
            // +0x120 bit 7: Layer_Render 0x1401e9233 / 0x1401e9e9f and Model_Render 0x140222770 push the perspective.
            if let b = Self.bool(v) { o.perspective = b }
            return true
        default: break
        }
        if let img = o as? ImageLayer {
            switch name {
            // flags304 bits read while rendering (Layer_Render 0x1401e8ecb, Image_DrawIntoComposite 0x140207b5b,
            // Image_DrawDirect 0x140208786) or when the layer next allocates its targets (Layer_AllocRenderTargets
            // 0x1401ea500 via vt+0x128 0x1402091e0: nointerpolation 0x4000, clampuvs 0x8000).
            case "copybackground": if let b = Self.bool(v) { img.copyBackground = b }; return true
            case "nointerpolation": if let b = Self.bool(v) { img.noInterpolation = b }; return true
            case "clampuvs": if let b = Self.bool(v) { img.clampUVs = b }; return true
            case "ledsource": if let b = Self.bool(v) { img.ledSource = b }; return true // vt+0x68 0x1401ea2d0
            case "colorBlendMode": if let f = Self.num(v) { img.colorBlendMode = Int(f) }; return true // 0x1401e8ef2
            default: break
            }
        }
        if let t = o as? TextObject {
            switch name {
            case "clampuvs": if let b = Self.bool(v) { t.clampUVs = b }; return true
            case "ledsource": if let b = Self.bool(v) { t.ledSource = b }; return true
            case "colorBlendMode": if let f = Self.num(v) { t.colorBlendMode = Int(f) }; return true
            default: break
            }
        }
        if let m = o as? ModelObject, name == "rootmotion" {
            // +0x310 bit 0, read by Model_Update 0x14021cbf8 every update (RootMotion.swift).
            if let b = Self.bool(v) { m.rootMotionEnabled = b }
            return true
        }
        if let m = o as? ModelObject, name == "castshadow" {
            // +0x120 bit 11; the shadow caster list (0x14018acb0) needs 0x800 | 0x400 (0x400 = opaque mesh, model load).
            if let b = Self.bool(v) { m.castShadowFlag = b }
            return true
        }
        if let s = o as? SoundObject {
            switch name {
            // Sound_Update 0x1401f5980 reads these every frame (mintime/maxtime 0x1401f6c1a, mode byte +0x30c 0x1401f6930).
            case "mintime": if let f = Self.num(v) { s.minTime = f }; return true
            case "maxtime": if let f = Self.num(v) { s.maxTime = f }; return true
            case "playbackmode":
                // Enum +0x30c: loop 0, random 1, single 2; unknown → loop (table[0]).
                if let str = Self.str(v) { s.mode = str == "random" ? .random : str == "single" ? .single : .loop }
                return true
            default: break
            }
        }
        if let l = o as? LightObject {
            switch name {
            case "density": if let f = Self.num(v) { l.density = f }; return true
            case "volumetricsexponent": if let f = Self.num(v) { l.volumetricsExponent = f }; return true
            case "cascadedistance0", "cascadedistance1", "cascadedistance2":
                if let f = Self.num(v), let i = Int(String(name.last!)) { l.cascadeDistances[i] = f }
                return true
            case "lightsourcesize": if let f = Self.num(v) { l.lightSourceSize = f }; return true
            case "controlpoint": l.controlPoint = Self.v3(v, l.controlPoint); return true
            case "castshadow": if let b = Self.bool(v) { l.castShadow = b }; return true
            case "castvolumetrics": if let b = Self.bool(v) { l.castVolumetrics = b }; return true
            case "usecookie":
                if let b = Self.bool(v) {
                    l.useCookie = b
                    // Light load 0x14025d080 names the cookie only with usecookie; the change callback 0x14025c610
                    // drops the cached resources so the next frame reloads them.
                    if b, l.cookieName == nil {
                        l.cookieName = (l.json["cookie"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "cookie/flashlight1"
                    }
                }
                return true
            case "light":
                // Type enum +0x2c0 (table 0x14025e853), change callback 0x14025c610.
                if let s = Self.str(v) {
                    switch s {
                    case "lpoint": l.kind = .point
                    case "lspot": l.kind = .spot
                    case "ltube": l.kind = .tube
                    case "ldirectional": l.kind = .directional
                    default: l.kind = nil
                    }
                }
                return true
            default: break
            }
        }
        return false
    }

    /// Material properties (table 0x1404e7fd0, bytes +0x1f0…+0x1f4) are read by Material_Apply 0x140155fc0 at every
    /// draw; the combos they add at load (ADDITIVE, ALPHATOCOVERAGE) stay as built.
    func applyMaterialProperty(_ m: Material, _ name: String, _ v: SVal) {
        guard let s = Self.str(v) else { return }
        switch name {
        case "blending": m.blending = Material.Blending(rawValue: s) ?? .normal
        case "alphawriting": m.alphaWriting = ["enabled", "disabled"].contains(s) ? s : "default"
        case "depthtest": m.depthTest = s == "enabled"
        case "depthwrite": m.depthWrite = s == "enabled"
        case "cullmode": m.cullNone = s == "nocull"
        default: break
        }
    }

    /// `general` writes (table 0x1404e81c0, registered by 0x140199780). The value goes into `scene.general`, which photon
    /// reads every frame for the sort flags, perspective push fov, puppet gravity/wind and the projection; the engine's
    /// change callbacks are mirrored for the rest: bloom 0x1401863e0 (dirty bit S+0xe0 bit 31, consumed after
    /// Bindings_Tick by 0x140184020 at 0x1401802f5), ambient/skylight 0x1401863f0, fog 0x140186440.
    func applyGeneral(_ name: String, _ v: SVal) -> Bool {
        guard let t = ScriptReflection.classes["general"]?.index[name]?.type else { return false }
        let s = scene
        let value: Any
        switch (t, v) {
        case (.bool, .bool(let b)), (.byte, .bool(let b)): value = NSNumber(value: b)
        case (.int, _): guard let f = Self.num(v) else { return true }; value = NSNumber(value: Int(f))
        case (.float, _): guard let f = Self.num(v) else { return true }; value = NSNumber(value: f)
        case (.vec2, _), (.vec3, _), (.vec4, _):
            let d = SceneObject.vec3(s.general[name]) ?? .zero
            let c = Self.v3(v, d)
            value = "\(c.x) \(c.y) \(c.z)"
        default: return false
        }
        s.general[name] = value
        switch name {
        case "bloom": if case .bool(let b) = v { s.bloom = b } // read each frame at 0x140180a51
        case "clearenabled": if case .bool(let b) = v { s.clearEnabled = b } // Scene_DrawObjectsToMain 0x14018358e
        case "ambientcolor", "skylightcolor": s.applyGeneralLighting()
        default:
            if name.hasPrefix("fog") { s.applyGeneralLighting() }
            if name.hasPrefix("bloom") { bloomDirty = true }
        }
        return true
    }

    /// `0x140184020`: re-uploads the bloom constants after a script changed a bloom property (non-HDR: the quarter
    /// downsample material R+0x3160 gets bloomstrength / bloomthreshold / bloomtint; HDR: R+0x3190 gets bloomstrength =
    /// hdrstrength / (scatter^(max(n, 2) − 2) + 1) with n = min(iterations, levels), blend = (T, T − T·f, 2·T·f,
    /// 0.25 / (T·f + 1e-5)), bloomtint, and both upsample materials (R+0x31a0 / R+0x31a8) get scatter).
    func applyBloomConstants() {
        let s = scene, g = s.general
        let tint = SceneObject.vec3(g["bloomtint"]) ?? SIMD3(1, 1, 1)
        let tintStr = "\(tint.x) \(tint.y) \(tint.z)"
        if s.hdr {
            s.hdrStrength = EngineValue.float(g["bloomhdrstrength"], default: 2)
            s.hdrScatter = EngineValue.float(g["bloomhdrscatter"], default: 1.619)
            s.hdrIterations = EngineValue.int(g["bloomhdriterations"], default: 8)
            let T = EngineValue.float(g["bloomhdrthreshold"], default: 1)
            let f = EngineValue.float(g["bloomhdrfeather"], default: 0.1)
            let n = s.hdrIterationCount
            s.hdrDownBloom?.constants["bloomstrength"] = s.hdrStrength / (powf(s.hdrScatter, Float(max(n, 2) - 2)) + 1)
            s.hdrDownBloom?.constants["blend"] = "\(T) \(T - T * f) \(2 * T * f) \(0.25 / (T * f + 1e-5))"
            s.hdrDownBloom?.constants["bloomtint"] = tintStr
            s.hdrUp?.constants["scatter"] = NSNumber(value: s.hdrScatter)
            s.hdrUpCubic?.constants["scatter"] = NSNumber(value: s.hdrScatter)
        } else if let m = s.bloomPasses.first?.0 {
            m.constants["bloomstrength"] = NSNumber(value: EngineValue.float(g["bloomstrength"], default: 2))
            m.constants["bloomthreshold"] = NSNumber(value: EngineValue.float(g["bloomthreshold"], default: 0.65))
            m.constants["bloomtint"] = tintStr
        }
    }
}
