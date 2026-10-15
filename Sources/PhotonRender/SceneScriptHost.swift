import AppKit
import Foundation
import JavaScriptCore
import PhotonCore
import simd

/// Host side of the generic wrappers (docs/re/08 §3.9, §3.10): property get/set and method calls on
/// photon's scene objects. Properties photon does not model fall back to a per-object store seeded from
/// the object's scene.json value, so scripts can still read and write them.
extension SceneScriptEngine {
    private static let deg = Float(180 / Double.pi)

    // MARK: - Conversions

    static func arr<V: SIMD>(_ v: V) -> [Float] where V.Scalar == Float { (0..<v.scalarCount).map { v[$0] } }

    static func v3(_ s: SVal, _ d: SIMD3<Float>) -> SIMD3<Float> {
        switch s {
        case .vec(let v) where v.count >= 3: return SIMD3(v[0], v[1], v[2])
        case .num(let n): return SIMD3(repeating: Float(n))
        default: return d
        }
    }

    static func v2(_ s: SVal, _ d: SIMD2<Float>) -> SIMD2<Float> {
        switch s {
        case .vec(let v) where v.count >= 2: return SIMD2(v[0], v[1])
        case .num(let n): return SIMD2(repeating: Float(n))
        default: return d
        }
    }

    static func num(_ s: SVal) -> Float? {
        if case .num(let n) = s { return Float(n) }
        if case .vec(let v) = s, let f = v.first { return f }
        return nil
    }

    static func bool(_ s: SVal) -> Bool? {
        if case .bool(let b) = s { return b }
        return nil
    }

    static func str(_ s: SVal) -> String? {
        switch s {
        case .str(let x): return x
        case .num(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    /// A scene.json value converted to a reflection type (fallback for unmodelled properties).
    static func fromJSON(_ v: Any?, _ type: ScriptReflection.ValueType) -> SVal {
        switch type {
        case .vec2, .vec3, .vec4:
            var f = jsonFloats(v)
            if f.count == 1 { f = Array(repeating: f[0], count: type.components) }
            while f.count < type.components { f.append(0) }
            return .vec(Array(f.prefix(type.components)))
        case .float, .int:
            return .num(Double(jsonFloats(v).first ?? 0))
        case .bool, .byte:
            return .bool(jsonBool(v, default: false))
        case .string:
            switch unwrapUserValue(v) {
            case let s as String: return .str(s)
            case let n as NSNumber: return .str(n.stringValue)
            default: return .str("")
            }
        case .object:
            return .null
        }
    }

    private func propType(_ ref: HostRef, _ name: String) -> ScriptReflection.ValueType? {
        ScriptReflection.classes[className(ref)]?.index[name]?.type
    }

    private func fallback(_ ref: HostRef, _ h: Int, _ name: String, json: [String: Any]?) -> SVal {
        if let s = stored[h]?[name] { return s }
        guard let t = propType(ref, name) else { return .null }
        return Self.fromJSON(json?[name], t)
    }

    // MARK: - get

    func get(_ ref: HostRef, _ h: Int, _ name: String) -> SVal {
        switch ref {
        case .scene: return getScene(h, name)
        case .sceneObject: return getScene(handle(.scene, key: "scene"), name)
        case .object(let o): return getObject(o, h, name)
        case .instance(let p):
            let ov = p.override
            switch name {
            case "alpha": return .num(Double(ov.alpha))
            case "size": return .num(Double(ov.size))
            case "count": return .num(Double(ov.count))
            case "speed": return .num(Double(ov.speed))
            case "lifetime": return .num(Double(ov.lifetime))
            case "brightness": return .num(Double(ov.brightness))
            case "rate": return .num(Double(ov.rate))
            case "colorn": return .vec(Self.arr(ov.colorn ?? SIMD3(1, 1, 1)))
            default:
                if let i = Self.cpIndex(name, "controlpointangle") { return .vec(Self.arr(ov.cpAngle[i] ?? .zero)) }
                if let i = Self.cpIndex(name, "controlpoint") { return .vec(Self.arr(ov.cp[i] ?? .zero)) }
                return fallback(ref, h, name, json: nil)
            }
        case .effect(let e, _):
            switch name {
            case "visible": return .bool(e.visible)
            case "name": return .str(e.name)
            default: return fallback(ref, h, name, json: nil)
            }
        case .material(let m, _, _):
            switch name {
            case "blending": return .str(m.blending.rawValue)
            case "alphawriting": return .str(m.alphaWriting)
            case "depthtest": return .str(m.depthTest ? "enabled" : "disabled")
            case "depthwrite": return .str(m.depthWrite ? "enabled" : "disabled")
            case "cullmode": return .str(m.cullNone ? "nocull" : "normal")
            default: return fallback(ref, h, name, json: nil)
            }
        case .constants(let e, let pass, _):
            guard let m = e.passes.first(where: { $0.jsonIndex == pass && $0.material != nil })?.material else { return .null }
            let t = valueType(ref, name, json: m.constants[name] as? [String: Any])
            if m.program?.info.values.values.contains(where: { $0.materialKey == name && $0.degrees }) == true {
                // rad2deg constants: descriptor flag 4 (0x14015544e), native → JS × 57.2958 (docs/re/02 §4.2).
                let f = jsonFloats(m.constants[name]).map { Double($0) * 57.2958 }
                if t == .float || t == .int { return .num(f.first ?? 0) }
                return .vec(f.map { Float($0) })
            }
            if t == .float || t == .int { return .num(Double(jsonFloats(m.constants[name]).first ?? 0)) }
            return Self.fromJSON(m.constants[name], t)
        case .propertyAnimation, .anim:
            guard let a = animation(ref) else { return .null }
            switch name {
            case "rate": return .num(Double(a.rate))
            case "fps": return .num(Double(a.fps))
            case "frameCount": return .num(Double(a.length))
            case "duration": return .num(Double(a.duration))
            case "name": return .str(a.name)
            default: return .null
            }
        case .videoTexture(_, let v):
            let c = v.scriptClock
            switch name {
            case "rate": return .num(Double(c?.rate ?? 1))
            case "loop": return .bool(c?.loop ?? true)
            case "duration": return .num(v.duration)
            default: return fallback(ref, h, name, json: nil)
            }
        case .textureAnimation(let img):
            let frames = img.texture?.tex.frames ?? []
            switch name {
            case "rate": return .num(Double(img.spriteClock?.rate ?? 1))
            case "frameCount": return .num(Double(frames.count))
            case "duration": return .num(Double(frames.reduce(0) { $0 + $1.frameTime }))
            default: return .null
            }
        case .animationLayer(let img, let idx):
            guard let p = Self.puppet(img), let l = p.layers.first(where: { $0.jsonIndex == idx }) else { return fallback(ref, h, name, json: nil) }
            switch name {
            case "visible": return .bool(l.visible)
            case "additive": return .bool(l.additive)
            case "blendin": return .bool(l.blendIn)
            case "blendout": return .bool(l.blendOut)
            case "name": return .str(l.name)
            case "rate": return .num(Double(l.rate))
            case "blend": return .num(Double(l.blend))
            case "blendtime": return .num(Double(l.blendTime))
            case "fps": return .num(Double(l.animation.fps))
            case "frameCount": return .num(Double(l.animation.frames))
            case "duration": return .num(Double(l.duration))
            default: return .null
            }
        }
    }

    static func cpIndex(_ name: String, _ prefix: String) -> Int? {
        guard name.hasPrefix(prefix), let i = Int(name.dropFirst(prefix.count)), (0..<8).contains(i) else { return nil }
        return i
    }

    private func getObject(_ o: SceneObject, _ h: Int, _ name: String) -> SVal {
        switch name {
        case "origin": return .vec(Self.arr(o.origin))
        case "scale": return .vec(Self.arr(o.scale))
        case "angles": return .vec(Self.arr(o.angles * Self.deg)) // flag 4: JS sees degrees
        case "parallaxDepth": return .vec(Self.arr(o.parallaxDepth))
        case "visible": return .bool(o.visible)
        case "name": return .str(o.objectName)
        default: break
        }
        if let img = o as? ImageLayer {
            switch name {
            case "size": return .vec(Self.arr(img.size))
            case "color": return .vec(Self.arr(img.color))
            case "alpha": return .num(Double(img.alpha))
            case "brightness": return .num(Double(img.brightness))
            case "alignment": return .str(img.alignment.rawValue)
            case "colorBlendMode": return .num(Double(img.colorBlendMode))
            case "copybackground": return .bool(img.copyBackground)
            case "clampuvs": return .bool(img.clampUVs)
            case "nointerpolation": return .bool(img.noInterpolation)
            default: break
            }
        }
        if let t = o as? TextObject {
            switch name {
            case "text": return .str(t.text)
            case "font": return .str(t.font)
            case "pointsize": return .num(Double(t.pointSize))
            case "padding": return .vec(Self.arr(t.padding))
            case "spacing": return .vec(Self.arr(t.spacing))
            case "maxwidth": return .num(Double(t.maxWidth))
            case "maxrows": return .num(Double(t.maxRows))
            case "backgroundcolor": return .vec(Self.arr(t.backgroundColor))
            case "backgroundbrightness": return .num(Double(t.backgroundBrightness))
            case "opaquebackground": return .bool(t.opaqueBackground)
            case "limitwidth": return .bool(t.limitWidth)
            case "limitrows": return .bool(t.limitRows)
            case "limituseellipsis": return .bool(t.limitUseEllipsis)
            case "blockalign": return .bool(t.blockAlign)
            case "msdf": return .bool(t.msdf)
            case "outline": return .bool(t.outline)
            case "blur": return .bool(t.blur)
            case "dropshadow": return .bool(t.dropShadow)
            case "horizontalalign": return .str(["left", "center", "right"][min(max(t.horizontalAlign, 0), 2)])
            case "verticalalign": return .str(["bottom", "center", "top"][min(max(t.verticalAlign, 0), 2)])
            case "anchor": return .str(Self.anchorNames[t.anchor.rawValue])
            case "color": return .vec(Self.arr(t.color))
            case "alpha": return .num(Double(t.alpha))
            case "brightness": return .num(Double(t.brightness))
            case "size": return .vec(Self.arr(t.size))
            case "colorBlendMode": return .num(Double(t.colorBlendMode))
            default: break
            }
        }
        if let p = o as? ParticleSystemObject, name == "instance" {
            return .host(handle(.instance(p), key: "i\(ObjectIdentifier(p).hashValue)"), "instance")
        }
        if let s = o as? SoundObject, name == "volume" { return .num(Double(s.volume)) }
        if let c = o as? CameraObject {
            if name == "zoom" { return .num(Double(c.zoom)) }
            if name == "fov" { return .num(Double(c.fov)) }
        }
        if let l = o as? LightObject { // light reflection 0x14025da80
            switch name {
            case "color": return .vec(Self.arr(l.color))
            case "intensity": return .num(Double(l.intensity))
            case "radius": return .num(Double(l.radius))
            case "exponent": return .num(Double(l.exponent))
            case "innercone": return .num(Double(l.innerCone))
            case "outercone": return .num(Double(l.outerCone))
            default: break
            }
        }
        return fallback(.object(o), h, name, json: o.json)
    }

    static let anchorNames = ["none", "center", "top", "topright", "right", "bottomright", "bottom", "bottomleft", "left", "topleft"]

    private func getScene(_ h: Int, _ name: String) -> SVal {
        let s = scene
        switch name {
        case "clearcolor": return .vec(Self.arr(s.clearColor))
        case "bloom": return .bool(s.bloom)
        case "cameraparallax": return .bool(s.cameraParallax)
        case "cameraparallaxamount": return .num(Double(s.parallaxAmount))
        case "cameraparallaxdelay": return .num(Double(s.parallaxDelay))
        case "cameraparallaxmouseinfluence": return .num(Double(s.parallaxMouseInfluence))
        case "camerashake": return .bool(s.cameraShake)
        case "camerashakespeed": return .num(Double(s.shakeSpeed))
        case "camerashakeamplitude": return .num(Double(s.shakeAmplitude))
        case "camerashakeroughness": return .num(Double(s.shakeRoughness))
        default: return fallback(.scene, h, name, json: s.general)
        }
    }

    // MARK: - set

    func set(_ ref: HostRef, _ h: Int, _ name: String, _ v: SVal) {
        switch ref {
        case .scene: setScene(h, name, v)
        case .sceneObject: setScene(handle(.scene, key: "scene"), name, v)
        case .object(let o): setObject(o, h, name, v)
        case .instance(let p):
            var ov = p.override
            switch name {
            case "alpha": if let f = Self.num(v) { ov.alpha = f }
            case "size": if let f = Self.num(v) { ov.size = f }
            case "count": if let f = Self.num(v) { ov.count = f }
            case "speed": if let f = Self.num(v) { ov.speed = f }
            case "lifetime": if let f = Self.num(v) { ov.lifetime = f }
            case "brightness": if let f = Self.num(v) { ov.brightness = f }
            case "rate": if let f = Self.num(v) { ov.rate = max(0.01, f) }
            case "colorn": ov.colorn = Self.v3(v, ov.colorn ?? SIMD3(1, 1, 1))
            default:
                if let i = Self.cpIndex(name, "controlpointangle") { ov.cpAngle[i] = Self.v3(v, ov.cpAngle[i] ?? .zero) }
                else if let i = Self.cpIndex(name, "controlpoint") { ov.cp[i] = Self.v3(v, ov.cp[i] ?? .zero) }
                else { stored[h, default: [:]][name] = v; return }
            }
            p.override = ov
            p.system?.applyOverrides(force: false)
        case .effect(let e, let owner):
            switch name {
            case "visible":
                if let b = Self.bool(v), b != e.visible {
                    e.visible = b
                    Self.refreshEffects(owner)
                }
            default: stored[h, default: [:]][name] = v
            }
        case .material(let m, _, _):
            applyMaterialProperty(m, name, v)
        case .constants(let e, let pass, _):
            let floats: [Float]
            switch v {
            case .num(let n): floats = [Float(n)]
            case .vec(let a): floats = a
            case .bool(let b): floats = [b ? 1 : 0]
            default: return
            }
            for p in e.passes where p.jsonIndex == pass {
                // rad2deg constants: JS → native × 0.0174533 (descriptor flag 4).
                let deg = p.material?.program?.info.values.values.contains(where: { $0.materialKey == name && $0.degrees }) == true
                p.material?.constants[name] = floats.map { NSNumber(value: deg ? $0 * 0.0174533 : $0) }
            }
        case .propertyAnimation, .anim:
            if name == "rate", let f = Self.num(v) { animation(ref)?.rate = f }
        case .videoTexture(_, let video):
            // rate → player vt+0x68 (0x1401fa6d0); loop → vt+0x70 (0x1401fa700).
            switch name {
            case "rate": if let f = Self.num(v) { video.scriptClock?.rate = f }
            case "loop": if let b = Self.bool(v) { video.scriptClock?.loop = b }
            default: stored[h, default: [:]][name] = v
            }
        case .textureAnimation(let img):
            // Rate callback 0x1401fa4a0: a rate other than 1 detaches, taking the texture's (index, time) when it is a
            // sprite sheet; `playing` is left as it is.
            if name == "rate", let f = Self.num(v) {
                let c = spriteClock(img)
                c.rate = f
                if f != 1 && c.attached { Self.copySharedClock(img, into: c); c.attached = false }
            }
        case .animationLayer(let img, let idx):
            guard let p = Self.puppet(img), let i = p.layers.firstIndex(where: { $0.jsonIndex == idx }) else { return }
            switch name {
            case "visible": if let b = Self.bool(v) { p.layers[i].visible = b }
            case "additive": if let b = Self.bool(v) { p.layers[i].additive = b }
            case "blendin": if let b = Self.bool(v) { p.layers[i].blendIn = b }
            case "blendout": if let b = Self.bool(v) { p.layers[i].blendOut = b }
            case "rate": if let f = Self.num(v) { p.layers[i].rate = f }
            case "blend": if let f = Self.num(v) { p.layers[i].blend = f }
            case "blendtime": if let f = Self.num(v) { p.layers[i].blendTime = f }
            default: break
            }
        }
    }

    /// Effect visibility changes the layer's composite step count, geometry and targets (docs/re/03 §6).
    static func refreshEffects(_ owner: SceneObject) {
        if let img = owner as? ImageLayer {
            img.compositeSteps = img.effects.filter(\.visible).reduce(0) { $0 + 1 + $1.composeCount }
            img.buildGeometry()
            img.allocateTargets()
        } else if let t = owner as? TextObject {
            t.compositeSteps = t.effects.filter(\.visible).reduce(0) { $0 + 1 + $1.composeCount }
            t.rebuild()
        }
    }

    private func setObject(_ o: SceneObject, _ h: Int, _ name: String, _ v: SVal) {
        switch name {
        case "origin": o.origin = Self.v3(v, o.origin); return
        case "scale": o.scale = Self.v3(v, o.scale); return
        case "angles": o.angles = Self.v3(v, o.angles * Self.deg) / Self.deg; return
        case "parallaxDepth": o.parallaxDepth = Self.v2(v, o.parallaxDepth); return
        case "visible": if let b = Self.bool(v) { o.visible = b }; return
        default: break
        }
        if let img = o as? ImageLayer {
            switch name {
            case "size":
                let s = Self.v2(v, img.size)
                if s != img.size { img.size = s; img.buildGeometry() }
                return
            case "color": img.color = Self.v3(v, img.color); return
            case "alpha": if let f = Self.num(v) { img.alpha = f }; return
            case "brightness": if let f = Self.num(v) { img.brightness = f }; return
            case "alignment":
                if let s = Self.str(v), let a = ImageLayer.Alignment(rawValue: s), a != img.alignment { img.alignment = a }
                return
            default: break
            }
        }
        if let t = o as? TextObject {
            var rebuild = false
            func upd<T: Equatable>(_ kp: ReferenceWritableKeyPath<TextObject, T>, _ nv: T?) {
                guard let nv, t[keyPath: kp] != nv else { return }
                t[keyPath: kp] = nv
                rebuild = true
            }
            switch name {
            case "text": upd(\.text, Self.str(v))
            case "font": upd(\.font, Self.str(v))
            case "pointsize": upd(\.pointSize, Self.num(v))
            case "padding": upd(\.padding, Self.v2(v, t.padding))
            case "spacing": upd(\.spacing, Self.v2(v, t.spacing))
            case "maxwidth": upd(\.maxWidth, Self.num(v))
            case "maxrows": upd(\.maxRows, Self.num(v).map { Int($0) })
            case "opaquebackground": upd(\.opaqueBackground, Self.bool(v))
            case "limitwidth": upd(\.limitWidth, Self.bool(v))
            case "limitrows": upd(\.limitRows, Self.bool(v))
            case "limituseellipsis": upd(\.limitUseEllipsis, Self.bool(v))
            case "blockalign": upd(\.blockAlign, Self.bool(v))
            case "horizontalalign":
                if let s = Self.str(v) { upd(\.horizontalAlign, s == "center" ? 1 : s == "right" ? 2 : 0) }
            case "verticalalign":
                if let s = Self.str(v) { upd(\.verticalAlign, s == "top" ? 2 : s == "bottom" ? 0 : 1) }
            case "anchor":
                if let s = Self.str(v) { t.anchor = TextObject.Anchor(rawValue: Self.anchorNames.firstIndex(of: s) ?? 0) ?? .none }
                return
            case "backgroundcolor": t.backgroundColor = Self.v3(v, t.backgroundColor); return
            case "backgroundbrightness": if let f = Self.num(v) { t.backgroundBrightness = f }; return
            case "color": t.color = Self.v3(v, t.color); return
            case "alpha": if let f = Self.num(v) { t.alpha = f }; return
            case "brightness": if let f = Self.num(v) { t.brightness = f }; return
            case "size": return // computed from the text block
            default:
                if applyReflected(t, name, v), let ty = propType(.object(t), name) {
                    stored[h, default: [:]][name] = Self.coerce(v, ty)
                } else {
                    stored[h, default: [:]][name] = v
                }
                return
            }
            if rebuild { t.rebuild() }
            return
        }
        if let s = o as? SoundObject, name == "volume", let f = Self.num(v) { s.volume = f; return }
        if let c = o as? CameraObject {
            if name == "zoom", let f = Self.num(v) { c.zoom = f; return }
            if name == "fov", let f = Self.num(v) { c.fov = f; return }
        }
        if let l = o as? LightObject {
            switch name {
            case "color": l.color = Self.v3(v, l.color); return
            case "intensity": if let f = Self.num(v) { l.intensity = f }; return
            case "radius": if let f = Self.num(v) { l.radius = f }; return
            case "exponent": if let f = Self.num(v) { l.exponent = f }; return
            case "innercone": if let f = Self.num(v) { l.innerCone = f }; return
            case "outercone": if let f = Self.num(v) { l.outerCone = f }; return
            default: break
            }
        }
        if applyReflected(o, name, v), let t = propType(.object(o), name) {
            stored[h, default: [:]][name] = Self.coerce(v, t)
            return
        }
        stored[h, default: [:]][name] = v
    }

    /// A written value as the reflected field holds it (int truncation, float precision), for read-back.
    static func coerce(_ v: SVal, _ t: ScriptReflection.ValueType) -> SVal {
        switch (t, v) {
        case (.int, .num(let n)): return .num(Double(Int(n)))
        case (.float, .num(let n)): return .num(Double(Float(n)))
        default: return v
        }
    }

    private func setScene(_ h: Int, _ name: String, _ v: SVal) {
        let s = scene
        switch name {
        case "clearcolor": s.clearColor = Self.v3(v, s.clearColor)
        case "cameraparallax": if let b = Self.bool(v) { s.cameraParallax = b }
        case "cameraparallaxamount": if let f = Self.num(v) { s.parallaxAmount = f }
        case "cameraparallaxdelay": if let f = Self.num(v) { s.parallaxDelay = f }
        case "cameraparallaxmouseinfluence": if let f = Self.num(v) { s.parallaxMouseInfluence = f }
        case "camerashake": if let b = Self.bool(v) { s.cameraShake = b }
        case "camerashakespeed": if let f = Self.num(v) { s.shakeSpeed = f }
        case "camerashakeamplitude": if let f = Self.num(v) { s.shakeAmplitude = f }
        case "camerashakeroughness": if let f = Self.num(v) { s.shakeRoughness = f }
        case "bloomstrength", "bloomthreshold":
            if let f = Self.num(v) {
                s.general[name] = NSNumber(value: f)
                s.bloomPasses.first?.0.constants[name] = NSNumber(value: f)
            }
        case "fov", "nearz", "farz", "zoom":
            // projection() reads these from `general` every frame.
            if let f = Self.num(v) { s.general[name] = NSNumber(value: f) }
        default:
            if applyGeneral(name, v) { stored[h]?[name] = nil } else { stored[h, default: [:]][name] = v }
        }
    }

    // MARK: - Methods

    private func argHandle(_ a: JSValue?) -> Int? {
        guard let a, a.isObject, let h = a.forProperty("__host"), h.isNumber else { return nil }
        return Int(h.toInt32())
    }

    /// The scene's object list as scripts see it: during Scene_Load only the objects created so far.
    /// The object list S+0x158 as thisScene sees it, objects pending destruction included (index space of getLayer(n)
    /// and getLayerIndex).
    var scriptObjectList: [SceneObject] {
        guard !hiddenObjects.isEmpty else { return scene.objects }
        return scene.objects.filter { !hiddenObjects.contains(ObjectIdentifier($0)) }
    }

    /// Objects visible to the name / id lookups (0x1401966d0, 0x140196840), enumerateLayers and getLayerCount
    /// (0x14018b570: size minus the pending set): the list without destroyLayer'd objects.
    var scriptObjects: [SceneObject] {
        guard !pendingDestroy.isEmpty else { return scriptObjectList }
        return scriptObjectList.filter { !pendingDestroy.contains(ObjectIdentifier($0)) }
    }

    /// `0xa08` argument: wrapper, name, or id string; a Number is an index (§3.9, Unknown 2).
    func resolveLayer(_ a: JSValue?) -> SceneObject? {
        guard let a else { return nil }
        if let h = argHandle(a), h < refs.count, case .object(let o) = refs[h] { return o }
        let objects = scriptObjects
        if a.isString {
            let s = a.toString() ?? ""
            if let o = objects.first(where: { $0.objectName == s }) { return o }
            // Resolver 0x1816372d0: name first (host +0x08), then strtol(s, 10) as an id (host +0x10).
            let id = Self.strtol10(s)
            return objects.first { $0.id == id }
        }
        if a.isNumber {
            // host 0x140196980: unsigned bound check on the whole list; an object pending destruction gives null.
            let all = scriptObjectList, i = Int(a.toInt32())
            guard all.indices.contains(i), !pendingDestroy.contains(ObjectIdentifier(all[i])) else { return nil }
            return all[i]
        }
        return nil
    }

    private func jsArray(_ items: [JSValue]) -> JSValue {
        let a = JSValue(newArrayIn: context)!
        for (i, v) in items.enumerated() { a.setValue(v, at: i) }
        return a
    }

    private func vecArg(_ a: JSValue?) -> [Float]? {
        guard let a else { return nil }
        if a.isNumber { return [Float(a.toDouble())] }
        guard a.isObject else { return nil }
        var out: [Float] = []
        for k in ["x", "y", "z", "w"] {
            guard let c = a.forProperty(k), c.isNumber else { break }
            out.append(Float(c.toDouble()))
        }
        return out.isEmpty ? nil : out
    }

    /// C `strtol(s, 0, 10)`: leading whitespace, optional sign, decimal digits; 0 when there are none.
    static func strtol10(_ s: String) -> Int {
        var t = Substring(s).drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\u{0B}" || $0 == "\u{0C}" })
        var neg = false
        if let c = t.first, c == "+" || c == "-" { neg = c == "-"; t = t.dropFirst() }
        let d = t.prefix(while: { $0 >= "0" && $0 <= "9" })
        let v = Int(d.prefix(18)) ?? 0
        return neg ? -v : v
    }

    func spriteClock(_ img: ImageLayer) -> ImageLayer.SpriteClock {
        if let c = img.spriteClock { return c }
        let c = ImageLayer.SpriteClock()
        img.spriteClock = c
        return c
    }

    /// The texture's shared clock (+0x9c index, +0xa0 time) copied as one qword into the animation's +0xe8/+0xec, only
    /// when the layer texture is a sprite sheet (0x1401fa369–0x1401fa382).
    static func copySharedClock(_ img: ImageLayer, into c: ImageLayer.SpriteClock) {
        guard let gpu = img.texture, gpu.tex.flags.contains(.spriteSheet) else { return }
        c.index = gpu.spriteIndex
        c.time = gpu.spriteTime
    }

    func call(_ ref: HostRef, _ h: Int, _ name: String, _ args: [JSValue], _ curKey: String) -> JSValue? {
        let ctx = context
        let undef = JSValue(undefinedIn: ctx)!
        func bool(_ b: Bool) -> JSValue { JSValue(bool: b, in: ctx) }
        func num(_ d: Double) -> JSValue { JSValue(double: d, in: ctx) }
        let nul = JSValue(nullIn: ctx)!

        if name == "getAnimation" {
            // Named animation, else the one on the property the running script is bound to (§3.10). Host +0x78 =
            // exe 0x14018db00 matches `options.name` or the bound property name; nothing found → null.
            let named = args.first.flatMap { $0.isString ? $0.toString() : nil }
            if case .scene = ref { return sceneAnimation(named ?? curKey) }
            // Effect wrappers (thisObject of constant scripts): the effect's constant animations.
            if case .effect(let e, _) = ref {
                guard let a = scene.constantAnimations?.find(effect: e, name: named ?? curKey) else { return nul }
                return jsWrap(handle(.anim(a), key: "ca\(ObjectIdentifier(a).hashValue)"))
            }
            guard case .object(let o) = ref else { return nul }
            let want = args.first.flatMap { $0.isString ? $0.toString() : nil }
            var key: String?
            if let want {
                key = o.animations.first(where: { $0.value.name == want })?.key ?? (o.animations[want] != nil ? want : nil)
                if key == nil {
                    // An animated property the object type does not animate itself: register it so it can play.
                    for (k, v) in o.json {
                        guard let a = PropertyAnimation(json: v), a.name == want else { continue }
                        o.animations[k] = a
                        key = k
                        break
                    }
                }
            }
            else if o.animations[curKey] != nil { key = curKey }
            else { key = o.animations.first(where: { $0.value.name == curKey })?.key }
            guard let key else { return nul }
            return jsWrap(handle(.propertyAnimation(o, key), key: "p\(ObjectIdentifier(o).hashValue)_\(key)"))
        }

        switch ref {
        case .scene:
            return callScene(name, args)
        case .sceneObject:
            return undef
        case .object(let o):
            switch name {
            case "getTransformMatrix":
                // 0x1401df5e0: vt+0x80 (image/text layers include their alignment offset).
                let m = Self.vt80(o)
                return jsMk(9, [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { Self.arr($0) })
            case "getParent": return jsWrap(o.parent)
            case "getChildren": return jsArray(scene.objects.filter { $0.parent === o }.map { jsWrap($0) })
            case "setParent":
                scriptSetParent(o, args)
                return undef
            case "rotateObjectSpace":
                if let v = vecArg(args.first), v.count >= 3 { Self.rotateObjectSpace(o, SIMD3(v[0], v[1], v[2])) }
                return undef
            case "getAttachmentIndex":
                // 0x1401e01d0: vt+0x70(name) (puppet / model attachment by exact name, else −1).
                guard let n = args.first, n.isString else { return num(-1) }
                return num(Double(o.attachmentIndex(n.toString() ?? "")))
            case "getAttachmentMatrix", "getAttachmentOrigin", "getAttachmentAngles":
                // 0x1401e01f0 / 0x1401e02c0 / 0x1401e0390: M = identity, replaced by vt+0x78(index) (an int argument, or
                // the index of a string name) when that succeeds; result = world · M (0x14005ecb0). Origin = its
                // translation; angles (degrees) = z atan2(M1, M0), y atan2(−M2, √(M6² + M10²)),
                // x atan2(sin z·M8 − cos z·M9, cos z·M5 − sin z·M4).
                var idx = -1
                if let a = args.first {
                    if a.isNumber { idx = Int(a.toInt32()) } else if a.isString { idx = o.attachmentIndex(a.toString() ?? "") }
                }
                let M = Self.vt80(o) * (o.attachmentTransform(idx) ?? matrix_identity_float4x4)
                let m = [M.columns.0, M.columns.1, M.columns.2, M.columns.3].flatMap { Self.arr($0) }
                if name == "getAttachmentMatrix" { return jsMk(9, m) }
                if name == "getAttachmentOrigin" { return jsMk(2, [m[12], m[13], m[14]]) }
                let z = atan2f(m[1], m[0])
                let y = atan2f(-m[2], (m[6] * m[6] + m[10] * m[10]).squareRoot())
                let sz = sinf(z), cz = cosf(z)
                let x = atan2f(sz * m[8] - cz * m[9], cz * m[5] - sz * m[4])
                return jsMk(2, [x * 57.2958, y * 57.2958, z * 57.2958])
            case "lookAt", "lookAtYaw":
                if let t = vecArg(args.first), t.count >= 3 {
                    let up = args.count >= 2 ? vecArg(args[1]).flatMap { $0.count >= 3 ? SIMD3($0[0], $0[1], $0[2]) : nil } : nil
                    Self.lookAt(o, target: SIMD3(t[0], t[1], t[2]), up: up ?? SIMD3(0, 1, 0), yawOnly: name == "lookAtYaw")
                }
                return undef
            default: break
            }
            if let img = o as? ImageLayer {
                switch name {
                case "getEffectCount": return num(Double(img.effects.count))
                case "getEffect": return effectArg(img.effects, owner: img, args.first)
                case "transformAttachmentToTexture": return transformAttachmentToTexture(img, args)
                // 0x14020e670: null unless material texture 0 is animated (flags & 4).
                case "getTextureAnimation":
                    guard img.material.textures[0]?.gpu?.tex.flags.contains(.spriteSheet) == true else { return nul }
                    return jsWrap(handle(.textureAnimation(img), key: "t\(ObjectIdentifier(img).hashValue)"))
                case "getVideoTexture":
                    // 0x14020e7b0: only when material texture 0 is a video with a player.
                    guard let v = img.material.textures[0]?.gpu?.video else { return nul }
                    if v.scriptClock == nil {
                        let d = max(v.duration, 1e-6)
                        let t = Double(scene.frame.time).truncatingRemainder(dividingBy: d)
                        v.scriptClock = ScriptVideoClock(start: t)
                        v.scriptClock?.advance(Double(scene.frame.time), duration: d)
                        videoClocks.append(v)
                    }
                    return jsWrap(handle(.videoTexture(img, v), key: "v\(ObjectIdentifier(v).hashValue)"))
                case "getAnimationLayerCount": return num(Double(img.puppet?.layers.count ?? 0))
                // Bones (puppet P = layer +0x4b8, bone records P+0x38 of 0xf0 bytes: name +0, parent +0x60).
                case "getBoneCount": return img.puppet.map { num(Double($0.mdl.bones.count)) } ?? undef
                case "getBoneIndex":
                    // 0x140210790: −1 unless a string naming a bone.
                    guard let p = img.puppet, let a = args.first, a.isString else { return num(-1) }
                    return num(Double(p.mdl.bones.firstIndex { $0.name == a.toString() } ?? -1))
                case "getBoneParentIndex":
                    // 0x140210860: index or name; the parent, −1 for roots / unknown bones.
                    guard let p = img.puppet, let b = boneArg(p, args.first) else { return num(-1) }
                    return num(Double(p.mdl.bones[b].parent))
                case "getBoneTransform":
                    // 0x14020f1d0: P+0x340[b] = bone world × layer world (column form layerWorld · boneWorld).
                    guard let p = img.puppet, let b = boneArg(p, args.first), b < p.boneWorld.count else { return undef }
                    let M = img.layerWorld * p.boneWorld[b]
                    return jsMk(9, [M.columns.0, M.columns.1, M.columns.2, M.columns.3].flatMap { Self.arr($0) })
                case "applyBonePhysicsImpulse", "resetBonePhysicsSimulation":
                    guard let p = img.puppet, let b = boneArg(p, args.first) else { return undef }
                    if name == "resetBonePhysicsSimulation" { p.resetPhysics(b); return undef }
                    func v3(_ i: Int) -> SIMD3<Float> {
                        guard i < args.count, let f = vecArg(args[i]), f.count >= 3 else { return .zero }
                        return SIMD3(f[0], f[1], f[2])
                    }
                    p.applyPhysicsImpulse(b, linear: v3(1), angularDegrees: v3(2))
                    return undef
                case "setBoneTransform":
                    // 0x14020f350: P+0x340[b] = M (scene space); P+0x2c8[b] = inverse(world) · M; P+0x2f8[b] =
                    // P+0x2c8[b] · P+0x2b0[b] (skin). It lasts until the next puppet update rebuilds the pose; scripts run
                    // after the object updates (Scene_Update 0x1401891a0 precedes Bindings_Tick), so a write in update()
                    // shows in that frame.
                    guard args.count >= 2, let p = img.puppet, let b = boneArg(p, args[0]), b < p.boneWorld.count,
                          let m = args[1].forProperty("m"), let a = m.toArray() as? [NSNumber], a.count == 16 else { return undef }
                    let f = a.map { $0.floatValue }
                    let M = simd_float4x4(columns: (SIMD4(f[0], f[1], f[2], f[3]), SIMD4(f[4], f[5], f[6], f[7]),
                                                    SIMD4(f[8], f[9], f[10], f[11]), SIMD4(f[12], f[13], f[14], f[15])))
                    p.boneWorld[b] = img.layerWorld.inverse * M
                    if b < p.skin.count, b < p.inverseBindWorld.count { p.skin[b] = p.boneWorld[b] * p.inverseBindWorld[b] }
                    return undef
                case "getLocalBoneTransform", "getLocalBoneOrigin", "getLocalBoneAngles":
                    // 0x14020f6b0 / 0x1402100d0 / 0x14020fa10: P+0x310[b] (index or first bone of that name); the origin is
                    // its translation, the angles (radians, no degree conversion) the Euler extraction z = atan2(m1, m0),
                    // y = atan2(−m2, √(m6² + m10²)), x = atan2(sin z·m8 − cos z·m9, cos z·m5 − sin z·m4).
                    guard let p = img.puppet, let b = boneArg(p, args.first), b < p.boneLocal.count else { return undef }
                    let L = p.boneLocal[b]
                    let m = [L.columns.0, L.columns.1, L.columns.2, L.columns.3].flatMap { Self.arr($0) }
                    if name == "getLocalBoneTransform" { return jsMk(9, m) }
                    if name == "getLocalBoneOrigin" { return jsMk(2, [m[12], m[13], m[14]]) }
                    let z = atan2f(m[1], m[0])
                    let y = atan2f(-m[2], (m[6] * m[6] + m[10] * m[10]).squareRoot())
                    let sz = sinf(z), cz = cosf(z)
                    return jsMk(2, [atan2f(sz * m[8] - cz * m[9], cz * m[5] - sz * m[4]), y, z])
                case "setLocalBoneTransform", "setLocalBoneOrigin", "setLocalBoneAngles":
                    // 0x14020f840: P+0x310[b] = M; 0x140210250: translation = v; 0x14020fce0: the 3×3 part = Rz·Ry·Rx of v
                    // (radians; translation kept, scale dropped). Each then rebuilds the hierarchy from b (0x14020db40).
                    guard args.count >= 2, let p = img.puppet, let b = boneArg(p, args[0]), b < p.boneLocal.count else { return undef }
                    var L = p.boneLocal[b]
                    if name == "setLocalBoneTransform" {
                        guard let mv = args[1].forProperty("m"), let a = mv.toArray() as? [NSNumber], a.count == 16 else { return undef }
                        let f = a.map { $0.floatValue }
                        L = simd_float4x4(columns: (SIMD4(f[0], f[1], f[2], f[3]), SIMD4(f[4], f[5], f[6], f[7]),
                                                    SIMD4(f[8], f[9], f[10], f[11]), SIMD4(f[12], f[13], f[14], f[15])))
                    } else {
                        guard let v = vecArg(args[1]), v.count >= 3 else { return undef }
                        if name == "setLocalBoneOrigin" {
                            L.columns.3 = SIMD4(v[0], v[1], v[2], L.columns.3.w)
                        } else {
                            let R = Mat.rotation(SIMD3(v[0], v[1], v[2]))
                            L.columns.0 = R.columns.0; L.columns.1 = R.columns.1; L.columns.2 = R.columns.2
                        }
                    }
                    p.boneLocal[b] = L
                    p.rebuildFromLocal(b)
                    return undef
                // Blend shapes = morph targets of mesh 0 (P+0x18 +0x68 records), weights P+0x3a0, mask P+0x398.
                case "getBlendShapeIndex":
                    // 0x140210400: −1 unless a string naming a target.
                    guard let p = img.puppet, let a = args.first, a.isString, let m = p.mdl.meshes.first else { return num(-1) }
                    return num(Double(m.morphTargets.firstIndex { $0.name == a.toString() } ?? -1))
                case "getBlendShapeWeight":
                    // 0x1402104b0: weight of an index (bounds-checked) or named target; nothing otherwise.
                    guard let p = img.puppet, !p.morphs.isEmpty, let k = morphArg(p, args.first), k < p.morphs[0].weights.count else { return undef }
                    return num(Double(p.morphs[0].weights[k]))
                case "setBlendShapeWeight":
                    // 0x1402105c0: weight = w; mask bit set when |w| > FLT_EPSILON, else cleared.
                    guard args.count >= 2, args[1].isNumber, let p = img.puppet, !p.morphs.isEmpty,
                          let k = morphArg(p, args.first), k < p.morphs[0].weights.count else { return undef }
                    let w = Float(args[1].toDouble())
                    p.morphs[0].weights[k] = w
                    if k < 64 {
                        if abs(w - 0) > 1.1920929e-07 { p.morphs[0].mask |= 1 << UInt64(k) } else { p.morphs[0].mask &= ~(1 << UInt64(k)) }
                    }
                    return undef
                case "getAnimationLayer", "createAnimationLayer", "playSingleAnimation", "destroyAnimationLayer":
                    return animationLayerCall(img, name, args)
                default: return undef
                }
            }
            if let t = o as? TextObject {
                switch name {
                case "getEffectCount": return num(Double(t.effects.count))
                case "getEffect": return effectArg(t.effects, owner: t, args.first)
                default: return undef
                }
            }
            if let m = o as? ModelObject {
                // Model wrapper (map 0x1404e87a0): getAnimationLayer 0x140226bc0 / getAnimationLayerCount 0x140226cb0.
                switch name {
                case "getAnimationLayerCount": return num(Double(m.skeleton?.layers.count ?? 0))
                case "getAnimationLayer", "createAnimationLayer", "playSingleAnimation", "destroyAnimationLayer":
                    return animationLayerCall(m, name, args)
                default: return undef
                }
            }
            if let p = o as? ParticleSystemObject {
                switch name {
                case "play": p.scriptPlay()
                case "pause": p.scriptPause()
                case "stop": p.scriptStop()
                case "isPlaying": return bool(p.system?.isPlaying ?? false)
                // 0x14024cac0: int argument (ToInt32 of the JS value); 0 → 1, negative → nothing.
                case "emitParticles": p.scriptEmit(Int(args.first.map { $0.toInt32() } ?? 0))
                default: break
                }
                return undef
            }
            if let s = o as? SoundObject {
                switch name {
                case "play": s.scriptPlay()
                case "pause": s.scriptPause()
                case "stop": s.scriptStop()
                case "isPlaying": return bool(s.isPlaying)
                default: break
                }
                return undef
            }
            return undef
        case .effect(let e, let owner):
            let mats = e.passes.compactMap(\.material)
            switch name {
            case "getMaterialCount": return num(Double(mats.count))
            case "getMaterial":
                // 0x1401ee0c0: an index into the passes, or a string compared (_stricmp) with each pass material's
                // path; the loop does not stop, so the last match wins, and an empty string matches every pass.
                guard let a = args.first else { return nul }
                var m: Material?
                if a.isString {
                    let n = (a.toString() ?? "").lowercased()
                    for x in mats where n.isEmpty || x.path.lowercased() == n { m = x }
                } else if a.isNumber, mats.indices.contains(Int(a.toInt32())) {
                    m = mats[Int(a.toInt32())]
                }
                guard let m else { return nul }
                return jsWrap(handle(.material(m, e, owner), key: "m\(ObjectIdentifier(m).hashValue)"))
            case "setMaterialProperty":
                // 0x1401ee1d0: for every pass material, the constant property named `key` takes the value only when the
                // argument's type matches the property's: a JS number → a float property (an int-valued number may also
                // feed an int one), Vec2/3/4 → 2/3/4-component properties; rad2deg constants (descriptor flag 4) get
                // × 0.0174533. Anything else is skipped.
                guard args.count >= 2, args[0].isString, let key = args[0].toString() else { return undef }
                let a = args[1]
                var v: [Float] = []
                if a.isNumber { v = [Float(a.toDouble())] }
                else if let f = vecArg(a), f.count >= 2, a.isObject {
                    v = f
                    if a.forProperty("w").isNumber == false && v.count == 4 { v.removeLast() }
                }
                guard !v.isEmpty else { return undef }
                for p in e.passes {
                    guard let m = p.material, let info = m.program?.info.values.values.first(where: { $0.materialKey == key }) else { continue }
                    let comps = info.components
                    guard (a.isNumber && comps == 1) || (!a.isNumber && v.count == comps) else { continue }
                    m.constants[key] = v.map { NSNumber(value: info.degrees ? $0 * 0.0174533 : $0) }
                }
                return undef
            case "executeMaterialFunction":
                // 0x1401ee3a0: clears the effect's fbos for the named `functions` entry (Effect.functionClears).
                guard let n = args.first, n.isString, let name = n.toString() else { return undef }
                let clears = e.functionClears(name)
                if let img = owner as? ImageLayer { img.pendingClears += clears }
                else if let t = owner as? TextObject { t.pendingClears += clears }
                return undef
            default: return undef
            }
        case .propertyAnimation, .anim:
            guard let a = animation(ref) else { return undef }
            switch name {
            case "play": a.play()
            case "pause": a.paused = true
            case "stop": a.stop()
            case "isPlaying": return bool(a.isPlaying)
            case "setFrame": if let f = args.first, f.isNumber { a.setFrame(Float(f.toDouble())) }
            case "getFrame": return num(Double(a.frame))
            default: break
            }
            return undef
        case .textureAnimation(let img):
            let c = spriteClock(img)
            // Methods 0x1401fa330–0x1401fa490 (the clock is (index +0xe8, time +0xec); attached = +0x48 == 0).
            switch name {
            case "play": c.playing = true                                                          // 0x1401fa330
            case "pause":                                                                         // 0x1401fa340
                if c.attached { Self.copySharedClock(img, into: c) }
                c.playing = false; c.attached = false
            case "stop": c.index = 0; c.time = 0; c.attached = false; c.playing = false          // 0x1401fa3a0
            case "isPlaying": return bool(!(!c.attached && !c.playing))                           // 0x1401fa3d0
            case "setFrame":                                                                      // 0x1401fa400
                // No clamp: the draw shows frame 0 for an index past the end (C+0x132c, 0x14015f13e); a negative index
                // leaves C+0x132c "unset" so the layer shows the shared clock.
                if let f = args.first, f.isNumber {
                    c.index = Int(f.toInt32()); c.time = 0
                    if c.attached { c.attached = false; c.playing = true }
                }
            case "join": c.attached = true                                                         // 0x1401fa490
            case "getFrame":                                                                      // 0x1401fa430
                if c.attached, let gpu = img.texture, gpu.tex.flags.contains(.spriteSheet) { return num(Double(gpu.spriteIndex)) }
                return num(Double(c.index))
            default: break
            }
            return undef
        case .animationLayer(let img, let idx):
            guard let p = Self.puppet(img), let i = p.layers.firstIndex(where: { $0.jsonIndex == idx }) else { return undef }
            switch name {
            case "play": p.layers[i].paused = false; p.layers[i].finished = false
            case "pause": p.layers[i].paused = true
            case "stop": p.layers[i].paused = true; p.layers[i].time = 0; p.layers[i].finished = false
            case "isPlaying": return bool(!p.layers[i].paused && !p.layers[i].finished)
            case "setFrame":
                if let f = args.first, f.isNumber { p.layers[i].time = Float(f.toDouble()) * p.layers[i].frameTime; p.layers[i].finished = false }
            case "getFrame": return num(Double(p.layers[i].time / p.layers[i].frameTime))
            case "addEndedCallback":
                // 0x14026c4f0: appended to the layer's callback vector (+0x130); run after the puppet update in which the
                // layer ends (0x1402002b2 → 0x140177bf0).
                if let a = args.first, a.isObject, let id = a.forProperty("__fn"), id.isNumber {
                    endedCallbacks["a\(ObjectIdentifier(img).hashValue)_\(idx)", default: []].append(Int(id.toInt32()))
                }
            default: break
            }
            return undef
        case .videoTexture(_, let v):
            guard let c = v.scriptClock else { return undef }
            switch name {
            case "play": c.play()
            case "pause": c.pause()
            case "stop": c.stop()
            case "isPlaying": return bool(c.isPlaying)
            case "getCurrentTime":
                let d = max(v.duration, 1e-6)
                return num(Double(Float(c.loop ? c.time.truncatingRemainder(dividingBy: d) : min(c.time, d))))
            case "setCurrentTime": if let f = args.first, f.isNumber { c.seek(Double(Float(f.toDouble()))) }
            case "addEndedCallback":
                if let a = args.first, a.isObject, let id = a.forProperty("__fn"), id.isNumber {
                    if let i = videoCallbacks.firstIndex(where: { $0.0 === v }) { videoCallbacks[i].1.append(Int(id.toInt32())) }
                    else { videoCallbacks.append((v, [Int(id.toInt32())])) }
                }
            default: break
            }
            return undef
        case .instance, .material, .constants:
            return undef
        }
    }

    private func effectArg(_ effects: [Effect], owner: SceneObject, _ a: JSValue?) -> JSValue {
        guard let a else { return JSValue(nullIn: context) }
        var e: Effect?
        if a.isNumber { let i = Int(a.toInt32()); e = effects.indices.contains(i) ? effects[i] : nil }
        // 0x1401ecfe0: a non-empty name is compared with every effect; the loop does not stop, so the last match wins.
        else if a.isString, let s = a.toString(), !s.isEmpty { e = effects.last { $0.name == s } }
        guard let e else { return JSValue(nullIn: context) }
        return jsWrap(handle(e, owner))
    }

    private func callScene(_ name: String, _ args: [JSValue]) -> JSValue {
        let ctx = context
        let s = scene
        switch name {
        case "getLayer":
            return jsWrap(resolveLayer(args.first))
        case "getLayerByID":
            // dll 0x181632620: ToString of any argument, then strtol(…, 10) ("12abc" → 12, "abc" → 0, 3.9 → 3).
            guard let a = args.first else { return JSValue(nullIn: ctx) }
            let id = Self.strtol10(a.toString() ?? "")
            return jsWrap(scriptObjects.first { $0.id == id })
        case "getLayerCount":
            return JSValue(double: Double(scriptObjects.count), in: ctx)
        case "enumerateLayers":
            return jsArray(scriptObjects.map { jsWrap($0) })
        case "getLayerIndex":
            // 0x14018c580: position in the whole list (no pending-set test).
            guard let o = resolveLayer(args.first), let i = scriptObjectList.firstIndex(where: { $0 === o }) else { return JSValue(double: -1, in: ctx) }
            return JSValue(double: Double(i), in: ctx)
        case "sortLayer":
            guard let o = resolveLayer(args.first), args.count > 1, args[1].isNumber,
                  let i = s.objects.firstIndex(where: { $0 === o }) else { return JSValue(undefinedIn: ctx) }
            s.objects.remove(at: i)
            s.objects.insert(o, at: min(max(Int(args[1].toInt32()), 0), s.objects.count))
            return JSValue(undefinedIn: ctx)
        case "destroyLayer":
            // dll 0x181632fc0 → host 0x14018b730: true when the object is in the scene list (it joins the pending set,
            // or already is in it), false otherwise or without an argument; removal waits for flushPendingDestroys.
            guard let o = resolveLayer(args.first), s.objects.contains(where: { $0 === o }) else { return JSValue(bool: false, in: ctx) }
            pendingDestroy.insert(ObjectIdentifier(o))
            return JSValue(bool: true, in: ctx)
        case "createLayer":
            guard let a = args.first else { return JSValue(nullIn: ctx) }
            var conf: [String: Any]?
            if a.isString, let path = a.toString() {
                if let j = s.resources.fs.readJSON(path) as? [String: Any],
                   ["image", "text", "particle", "sound", "model"].contains(where: { j[$0] != nil }) {
                    conf = j
                } else {
                    conf = ["image": path]
                }
            } else if a.isObject {
                // 0x181633a38: the config is serialised with `_Internal.stringifyConfig` (JSON.stringify with
                // stringifyAdapter), so an IModelData becomes its token.
                if let f = ctx.objectForKeyedSubscript("_Internal")?.forProperty("stringifyConfig"), !f.isUndefined,
                   let json = f.call(withArguments: [a])?.toString(), let d = json.data(using: .utf8) {
                    conf = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
                } else {
                    conf = a.toDictionary() as? [String: Any]
                }
            }
            guard let conf, let o = s.addScriptLayer(conf) else { return JSValue(nullIn: ctx) }
            registerCreated(o)
            return jsWrap(o)
        case "getInitialLayerConfig":
            guard let o = resolveLayer(args.first) else { return JSValue(nullIn: ctx) }
            return JSValue(object: o.json, in: ctx)
        case "getCameraTransforms":
            let obj = JSValue(newObjectIn: ctx)!
            obj.setValue(jsMk(2, Self.arr(s.cameraEye)), forProperty: "eye")
            obj.setValue(jsMk(2, Self.arr(s.cameraCenter)), forProperty: "center")
            obj.setValue(jsMk(2, Self.arr(s.cameraUp)), forProperty: "up")
            obj.setValue(Double(s.cameraZoom), forProperty: "zoom")
            return obj
        case "setCameraTransforms":
            guard let a = args.first, a.isObject else { return JSValue(undefinedIn: ctx) }
            func v(_ k: String) -> SIMD3<Float>? {
                guard let f = vecArg(a.forProperty(k)), f.count >= 3 else { return nil }
                return SIMD3(f[0], f[1], f[2])
            }
            if let e = v("eye") { s.cameraEye = e }
            if let c = v("center") { s.cameraCenter = c }
            if let u = v("up") { s.cameraUp = u }
            if let z = a.forProperty("zoom"), z.isNumber { s.cameraZoom = Float(z.toDouble()) }
            return JSValue(undefinedIn: ctx)
        case "createModelData":
            // The prelude validates the descriptor like dll 0x18162fd40 and passes plain arrays; this is the host side
            // (exe 0x14018c720, per shape 0x1401c2f10). Returns the token, or the error code (negated).
            guard let d = args.first?.toDictionary() as? [String: Any], let shapes = d["shapes"] as? [[String: Any]] else {
                return JSValue(double: -4, in: ctx)
            }
            var meshes: [MdlFile.Mesh] = []
            var infos: [ScriptModelShape] = []
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for sh in shapes {
                let fmt = UInt32((sh["format"] as? NSNumber)?.intValue ?? 0)
                let floats = ((sh["vertices"] as? [NSNumber]) ?? []).map { $0.floatValue }
                let stride = MdlFile.stride(fmt)
                // Error 3 "Inconsistent vertex buffer size" (0x1401c2f85), checked before the material.
                guard stride > 0, (floats.count * 4) % stride == 0 else { return JSValue(double: -3, in: ctx) }
                let mat = (sh["material"] as? String) ?? ""
                guard s.resources.fs.read(mat) != nil else { return JSValue(double: -1, in: ctx) }
                let idx = ((sh["indices"] as? [NSNumber]) ?? []).map { $0.uint32Value }
                let index32 = (sh["index32"] as? Bool) ?? false
                let count = floats.count * 4 / stride
                let indices = idx.isEmpty ? (0..<UInt32(count)).map { $0 } : idx
                let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
                meshes.append(MdlFile.Mesh(material: mat, flags: index32 ? 1 : 0, vertexFlags: fmt, stride: stride,
                                           vertices: data, indices: indices))
                infos.append(ScriptModelShape(sh, floats: floats, indices: idx))
                // Bounds without explicit ones: min/max over every consecutive float triplet (0x14018d010–0x14018d07c).
                var i = 0
                while i + 2 < floats.count {
                    let p = SIMD3(floats[i], floats[i + 1], floats[i + 2])
                    lo = simd_min(lo, p); hi = simd_max(hi, p); i += 3
                }
            }
            if let mn = d["boundsMin"] as? [NSNumber], let mx = d["boundsMax"] as? [NSNumber], mn.count >= 3, mx.count >= 3 {
                lo = SIMD3(mn[0].floatValue, mn[1].floatValue, mn[2].floatValue)
                hi = SIMD3(mx[0].floatValue, mx[1].floatValue, mx[2].floatValue)
            }
            let token = s.resources.nextModelToken
            s.resources.nextModelToken += 1
            s.resources.modelData[token] = MdlFile(meshes: meshes, bounds: (lo, hi))
            modelShapes[token] = infos
            return JSValue(double: Double(token), in: ctx)
        case "updateModelData":
            guard args.count >= 3, let d = args[1].toDictionary() as? [String: Any] else { return JSValue(double: 4, in: ctx) }
            let token = Int(args[0].toInt32())
            return JSValue(double: Double(updateModelData(token, (d["shapes"] as? [[String: Any]]) ?? [], replace: args[2].toBool())), in: ctx)
        case "destroyModelData":
            if let t = args.first, t.isNumber { s.resources.modelData[Int(t.toInt32())] = nil; modelShapes[Int(t.toInt32())] = nil }
            return JSValue(undefinedIn: ctx)
        default:
            return JSValue(nullIn: ctx)
        }
    }

    /// `thisScene.getAnimation(name)` (dll 0x181635ee0 → host +0x78 = exe 0x14018db00 with no owner): the first
    /// property animation in the binding manager's list (registration order) whose `options.name` or bound property
    /// name equals `name`, on any object; nil → null.
    func sceneAnimation(_ name: String) -> JSValue {
        for o in scene.objects {
            for key in o.animations.keys.sorted() where o.animations[key]!.name == name || key == name {
                return jsWrap(handle(.propertyAnimation(o, key), key: "p\(ObjectIdentifier(o).hashValue)_\(key)"))
            }
            for e in effects(of: o) {
                if let a = scene.constantAnimations?.find(effect: e, name: name) {
                    return jsWrap(handle(.anim(a), key: "ca\(ObjectIdentifier(a).hashValue)"))
                }
            }
        }
        return JSValue(nullIn: context)
    }
}

extension SceneScriptEngine {
    /// Host side of `engine.openUserShortcut(name)` (dll 0x181656b70 → host +0xf0): 0 = ran, 1 = not run,
    /// 2 = a command already ran during this click (checked in the prelude). The command is a `usershortcut` user
    /// property configured by the user (`{isbound, commandtype, file}`, the same keys the exe's user-property pass
    /// reads at 0x140173c79–0x140173ea9): `web` opens a URL, any other type except `cmd` opens the file.
    /// Shell commands (`cmd`) are not run on macOS.
    func runUserShortcut(_ name: String, values: [String: Any], types: [String: String]) -> Int {
        guard types[name] == "usershortcut", let v = values[name] as? [String: Any],
              (v["isbound"] as? Bool) == true, let file = v["file"] as? String, !file.isEmpty else { return 1 }
        let type = (v["commandtype"] as? String) ?? ""
        if type == "cmd" { Self.emit(0, "openUserShortcut(\(name)): command shortcuts are not supported"); return 1 }
        let url = type == "web" ? URL(string: file) : URL(fileURLWithPath: file)
        guard let url else { return 1 }
        return NSWorkspace.shared.open(url) ? 0 : 1
    }
}

extension SceneScriptEngine {
    /// `lookAt(target, up = (0,1,0))` 0x1401dfc00 and `lookAtYaw` 0x1401dfe30: d = target − origin (lookAtYaw first
    /// removes its component along `up`: d −= up·dot(up, d)). Cameras (type 8) look at origin + d, every other object at
    /// origin − d. When |d|² > FLT_EPSILON the angles become the Euler angles of the right-handed look-at matrix
    /// (0x14019d920, column-major: s = normalize(cross(f, up)), u = cross(s, f), third column −f):
    /// z = atan2(M[4], M[0]), y = atan2(−M[8], sqrt(M[9]² + M[10]²)),
    /// x = atan2(sin z·M[2] − cos z·M[6], cos z·M[5] − sin z·M[1]); stored as the object's angles (0x1401dd630).
    static func lookAt(_ o: SceneObject, target: SIMD3<Float>, up: SIMD3<Float>, yawOnly: Bool, isCamera: Bool = false) {
        let eye = o.origin
        var d = target - eye
        if yawOnly {
            let k = up.x * d.x + up.y * d.y + up.z * d.z
            d = SIMD3(d.x - up.x * k, d.y - up.y * k, d.z - up.z * k)
        }
        let center: SIMD3<Float> = isCamera ? (yawOnly ? eye + d : target) : eye - d
        guard d.x * d.x + d.y * d.y + d.z * d.z > 1.1920929e-07 else { return }
        var f = center - eye
        let fl = 1 / (f.x * f.x + f.y * f.y + f.z * f.z).squareRoot()
        f = SIMD3(f.x * fl, f.y * fl, f.z * fl)
        var sv = SIMD3(up.z * f.y - up.y * f.z, up.x * f.z - up.z * f.x, up.y * f.x - up.x * f.y)
        let sl = 1 / (sv.x * sv.x + sv.y * sv.y + sv.z * sv.z).squareRoot()
        sv = SIMD3(sv.x * sl, sv.y * sl, sv.z * sl)
        let u = SIMD3(f.z * sv.y - f.y * sv.z, f.x * sv.z - f.z * sv.x, f.y * sv.x - f.x * sv.y)
        // Column-major M: M[0]=s.x M[1]=u.x M[2]=−f.x · M[4]=s.y M[5]=u.y M[6]=−f.y · M[8]=s.z M[9]=u.z M[10]=−f.z
        let z = atan2f(sv.y, sv.x)
        let sz = sinf(z), cz = cosf(z)
        let y = atan2f(-sv.z, (-f.z * -f.z + u.z * u.z).squareRoot())
        let x = atan2f(sz * -f.x - cz * -f.y, cz * u.y - sz * u.x)
        o.angles = SIMD3(x, y, z)
    }
}

/// One shape of a createModelData buffer set (exe shape record: buffers +0x238 vector of 0x20-byte entries, mesh
/// +0x20 vector of 0xc8-byte entries): data as last written, capacities and the creation flags.
struct ScriptModelShape {
    var vertices: [Float]
    var indices: [UInt32]
    var index32: Bool
    var hasIndices: Bool
    var vertexDynamic: Bool
    var indexDynamic: Bool
    var format: UInt32
    var material: String
    var vertexCapacity: Int
    var indexCapacity: Int

    init(_ sh: [String: Any], floats: [Float], indices: [UInt32]) {
        vertices = floats
        self.indices = indices
        index32 = (sh["index32"] as? Bool) ?? false
        hasIndices = sh["indices"] != nil
        vertexDynamic = (sh["vertexDynamic"] as? Bool) ?? true
        indexDynamic = (sh["indexDynamic"] as? Bool) ?? true
        format = UInt32((sh["format"] as? NSNumber)?.intValue ?? 0)
        material = (sh["material"] as? String) ?? ""
        vertexCapacity = floats.count
        indexCapacity = indices.count
    }
}

extension SceneScriptEngine {
    /// `IModelData.applyData` (replace = false) / `replaceData` (true): host +0x58 → exe 0x1401d6400. Returns the
    /// error code (0 = none; table 0x18162fc80). Per shape i of the descriptor:
    /// - remove (null shape) or `indexBuffer: null`: applyData → 11 and stop; replaceData skips removed shapes
    ///   (deleted after the loop);
    /// - replaceData past the existing shapes appends a new one;
    /// - a different non-empty material: applyData → 12, replaceData takes it;
    /// - a different non-zero vertex format: applyData → 13;
    /// - reallocation (format change, more vertex floats or indices than the buffers hold, a buffer written that was
    ///   not created dynamic, or removing an index buffer that exists): applyData → 7; replaceData rebuilds the
    ///   shape (0x1401c2f10: vertex bytes not a multiple of the stride → 3; unknown material → 1);
    /// - otherwise the data is copied into the existing buffers (the existing byte size is copied); indices must
    ///   match the buffer's index type (Uint32Array ↔ 32-bit) or → 9.
    /// More shapes than exist in applyData → 10 before anything else. Models showing the token are rebuilt when
    /// anything changed.
    func updateModelData(_ token: Int, _ shapes: [[String: Any]], replace: Bool) -> Int {
        guard var info = modelShapes[token], scene.resources.modelData[token] != nil else { return 4 }
        if !replace && shapes.count > info.count { return 10 }
        var err = 0
        var changed = false
        var removed: [Int] = []
        loop: for (i, d) in shapes.enumerated() {
            let remove = (d["remove"] as? Bool) ?? false
            let removeIB = (d["removeIndices"] as? Bool) ?? false
            if remove || removeIB {
                if !replace { err = 11; break loop }
                if remove { removed.append(i); continue }
            }
            if replace && i >= info.count {
                info.append(ScriptModelShape([:], floats: [], indices: []))
                info[i].vertexDynamic = true; info[i].indexDynamic = true
            }
            let mat = (d["material"] as? String) ?? ""
            if !mat.isEmpty && mat != info[i].material {
                if !replace { err = 12; break loop }
                info[i].material = mat
                changed = true
            }
            guard i < info.count else { continue }
            let fmt = UInt32((d["format"] as? NSNumber)?.intValue ?? 0)
            let fmtChanged = fmt != 0 && fmt != info[i].format
            if fmtChanged && !replace { err = 13; break loop }
            let verts = (d["vertices"] as? [NSNumber])?.map { $0.floatValue }
            let idx = (d["indices"] as? [NSNumber])?.map { $0.uint32Value }
            let idx32 = (d["index32"] as? Bool) ?? false
            let growV = verts.map { $0.count > info[i].vertexCapacity } ?? false
            let growI = idx.map { $0.count > info[i].indexCapacity } ?? false
            var cl = fmtChanged || growV, al = fmtChanged || growI
            if verts != nil && !info[i].vertexDynamic { cl = true }
            if idx != nil && !info[i].indexDynamic { al = true }
            if removeIB && info[i].hasIndices { al = true }
            let realloc = cl || al
            if realloc || (verts != nil && !info[i].vertexDynamic) || (idx != nil && !info[i].indexDynamic) {
                if !replace { err = 7; break loop }
                if realloc {
                    // Rebuild from the descriptor (0x1401c2f10).
                    let f = fmt != 0 ? fmt : info[i].format
                    let stride = MdlFile.stride(f)
                    let v = verts ?? []
                    if stride == 0 || (v.count * 4) % stride != 0 { err = 3; changed = true; break loop }
                    if !info[i].material.isEmpty && scene.resources.fs.read(info[i].material) == nil { err = 1; changed = true; break loop }
                    info[i].format = f
                    info[i].vertices = v
                    info[i].vertexCapacity = v.count
                    info[i].indices = removeIB ? [] : (idx ?? [])
                    info[i].hasIndices = !removeIB && idx != nil
                    info[i].index32 = idx32
                    info[i].indexCapacity = info[i].indices.count
                    info[i].vertexDynamic = (d["vertexDynamic"] as? Bool) ?? true
                    info[i].indexDynamic = (d["indexDynamic"] as? Bool) ?? true
                    changed = true
                    continue
                }
            } else if !replace {
                if growV { err = 5; break loop }
                if growI { err = 6; break loop }
            }
            // In-place copy: the existing byte size is copied from the new data (only what it provides here).
            if let verts {
                let n = min(verts.count, info[i].vertices.count)
                info[i].vertices.replaceSubrange(0..<n, with: verts.prefix(n))
                changed = true
            }
            if let idx {
                guard idx32 == info[i].index32 else { err = 9; break loop }
                let n = min(idx.count, info[i].indices.count)
                info[i].indices.replaceSubrange(0..<n, with: idx.prefix(n))
                changed = true
            }
        }
        for i in removed.reversed() where i < info.count { info.remove(at: i); changed = true }
        modelShapes[token] = info
        if changed { rebuildModelData(token) }
        return err
    }

    /// Writes the shape records back into the token's mdl and rebuilds every model object that shows it (the
    /// listeners notified at 0x1401d6ae1).
    private func rebuildModelData(_ token: Int) {
        guard let info = modelShapes[token], let old = scene.resources.modelData[token] else { return }
        var meshes: [MdlFile.Mesh] = []
        for sh in info {
            let stride = MdlFile.stride(sh.format)
            guard stride > 0 else { continue }
            let count = sh.vertices.count * 4 / stride
            let indices = sh.hasIndices ? sh.indices : (0..<UInt32(count)).map { $0 }
            let data = sh.vertices.withUnsafeBufferPointer { Data(buffer: $0) }
            meshes.append(MdlFile.Mesh(material: sh.material, flags: sh.index32 ? 1 : 0, vertexFlags: sh.format, stride: stride,
                                       vertices: data, indices: indices))
        }
        scene.resources.modelData[token] = MdlFile(meshes: meshes, bounds: old.bounds)
        for case let m as ModelObject in scene.objects where (m.json["model"] as? NSNumber)?.intValue == token {
            let fresh = ModelObject(json: m.json, id: m.id, resources: scene.resources)
            m.parts = fresh.parts
            m.mdl = fresh.mdl
        }
    }
}

extension SceneScriptEngine {
    func animation(_ ref: HostRef) -> PropertyAnimation? {
        switch ref {
        case .propertyAnimation(let o, let key): return o.animations[key]
        case .anim(let a): return a
        default: return nil
        }
    }
}

extension SceneScriptEngine {
    /// `int|string` bone argument (type bits 0x8 / 0x200): a non-negative index below the bone count, or the index
    /// of the bone with that name.
    func boneArg(_ p: Puppet, _ a: JSValue?) -> Int? {
        guard let a else { return nil }
        if a.isNumber { let i = Int(a.toInt32()); return i >= 0 && i < p.mdl.bones.count ? i : nil }
        if a.isString { return p.mdl.bones.firstIndex { $0.name == a.toString() } }
        return nil
    }

    func morphArg(_ p: Puppet, _ a: JSValue?) -> Int? {
        guard let a, let m = p.mdl.meshes.first else { return nil }
        if a.isNumber { let i = Int(a.toInt32()); return i >= 0 ? i : nil }
        if a.isString { return m.morphTargets.firstIndex { $0.name == a.toString() } }
        return nil
    }
}

extension SceneScriptEngine {
    /// Puppet / model animation-layer methods (image 0x14020e910 / 0x14020ea30 / 0x14020ef40 / 0x14020ef80, model
    /// 0x140226bc0 / 0x140226d00 / 0x140227220 / 0x140227260):
    /// - getAnimationLayer(int | name): index into the layer list, or the last layer whose name matches;
    /// - createAnimationLayer(animation, options?): `animation` is an animation name (its id is set as `animation`) or a
    ///   layer config object; `options` (object or JSON text) supplies `blendin`/`blendout` = false when absent and is
    ///   merged into the config; the layer is created like an `animationlayers` element (AnimLayer_Create 0x1401fcc20);
    /// - playSingleAnimation: the same, plus timeline flag 0x8000000 — the layer is removed after the update in which it
    ///   ends (after its ended callbacks);
    /// - destroyAnimationLayer(int | name | layer): removes the layer at that index, every layer with that name, or that
    ///   layer; true when something was removed.
    func animationLayerCall(_ o: SceneObject, _ name: String, _ args: [JSValue]) -> JSValue {
        let ctx = context
        let nul = JSValue(nullIn: ctx)!
        guard let p = Self.puppet(o) else { return name == "destroyAnimationLayer" ? JSValue(bool: false, in: ctx) : nul }
        func wrapLayer(_ idx: Int) -> JSValue { jsWrap(handle(.animationLayer(o, idx), key: "a\(ObjectIdentifier(o).hashValue)_\(idx)")) }
        func jsonArg(_ v: JSValue?) -> [String: Any]? {
            guard let v, !v.isUndefined, !v.isNull else { return nil }
            if v.isString, let d = v.toString()?.data(using: .utf8) { return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }
            if v.isObject { return v.toDictionary() as? [String: Any] }
            return nil
        }
        switch name {
        case "getAnimationLayer":
            guard let a = args.first else { return nul }
            if a.isNumber {
                let i = Int(a.toInt32())
                return p.layers.indices.contains(i) ? wrapLayer(p.layers[i].jsonIndex) : nul
            }
            guard a.isString, let n = a.toString(), !n.isEmpty, let l = p.layers.last(where: { $0.name == n }) else { return nul }
            return wrapLayer(l.jsonIndex)
        case "createAnimationLayer", "playSingleAnimation":
            guard let a = args.first, !(a.isString && (a.toString() ?? "").isEmpty) else { return nul }
            var options = jsonArg(args.count > 1 ? args[1] : nil) ?? [:]
            if options["blendin"] == nil { options["blendin"] = false }
            if options["blendout"] == nil { options["blendout"] = false }
            var config: [String: Any]
            if a.isString {
                guard let anim = p.mdl.animations.first(where: { $0.name == a.toString() }) else { return nul }
                config = options
                config["animation"] = NSNumber(value: anim.id)
            } else {
                guard var c = jsonArg(a) else { return nul }
                for (k, v) in options { c[k] = v }
                config = c
            }
            nextCreatedLayer += 1
            let idx = 100_000 + nextCreatedLayer
            guard p.addLayer(config, jsonIndex: idx) else { return nul }
            if name == "playSingleAnimation", let i = p.layers.firstIndex(where: { $0.jsonIndex == idx }) { p.layers[i].singleShot = true }
            return wrapLayer(idx)
        default: // destroyAnimationLayer
            guard let a = args.first else { return JSValue(bool: false, in: ctx) }
            let before = p.layers.count
            if a.isNumber {
                let i = Int(a.toInt32())
                if p.layers.indices.contains(i) { p.layers.remove(at: i) }
            } else if a.isString, let n = a.toString(), !n.isEmpty {
                p.layers.removeAll { $0.name == n }
            } else if a.isObject, let hv = a.forProperty("__host"), hv.isNumber {
                let h = Int(hv.toInt32())
                if h < refs.count, case .animationLayer(let owner, let idx) = refs[h], owner === o {
                    p.layers.removeAll { $0.jsonIndex == idx }
                }
            }
            return JSValue(bool: p.layers.count != before, in: ctx)
        }
    }
}

extension SceneScriptEngine {
    /// `rotateObjectSpace(v)` 0x1401df620: the object's rotation matrix (+0x14c, column-major mat3 kept by Obj_SetAngles
    /// 0x1401dd630 as Rz(z)·Ry(y)·Rx(x)) is post-multiplied by glm `rotate` about the basis axes z, y, x (table
    /// 0x1404903a8 = 2, 1, 0) by v.z, v.y, v.x — radians, the argument is a plain Vec3 — and the angles are re-extracted:
    /// z = atan2(m1, m0), x = atan2(sin z·m6 − cos z·m7, cos z·m4 − sin z·m3), y = atan2(−m2, √(m8² + m5²)).
    static func rotateObjectSpace(_ o: SceneObject, _ v: SIMD3<Float>) {
        let a = o.angles
        let cz = cosf(a.z), sz = sinf(a.z), cy = cosf(a.y), sy = sinf(a.y), cx = cosf(a.x), sx = sinf(a.x)
        var m: [Float] = [cy * cz, cy * sz, -sy,
                          sy * cz * sx - cx * sz, sy * sz * sx + cx * cz, sx * cy,
                          cx * cz * sy + sx * sz, cx * sz * sy - sx * cz, cx * cy]
        for axisIndex in [2, 1, 0] {
            var axis = SIMD3<Float>(0, 0, 0)
            axis[axisIndex] = 1
            let angle = v[axisIndex]
            let c = cosf(angle), s = sinf(angle)
            let inv = 1 / (axis.x * axis.x + axis.y * axis.y + axis.z * axis.z).squareRoot()
            let ax = axis * inv
            let t = (1 - c) * ax
            let r: [[Float]] = [[c + t.x * ax.x, t.x * ax.y + s * ax.z, t.x * ax.z - s * ax.y],
                                [t.y * ax.x - s * ax.z, c + t.y * ax.y, t.y * ax.z + s * ax.x],
                                [t.z * ax.x + s * ax.y, t.z * ax.y - s * ax.x, c + t.z * ax.z]]
            var out = [Float](repeating: 0, count: 9)
            for i in 0..<3 {
                for k in 0..<3 { out[3 * i + k] = m[k] * r[i][0] + m[3 + k] * r[i][1] + m[6 + k] * r[i][2] }
            }
            m = out
        }
        let z = atan2f(m[1], m[0])
        let s1 = sinf(z), c1 = cosf(z)
        let x = atan2f(s1 * m[6] - c1 * m[7], c1 * m[4] - s1 * m[3])
        let y = atan2f(-m[2], (m[8] * m[8] + m[5] * m[5]).squareRoot())
        o.angles = SIMD3(x, y, z)
    }
}
