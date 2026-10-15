import Foundation
import Metal
import PhotonCore
import simd

/// Frustum culling helpers (docs/re/06 §6.4).
enum Frustum {
    /// `0x1401849e0`: Gribb–Hartmann planes of a row-vector view-projection M (plane k component i from M[i][·]):
    /// c0+c3, c3−c0, c1+c3, c3−c1, c2+c3, c3−c2, each divided by the length of its xyz. In photon2's column-vector
    /// form the engine's columns are the rows of `vp`.
    static func planes(_ vp: simd_float4x4) -> [SIMD4<Float>] {
        func row(_ r: Int) -> SIMD4<Float> { SIMD4(vp[0][r], vp[1][r], vp[2][r], vp[3][r]) }
        let r0 = row(0), r1 = row(1), r2 = row(2), r3 = row(3)
        return [r0 + r3, r3 - r0, r1 + r3, r3 - r1, r2 + r3, r3 - r2].map { p in
            let l = simd_length(SIMD3(p.x, p.y, p.z))
            return l > 0 ? p / l : p
        }
    }

    /// `0x1401e5a10`: outside when `dot(n, c) + d < −r` for any plane.
    static func sphereVisible(_ planes: [SIMD4<Float>], center c: SIMD3<Float>, radius r: Float) -> Bool {
        for p in planes where p.x * c.x + p.y * c.y + p.z * c.z + p.w < -r { return false }
        return true
    }

    /// Image and text layers (`Layer_Render` 0x1401e8b68–0x1401e8ec5): with C+0x11c bit 1 and neither ledsource nor
    /// dependency (flags304 & 0x1100), centre = the alignment offset (+0x2f8) transformed by vt+0x80, which already
    /// contains that offset (so it counts twice), radius = |(w/2, h/2, 0)| through the same matrix's 3×3. A culled
    /// layer returns before anything, its composite and effects included.
    static func layerCulled(_ frame: FrameState, world W: simd_float4x4, offset: SIMD3<Float>, size: SIMD2<Float>,
                            exempt: Bool) -> Bool {
        guard frame.cullFlags & 2 != 0, !exempt, let planes = frame.cullPlanes else { return false }
        let c4 = W * SIMD4(offset, 1)
        let r4 = W * SIMD4(size.x / 2, size.y / 2, 0, 0)
        return !sphereVisible(planes, center: SIMD3(c4.x, c4.y, c4.z), radius: simd_length(SIMD3(r4.x, r4.y, r4.z)))
    }

    /// `Model_Render` 0x1402222f2–0x1402224f3: the bounds' min and max transformed by the object world (vt+0x80);
    /// centre = their midpoint, radius = half their distance.
    static func sphere(world W: simd_float4x4, min lo: SIMD3<Float>, max hi: SIMD3<Float>) -> (SIMD3<Float>, Float) {
        let a = W * SIMD4(lo, 1), b = W * SIMD4(hi, 1)
        let pa = SIMD3(a.x, a.y, a.z), pb = SIMD3(b.x, b.y, b.z)
        return ((pa + pb) * 0.5, simd_length(pb - pa) * 0.5)
    }
}

/// Shared per-frame values and the matrix stacks the layer renderer pushes and pops.
final class FrameState {
    var time: Float = 0
    var frameTime: Float = 0
    var daytime: Float = 0
    var pointer = SIMD2<Float>(0.5, 0.5)
    var pointerLast = SIMD2<Float>(0.5, 0.5)
    var parallax = SIMD2<Float>(0.5, 0.5)
    /// g_PointerState = (p, p, click, 0): click is 1 only on the first frame the button is down (docs/re/07 §3.7).
    var pointerDown = false
    var pointerWasDown = false
    var model = Mat.identity
    var view = Mat.identity
    var proj = Mat.identity
    var hdr = false
    /// Main back-buffer size: g_Screen / g_TexelSize use it for every target (docs/re/07 §3.2).
    var screen = SIMD2<Float>(1920, 1080)
    /// C+0x1218 (1 or 2): `g_TextureReductionScale` (id 0x5c, 0x1400d994e).
    var textureReduction: Float = 1
    var eye = SIMD3<Float>(0, 0, 0)
    /// g_ViewForward (C+0x160) when it differs from the view matrix: the reflection pass mirrors the view, eye,
    /// g_ViewRight and g_ViewUp but leaves C+0x160 alone (Renderer_Frame 0x140180492–0x14018069b).
    var viewForward: SIMD3<Float>?
    /// The scene view of the current draw list: `Scene_Frame` writes g_ViewForward / g_ViewRight / g_ViewUp (C+0x160,
    /// C+0x16c, C+0x178; columns 2 (negated), 0 and 1 of the view, 0x140180194–0x14018029x) once per frame, so every
    /// draw sees the camera's vectors, also inside composites and effect passes where `view` is the identity.
    var cameraView: simd_float4x4?
    /// C+0xec0: the six frustum planes `SceneGraph_DrawList` 0x14018aac0 extracts from g_ViewProjectionMatrix (C+0x930,
    /// lazily refreshed) at the start of every draw list (0x14018ac5c–0x14018ac7f), so per-object parallax offsets and
    /// group projections do not change them. nil outside a draw list.
    var cullPlanes: [SIMD4<Float>]?
    /// C+0x11c: bit 0 model culling, bit 1 image/text culling. Scene load sets 3 (0x1401872d5) and clears bit 1 for
    /// orthographic scenes (0x140187610).
    var cullFlags = 0
    /// Effect matrices (docs/re/07 §3.4). Not reset between draws, like the engine's context fields.
    var layerModel = Mat.identity
    var effectModel = Mat.identity
    var effectMVP = Mat.identity
    var effectTextureProjection = Mat.identity
    /// g_AudioSpectrum{16,32,64}{Left,Right} (docs/re/06 §5.3), filled by SceneRenderer each frame.
    var audio = AudioSpectrumArrays()
    /// g_AltModelMatrix (C+0xa70) and g_AltViewProjectionMatrix (C+0xab0): the prelit image pass lights in world
    /// space while drawing into the composite (docs/re/06 §2.1.4). Context fields, not reset between draws.
    var altModel = Mat.identity
    var altViewProjection = Mat.identity
    /// g_LightAmbientColor / g_LightSkylightColor (C+0x1298 / C+0x12a4, from scene general, 0x140187e4a).
    var ambientColor = SIMD3<Float>(0, 0, 0)
    var skylightColor = SIMD3<Float>(0, 0, 0)
    /// g_bufLights (b3) members for this frame (`Lights_Update` 0x140190c80).
    var lights: [String: UniformValue] = [:]
    /// g_LightsColorRadius / g_LightsColorPremultiplied / g_LightsPosition (legacy `point` lights, `LegacyLights`).
    var legacyLights: [String: UniformValue] = LegacyLights.uniforms([])
    /// g_FogDistanceColor / g_FogDistanceParams / g_FogHeightColor / g_FogHeightParams (ids 0x87–0x8a, C+0x12b0 /
    /// C+0x12c8 / C+0x12bc / C+0x12d8, written by `Scene_UpdateFog` 0x140186440).
    var fog: [String: UniformValue] = [:]

    /// Engine `g_NormalModelMatrix` / `g_AltNormalModelMatrix` (0x1400d8840 / 0x1400d8aab): the 3×3 with each
    /// row normalised (each column here).
    static func normalMatrix(_ m: simd_float4x4) -> simd_float3x3 {
        func c(_ v: SIMD4<Float>) -> SIMD3<Float> { simd_normalize(SIMD3(v.x, v.y, v.z)) }
        return simd_float3x3(c(m.columns.0), c(m.columns.1), c(m.columns.2))
    }

    /// RunPass flags&1 path. Column-vector form of the row-vector products: S·X becomes X·S.
    func setEffectMatrices(world: simd_float4x4, lmvp: simd_float4x4, size: SIMD2<Float>, final: Bool) {
        let S = Mat.scale(SIMD3(size.x / 2, size.y / 2, 1))
        layerModel = world
        effectModel = final ? world : world * S
        effectMVP = final ? lmvp : lmvp * S
        effectTextureProjection = lmvp * S
    }

    /// Built-in uniforms (docs/re/07). MVP = Model·View·Proj in the engine's row-vector form.
    func builtins(color: SIMD3<Float>, alpha: Float, target: MTLTexture) -> [String: UniformValue] {
        let mvp = proj * view * model
        let vp = proj * view
        let w = screen.x, h = screen.y
        let normal = Self.normalMatrix(model)
        var u: [String: UniformValue] = [
            "g_ModelViewProjectionMatrix": .matrix(mvp),
            "g_ModelViewProjectionMatrixInverse": .matrix(mvp.inverse),
            "g_ModelMatrix": .matrix(model),
            "g_ModelMatrixInverse": .matrix(model.inverse),
            "g_NormalModelMatrix": .matrix3(normal),
            "g_ViewProjectionMatrix": .matrix(vp),
            "g_LayerModelMatrix": .matrix(layerModel),
            "g_EffectModelMatrix": .matrix(effectModel),
            "g_EffectModelViewProjectionMatrix": .matrix(effectMVP),
            "g_EffectModelViewProjectionMatrixInverse": .matrix(effectMVP.inverse),
            "g_EffectTextureProjectionMatrix": .matrix(effectTextureProjection),
            "g_EffectTextureProjectionMatrixInverse": .matrix(effectTextureProjection.inverse),
            "g_Time": .floats([time]),
            "g_Frametime": .floats([frameTime]),
            "g_Daytime": .floats([daytime]),
            "g_Color": .floats([color.x, color.y, color.z]),
            "g_Alpha": .floats([alpha]),
            "g_Color4": .floats([color.x, color.y, color.z, alpha]),
            "g_Screen": .floats([w, h, w / h]),
            "g_TexelSize": .floats([1 / w, 1 / h]),
            "g_TexelSizeHalf": .floats([0.5 / w, 0.5 / h]),
            "g_TextureReductionScale": .floats([textureReduction]),
            // g_HDRParams (0x8b, b0): renderer D+0x40/+0x44 via vt+0x158 (0x14009b790), (1, 1) unless an ST.2084 output
            // rewrites it (0x140110885–0x1401108bd, docs/re/07 Unknowns). Read by passthroughlinear (`rgb / g_HDRParams.x`).
            "g_HDRParams": .floats([1, 1]),
            "g_PointerPosition": .floats([pointer.x, pointer.y]),
            "g_PointerPositionLast": .floats([pointerLast.x, pointerLast.y]),
            "g_PointerState": .floats([pointerDown ? 1 : 0, pointerDown ? 1 : 0, pointerDown && !pointerWasDown ? 1 : 0, 0]),
            "g_ParallaxPosition": .floats([parallax.x, parallax.y]),
            "g_EyePosition": .floats([eye.x, eye.y, eye.z]),
            "g_AudioSpectrum16Left": .floats(audio.left16),
            "g_AudioSpectrum16Right": .floats(audio.right16),
            "g_AudioSpectrum32Left": .floats(audio.left32),
            "g_AudioSpectrum32Right": .floats(audio.right32),
            "g_AudioSpectrum64Left": .floats(audio.left64),
            "g_AudioSpectrum64Right": .floats(audio.right64),
            "g_AltModelMatrix": .matrix(altModel),
            "g_AltNormalModelMatrix": .matrix3(Self.normalMatrix(altModel)),
            "g_AltViewProjectionMatrix": .matrix(altViewProjection),
            "g_LightAmbientColor": .floats([ambientColor.x, ambientColor.y, ambientColor.z]),
            "g_LightSkylightColor": .floats([skylightColor.x, skylightColor.y, skylightColor.z]),
        ]
        if let v = cameraView {
            let right = SIMD3(v.columns.0.x, v.columns.1.x, v.columns.2.x), up = SIMD3(v.columns.0.y, v.columns.1.y, v.columns.2.y)
            let fwd = viewForward ?? -SIMD3(v.columns.0.z, v.columns.1.z, v.columns.2.z)
            u["g_ViewRight"] = .floats([right.x, right.y, right.z])
            u["g_ViewUp"] = .floats([up.x, up.y, up.z])
            u["g_ViewForward"] = .floats([fwd.x, fwd.y, fwd.z])
        }
        for (k, v) in lights { u[k] = v }
        for (k, v) in legacyLights { u[k] = v }
        for (k, v) in fog { u[k] = v }
        return u
    }
}

/// Common object fields (docs/re/04 §4.2).
class SceneObject {
    let id: Int
    let json: [String: Any]
    var origin = SIMD3<Float>(0, 0, 0)
    var scale = SIMD3<Float>(1, 1, 1)
    var angles = SIMD3<Float>(0, 0, 0)
    var parallaxDepth = SIMD2<Float>(1, 1)
    var visible = true
    var parentID: Int?
    weak var parent: SceneObject?

    init(json: [String: Any], id: Int) {
        self.json = json
        self.id = id
        if let v = Self.vec3(json["origin"]) { origin = v }
        if let v = Self.vec3(json["scale"]) { scale = v }
        if let v = Self.vec3(json["angles"]) { angles = v }
        let pd = jsonFloats(json["parallaxDepth"])
        if pd.count == 1 { parallaxDepth = SIMD2(pd[0], pd[0]) } else if pd.count >= 2 { parallaxDepth = SIMD2(pd[0], pd[1]) }
        visible = jsonBool(json["visible"], default: true)
        parentID = (json["parent"] as? NSNumber)?.intValue
        for key in ["origin", "scale", "angles"] {
            if let a = PropertyAnimation(json: json[key]) { animations[key] = a }
        }
    }

    /// Scratch composite names (`Layer_AllocRenderTargets` 0x1401eade4–0x1401eb08d): walk the parent chain (+0x180); every
    /// ancestor of type 1/4/10 (vt+0x60, bitmask 0x412) with `+0x120 & 4` whose current input target
    /// `RT[(compositeSteps − (flags304 & 0x10 ? 0 : 1)) & 1]` already has this name counts once, and a non-zero count is
    /// appended. A passthrough ancestor with no effects and no dedicated composite (index −1) is never compared.
    var hasPassthroughAncestor: Bool {
        var p = parent
        while let a = p { if (a as? ImageLayer)?.passthrough == true { return true }; p = a.parent }
        return false
    }

    static func scratchName(_ base: String, for obj: SceneObject) -> String {
        var count = 0
        var p = obj.parent
        while let a = p {
            if let img = a as? ImageLayer, img.passthrough {
                let total = img.compositeSteps - (img.needComposite ? 0 : 1)
                if total >= 0, total % 2 < img.targets.count, img.targets[total % 2].name == base { count += 1 }
            }
            p = a.parent
        }
        return count > 0 ? base + String(count) : base
    }

    /// Channel counts per animatable property (vec3 = 3, float = 1).
    static let arity: [String: Int] = ["origin": 3, "scale": 3, "angles": 3, "alpha": 1, "brightness": 1, "color": 3, "zoom": 1, "fov": 1]

    /// Keyframe-animated fields (docs/re/04 §5), advanced in `update`.
    var animations: [String: PropertyAnimation] = [:]
    private var animationsLinked = false

    /// Advances animations and writes their values into the fields. A linked child is not advanced: `Bindings_Tick`
    /// advances only the timeline owner, once per frame (stamp +0x88, 0x14017238c).
    func updateAnimations(_ dt: Float) {
        if !animationsLinked {
            animationsLinked = true
            PropertyAnimation.link(animations.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
        }
        for (_, a) in animations where a.timelineParent == nil { a.advance(dt) }
        for (key, a) in animations {
            if let v = a.value(arity: Self.arity[key] ?? a.channelCount) { apply(key, v) }
        }
    }

    func apply(_ key: String, _ v: [Float]) {
        func v3(_ d: SIMD3<Float>) -> SIMD3<Float> { SIMD3(v.count > 0 ? v[0] : d.x, v.count > 1 ? v[1] : d.y, v.count > 2 ? v[2] : d.z) }
        switch key {
        case "origin": origin = v3(origin)
        case "scale": scale = v3(scale)
        case "angles": angles = v3(angles)
        default: break
        }
    }

    static func vec3(_ v: Any?) -> SIMD3<Float>? {
        let f = jsonFloats(v)
        guard !f.isEmpty else { return nil }
        if f.count == 1 { return SIMD3(f[0], f[0], f[0]) }
        return SIMD3(f[0], f.count > 1 ? f[1] : 0, f.count > 2 ? f[2] : 0)
    }

    /// `Object_GetWorld` 0x1401dd7d0: local = S·R·T (row-vector); with an attachment the parent's
    /// vt+0x78 first applies `M = local × attach × boneWorld`; then world = M·parent.world
    /// →  P = parent · boneWorld · attach · T · R · S.
    var world: simd_float4x4 {
        var local = Mat.translate(origin) * Mat.rotation(angles) * Mat.scale(scale)
        if let p = parent, let a = p.attachmentTransform(attachmentIndex) { local = a * local }
        return (parent?.world ?? Mat.identity) * local
    }

    /// `attachment` (object loader 0x1401de5c1): an attachment point name on the parent's puppet, resolved to
    /// obj +0x190 through the parent's vt+0x70 once the parent is linked.
    lazy var attachmentName: String? = json["attachment"] as? String
    private var resolvedAttachment: (parent: ObjectIdentifier, index: Int)?
    var attachmentIndex: Int {
        guard let p = parent else { return -1 }
        if let s = scriptAttachment { return s.parent == ObjectIdentifier(p) ? s.index : -1 }
        guard let name = attachmentName else { return -1 }
        if let r = resolvedAttachment, r.parent == ObjectIdentifier(p) { return r.index }
        let i = p.attachmentIndex(name)
        resolvedAttachment = (ObjectIdentifier(p), i)
        return i
    }
    func attachmentIndex(_ name: String) -> Int { -1 }
    func attachmentTransform(_ index: Int) -> simd_float4x4? { nil }

    var effectiveVisible: Bool { visible && (parent?.effectiveVisible ?? true) }
    /// Object vt+0x68: "draw me" for the scene list. Layers (0x1401ea2d0, text 0x1402577e0) also answer true for
    /// `flags304 & 0x1100` (ledsource, or another object's `dependencies` entry) even when hidden.
    var renderVisible: Bool { effectiveVisible }
    /// `flags304 |= 0x1010` from `SceneData_Load` 0x1401881b0: the id appears in some object's `dependencies`.
    var isDependency = false

    /// Object flag `+0x120 & 2`: set (recursively, `0x1401dd900`) on every descendant of an object whose flags have
    /// bit 1 or bit 2 (`0x1401de698`, `0x1401de8bf`); bit 2 marks a passthrough image (`0x1401fb35f`). Such objects are
    /// skipped by the scene list and drawn by their passthrough group (docs/re/03 §7).
    var drawnByGroup: Bool {
        guard let p = parent else { return false }
        if let img = p as? ImageLayer, img.passthrough { return true }
        return p.drawnByGroup
    }

    /// `perspective` (+0x120 bit 7, bool loader 0x14019c620; layer table 0x1404e8360 and model table 0x1404e8760 only).
    lazy var perspective: Bool = EngineValue.bool(json["perspective"], default: false)

    /// `Layer_Render` 0x1401e8aa0: with `perspective`, the scene draw runs between a view/projection push and
    /// `Camera_PushPerspective` 0x1401e5b60 (direct path 0x1401e9233–0x1401e92f3, final compose 0x1401e9e9f).
    func withPerspective(_ frame: FrameState, _ scene: SceneRenderer, _ body: () -> Void) {
        guard perspective, scene.isOrtho else { body(); return }
        let v = frame.view, p = frame.proj
        scene.pushPerspective(frame)
        body()
        frame.view = v; frame.proj = p
    }

    /// `sortorder` (+0x124, Object_RegisterProps 0x1401e0916).
    lazy var sortOrder: Int = (json["sortorder"] as? NSNumber)?.intValue ?? 0
    /// `name` (+0x1d8, Object_RegisterProps 0x1401e0530): scripts may rename an object; name lookups use the current value.
    lazy var objectName: String = (json["name"] as? String) ?? ""
    /// `solid` (+0x120 bit 13, ctor flags 0x2001 → default true): `Scene_HitTest` 0x140189e10 skips objects without it
    /// (0x14018a02d `test word [obj+0x120], 0x2000`).
    lazy var solid: Bool = EngineValue.bool(json["solid"], default: true)
    /// `disablepropagation` (+0x120 bit 14, bool loader 0x14019bb40, default off): a cursor hit on this object stops
    /// `Scene_HitTest` 0x140189e10 from testing the objects below it while its parent chain is visible (0x14018a86f).
    lazy var disablePropagation: Bool = EngineValue.bool(json["disablepropagation"], default: false)
    /// Script `setParent` with an attachment (0x1401de750 → +0x190): overrides the `attachment` name resolution.
    var scriptAttachment: (parent: ObjectIdentifier, index: Int)?
    /// `+0x120 & 0x100` at creation: drawn in the sorted transparent pass of perspective scenes (see SceneRenderer.drawList).
    var isTransparent: Bool { false }

    var root: SceneObject { parent?.root ?? self }

    /// `reflected` (Scene_CreateObject 0x14019086d–0x140190926): a JSON bool, anything else counts as true.
    lazy var reflected: Bool = {
        if let n = json["reflected"] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        return true
    }()
    /// Object flag `+0x120 & 8` after load: the object samples `_rt_Reflection` (only models set it, 0x1402252af).
    var needsReflection: Bool { false }
    /// Joins the reflection list S+0x1c8 at creation: `reflected`, not a light or sound (r15b cleared at 0x140190471 /
    /// 0x140190601), and not itself a reflection user (`+0x120 & 8`, 0x140190916).
    var inReflectionList: Bool { reflected && !(self is LightObject) && !(self is SoundObject) && !needsReflection }

    func update(_ dt: Float) { updateAnimations(dt) }
    func render(_ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer) {}
}

/// A `camera` object (Scene_CreateObject 0x140190693: 0x360 bytes, vtable 0x140490980; fov +0x2d8 = 50,
/// zoom +0x2dc = 1, path index +0x2e0 = −1). `Scene_Update` 0x1401891a0 picks the last visible camera (whose parent
/// chain is visible) as the active one; its zoom becomes S+0x114 (0x1401893a2), which `Scene_Frame` multiplies with
/// general `zoom` for the ortho projection (0x14017fd50, docs/re/04 §3.2). Its world matrix also supplies the view
/// (eye = row 3, centre = row 3 − row 2, up = row 1, 0x1401892d3) and, in perspective scenes, its fov the projection.
final class CameraObject: SceneObject {
    var zoom: Float = 1
    var fov: Float = 50
    /// `path` file player (`Camera_Load` 0x1401f2030 / `Camera_Update` 0x1401f2ad0, CameraPath.swift).
    var pathPlayer: CameraPathPlayer?
    var ortho = false
    private var pathZoom: Float?, pathFov: Float?
    /// `Scene_Update` 0x140189367–0x1401893b1 / 0x1401893bf–0x140189402: while a path is selected (+0x2e0 ≥ 0) its
    /// zoom (+0x338) and fov (+0x33c) replace the object's own.
    var currentZoom: Float { pathZoom ?? zoom }
    var currentFov: Float { pathFov ?? fov }

    /// Camera_Update runs only for a visible camera with a visible parent chain (0x1401f2adf–0x1401f2b0d).
    override func update(_ dt: Float) {
        super.update(dt)
        guard let player = pathPlayer, effectiveVisible else { return }
        guard let r = player.update(dt, world: world, ortho: ortho) else {
            if player.current < 0 { pathZoom = nil; pathFov = nil }
            return
        }
        origin = r.eye
        angles = CameraPathPlayer.angles(eye: r.eye, center: r.center, up: r.up)
        pathZoom = r.zoom ?? 1
        pathFov = r.fov ?? 50
    }

    override init(json: [String: Any], id: Int) {
        super.init(json: json, id: id)
        zoom = jsonFloats(json["zoom"]).first ?? 1
        fov = jsonFloats(json["fov"]).first ?? 50
        for key in ["zoom", "fov"] {
            if let a = PropertyAnimation(json: json[key]) { animations[key] = a }
        }
    }

    override func apply(_ key: String, _ v: [Float]) {
        switch key {
        case "zoom": if let z = v.first { zoom = z }
        case "fov": if let f = v.first { fov = f }
        default: super.apply(key, v)
        }
    }
}

/// An image layer (docs/re/03 §4–§8).
final class ImageLayer: SceneObject {
    enum Alignment: String { case center, top, topright, right, bottomright, bottom, bottomleft, left, topleft }

    let resources: SceneResources
    var material: Material
    var composeMaterial: Material?
    /// `L+0x4a8` for a passthrough group (`+0x120 & 4` with children, `Image_UpdateMaterialVariants` 0x14020aa72):
    /// `fullscreenlayer.json` when fullscreen, else `Image_ComposeMaterialPath` 0x1401ecae0 (effectpassthrough(_4)),
    /// no combos. `Image_DrawDirect` 0x140208670 draws the group RT with it instead of the layer material.
    lazy var groupMaterial: Material = resources.material(
        fullscreen ? "materials/util/fullscreenlayer.json" : resources.composeMaterialPath)
    var effects: [Effect] = []
    var size = SIMD2<Float>(0, 0)
    var color = SIMD3<Float>(1, 1, 1)
    var alpha: Float = 1
    var brightness: Float = 1
    var colorBlendMode = 0
    var copyBackground = true
    var clampUVs = true
    var noInterpolation = false
    var alignment = Alignment.center
    var fullscreen = false, noPadding = false, autosize = false, passthrough = false, solidLayer = false
    /// Image model `projectlayer` / `instanced` (Image ctor 0x1401fac50, docs/re/loader-keys.md).
    var projectLayer = false, instanced = false
    /// `+0x120 & 0x200` (fullscreen or projectlayer): the transparent sort key is −∞ (0x14018665a–0x140186681).
    var sortsLast: Bool { fullscreen || projectLayer }
    var compositeSteps = 0
    /// Dedicated composite (flags304 & 0x10): non-normal blend modes, and puppets that have effects. For those the
    /// plain image goes into the composite and the skinned mesh is drawn at the compose step (docs/re/06 §2.1).
    /// Lit layers that composite also get it: `!(prelit && skinned)` sets flags304 |= 0x10 (0x140209b79).
    var needComposite: Bool {
        loadBlendComposite || puppetComposite || (prelitMaterial != nil && puppetFile == nil)
            || layerNeedsComposite
    }
    /// flags304 & 0x10 from the blend mode is set once, by `Layer_LoadEffects` 0x1401e6f50 at load: a script that later
    /// writes `colorBlendMode` (+0x32c) changes only what Layer_Render reads live: the `_rt_FullFrameBuffer` snapshot
    /// (0x1401e8ef2) and the additive override for 31 (0x140208786 / vt+0x120). It never changes the composite path, its targets
    /// (Layer_AllocRenderTargets 0x1401ea500 counts flags304 & 0x10) or the compose material's BLENDMODE combo.
    private(set) var loadBlendComposite = false
    /// `Layer_LoadEffects` 0x1401e6f50 (0x1401e6f74–0x1401e6fa2): `ledsource` (flags304 0x100) or scene fog
    /// (C+0x118 & 0x1800000) also force the dedicated composite, and so does being a dependency (0x1401881b0).
    var layerNeedsComposite: Bool { ledSource || resources.fogFlags != 0 || isDependency }
    /// `ledsource` (+0x304 bit 8).
    var ledSource = false
    override var renderVisible: Bool { effectiveVisible || ledSource || isDependency }
    /// The image model's `material` path (for the variants rebuilt by `updateCompositeVariants`).
    var materialPath = ""
    /// `L+0x4a0` prelit variant (`Image_UpdateMaterialVariants` 0x140209540, docs/re/06 §2.1.1): built when the image
    /// material is lit (`+0x1fc & 0x18`) and the layer goes through a composite or is a sprite. It lights the image
    /// in world space while drawing it into the composite.
    var prelitMaterial: Material?
    /// Lit puppets with a texture-channel mesh: P+0x3e8 albedo RT, P+0x410 copy material, P+0x3f0 triangle.
    var albedoTarget: RenderTarget?
    var albedoMaterial: Material?
    var albedoTriangle: Mesh?
    /// Non-direct puppets (`Puppet_BuildGeometry` 0x14020b20d sets flags304 |= 0x10): visible effects, a sprite
    /// sheet, or a texture-channel mesh (`Image_UpdateMaterialVariants` 0x140209559–0x140209703).
    var puppetComposite: Bool {
        guard let mdl = puppetFile else { return false }
        let sprite = material.textures[0]?.gpu?.tex.flags.contains(.spriteSheet) ?? false
        // A dependency layer (particle `emitterimage`, flags304 |= 0x1010, docs/re/05 §S6.5) also draws composed: the
        // image-space composite through the skinned mesh.
        return compositeSteps > 0 || sprite || mdl.meshes.contains { $0.flags & 2 != 0 } || isDependency
    }
    /// `P+0x408`: the texture-channel mesh's own material with `BLENDROWCOUNT` (0x140209540).
    var channelMaterial: Material?

    var geomSize = SIMD2<Float>(0, 0)
    var effectQuad: Quad?
    var objectQuad: Quad?
    var directQuad: Quad?
    var intoCompositeQuad: Quad?
    /// The image quad centred on the layer origin (`L+0x2d8`), drawn by the prelit pass.
    var prelitQuad: Quad?
    var targets: [RenderTarget] = []
    var rtSize = SIMD2<Int>(4, 4)
    /// FBO `clear` colours, applied on the next render (docs/re/03 §6 step 7).
    var pendingClears: [(RenderTarget, [Float])] = []
    var skinnedMaterial: Material?
    /// Clip groups (docs/re/06 §2.1.6): `P+0x420` clippingmaskimage4 mask material, `P+0x428` clip-target variants of
    /// the direct (image material) and compose materials (`CLIPPINGUVS=1`, `CLIPPINGTARGET=1`), and flattexture.json
    /// for folding `_rt_FullAlphaMaskIntermediate` into `_rt_FullAlphaMask`.
    var clipMaskMaterial: Material?
    var clipTargetMaterial: Material?
    var clipComposeTargetMaterial: Material?
    var clipFlatMaterial: Material?
    var puppetFile: MdlFile?
    var puppet: Puppet?
    /// Puppet +0x418: the "morph_" texture, bound as texture 5 of the skinned and compose materials.
    var morphTexture: BoundTexture?

    /// `Image_UpdateMaterialVariants` 0x140209540 / `Image_BuildComposeMaterial`: `MORPHING` when mdl mesh 0 has
    /// `a_PositionVec4` (vflags & 0x10000), `MORPHING_MODIFIERS` when it also has mflags & 0x2000.
    static func morphCombos(_ mdl: MdlFile) -> [String: Any] {
        guard let m = mdl.meshes.first, m.vertexFlags & 0x10000 != 0 else { return [:] }
        var c: [String: Any] = ["MORPHING": 1]
        if m.flags & 0x2000 != 0 { c["MORPHING_MODIFIERS"] = 1 }
        return c
    }
    var layerWorldSaved = Mat.identity
    var layerMVP = Mat.identity
    /// Sprite-sheet timeline taken over by `getTextureAnimation()` (docs/re/08 §3.10). Nil = frames follow scene time.
    var spriteClock: SpriteClock?

    /// The script texture animation (0xf0-byte object at layer +0x4c0, `getTextureAnimation` 0x14020e670; ctor: attached
    /// (+0x48 = 0), playing (+0xe0 = 1), rate (+0xe4) 1, frame index +0xe8 and frame time +0xec 0). While attached the layer
    /// shows the texture's shared clock (texture +0x9c/+0xa0); detached it keeps its own (index, time) pair, stepped at the
    /// end of the image update (0x1402063b9–0x140206405) only while playing and only for a sprite-sheet texture, by
    /// `SpriteSheet_Step` 0x14015fdd0 with dt = frame time C+0x14c × rate (the same one-frame-per-call rule as the
    /// texture clock). `Image_Render` 0x140206587–0x1402065bb: while detached, C+0x132c = own index around the whole
    /// `Layer_Render` call, so every sprite sheet drawn in the layer's passes shows that frame (see `Draw`).
    final class SpriteClock {
        var index = 0
        var time: Float = 0
        var rate: Float = 1
        var playing = true
        var attached = true
        init() {}
    }

    init?(json: [String: Any], id: Int, resources: SceneResources, nextEffectID: () -> Int) {
        self.resources = resources
        guard let modelPath = json["image"] as? String, let model = resources.fs.readJSON(modelPath) as? [String: Any] else { return nil }
        fullscreen = (model["fullscreen"] as? Bool) ?? false
        noPadding = (model["nopadding"] as? Bool) ?? false
        autosize = (model["autosize"] as? Bool) ?? false
        passthrough = (model["passthrough"] as? Bool) ?? false
        solidLayer = (model["solidlayer"] as? Bool) ?? false
        projectLayer = (model["projectlayer"] as? Bool) ?? false   // flags304 0x400, +0x120 0x200 (0x1401faf19)
        instanced = (model["instanced"] as? Bool) ?? false         // flags304 0x800 (0x1401faf54)
        let materialPath = (model["material"] as? String) ?? "materials/util/error.json"
        self.materialPath = materialPath
        // Image ctor 0x1401fad7c–0x1401fadee: model `width` / `height` go through Json_AsFloat for tags 0–3, so a missing
        // key or null gives 0; other types keep 0. The object's reflected `size` (Layer table, loaded afterwards by
        // Object_LoadJsonProps) overrides them.
        func modelDim(_ k: String) -> Float {
            switch model[k] {
            case nil, is NSNull: return 0
            case let n as NSNumber where !EngineValue.isBoolPublic(n): return n.floatValue
            default: return 0
            }
        }
        size = SIMD2(modelDim("width"), modelDim("height"))
        // `instanced` (0x1401faf75–0x1401fb19c): the size is parsed from the object's `size` first; the material is a
        // private instance `MaterialMgr_CreateInstance(material, object.instance)` 0x140150770 with
        // `instance.usertexturereference = {width, height}` = that size.
        var instanceOverride: [String: Any]? = nil
        if instanced {
            let sz = EngineValue.vecStep(json["size"], [0, 0], count: 2)
            var inst = (json["instance"] as? [String: Any]) ?? [:]
            inst["usertexturereference"] = ["width": sz[0], "height": sz[1]]
            inst.removeValue(forKey: "id")
            instanceOverride = inst
        }
        // Puppet warp (Image_LoadModel 0x1401fbae0): only when neither fullscreen nor passthrough.
        if let puppetPath = model["puppet"] as? String, !fullscreen, !passthrough,
           let data = resources.fs.read(puppetPath), let mdl = try? MdlFile(data: data), !mdl.bones.isEmpty {
            // +0x498 plain image material (composite path), +0x4a8 skinned material (direct path).
            material = resources.material(materialPath)
            var skin: [String: Any] = ["SKINNING": 1, "BONECOUNT": mdl.bones.count]
            if mdl.meshes.first.map({ $0.flags & 4 != 0 }) ?? false { skin["SKINNING_ALPHA"] = 1 }
            for (k, v) in Self.morphCombos(mdl) { skin[k] = v }
            skinnedMaterial = resources.material(materialPath, override: ["combos": skin])
            puppetFile = mdl
        } else if let inst = instanceOverride {
            material = resources.material(materialPath, override: inst)
        } else {
            material = resources.material(materialPath)
        }
        super.init(json: json, id: id)

        size = EngineValue.vec2(json["size"], default: size)
        if let c = Self.vec3(json["color"]) { color = c }
        if let a = jsonFloats(json["alpha"]).first { alpha = a }
        if let b = jsonFloats(json["brightness"]).first { brightness = b }
        colorBlendMode = (unwrapUserValue(json["colorBlendMode"]) as? NSNumber)?.intValue ?? 0
        loadBlendComposite = colorBlendMode != 0 && colorBlendMode != 31
        for key in ["alpha", "brightness", "color"] {
            if let a = PropertyAnimation(json: json[key]) { animations[key] = a }
        }
        copyBackground = jsonBool(json["copybackground"], default: true)
        ledSource = jsonBool(json["ledsource"], default: false)
        clampUVs = jsonBool(json["clampuvs"], default: true)
        noInterpolation = jsonBool(json["nointerpolation"], default: false)
        alignment = Alignment(rawValue: (json["alignment"] as? String) ?? "center") ?? .center

        for (ei, e) in ((json["effects"] as? [[String: Any]]) ?? []).enumerated() {
            guard let file = e["file"] as? String else { continue }
            let eid = (e["id"] as? NSNumber)?.intValue ?? nextEffectID()
            guard let effect = Effect(path: file, instance: e, id: eid, scene: resources) else { continue }
            effect.jsonIndex = ei
            if effect.visible { compositeSteps += 1 + effect.composeCount }
            effects.append(effect)
        }
        updateCompositeVariants()
        if let mdl = puppetFile, mdl.meshes.first.map({ !$0.clipGroups.isEmpty }) ?? false {
            // `Image_UpdateMaterialVariants` 0x140209540 / 0x14020a998.
            var skin: [String: Any] = ["SKINNING": 1, "BONECOUNT": mdl.bones.count]
            if mdl.meshes.first.map({ $0.flags & 4 != 0 }) ?? false { skin["SKINNING_ALPHA"] = 1 }
            for (k, v) in Self.morphCombos(mdl) { skin[k] = v }
            var mask = skin
            if material.blendMode == .alphaToCoverage { mask["ALPHATOCOVERAGE"] = 1 }
            clipMaskMaterial = resources.material("materials/util/clippingmaskimage4.json", override: ["combos": mask])
            skin["CLIPPINGUVS"] = 1; skin["CLIPPINGTARGET"] = 1
            clipTargetMaterial = resources.material(materialPath, override: ["combos": skin])
            clipFlatMaterial = resources.material("materials/util/flattexture.json")
        }
        buildGeometry()
        allocateTargets()
        if let mdl = puppetFile {
            let d = textureDims ?? SIMD4(1, 1, 1, 1)
            puppet = Puppet(mdl: mdl, layersJSON: (json["animationlayers"] as? [[String: Any]]) ?? [],
                            uvScale: SIMD2(d.x > 0 ? d.z / d.x : 1, d.y > 0 ? d.w / d.y : 1))
            if let m0 = mdl.meshes.first, m0.vertexFlags & 0x10000 != 0 {
                morphTexture = MorphGPU.puppetTexture(device: resources.device, mesh: m0)
            }
            if let p = puppet, let path = p.channelMaterialPath, p.channelMesh != nil {
                channelMaterial = resources.material(path, override: ["combos": ["BLENDROWCOUNT": p.blendRowCount]])
            }
        }
    }

    override func update(_ dt: Float) {
        super.update(dt)
        if let p = puppet, p.ikUsesScene, let s = scene {   // C+0x1510 gravity/wind/time for rope chains
            p.ikEnvironment = PuppetIK.Environment(general: s.general, time: s.frame.time, orthoWidth: s.orthoSize.x)
        }
        puppet?.update(dt, layerWorld: layerWorld)
        if let c = spriteClock, !c.attached, c.playing, let tex = texture?.tex, tex.flags.contains(.spriteSheet) {
            GPUTexture.stepSprite(tex.frames, index: &c.index, time: &c.time, dt: dt * c.rate)
        }
    }

    override func attachmentIndex(_ name: String) -> Int { puppet?.attachmentIndex(name) ?? -1 }
    override func attachmentTransform(_ index: Int) -> simd_float4x4? { puppet?.attachmentTransform(index) }

    override func apply(_ key: String, _ v: [Float]) {
        switch key {
        case "alpha": if let a = v.first { alpha = a }
        case "brightness": if let b = v.first { brightness = b }
        case "color": if v.count >= 3 { color = SIMD3(v[0], v[1], v[2]) }
        default: super.apply(key, v)
        }
    }

    /// Image_Load 0x1401fb31b: material blend not normal/alphatocoverage, or passthrough without copybackground.
    override var isTransparent: Bool {
        (material.blending != .normal && material.blending != .alphatocoverage) || (passthrough && !copyBackground)
    }

    var texture: GPUTexture? { material.textures[0]?.gpu }
    weak var scene: SceneRenderer?
    private var builtForScreen = SIMD2<Int>(0, 0)

    /// (texW, texH, imgW, imgH) of texture slot 0. Render-target textures (e.g. `_rt_FullFrameBuffer` on
    /// fullscreen layers) report their actual size in both halves (docs/re/07 §3.6).
    var textureDims: SIMD4<Float>? {
        if let t = texture?.tex {
            return SIMD4(Float(t.textureWidth), Float(t.textureHeight), Float(t.imageWidth), Float(t.imageHeight))
        }
        if let name = material.textureNames[0], name.hasPrefix("_rt_"), let rt = scene?.namedTarget(name) {
            return SIMD4(Float(rt.width), Float(rt.height), Float(rt.width), Float(rt.height))
        }
        return nil
    }

    /// `Image_OnTextureChanged` + image geometry builder 0x1402066a0.
    /// The prelit and compose variants (`Image_UpdateMaterialVariants` 0x140209540); rerun when a layer becomes a
    /// dependency after load (image vt+0x110 0x1402065e0).
    func updateCompositeVariants() {
        let lit = material.litFlags
        let spriteSheet = material.textures[0]?.gpu?.tex.flags.contains(.spriteSheet) ?? false
        if lit != 0, puppetFile == nil, compositeSteps > 0 || needComposite || spriteSheet {
            prelitMaterial = resources.material(materialPath, override: [
                "combos": ["LIGHTING": lit & 0x10 != 0 ? 1 : 0, "REFLECTION": lit & 8 != 0 ? 1 : 0, "PRELIGHTING": 1],
                "cullmode": "nocull",
            ])
        } else if lit != 0, let mdl = puppetFile, puppetComposite {
            // Lit puppet (`L+0x4b0` = lit && (needsComp || sprite || hasTC), 0x140209559–0x140209703): the prelit variant
            // adds SKINNING=1, BONECOUNT, PRELIGHTINGDUALVERTEX=1 and the morph combos (no SKINNING_ALPHA), nocull.
            var combos: [String: Any] = ["LIGHTING": lit & 0x10 != 0 ? 1 : 0, "REFLECTION": lit & 8 != 0 ? 1 : 0, "PRELIGHTING": 1,
                                         "SKINNING": 1, "BONECOUNT": mdl.bones.count, "PRELIGHTINGDUALVERTEX": 1]
            for (k, v) in Self.morphCombos(mdl) { combos[k] = v }
            prelitMaterial = resources.material(materialPath, override: ["combos": combos, "cullmode": "nocull"])
            // With a texture-channel mesh: `_rt_imageLayerAlbedo_<id>` (texture content size, rgba16f when HDR, 0x140209fd1)
            // and the albedo copy material `fullscreenlayer.json` with textures[0] = the image texture, blending normal,
            // SPRITESHEET when the texture is a sprite sheet (P+0x410).
            if mdl.meshes.contains(where: { $0.flags & 2 != 0 }), albedoTarget == nil {
                let d = textureDims ?? SIMD4(4, 4, 4, 4)
                albedoTarget = resources.targets.acquire("_rt_imageLayerAlbedo_\(id)", width: max(Int(d.z), 1), height: max(Int(d.w), 1),
                                                         format: resources.hdr ? .rgba16Float : .rgba8Unorm, samplerFlags: 2)
                var o: [String: Any] = ["blending": "normal"]
                if let n = material.textureNames[0] { o["textures"] = [n] }
                if spriteSheet { o["combos"] = ["SPRITESHEET": 1] }
                albedoMaterial = resources.material("materials/util/fullscreenlayer.json", override: o)
                // P+0x3f0: full-screen triangle (-1,1) (-1,-3) (3,1), uv (0,0) (0,2·wr) (2·wr,0) with wr = content/texture
                // width; the engine uses wr for v as well (0x14020a366).
                let wr = d.x > 0 ? d.z / d.x : 1
                albedoTriangle = Mesh(layout: VertexLayout(stride: 20, attributes: [.init(id: 0, format: .float3, offset: 0),
                                                                                   .init(id: 7, format: .float2, offset: 12)]),
                                      vertices: [-1, 1, 0, 0, 0, -1, -3, 0, 0, 2 * wr, 3, 1, 0, 2 * wr, 0], indices: [0, 1, 2],
                                      vertexCount: 3)
            }
        }
        if needComposite {
            var combos: [String: Any] = ["BLENDMODE": colorBlendMode == 31 ? 0 : colorBlendMode, "FOG_COMPUTED": 1]
            if let mdl = puppetFile, puppetComposite {
                combos["SKINNING"] = 1; combos["BONECOUNT"] = mdl.bones.count
                if mdl.meshes.first.map({ $0.flags & 4 != 0 }) ?? false { combos["SKINNING_ALPHA"] = 1 }
                for (k, v) in Self.morphCombos(mdl) { combos[k] = v }
            }
            composeMaterial = resources.material(resources.composeMaterialPath, override: ["combos": combos])
            if puppetComposite, puppetFile?.meshes.first.map({ !$0.clipGroups.isEmpty }) ?? false {
                combos["CLIPPINGUVS"] = 1; combos["CLIPPINGTARGET"] = 1
                clipComposeTargetMaterial = resources.material(resources.composeMaterialPath, override: ["combos": combos])
            }
        }
    }

    /// `SceneData_Load` 0x1401881b0: mark as a dependency and rebuild (vt+0x110) when that newly needs a composite.
    func markDependency() {
        guard !isDependency else { return }
        let had = needComposite
        isDependency = true
        if !had {
            updateCompositeVariants()
            buildGeometry()
            allocateTargets()
        }
    }

    func buildGeometry() {
        let tex = texture?.tex
        let dims = textureDims ?? .zero
        let texW = dims.x, texH = dims.y, imgW = dims.z, imgH = dims.w
        let sprite = tex?.flags.contains(.spriteSheet) ?? false
        if fullscreen {
            size = SIMD2(imgW, imgH); geomSize = SIMD2(2, 2)
        } else if autosize {
            if sprite, let f = tex?.frames.first {
                size = SIMD2(f.xAxis.x * texW, f.yAxis.y * texH)
            } else if projectLayer, let sc = scene {
                // Image_OnTextureChanged 0x1402093f6–0x140209421: projectlayer autosize = C+0x84/+0x88, the integer
                // authored projection size.
                size = SIMD2(Float(Int(sc.orthoSize.x)), Float(Int(sc.orthoSize.y)))
            } else if let u = material.userTextureSize {
                // A bound user texture (material +0x1f8 & 4): the reference size at material+0x2b0/+0x2b2.
                size = SIMD2(Float(u.x), Float(u.y))
            } else {
                size = SIMD2(imgW, imgH)
            }
            geomSize = size
        } else {
            geomSize = size
        }
        geomSize = SIMD2(Float(Int(geomSize.x)), Float(Int(geomSize.y)))
        var uvScale = SIMD2<Float>(texW > 0 ? imgW / texW : 1, texH > 0 ? imgH / texH : 1)
        let texUV = uvScale
        if (sprite && (tex?.frames.count ?? 0) >= 3) || compositeSteps > 0 || needComposite { uvScale = SIMD2(1, 1) }
        let ts = SIMD2(texW, texH)
        effectQuad = Quad(size: SIMD2(2, 2), textureSize: ts, uvScale: uvScale, flags: .centered)
        objectQuad = Quad(size: geomSize, textureSize: ts, uvScale: uvScale,
                          flags: fullscreen || passthrough || solidLayer ? .centered : [.centered, .inset])
        let plain = fullscreen || noPadding || passthrough || solidLayer
        directQuad = Quad(size: geomSize, textureSize: ts, uvScale: uvScale, flags: plain ? .centered : [.centered, .inset])
        _ = texUV
    }

    /// `Layer_AllocRenderTargets` 0x1401ea500 (docs/re/03 §6).
    func allocateTargets() {
        targets.forEach { resources.targets.release($0) }
        targets = []
        let tex = texture?.tex
        var point = false
        var rt: SIMD2<Int>
        var uvScale = SIMD2<Float>(1, 1)
        if tex == nil, let d = textureDims {
            rt = fullscreen ? SIMD2(Int(d.z), Int(d.w)) : SIMD2(Int(size.x.rounded()), Int(size.y.rounded()))
            if !fullscreen && !(passthrough || solidLayer) { rt = SIMD2(Int(d.z), Int(d.w)) }
        } else if let tex {
            point = tex.flags.contains(.noInterpolation)
            rt = SIMD2(tex.imageWidth, tex.imageHeight)
            if tex.flags.contains(.spriteSheet), let f = tex.frames.first {
                rt = SIMD2(Int(f.xAxis.x * Float(tex.textureWidth)), Int(f.yAxis.y * Float(tex.textureHeight)))
            } else if !fullscreen && (passthrough || solidLayer) {
                rt = SIMD2(Int(size.x.rounded()), Int(size.y.rounded()))
            }
            uvScale = SIMD2(Float(tex.imageWidth) / Float(max(tex.textureWidth, 1)), Float(tex.imageHeight) / Float(max(tex.textureHeight, 1)))
        } else {
            rt = SIMD2(Int(size.x.rounded()), Int(size.y.rounded()))
        }
        // Image_GetCompositeInfo 0x140209310–0x14020933c: with a texture, the composite is rtSize / C+0x1218 (integer
        // division) unless the layer is fullscreen without a sprite sheet.
        let R = resources.textureReduction
        if R > 1, let tex, !(fullscreen && !tex.flags.contains(.spriteSheet)) { rt = SIMD2(rt.x / R, rt.y / R) }
        if noInterpolation { point = true }
        let W = max(rt.x, 4), H = max(rt.y, 4)
        rtSize = SIMD2(W, H)
        let format = renderTargetFormat(hdr: resources.hdr)
        let sf = (point ? 1 : 0) | (clampUVs ? 2 : 0)
        var count = min(2, compositeSteps + (needComposite ? 1 : 0))
        // Layer_AllocRenderTargets 0x1401ea500: a passthrough group with children gets one target even without effects.
        if count == 0 && passthrough && !groupChildren.isEmpty { count = 1 }
        for i in 0..<count {
            let name = (needComposite && i == 0) ? "_rt_imageLayerComposite_\(id)_a"
                : SceneObject.scratchName("sc.\(W).\(H).\(point ? "n" : "b")\(clampUVs ? "c" : "r")\(i)", for: self)
            targets.append(resources.targets.acquire(name, width: W, height: H, format: format, samplerFlags: sf))
        }
        let ts = SIMD2(textureDims?.x ?? Float(W), textureDims?.y ?? Float(H))
        intoCompositeQuad = Quad(size: SIMD2(Float(W), Float(H)), textureSize: ts, uvScale: uvScale, flags: [])
        prelitQuad = Quad(size: SIMD2(Float(W), Float(H)), textureSize: ts, uvScale: uvScale, flags: .centered)

        for effect in effects {
            for k in effect.fbos.indices {
                let f = effect.fbos[k]
                var w = (f.width ?? 0xFFFF) <= 4096 ? f.width! : W
                var h = (f.height ?? 0xFFFF) <= 4096 ? f.height! : H
                if let fit = f.fit, fit <= 4096 {
                    if w >= h { let nw = min(fit, w); h = Int(Float(h) / Float(w) * Float(nw)); w = nw }
                    else { let nh = min(fit, h); w = Int(Float(w) / Float(h) * Float(nh)); h = nh }
                }
                var name = f.name
                if f.unique { name += "_\(effect.id)" } else if !fullscreen { name += "_\(w)_\(h)_\(f.scale)" }
                if let existing = f.target {
                    existing.resize(device: resources.device, width: w, height: h) // RT_Resize (0x140161f40)
                } else {
                    effect.fbos[k].target = resources.targets.acquire(name, width: w, height: h, scale: f.scale,
                                                                      format: Self.fboFormat(f.format), samplerFlags: f.repeatUVs ? 0 : 2)
                }
                if let clear = f.clear, let rt = effect.fbos[k].target { pendingClears.append((rt, clear)) }
            }
        }
    }

    static func fboFormat(_ code: Int) -> MTLPixelFormat {
        switch code {
        case 8: return .rg8Unorm
        case 9: return .r8Unorm
        case 0xA: return .rg16Float
        case 0xB: return .r16Float
        case 0xD: return .rgb10a2Unorm
        case 0xE, 0xF: return .rgba16Float
        case 0x11, 0x12: return .rgba16Unorm
        case 0x13, 0x14: return .rgba16Snorm
        // `TexFormat_toDXGI` 0x1400d2a20 jump table (0x1400d2aa4): 1, 2, 3, 5 and 0x15 (`rgba8888s`) all go to the default
        // R8G8B8A8_UNORM; there is no SNORM 8-bit format.
        default: return .rgba8Unorm
        }
    }

    /// Alignment offset table (docs/re/03 §5).
    var alignmentOffset: SIMD3<Float> {
        let W = geomSize.x, H = geomSize.y
        switch alignment {
        case .center: return .zero
        case .top: return SIMD3(0, -H / 2, 0)
        case .topright: return SIMD3(-W / 2, -H / 2, 0)
        case .right: return SIMD3(-W / 2, 0, 0)
        case .bottomright: return SIMD3(-W / 2, H / 2, 0)
        case .bottom: return SIMD3(0, H / 2, 0)
        case .bottomleft: return SIMD3(W / 2, H / 2, 0)
        case .left: return SIMD3(W / 2, 0, 0)
        case .topleft: return SIMD3(W / 2, -H / 2, 0)
        }
    }

    var layerWorld: simd_float4x4 {
        alignment == .center ? world : world * Mat.translate(alignmentOffset)
    }

    var colorUniform: SIMD3<Float> { color }

    // MARK: - Passthrough groups

    /// Direct children in scene order (the engine's `+0x198` vector is filled as parents are resolved at load).
    var groupChildren: [SceneObject] {
        guard passthrough, let scene else { return [] }
        return scene.objects.filter { $0.parent === self }
    }

    /// `Layer_DrawGroupChildren` 0x1401ecb20: unless fullscreen, model = inverse(W2), view = I and
    /// proj = OrthoOffCenterLH(−w/2, w/2, −h/2, h/2, −1000, 1000) with (w, h) = the layer `size` (renderer vt+0x18,
    /// 0x1401ecbf5–0x1401eccf9); the context base matrix C+0xaf0 is the model top meanwhile. Without `copybackground`
    /// the alpha-MAX blend state is on (0x1401ecd32–0x1401ecd5f). Each child renders itself (vt+0x68, vt+0x50); a child
    /// that is not itself a group also renders its descendants (0x1401ecdad–0x1401ecdee, 0x1401eca70). Alpha writes are on
    /// for the whole group (`SetColorWrite(1, 1)`). photon2 folds inverse(W2) into the view, since children set their
    /// own absolute model matrix: proj·inverse(W2)·childWorld is the same transform.
    func drawGroupChildren(_ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer, _ W2: simd_float4x4) {
        let kids = groupChildren
        guard !kids.isEmpty else { return }
        let m = frame.model, v = frame.view, p = frame.proj
        if !fullscreen {
            frame.model = Mat.identity
            frame.view = W2.inverse
            frame.proj = Mat.orthoLH(l: -size.x / 2, r: size.x / 2, b: -size.y / 2, t: size.y / 2, zn: -1000, zf: 1000)
        }
        ctx.forceAlphaWrite += 1
        if !copyBackground { ctx.alphaMaxMode += 1 }
        func descendants(_ o: SceneObject) {
            for c in scene.objects where c.parent === o {
                c.render(ctx, frame, scene)
                descendants(c)
            }
        }
        for c in kids {
            c.render(ctx, frame, scene)
            if !((c as? ImageLayer)?.passthrough ?? false) { descendants(c) }
        }
        if !copyBackground { ctx.alphaMaxMode -= 1 }
        ctx.forceAlphaWrite -= 1
        frame.model = m; frame.view = v; frame.proj = p
    }

    // MARK: - Render (Layer_Render 0x1401e8aa0)

    /// Geometry and targets depend on render-target sizes, which follow the output size.
    func refreshIfScreenChanged(_ frame: FrameState) {
        let screen = SIMD2(Int(frame.screen.x), Int(frame.screen.y))
        guard texture == nil, screen != builtForScreen else { return }
        builtForScreen = screen
        buildGeometry()
        allocateTargets()
    }

    override func render(_ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer) {
        // `Image_Render` 0x140206587–0x1402065bb: a detached texture animation pins C+0x132c to its frame for the whole
        // layer render, then resets it to −1.
        guard let c = spriteClock, !c.attached, let st = ctx.builtinState else { return renderLayer(ctx, frame, scene) }
        st.spriteFrameOverride = c.index
        defer { st.spriteFrameOverride = -1 }
        renderLayer(ctx, frame, scene)
    }

    private func renderLayer(_ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer) {
        // Layer_Render 0x1401e8aab: vt+0x68 gates the call; a hidden ledsource/dependency layer still runs its
        // composite and effects, and skips only the draws into the scene (0x1401e8fd1 direct, 0x1401e9d05 final).
        guard renderVisible else { return }
        if Frustum.layerCulled(frame, world: layerWorld, offset: alignment == .center ? .zero : alignmentOffset, size: size,
                               exempt: ledSource || isDependency) { return }
        refreshIfScreenChanged(frame)
        for (rt, c) in pendingClears {
            ctx.bind(rt.texture)
            ctx.clear(MTLClearColor(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]), alpha: Double(c[3])))
            ctx.unbind()
        }
        pendingClears.removeAll()
        let W2 = layerWorld
        // Layer_Render 0x1401e8ee8–0x1401e8f98: the snapshot depends on vt+0x118 (the material reads the frame buffer) or
        // the live colorBlendMode ∉ {0, 31}; a fullscreen layer takes it only for that blend mode or with children.
        let liveBlend = colorBlendMode != 0 && colorBlendMode != 31
        let needsBg = material.readsFrameBuffer || liveBlend
        // …and not when the parent (+0x180) is a passthrough image (`+0x120 & 4`, 0x1401e8f63–0x1401e8f76): inside a
        // group the frame buffer keeps its earlier snapshot.
        if needsBg && (!fullscreen || liveBlend || scene.objects.contains { $0.parent === self })
            && (parent as? ImageLayer)?.passthrough != true {
            ctx.copyCurrent(into: scene.fullFrameBuffer.texture)
        }

        if compositeSteps == 0 && !needComposite {
            guard effectiveVisible else { return }
            if passthrough {
                // Direct path of a passthrough group (Layer_Render 0x1401e8fd1–0x1401e9125 → 0x1401ec720): background
                // (or a transparent clear) and the children into RT[0], then the direct draw with RT[0] as tex0
                // (0x140208670). Without children a passthrough layer draws nothing.
                guard !groupChildren.isEmpty, let rt = targets.first else { return }
                ctx.bind(rt.texture)
                if fullscreen {
                    ctx.unbind(); ctx.copyCurrent(into: rt.texture); ctx.bind(rt.texture)
                } else if copyBackground {
                    let saved = frame.model
                    frame.model = W2
                    draw(material, objectQuad!, ctx, frame, scene, blend: BlendState(mode: .normal, alphaWrite: true),
                         color: colorUniform, alpha: alpha)
                    frame.model = saved
                } else {
                    ctx.clear(MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
                }
                drawGroupChildren(ctx, frame, scene, W2)
                ctx.unbind()
                let saved = frame.model
                frame.model = W2
                // 0x140208670: M = +0x4a8 (group material) with tex0 = RT[0]; blending cbm 31 → additive,
                // `flags304 & 0x60 == 0x20` (passthrough without copybackground) → translucent, else M's own.
                let G = groupMaterial
                var blend = BlendState(mode: colorBlendMode == 31 ? .additive : G.blendMode)
                if colorBlendMode != 31 && !copyBackground { blend.mode = .translucent }
                withPerspective(frame, scene) {
                    draw(G, directQuad!, ctx, frame, scene, blend: blend, color: colorUniform, alpha: alpha,
                         textures: [0: BoundTexture(target: rt)])
                }
                frame.model = saved
                return
            }
            let saved = frame.model
            frame.model = W2
            var blend = BlendState(mode: colorBlendMode == 31 ? .additive : material.blendMode)
            if passthrough && !copyBackground { blend.mode = .translucent }
            withPerspective(frame, scene) {
                if let puppet, let skinned = skinnedMaterial {
                    drawPuppet(skinned, clipTargetMaterial, puppet.mesh, ctx, frame, scene, blend: blend, color: colorUniform, alpha: alpha,
                               tex0: skinned.textures[0])
                } else {
                    draw(material, directQuad!, ctx, frame, scene, blend: blend, color: colorUniform, alpha: alpha)
                }
            }
            frame.model = saved
            return
        }

        // Effect / composite path
        let savedModel = frame.model, savedView = frame.view, savedProj = frame.proj
        layerWorldSaved = W2
        layerMVP = frame.proj * frame.view * W2
        let total = needComposite ? compositeSteps : compositeSteps - 1
        var src = total & 1
        guard targets.count > 0 else { return }
        if targets.count == 1 { src = 0 }
        if !fullscreen {
            ctx.bind(targets[src].texture)
            if !passthrough {
                let sceneVP = frame.proj * frame.view
                frame.model = Mat.identity; frame.view = Mat.identity
                frame.proj = Mat.orthoLH(l: 0, r: Float(rtSize.x), b: 0, t: Float(rtSize.y), zn: -1000, zf: 1000)
                if let pm = prelitMaterial, let puppet {
                    // vtE0 `Image_PuppetAlbedoPrepass` 0x140207740 (only with an albedo RT), then the prelit branch of
                    // `Image_DrawIntoComposite` 0x140207c74: model = T(cw/2R, ch/2R)·model, Alt model = layer world, Alt VP =
                    // scene V·P, opaque, the dual-vertex mesh (skinned position lit in world space, a_PositionC1 placed in
                    // composite pixels), tex0 = the albedo RT when there is one. RT[src] is not cleared first: the bind
                    // (RT vt+0x48 0x1400d3920) only sets the target and viewport, so texels outside the mesh keep their
                    // previous contents.
                    var tex: [Int: BoundTexture] = [:]
                    if let albedo = renderAlbedoPrepass(ctx, frame, scene, puppet) { tex[0] = albedo }
                    frame.altModel = W2
                    frame.altViewProjection = sceneVP
                    frame.model = Mat.translate(SIMD3(Float(rtSize.x) / 2, Float(rtSize.y) / 2, 0))
                    drawMesh(pm, puppet.dualMesh, ctx, frame, scene, blend: BlendState(mode: .normal, alphaWrite: true),
                             color: colorUniform, alpha: alpha, textures: tex)
                    frame.model = Mat.identity
                } else if let pm = prelitMaterial, let q = prelitQuad {
                    // Prelit (`Image_DrawIntoComposite` 0x140207c74): model = T(cw/2R, ch/2R)·model, g_AltModelMatrix =
                    // layer world, g_AltViewProjectionMatrix = scene V·P (Image_Render). The shader lights with the
                    // Alt matrices and places the vertex with g_ModelViewProjectionMatrix. R (texture reduction) is 1;
                    // the `instanced` (flags304 & 0x800) size scaling is not implemented.
                    // With texture reduction R > 1 and tex flag 0x20 clear (0x140207e91–0x140207f75, doc 06 §2.1.4): a
                    // dedicated composite (flags304 & 0x10) scales the model rows 0/1 by 1/R (the translation row stays),
                    // otherwise the Alt model rows 0/1 are scaled by R.
                    let R = Float(resources.textureReduction)
                    let reduce = R > 1 && !(texture?.tex.flags.contains(.video) ?? false)
                    frame.altModel = reduce && !needComposite ? W2 * Mat.scale(SIMD3(R, R, 1)) : W2
                    frame.altViewProjection = sceneVP
                    frame.model = Mat.translate(SIMD3(Float(rtSize.x) / 2, Float(rtSize.y) / 2, 0))
                    if reduce && needComposite { frame.model = frame.model * Mat.scale(SIMD3(1 / R, 1 / R, 1)) }
                    draw(pm, q, ctx, frame, scene, blend: BlendState(mode: .normal, alphaWrite: true), color: colorUniform, alpha: alpha)
                    frame.model = Mat.identity
                } else {
                    // Puppets too: the unwarped image goes into the composite; the mesh is drawn at compose time.
                    draw(material, intoCompositeQuad!, ctx, frame, scene, blend: BlendState(mode: .normal, alphaWrite: true),
                         color: colorUniform, alpha: alpha)
                }
                // `Image_DrawIntoComposite` 0x140207b50 (unlit): then the texture-channel mesh, raw (pixel space, y up,
                // matching this ortho), with g_BlendMap = puppet +0x350 rows (id 0x73) and its material's blending.
                // Model rows 0..1 are scaled by 1/texture reduction, which is 1 here.
                if prelitMaterial == nil, let puppet, let cm = puppet.channelMesh, let CM = channelMaterial {
                    var blend = BlendState(mode: CM.blendMode)
                    if CM.blendMode == .normal { blend.alphaWrite = true }
                    drawMesh(CM, cm, ctx, frame, scene, blend: blend, color: colorUniform, alpha: alpha,
                             extra: ["g_BlendMap": .floats(Array(puppet.blendMap.prefix(max(puppet.blendRowCount, 1) * 4)))])
                }
            } else if copyBackground {
                frame.model = W2
                draw(material, objectQuad!, ctx, frame, scene, blend: BlendState(mode: .normal, alphaWrite: true),
                     color: colorUniform, alpha: alpha)
            } else {
                ctx.clear(MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
            }
            // `Image_DrawIntoComposite` 0x140207b50: a passthrough group then draws its children into the same target.
            if passthrough { drawGroupChildren(ctx, frame, scene, W2) }
            ctx.unbind()
        } else {
            ctx.copyCurrent(into: targets[src].texture)
            if passthrough && !groupChildren.isEmpty {
                ctx.bind(targets[src].texture)
                drawGroupChildren(ctx, frame, scene, W2)
                ctx.unbind()
            }
        }

        frame.model = Mat.identity; frame.view = Mat.identity
        frame.proj = Mat.orthoLH(l: -1, r: 1, b: -1, t: 1, zn: -1000, zf: 1000)
        var step = 0
        var finalEffect: Effect?
        var finalPass = 0
        var fbCopied = false
        effectLoop: for effect in effects where effect.visible {
            var dst = targets.count > 1 ? 1 - src : src
            var bound = false
            for p in effect.passes.indices {
                if !needComposite && step == total {
                    finalEffect = effect; finalPass = p
                    // 0x1401e9c54: a target bound for this effect is unbound and becomes the input first.
                    if bound { ctx.unbind(); src = dst }
                    break effectLoop
                }
                if !bound {
                    bound = true
                    if effect.readsFrameBuffer && !fbCopied { ctx.copyCurrent(into: scene.fullFrameBuffer.texture); fbCopied = true }
                    ctx.bind(targets[dst].texture)
                }
                runPass(effect, p, src: src, final: false, ctx, frame, scene)
                if effect.passes[p].compose {
                    step += 1
                    if step < total { ctx.unbind(); swap(&src, &dst); ctx.bind(targets[dst].texture) }
                }
            }
            if bound { step += 1; ctx.unbind(); src = dst }
        }
        frame.model = savedModel; frame.view = savedView; frame.proj = savedProj

        if effectiveVisible {
            let m = frame.model, v = frame.view, pr = frame.proj
            if !fullscreen {
                frame.model = W2
                if perspective && scene.isOrtho { scene.pushPerspective(frame) }   // 0x1401e9e9f; restored below
            } else {
                frame.model = Mat.identity; frame.view = Mat.identity
                frame.proj = Mat.orthoLH(l: -1, r: 1, b: -1, t: 1, zn: -1000, zf: 1000)
            }
            if needComposite, let C = composeMaterial {
                let blend = BlendState(mode: colorBlendMode == 31 ? .additive : material.blendMode)
                if let puppet, puppetComposite {
                    // Skinned mesh with raw mdl UVs sampling the image-space composite (docs/re/06 §2.1).
                    drawPuppet(C, clipComposeTargetMaterial, puppet.rawMesh, ctx, frame, scene, blend: blend, color: SIMD3(1, 1, 1),
                               alpha: 1, tex0: BoundTexture(target: targets[src]))
                } else {
                    draw(C, objectQuad!, ctx, frame, scene, blend: blend, color: SIMD3(1, 1, 1), alpha: 1,
                         textures: [0: BoundTexture(target: targets[src])])
                }
            } else if let fe = finalEffect {
                if !fbCopied && fe.readsFrameBuffer { ctx.copyCurrent(into: scene.fullFrameBuffer.texture) }
                for p in finalPass..<fe.passes.count { runPass(fe, p, src: src, final: true, ctx, frame, scene) }
            }
            frame.model = m; frame.view = v; frame.proj = pr
        }
    }

    /// `RunPass` 0x1401ebf60
    func runPass(_ effect: Effect, _ p: Int, src: Int, final: Bool, _ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer) {
        let P = effect.passes[p]
        let T = P.target >= 0 ? effect.fbos[P.target].target : nil
        switch P.command {
        case .swap:
            guard P.source >= 0, P.target >= 0 else { return }
            for q in effect.passes.indices where effect.passes[q].command != .swap {
                func sw(_ x: Int) -> Int { x == P.source ? P.target : x == P.target ? P.source : x }
                effect.passes[q].source = sw(effect.passes[q].source)
                effect.passes[q].target = sw(effect.passes[q].target)
                effect.passes[q].binds = effect.passes[q].binds.map { (sw($0.fbo), $0.index) }
            }
        case .copy:
            let S = P.source >= 0 ? effect.fbos[P.source].target : nil
            if let S { ctx.bind(S.texture) }
            if let T { ctx.copyCurrent(into: T.texture) }
            if S != nil { ctx.unbind() }
        case .draw:
            guard let M = P.material else { return }
            if let T { ctx.bind(T.texture) }
            var overrides: [Int: BoundTexture] = [:]
            if P.binds.isEmpty {
                overrides[0] = BoundTexture(target: targets[src])
            } else {
                for b in P.binds {
                    if b.fbo >= 0, let rt = effect.fbos[b.fbo].target { overrides[b.index] = BoundTexture(target: rt) }
                    else if b.fbo < 0 { overrides[b.index] = BoundTexture(target: targets[src]) }
                }
            }
            for (slot, name) in M.textureNames where overrides[slot] == nil && name.hasPrefix("_rt_") {
                if let rt = scene.namedTarget(name) { overrides[slot] = BoundTexture(target: rt) }
            }
            let last = final && effect.lastNormalPass == p
            frame.setEffectMatrices(world: layerWorldSaved, lmvp: layerMVP, size: size, final: final)
            if last {
                let blend = BlendState(mode: colorBlendMode == 31 ? .additive : material.blendMode)
                draw(M, objectQuad!, ctx, frame, scene, blend: blend, color: colorUniform, alpha: alpha, textures: overrides)
            } else {
                draw(M, effectQuad!, ctx, frame, scene, blend: BlendState(mode: M.blendMode, alphaWrite: true),
                     color: colorUniform, alpha: alpha, textures: overrides)
            }
            if T != nil { ctx.unbind() }
        }
    }

    func draw(_ m: Material, _ quad: Quad, _ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer,
              blend: BlendState, color: SIMD3<Float>, alpha: Float, textures: [Int: BoundTexture] = [:]) {
        drawMesh(m, quad.mesh, ctx, frame, scene, blend: blend, color: color, alpha: alpha, textures: textures)
    }

    /// The puppet mesh draw of `Image_DrawDirect` 0x140208670 / `Image_DrawComposed` 0x140208c80. Without clip groups
    /// it is one indexed draw. With them it runs the clip command list (0x14020881c / 0x140208cef):
    /// `0` → draw runtime section s with M, s += 1; `1, k` → mask k from section s (clear), draw s+1 with the clip-target
    /// variant, s += 2; `2, n, (k, sec)×n, k` → parent masks (first clears, the rest go through the intermediate), then
    /// mask k from s through the intermediate, draw s+1, s += 2.
    func drawPuppet(_ M: Material, _ target: Material?, _ template: Mesh, _ ctx: RenderContext, _ frame: FrameState,
                    _ scene: SceneRenderer, blend: BlendState, color: SIMD3<Float>, alpha: Float, tex0: BoundTexture?) {
        let base: [Int: BoundTexture] = tex0.map { [0: $0] } ?? [:]
        guard let puppet, let prog = puppet.clip, let target, let maskM = clipMaskMaterial, !Self.noClip,
              let groups = puppet.mdl.meshes.first?.clipGroups else {
            drawMesh(M, template, ctx, frame, scene, blend: blend, color: color, alpha: alpha, textures: base)
            return
        }
        // `_rt_FullAlphaMask` / `_rt_FullAlphaMaskIntermediate`: created lazily at screen size, format 9 (R8_UNORM).
        let w = scene.sceneTarget.texture.width, h = scene.sceneTarget.texture.height
        func rt(_ name: String) -> RenderTarget {
            if let t = scene.resources.targets.find(name), t.texture.width == w, t.texture.height == h { return t }
            if let t = scene.resources.targets.find(name) { scene.resources.targets.release(t) }
            return scene.resources.targets.acquire(name, width: w, height: h, format: .r8Unorm, samplerFlags: 2)
        }
        func section(_ k: Int) -> Mesh {
            var m = template
            m.indices = k >= 0 && k < prog.sections.count ? prog.sections[k] : []
            return m
        }
        // `Puppet_RenderClipMask` 0x14020d6a0.
        func clipMask(_ k: Int, _ sec: Int, clear: Bool, viaIntermediate: Bool) {
            guard k >= 0, k < groups.count else { return }
            let g = groups[k]
            let T = rt(viaIntermediate ? "_rt_FullAlphaMaskIntermediate" : "_rt_FullAlphaMask")
            ctx.bind(T.texture)
            let c: Double = g.inverted ? 1 : 0
            if clear || viaIntermediate { ctx.clear(MTLClearColor(red: c, green: c, blue: c, alpha: c)) }
            var tex = base
            if let mt = scene.resources.textures.texture(named: g.maskTexture) { tex[1] = BoundTexture(gpu: mt) }
            drawMesh(maskM, section(sec), ctx, frame, scene, blend: BlendState(mode: maskM.blendMode), color: color, alpha: alpha,
                     textures: tex, extra: ["g_RenderVar0": .floats([g.inverted ? 1 : 0, .nan, .nan, .nan])]) // only .x (0x14020d798)
            ctx.unbind()
            if viaIntermediate, let flat = clipFlatMaterial {
                // M/V/P = I, alpha 1, flattexture (minimalalpha, translucent) with SrcBlend = DEST_COLOR (vt+0x108(1)),
                // full-screen quad into _rt_FullAlphaMask.
                let F = rt("_rt_FullAlphaMask")
                let saved = (frame.model, frame.view, frame.proj)
                frame.model = Mat.identity; frame.view = Mat.identity; frame.proj = Mat.identity
                ctx.bind(F.texture)
                var b = BlendState(mode: flat.blendMode); b.destColor = true
                drawMesh(flat, Self.clipFullscreenQuad.mesh, ctx, frame, scene, blend: b, color: SIMD3(1, 1, 1), alpha: 1,
                         textures: [0: BoundTexture(target: T)])
                ctx.unbind()
                (frame.model, frame.view, frame.proj) = saved
            }
        }
        func drawTarget(_ k: Int, _ sec: Int) {
            var tex = base
            tex[8] = BoundTexture(target: rt("_rt_FullAlphaMask"))
            // Blend = clip record +0x40: 2 (additive) when flags & 1, else 1 (translucent).
            drawMesh(target, section(sec), ctx, frame, scene, blend: BlendState(mode: groups[k].additive ? .additive : .translucent),
                     color: color, alpha: alpha, textures: tex)
        }
        let cmds = prog.commands
        var i = 0, s = 0
        while i < cmds.count {
            switch cmds[i] {
            case 0:
                drawMesh(M, section(s), ctx, frame, scene, blend: blend, color: color, alpha: alpha, textures: base)
                s += 1
            case 1 where i + 1 < cmds.count:
                i += 1
                let k = cmds[i]
                if k < groups.count {
                    clipMask(k, s, clear: true, viaIntermediate: false)
                    drawTarget(k, s + 1)
                }
                s += 2
            case 2 where i + 1 < cmds.count:
                i += 1
                let n = cmds[i]
                for j in 0..<n where i + 2 < cmds.count {
                    clipMask(cmds[i + 1], cmds[i + 2], clear: j == 0, viaIntermediate: j != 0)
                    i += 2
                }
                guard i + 1 < cmds.count else { return }
                i += 1
                let k = cmds[i]
                clipMask(k, s, clear: false, viaIntermediate: true)
                if k < groups.count { drawTarget(k, s + 1) }
                s += 2
            default:
                break
            }
            i += 1
        }
    }

    /// `Image_PuppetAlbedoPrepass` 0x140207740: colour (1,1,1,1); bind the albedo RT, clear (0,0,0,0); the copy material
    /// draws the full-screen triangle (no TRANSFORM, opaque); then model = I, view = I, proj = OrthoLH(0, W, 0, H, −1000, 1000)
    /// (W, H = the albedo RT size), g_BlendMap = P+0x350 rows, and the texture-channel mesh with its own material.
    func renderAlbedoPrepass(_ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer, _ puppet: Puppet) -> BoundTexture? {
        guard let rt = albedoTarget, let am = albedoMaterial, let tri = albedoTriangle else { return nil }
        let saved = (frame.model, frame.view, frame.proj)
        ctx.bind(rt.texture)
        ctx.clear(MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
        drawMesh(am, tri, ctx, frame, scene, blend: BlendState(mode: .normal, alphaWrite: true), color: SIMD3(1, 1, 1), alpha: 1)
        frame.model = Mat.identity; frame.view = Mat.identity
        frame.proj = Mat.orthoLH(l: 0, r: Float(rt.width), b: 0, t: Float(rt.height), zn: -1000, zf: 1000)
        if let cm = puppet.channelMesh, let CM = channelMaterial {
            var blend = BlendState(mode: CM.blendMode)
            if CM.blendMode == .normal { blend.alphaWrite = true }
            drawMesh(CM, cm, ctx, frame, scene, blend: blend, color: SIMD3(1, 1, 1), alpha: 1,
                     extra: ["g_BlendMap": .floats(Array(puppet.blendMap.prefix(max(puppet.blendRowCount, 1) * 4)))])
        }
        ctx.unbind()
        (frame.model, frame.view, frame.proj) = saved
        return BoundTexture(target: rt)
    }

    static let noClip = ProcessInfo.processInfo.environment["PHOTON_NOCLIP"] == "1"
    /// Scene `S+0x48`: the NDC full-screen quad.
    static let clipFullscreenQuad = Quad(size: SIMD2(2, 2), textureSize: .zero, uvScale: SIMD2(1, 1), flags: .centered)

    func drawMesh(_ m: Material, _ mesh: Mesh, _ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer,
                  blend: BlendState, color: SIMD3<Float>, alpha: Float, textures: [Int: BoundTexture] = [:],
                  extra: [String: UniformValue] = [:]) {
        var tex = textures
        for (slot, name) in m.textureNames where tex[slot] == nil && name.hasPrefix("_rt_") {
            if let rt = scene.namedTarget(name) { tex[slot] = BoundTexture(target: rt) }
        }
        var u = frame.builtins(color: color, alpha: alpha, target: ctx.current)
        // Slot 0's sprite frame comes from `Texture_UpdateSpriteUniforms` in `RenderContext.draw` like every other slot:
        // the texture's own step clock, or the detached script frame C+0x132c set by `render`.
        if let puppet {
            // `Image_Render` 0x140206430 binds bones and bone alpha (S+0x11e0 = P+0x268) for every pass of the layer.
            u["g_Bones"] = .bones(puppet.skin)
            if puppet.skinningAlpha { u["g_BonesAlpha"] = .floats(puppet.boneAlpha) }
            // Direct draw / compose hook 0x140209130 → `Puppet_SetMorphUniforms` 0x14020cff0 when MORPHING.
            if let mt = morphTexture, let m0 = puppet.mdl.meshes.first, let state = puppet.morphs.first, m.combos["MORPHING"] != nil {
                if tex[5] == nil { tex[5] = mt }
                for (k, v) in MorphGPU.uniforms(state, scale: m0.morphScale, stride: m0.morphVertexCount) { u[k] = v }
                if m0.flags & 0x2000 != 0 {
                    for (k, v) in MorphGPU.modifierUniforms(state, mesh: m0, boneWorld: puppet.boneWorld) { u[k] = v }
                }
            }
        }
        for (k, v) in extra { u[k] = v }
        ctx.draw(material: m, mesh: mesh, uniforms: u, textures: tex, blend: blend)
    }
}
