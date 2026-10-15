import Foundation
import Metal
import simd

/// Volumetric lights (docs/re/06 §6.5a). The engine object is the scene's sub-object at `+0x50` (vtable 0x14048ea08);
/// `this+0x88` is the render context C, `this+0x418` the state byte (bit 0 main pass, bit 1 light buffer needs a
/// clear, bit 2 light buffer pending a combine).
///
/// - `Volumetrics_RenderLight` 0x140196ce0 (slot 5) runs when a light with `castvolumetrics` is drawn (light vt+0x50
///   0x14025d300). It copies the scene depth into `_rt_volumetricsBack`, draws the light volume's back faces into the
///   depth of `_rt_volumetricsSingle` (cull FRONT toggled), then the volume's front faces (or a full-screen triangle
///   when the camera is inside) additively into `_rt_volumetricsLightBuffer` with `volumetricsfront`.
/// - `Volumetrics_Combine` 0x140198d00 runs in `SceneGraph_DrawList` 0x14018aac0 before the next drawn object that
///   is not a light (type 6), or after the last object: blur h/v at quality < 3, then `volumetrics_combine` (additive
///   passthrough) into the scene.
///
/// Implemented: point lights (reading the shadow atlas of `ShadowMaps`) and spot lights with or without a cookie (session 4);
/// spot shadows are not.
final class Volumetrics {
    /// `C+0x1ac` (app setting `shadows`) and `C+0x1ad` (`volumetrics`): disabled 0, low 1, high 3, ultra 4,
    /// anything else 2 (`Settings_Apply` 0x14010df40).
    let shadowQuality: Int
    let quality: Int
    private var needsClear = true   // state bit 1 (set by the scene ctor 0x140187150 and after every combine)
    private(set) var pending = false // state bit 2

    private var back: RenderTarget?        // full-size copy of the scene depth (fmt 0x19, R32 readable)
    private var singleDepth: MTLTexture?   // back-face depth of the volume (fmt 0x19 / 0x17), size / divisor
    private var single: RenderTarget?      // r32Float copy of `singleDepth` for sampling (platform difference)
    private var singleColor: RenderTarget? // colour target the depth-only back pass is bound with (platform difference)
    private var lightBuffer: RenderTarget?
    private var lightBufferB: RenderTarget?
    private var materials: [String: Material] = [:]
    private var lightMaterials: [ObjectIdentifier: (front: Material?, fullscreen: Material?)] = [:]
    private var sphere: Mesh?

    static func level(_ name: String?) -> Int {
        switch name {
        case "disabled": return 0
        case "low": return 1
        case "high": return 3
        case "ultra": return 4
        default: return 2
        }
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        shadowQuality = Self.level(environment["PHOTON_SHADOWS"])
        quality = Self.level(environment["PHOTON_VOLUMETRICS"])
    }

    /// Size divisor of the low-resolution targets: 8 below quality 3, else 4 (0x140196d88).
    var divisor: Int { quality >= 3 ? 4 : 8 }

    private func material(_ path: String, _ scene: SceneRenderer, override: [String: Any] = [:]) -> Material {
        let key = path + "|" + override.description
        if let m = materials[key] { return m }
        let m = scene.resources.material(path, override: override)
        materials[key] = m
        return m
    }

    private func ensureTargets(_ scene: SceneRenderer) {
        let res = scene.resources
        let w = scene.sceneTarget.texture.width, h = scene.sceneTarget.texture.height
        if let b = back, b.texture.width == w, b.texture.height == h { return }
        // A resize (Scene_Resize 0x14017f696 resizes every screen-following target): drop the old ones first, or
        // `acquire` would hand back the same old-size targets (and their refcounts would grow every frame).
        for t in [back, single, singleColor, lightBuffer, lightBufferB].compactMap({ $0 }) { res.targets.release(t) }
        lightBufferB = nil
        // 0x140196d63–0x140196f52: Back (1:1, depth 0x19), Single (1/div, depth 0x19, or 0x17 below quality 3),
        // LightBuffer (1/div, colour 0xf in HDR scenes else 1), LightBufferB (quality < 3).
        back = res.targets.acquire("_rt_volumetricsBack", width: w, height: h, format: .r32Float, samplerFlags: 2)
        single = res.targets.acquire("_rt_volumetricsSingle", width: w, height: h, scale: divisor, format: .r32Float, samplerFlags: 2)
        singleColor = res.targets.acquire("_rt_volumetricsSingleColor", width: w, height: h, scale: divisor, format: .r8Unorm, samplerFlags: 2)
        if let s = single {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: s.texture.width, height: s.texture.height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            singleDepth = res.device.makeTexture(descriptor: d)
        }
        let fmt: MTLPixelFormat = res.hdr ? .rgba16Float : .rgba8Unorm
        lightBuffer = res.targets.acquire("_rt_volumetricsLightBuffer", width: w, height: h, scale: divisor, format: fmt, samplerFlags: 2)
        if quality < 3 {
            lightBufferB = res.targets.acquire("_rt_volumetricsLightBufferB", width: w, height: h, scale: divisor, format: fmt, samplerFlags: 2)
        }
    }

    /// The light volume mesh of a point light (0x14025c660, radius 1): poles (0, ±1, 0) and 23 rings of 25 vertices,
    /// ring k at polar angle k·π/24, vertex j at azimuth j·π/12: (cos θ · sin φ, cos φ, sin θ · sin φ).
    private func sphereMesh() -> Mesh {
        if let s = sphere { return s }
        var v: [Float] = [0, 1, 0, 0, -1, 0]
        for k in 1..<24 {
            let phi = Float(k) * 0.1309
            for j in 0...24 {
                let theta = Float(j) * 0.261799
                v += [cos(theta) * sin(phi), cos(phi), sin(theta) * sin(phi)]
            }
        }
        func ring(_ k: Int, _ j: Int) -> UInt32 { UInt32(2 + (k - 1) * 25 + j) }
        // Index order (session 4, 0x14025c7f6–0x14025cf37, u16 indices): bands k = 0…21, j = 0…23 with a = ring k + j,
        // b = a + 1, c = ring k+1 + j, d = c + 1 → (a, b, c), (b, d, c); then caps j = 0…23: (0, R₀[j+1], R₀[j]) and
        // (1, R₂₂[j], R₂₂[j+1]). Right-handed normals point outward, i.e. counter-clockwise from outside.
        var idx: [UInt32] = []
        for k in 1..<23 {
            for j in 0..<24 {
                let a = ring(k, j), b = ring(k, j + 1), c = ring(k + 1, j), d = ring(k + 1, j + 1)
                idx += [a, b, c, b, d, c]
            }
        }
        for j in 0..<24 {
            idx += [0, ring(1, j + 1), ring(1, j)]
            idx += [1, ring(23, j), ring(23, j + 1)]
        }
        let layout = VertexLayout(stride: 12, attributes: [VertexLayout.Attribute(id: 0, format: .float3, offset: 0)])
        let m = Mesh(layout: layout, vertices: v, indices: idx, vertexCount: v.count / 3)
        sphere = m
        return m
    }

    private static let fullscreen = Quad(size: SIMD2(2, 2), textureSize: .zero, uvScale: SIMD2(1, 1), flags: .centered)

    private func draw(_ m: Material, _ mesh: Mesh, _ ctx: RenderContext, _ frame: FrameState, blend: BlendState,
                      textures: [Int: BoundTexture] = [:], extra: [String: UniformValue] = [:]) {
        var u = frame.builtins(color: SIMD3(1, 1, 1), alpha: 1, target: ctx.current)
        for (k, v) in extra { u[k] = v }
        ctx.draw(material: m, mesh: mesh, uniforms: u, textures: textures, blend: blend)
    }

    /// Spot volume meshes (light +0x378, built at 0x140197094–0x1401974de), in the light's clip space: `g_AltViewProjectionMatrix`
    /// = inverse(+0x338) takes them to world space. Depth values come from 0x14025c5d0 / 0x14025c5f0 (0 and 1 with
    /// REVERSEDEPTH, which photon2 always has): zA = 0, zB = 1.
    /// - Without a cookie, a 32-segment cone: vertex 0 = (0.5, 0.5, zB), vertex 1 = (0.5, 0.5, zA); per segment i, a = 2πi/32,
    ///   b = a + 0.19635: (sin a, −cos a, zA), (sin b, −cos b, zA), (sin a, −cos a, zB), (sin b, −cos b, zB) with indices
    ///   (v+2, v, v+1), (v+2, v+1, v+3), (1, v+1, v), (0, v+2, v+3).
    /// - With a cookie (0x140185940, flags & 2), a box: (±1, ±1, zA/zB) in the order (−1,−1), (1,−1), (1,1), (−1,1) at zA then
    ///   zB, indices 1,0,2, 2,0,3, 4,5,6, 4,6,7, 3,0,4, 3,4,7, 1,2,5, 5,2,6, 2,3,6, 6,3,7, 0,1,5, 0,5,4 (0x14019716e–0x140197225).
    private var spotMeshes: [Bool: Mesh] = [:]
    private func spotMesh(cookie: Bool) -> Mesh {
        if let m = spotMeshes[cookie] { return m }
        let zA: Float = 0, zB: Float = 1
        var v: [Float] = []
        var idx: [UInt32] = []
        if cookie {
            for z in [zA, zB] { v += [-1, -1, z, 1, -1, z, 1, 1, z, -1, 1, z] }
            idx = [1, 0, 2, 2, 0, 3, 4, 5, 6, 4, 6, 7, 3, 0, 4, 3, 4, 7, 1, 2, 5, 5, 2, 6, 2, 3, 6, 6, 3, 7, 0, 1, 5, 0, 5, 4]
        } else {
            v = [0.5, 0.5, zB, 0.5, 0.5, zA]
            for i in 0..<32 {
                let a = Float(i) * 0.03125 * 6.28319, b = a + 0.19635
                let base = UInt32(v.count / 3)
                v += [sin(a), -cos(a), zA, sin(b), -cos(b), zA, sin(a), -cos(a), zB, sin(b), -cos(b), zB]
                idx += [base + 2, base, base + 1, base + 2, base + 1, base + 3, 1, base + 1, base, 0, base + 2, base + 3]
            }
        }
        let layout = VertexLayout(stride: 12, attributes: [VertexLayout.Attribute(id: 0, format: .float3, offset: 0)])
        let m = Mesh(layout: layout, vertices: v, indices: idx, vertexCount: v.count / 3)
        spotMeshes[cookie] = m
        return m
    }

    private var cookies: [String: BoundTexture] = [:]
    /// Light +0x330 (`Light_Load` 0x14025d080), cached per name. Also the frame's `_alias_lightCookie`.
    func cookieTexture(_ light: LightObject, _ scene: SceneRenderer) -> BoundTexture? {
        guard light.useCookie, let name = light.cookieName else { return nil }
        if let t = cookies[name] { return t }
        guard let gpu = scene.resources.textures.texture(named: name) else { return nil }
        let t = BoundTexture(gpu: gpu)
        cookies[name] = t
        return t
    }

    func renderLight(_ light: LightObject, _ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer) {
        guard quality > 0, light.kind == .point || light.kind == .spot else { return }
        ensureTargets(scene)
        guard let back, let single, let singleColor, let singleDepth, let lightBuffer else { return }
        let world = light.world
        let pos = SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
        let radius = light.radius
        let isPoint = light.kind == .point
        let cookie = !isPoint && light.useCookie

        // 1. `_rt_volumetricsBack` = the bound target's depth (render target vt+8 0x1400d3310 → CopyResource).
        ctx.endEncoder()
        if let depth = ctx.depth, ctx.current === ctx.backBuffer {
            Blitter.shared(ctx.device).copyDepth(depth, into: back.texture, commandBuffer: ctx.commandBuffer)
        } else {
            ctx.bind(back.texture); ctx.clear(MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)); ctx.unbind()
        }

        // Light +0x338: point = 0x14025d420 point branch; spot = view × projection (spot branch), computed by
        // Lights_Update for volumetric spots (0x140193231–0x140193255).
        let lightProj = isPoint ? ShadowMaps.pointProjection(light, quality: shadowQuality, ortho: scene.isOrtho)
                                : ShadowMaps.spotViewProjection(light, ortho: scene.isOrtho)
        // 2. Back faces into the depth of `_rt_volumetricsSingle`: renderer vt+0xc0 toggles cull FRONT, Clear(depth).
        //    g_AltViewProjectionMatrix (C+0xab0) = point: scale(radius) at the light's world position (0x1401975b4–0x1401977b1);
        //    spot: inverse(+0x338) (0x1401975aa).
        let volume = isPoint ? Mat.translate(pos) * Mat.scale(SIMD3(repeating: radius)) : lightProj.inverse
        let mesh = isPoint ? sphereMesh() : spotMesh(cookie: cookie)
        let savedAltVP = frame.altViewProjection, savedAltModel = frame.altModel
        frame.altViewProjection = volume
        ctx.cullFront.toggle()
        ctx.attachDepth(singleDepth, to: singleColor.texture, clear: true)
        ctx.bind(singleColor.texture)
        draw(material("materials/util/volumetrics_back.json", scene), mesh, ctx, frame, blend: BlendState(mode: .normal))
        ctx.unbind()
        ctx.cullFront.toggle()
        Blitter.shared(ctx.device).copyDepth(singleDepth, into: single.texture, commandBuffer: ctx.commandBuffer)

        var textures: [Int: BoundTexture] = [1: BoundTexture(target: back), 3: BoundTexture(target: single)]
        // `_rt_shadowAtlas` (ShadowMaps); before any shadowed light was packed the slot falls back to an empty atlas.
        if let a = ctx.shadowAtlas { textures[0] = a }
        // Cookie texture (+0x330) as texture 2 when `usecookie` (0x1401987fd–0x140198815).
        if let c = cookieTexture(light, scene) { textures[2] = c }

        // 3. Light buffer: cleared to (0,0,0,1) for the first light after a combine (0x140197910–0x140197967).
        ctx.bind(lightBuffer.texture)
        if needsClear {
            needsClear = false
            ctx.clear(MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1))
        }
        pending = true

        // Inside tests (material +0x388 fullscreen / +0x390 front):
        let v = frame.view
        let forward = -SIMD3(v[0][2], v[1][2], v[2][2])
        let inside: Bool
        if isPoint {
            // |eye + 0.2·forward − light| < radius (0x140198071).
            inside = simd_length_squared(frame.eye + 0.2 * forward - pos) < radius * radius
        } else if cookie {
            // eye + 0.1·forward inside all six planes of +0x338 (0x1401849e0, 0x1401979d3–0x140197b44).
            let p = frame.eye + 0.1 * forward
            let c = lightProj * SIMD4(p, 1)
            inside = c.w > 0 && abs(c.x) <= c.w && abs(c.y) <= c.w && c.z >= 0 && c.z <= c.w
        } else {
            // Cone test (0x140197b54–0x14019804f): d = eye + 0.2·forward − light, a = normalised world row 0, h = d·a;
            // R = world distance between the unprojected far-plane points (0, 0, zA) and (0, 1, zA) of +0x338;
            // inside when 0 < h ≤ radius and (h / radius)·R ≥ |d − a·h|.
            let d = frame.eye + 0.2 * forward - pos
            let a = simd_normalize(SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z))
            let inv = lightProj.inverse
            let q0 = inv * SIMD4(0, 0, 0, 1), q1 = inv * SIMD4(0, 1, 0, 1)
            let R = simd_length(SIMD3(q1.x, q1.y, q1.z) / q1.w - SIMD3(q0.x, q0.y, q0.z) / q0.w)
            let h = simd_dot(d, a)
            inside = h > 0 && radius >= h && (h / radius) * R >= simd_length(d - a * h)
        }
        let mats = lightMaterials[ObjectIdentifier(light)] ?? {
            // 0x140198124–0x140198492: COOKIE (flags & 2), SHADOW (flags & 1 and C+0x1ac), QUALITY = C+0x1ad;
            // point lights add POINTLIGHT and LIGHTS_SHADOW_MAPPING_QUALITY = C+0x1ac. Spot shadow tiles exist since
            // session 5 (docs/re/06 §6.5d), so spots take SHADOW too.
            var combos: [String: Any] = ["QUALITY": quality]
            if isPoint { combos["POINTLIGHT"] = 1; combos["LIGHTS_SHADOW_MAPPING_QUALITY"] = shadowQuality }
            if cookie { combos["COOKIE"] = 1 }
            if light.castShadow && shadowQuality != 0 { combos["SHADOW"] = 1 }
            let pair = (front: material("materials/util/volumetrics_front.json", scene, override: ["combos": combos]),
                        fullscreen: material("materials/util/volumetrics_fullscreen.json", scene, override: ["combos": combos]))
            lightMaterials[ObjectIdentifier(light)] = pair
            return pair
        }()
        guard let m = inside ? mats.fullscreen : mats.front else { ctx.unbind(); return }

        frame.altModel = lightProj   // g_AltModelMatrix (C+0xa70) = +0x338
        // g_RenderVar3 (C+0xd8): point = +0x320 (M22, M32, M23, M33); spot = world row 0 as stored (0x1401985aa–0x1401985bd).
        let var3: [Float] = isPoint ? ShadowMaps.pointProjectionInfo(lightProj)
                                    : [world.columns.0.x, world.columns.0.y, world.columns.0.z, world.columns.0.w]
        let deg: Float = 0.0174533
        draw(m, inside ? Self.fullscreen.mesh : mesh, ctx, frame, blend: BlendState(mode: m.blendMode),
             textures: textures, extra: [
                // g_EffectModelMatrix (C+0x970) = inverse(view·projection) (0x140198555).
                "g_EffectModelMatrix": .matrix((frame.proj * frame.view).inverse),
                // g_RenderVar0 = atlas transform (+0x310, ShadowMaps packing).
                "g_RenderVar0": .floats([light.shadowAtlasTransform.x, light.shadowAtlasTransform.y,
                                         light.shadowAtlasTransform.z, light.shadowAtlasTransform.w]),
                "g_RenderVar1": .floats([radius * 0.99, cos(light.innerCone * deg), cos(light.outerCone * deg), light.intensity]),
                "g_RenderVar2": .floats([pos.x, pos.y, pos.z, light.density]),
                "g_RenderVar3": .floats(var3),
                "g_RenderVar4": .floats([light.color.x, light.color.y, light.color.z, light.volumetricsExponent]),
             ])
        ctx.unbind()
        frame.altViewProjection = savedAltVP
        frame.altModel = savedAltModel
    }

    /// `Volumetrics_Combine` 0x140198d00.
    func combine(_ ctx: RenderContext, _ frame: FrameState, _ scene: SceneRenderer) {
        guard pending, let lightBuffer else { return }
        pending = false
        needsClear = true
        let quad = Self.fullscreen.mesh
        if quality < 3, let b = lightBufferB {
            ctx.bind(b.texture)
            draw(material("materials/util/volumetrics_blur_h.json", scene), quad, ctx, frame, blend: BlendState(mode: .normal),
                 textures: [0: BoundTexture(target: lightBuffer)])
            ctx.unbind()
            ctx.bind(lightBuffer.texture)
            draw(material("materials/util/volumetrics_blur_v.json", scene), quad, ctx, frame, blend: BlendState(mode: .normal),
                 textures: [0: BoundTexture(target: b)])
            ctx.unbind()
        }
        let c = material("materials/util/volumetrics_combine.json", scene)
        draw(c, quad, ctx, frame, blend: BlendState(mode: c.blendMode), textures: [0: BoundTexture(target: lightBuffer)])
    }
}
