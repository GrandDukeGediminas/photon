import Foundation
import Metal
import PhotonCore
import simd

/// `Mesh_CreateQuad` (docs/re/03 §5): float3 position + float2 uv, indices 0,2,1, 1,2,3.
public struct Quad {
    public struct Flags: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let centered = Flags(rawValue: 1)
        public static let inset = Flags(rawValue: 2)
        public static let flipV = Flags(rawValue: 4)
    }

    public let vertices: [Float]

    public init(size: SIMD2<Float>, textureSize: SIMD2<Float>, uvScale: SIMD2<Float>, flags: Flags) {
        let (x0, x1, y0, y1): (Float, Float, Float, Float) = flags.contains(.centered)
            ? (-size.x / 2, size.x / 2, -size.y / 2, size.y / 2) : (0, size.x, 0, size.y)
        let du: Float = flags.contains(.inset) && textureSize.x > 0 ? 0.15 / textureSize.x : 0
        let dv: Float = flags.contains(.inset) && textureSize.y > 0 ? 0.15 / textureSize.y : 0
        let u0 = du, u1 = uvScale.x - du
        var v0 = dv, v1 = uvScale.y - dv
        if flags.contains(.flipV) { v0 = 1; v1 = 1 - v1 }
        vertices = [
            x0, y1, 0, u0, v0,
            x1, y1, 0, u1, v0,
            x0, y0, 0, u0, v1,
            x1, y0, 0, u1, v1,
        ]
    }

    public var mesh: Mesh { Mesh(layout: .quad, vertices: vertices, indices: [0, 2, 1, 1, 2, 3], vertexCount: 4) }
}

public struct DrawState {
    public var blend: BlendState
    public var cullNone = true
}

extension RenderContext {
    static let texDebug = ProcessInfo.processInfo.environment["PHOTON_TEXDEBUG"] == "1"
    static let noStale = ProcessInfo.processInfo.environment["PHOTON_NOSTALE"] == "1"
    /// Called before every emulated-geometry draw with the final uniform values (ParticleRender's `gsin` dumps).
    nonisolated(unsafe) static var geometryDrawObserver: ((ShaderProgram, Mesh, [String: UniformValue]) -> Void)?
    nonisolated(unsafe) private static var nullTex: BoundTexture?
    /// A 1×1 (0, 0, 0, 0) texture: what a NULL shader-resource view samples on D3D11.
    static func nullTexture(_ device: MTLDevice) -> BoundTexture {
        if let t = nullTex { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        let tex = device.makeTexture(descriptor: d)!
        var zero: UInt32 = 0
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)
        let sd = MTLSamplerDescriptor()
        let t = BoundTexture(texture: tex, sampler: device.makeSamplerState(descriptor: sd)!)
        nullTex = t
        return t
    }

    /// Draws `quad` with `material`, binding its textures (overridden by `textures`) and filling every
    /// constant buffer member from `uniforms` (built-ins and material values).
    func draw(material: Material, quad: Quad, uniforms: [String: UniformValue], textures overrides: [Int: BoundTexture],
              blend: BlendState) {
        draw(material: material, mesh: quad.mesh, uniforms: uniforms, textures: overrides, blend: blend)
    }

    /// `instances` / `viewports`: the shadow caster pass draws each mesh once per view, `gl_InstanceID` picking the
    /// view-projection and `gl_ViewportIndex` the viewport (renderer vt+0x150 sets the count, `Shadow_RenderView`
    /// 0x140196530). `depthBias`: the renderer's depth-bias rasterizer set (renderer init 0x1400991bd: DepthBias 0,
    /// clamp 0, SlopeScaledDepthBias −4.0), selected through vt+0xa0 for the caster pass.
    /// The frame a sprite sheet shows `time` seconds after it started (frames advance by their `frameTime`, looping).
    static func spriteFrame(_ tex: TexFile, time: Float) -> TexFile.Frame? {
        guard let first = tex.frames.first else { return nil }
        let total = tex.frames.reduce(Float(0)) { $0 + $1.frameTime }
        guard total > 0 else { return first }
        var t = time.truncatingRemainder(dividingBy: total)
        for f in tex.frames {
            if t < f.frameTime { return f }
            t -= f.frameTime
        }
        return tex.frames.last
    }

    public func draw(material: Material, mesh: Mesh, uniforms: [String: UniformValue], textures overrides: [Int: BoundTexture],
                     blend: BlendState, instances: Int = 1, viewports: [MTLViewport]? = nil, depthBias: Bool = false) {
        var blend = blend
        if forceAlphaWrite > 0 { blend.alphaWrite = true }
        // Material `alphawriting` (Material_Apply 0x140155fc0 → renderer vt+0xd8(rgb = 1, alpha = (mode == enabled)) for
        // `enabled`/`disabled`; `default` keeps the current state; Material_Unapply restores it from +0x1f8 bit 4).
        switch material.alphaWriting {
        case "enabled": blend.alphaWrite = true
        case "disabled": blend.alphaWrite = false
        default: break
        }
        if alphaMaxMode > 0 { blend.alphaMax = true }
        guard mesh.vertexCount > 0, let program = material.program,
              let pso = program.pipeline(device: device, blend: blend, pixelFormat: current.pixelFormat, depthFormat: currentDepthFormat,
                                         layout: mesh.layout, sampleCount: current.sampleCount) else { return }
        let e = renderEncoder()
        e.setRenderPipelineState(pso)
        e.setCullMode(.none)
        if currentDepthFormat != .invalid {
            // R_FlushState 0x140099f60: depth-stencil index = (+0x24 & 3) | (blend ∉ {normal, alphatocoverage} ? 1 : 0),
            // so translucent and additive draws never write depth.
            let blendWrites = blend.mode == .normal || blend.mode == .alphaToCoverage
            e.setDepthStencilState(depthState(test: material.depthTest, write: material.depthWrite && blendWrites))
        }
        if applyCulling {
            // Rasterizer states (renderer init 0x140099050, descs at 0x140099119–0x14009920e): FillMode SOLID,
            // FrontCounterClockwise = TRUE, CullMode BACK / FRONT / NONE at R+0xe8 / +0xf0 / +0xf8. R_FlushState picks one by
            // R+0x25 for every draw (bit 1 = cull off via vt+0xa8 0x14009af50, bit 0 = cull FRONT via vt+0xb0 0x14009af70).
            // Material cullmode "normal" culls back faces in every scene, ortho or perspective, and in every target.
            // D3D11 and Metal both judge winding as seen in the render target (NDC +y up, viewport y down), so D3D
            // "counter-clockwise is front" is Metal `.counterClockwise` (docs/re/03 "Depth", Winding).
            // Cull FRONT is only pushed for `alignmentfliph` (0x1401806ee) and reset by the particle perspective push
            // (0x1401e5cf0); photon2 has no fliph setting, so it is always BACK here.
            e.setFrontFacing(.counterClockwise)
            e.setCullMode(material.cullNone ? .none : (cullFront ? .front : .back))
        }

        if let viewports { e.setViewports(viewports) }
        if depthBias { e.setDepthBias(0, slopeScale: -4, clamp: 0) }
        defer {
            if viewports != nil {
                e.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(current.width), height: Double(current.height), znear: 0, zfar: 1))
            }
            if depthBias { e.setDepthBias(0, slopeScale: 0, clamp: 0) }
        }

        var textures = material.textures
        for (k, v) in overrides { textures[k] = v }
        // `_rt_shadowAtlas` (lit programs' g_Texture6, volumetrics' g_Texture0) is a depth atlas with a comparison sampler.
        for (slot, name) in material.textureNames where textures[slot] == nil && name == "_rt_shadowAtlas" {
            if let a = shadowAtlas { textures[slot] = a }
        }
        for (slot, name) in material.textureNames where textures[slot] == nil && name == "_alias_lightCookie" {
            if let c = lightCookie { textures[slot] = c }
        }

        // Material_Apply (0x140157284–0x1401572be) binds every slot the program declares with no null check: a slot is
        // never empty in the engine. Anything still unresolved here is an `_rt_`/`_alias_` name no target registered,
        // which stays the error-texture placeholder (`TextureMgr_Load` 0x14014cf90, `TextureMgr_Register` 0x14014c8f0).
        // `_rt_shadowAtlas` keeps its own placeholder (depth format, comparison sampler) and is left alone.
        if Self.texDebug { NSLog("photon: draw %@ slots %@ names %@ combos %@", material.path, "\(program.textureSlots.sorted())", "\(material.textureNames)", "\(program.combos)") }
        // D3D11 forces a shader-resource binding of the bound render target to NULL ("still bound on output! Forcing
        // to NULL"), and a NULL SRV samples as 0. That happens when the reflection pass's sorted transparent loop draws
        // the reflector into `_rt_Reflection` (docs/re/04 §6.7); Metal would read and write the same texture instead.
        for (slot, t) in textures where t.texture === current {
            textures[slot] = Self.nullTexture(device)
        }
        if let errorTexture {
            for slot in program.textureSlots where textures[slot] == nil && material.textureNames[slot] != "_rt_shadowAtlas" {
                textures[slot] = errorTexture
                if Self.texDebug { NSLog("photon: %@ slot %d (%@) → error texture", material.path, slot, material.textureNames[slot] ?? "nil") }
            }
        }

        var all = uniforms
        for (k, v) in material.materialUniforms() where all[k] == nil { all[k] = v }
        // `Texture_UpdateSpriteUniforms` 0x14015f0d0 runs for every slot the program uses (Material_Apply
        // 0x140157284–0x1401572be): a sprite-sheet texture writes its current frame into g_TextureNRotation /
        // g_TextureNTranslation (C+0x1cc+16N / C+0x26c+8N). Every slot, image layers' slot 0 included, steps the texture's
        // own frame clock (`GPUTexture.advanceSprite`) unless a detached texture animation pinned C+0x132c
        // (`StaleBuiltins.spriteFrameOverride`); a non-sprite texture writes nothing, so the slot keeps the last value.
        let state = builtinState ?? StaleBuiltins()
        let frametime: Float = { if case .floats(let f)? = all["g_Frametime"], let x = f.first { return x }; return 0 }()
        for slot in program.textureSlots where all["g_Texture\(slot)Rotation"] == nil {
            guard let gpu = textures[slot]?.gpu else { continue }
            // 0x14015f0d6–0x14015f322: a GIF user texture (+0xe0) steps here (vt+0x38 0x1400ee9e0, once per frame by
            // C+0x144, dt = C+0x14c), so a GIF only advances in frames where a draw uses it.
            if let gif = gpu.gif { gif.advance(frame: state.frame, dt: frametime); continue }
            guard gpu.tex.flags.contains(.spriteSheet), !gpu.tex.frames.isEmpty else { continue }
            let f: TexFile.Frame
            if state.spriteFrameOverride >= 0 {
                let fr = gpu.tex.frames
                f = fr[state.spriteFrameOverride < fr.count ? state.spriteFrameOverride : 0]
            } else {
                guard let g = gpu.advanceSprite(frame: state.frame, frametime: frametime) else { continue }
                f = g
            }
            gpu.imageIndex = f.imageIndex
            all["g_Texture\(slot)Rotation"] = .floats([f.xAxis.x, f.xAxis.y, f.yAxis.x, f.yAxis.y])
            all["g_Texture\(slot)Translation"] = .floats([f.u, f.v])
        }
        // Render-context fields that only some draws write and nothing resets (g_Orientation*, g_RenderVar0–4,
        // g_TextureNRotation/Translation): every draw sees the last value written (StaleBuiltins).
        // PHOTON_NOSTALE=1 (A/B only): every draw starts from zeros instead of the last written values.
        (Self.noStale ? StaleBuiltins() : state).apply(&all)
        for slot in 0..<10 {
            guard let t = textures[slot] else {
                if all["g_Texture\(slot)Texel"] == nil { all["g_Texture\(slot)Texel"] = .floats([0.5, 0.5, 2, 2]) }
                if all["g_Texture\(slot)MipMapInfo"] == nil { all["g_Texture\(slot)MipMapInfo"] = .floats([1]) }
                continue
            }
            if all["g_Texture\(slot)Resolution"] == nil { all["g_Texture\(slot)Resolution"] = .floats([t.resolution.x, t.resolution.y, t.resolution.z, t.resolution.w]) }
            if all["g_Texture\(slot)Texel"] == nil { all["g_Texture\(slot)Texel"] = .floats([1 / t.resolution.x, 1 / t.resolution.y, t.resolution.x, t.resolution.y]) }
            if all["g_Texture\(slot)MipMapInfo"] == nil { all["g_Texture\(slot)MipMapInfo"] = .floats([t.mipInfo]) }
        }

        for (index, layout) in program.vertexBuffers {
            let bytes = Self.pack(layout, all)
            e.setVertexBytes(bytes, length: max(bytes.count, 16), index: index)
        }
        for (index, layout) in program.fragmentBuffers {
            let bytes = Self.pack(layout, all)
            e.setFragmentBytes(bytes, length: max(bytes.count, 16), index: index)
        }
        let fallback = Blitter.shared(device)
        for slot in 0..<10 {
            if let t = textures[slot] {
                // A file texture binds what it holds now: the GIF's current frame or the sprite frame's image.
                let mt = t.gpu?.texture ?? t.texture
                e.setVertexTexture(mt, index: slot); e.setFragmentTexture(mt, index: slot)
                e.setVertexSamplerState(t.sampler, index: slot); e.setFragmentSamplerState(t.sampler, index: slot)
            } else {
                e.setFragmentSamplerState(fallback.sampler, index: slot)
                e.setVertexSamplerState(fallback.sampler, index: slot)
            }
        }
        let vbytes = mesh.vertices.count * 4
        if vbytes <= 4096 {
            e.setVertexBytes(mesh.vertices, length: vbytes, index: ShaderCompiler.vertexBufferIndex)
        } else if let buf = device.makeBuffer(bytes: mesh.vertices, length: vbytes, options: .storageModeShared) {
            e.setVertexBuffer(buf, offset: 0, index: ShaderCompiler.vertexBufferIndex)
        }
        // `ShaderProgram_Create` 0x1400d5a52–0x1400d5ac5: a non-zero `INSTANCECOUNT` combo sets program flag 0x20 and
        // program+0x1f = the count's low byte; `Material_Apply` (0x140157106–0x140157128, normal pass C+0x12eb == 2) sets the
        // renderer's instance count to it (vt+0x150) and `Material_Unapply` 0x14015748c resets it to 0 (one instance).
        // The shadow caster pass passes its own view count.
        var instances = instances
        if viewports == nil, let n = program.combos["INSTANCECOUNT"], n != 0 { instances = n & 0xff }
        if let gs = program.geometry {
            // Emulated geometry stage (GeometryEmulation): one instance per input point, the GS strips as a triangle list.
            // A GS program only draws point lists (the particle GS buffers, docs/re/05 §5.3).
            guard mesh.layout.stepPerInstance, gs.listVertexCount > 0 else { return }
            Self.geometryDrawObserver?(program, mesh, all)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: gs.listVertexCount, instanceCount: mesh.vertexCount)
        } else if mesh.layout.stepPerInstance {
            // A point list through a program without a geometry stage: D3D11 rasterises 1-pixel points. Not drawn here
            // (no corpus program: every particle material's shader has a .geom; unknowns P26).
            return
        } else if let idx = mesh.indices, !idx.isEmpty,
           let ib = device.makeBuffer(bytes: idx, length: idx.count * 4, options: .storageModeShared) {
            e.drawIndexedPrimitives(type: .triangle, indexCount: idx.count, indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0,
                                    instanceCount: max(instances, 1))
        } else {
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.vertexCount, instanceCount: max(instances, 1))
        }
        countDraw()
    }

    static func pack(_ layout: ShaderProgram.BufferLayout, _ values: [String: UniformValue]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: (layout.size + 15) & ~15)
        func put(_ f: Float, _ offset: Int) {
            guard offset >= 0, offset + 4 <= bytes.count else { return }
            withUnsafeBytes(of: f) { src in for i in 0..<4 { bytes[offset + i] = src[i] } }
        }
        // The engine fills each cbuffer from its {ID, offset} lists in declaration order (docs/re/07 §1.1), writing a
        // matrix ID as 64 bytes even into a `float3x3` variable, so the overrun is overwritten by the member that follows.
        // Writing in ascending offset order reproduces that; dictionary order made it vary from run to run.
        for (name, m) in layout.members.sorted(by: { $0.value.offset < $1.value.offset }) {
            if name.hasPrefix("g_AudioSpectrum") { AudioSystem.shaderDemand = true }
            guard let v = values[name] else { continue }
            switch v {
            case .floats(let f):
                if m.arrayCount > 0 && m.type.hasSuffix("vec4") || m.arrayCount > 0 && m.type == "vec4" {
                    // Packed scalar arrays: float4[k] holding consecutive scalars.
                    for (i, x) in f.enumerated() { put(x, m.offset + (i / 4) * m.arrayStride + (i % 4) * 4) }
                } else if m.arrayCount > 0 && m.type == "mat4" {
                    // mat4 arrays: 16 floats per element, already in register order (row r of P in register r).
                    for (i, x) in f.enumerated() { put(x, m.offset + (i / 16) * max(m.arrayStride, 64) + (i % 16) * 4) }
                } else if m.arrayCount > 0 {
                    let comps = Self.components(m.type)
                    for (i, x) in f.enumerated() { put(x, m.offset + (i / comps) * m.arrayStride + (i % comps) * 4) }
                } else {
                    for (i, x) in f.prefix(Self.components(m.type)).enumerated() { put(x, m.offset + i * 4) }
                }
            case .uints(let list):
                let packedArray = m.arrayCount > 0 && Self.components(m.type) == 4
                for (i, x) in list.enumerated() {
                    let o = packedArray ? m.offset + (i / 4) * m.arrayStride + (i % 4) * 4
                        : m.arrayCount > 0 ? m.offset + i * max(m.arrayStride, 4) : m.offset + i * 4
                    put(Float(bitPattern: x), o)
                }
            case .matrix(let p):
                // Buffer holds Pᵀ column-major: register r = row r of P.
                for r in 0..<4 { for c in 0..<4 { put(p[c][r], m.offset + r * 16 + c * 4) } }
            case .matrix3(let p):
                for r in 0..<3 { for c in 0..<3 { put(p[c][r], m.offset + r * 16 + c * 4) } }
            case .bones(let list):
                // HLSL float4x3, column_major: register c holds column c of the row-vector matrix M = Pᵀ,
                // i.e. (M[0][c]…M[3][c]) = row c of P.
                let stride = m.arrayStride > 0 ? m.arrayStride : 48
                for (b, p) in list.prefix(max(m.arrayCount, 1)).enumerated() {
                    for c in 0..<3 { for r in 0..<4 { put(p[r][c], m.offset + b * stride + c * 16 + r * 4) } }
                }
            }
        }
        return bytes
    }

    static func components(_ type: String) -> Int {
        switch type {
        case "vec2", "ivec2", "uvec2": return 2
        case "vec3", "ivec3", "uvec3": return 3
        case "vec4", "ivec4", "uvec4": return 4
        default: return 1
        }
    }
}

// MARK: - Engine matrix helpers (column-vector form P; the engine's row-vector M = Pᵀ)

public enum Mat {
    public static let identity = matrix_identity_float4x4

    /// D3DX OrthoOffCenterLH (docs/re/03 §2).
    public static func orthoLH(l: Float, r: Float, b: Float, t: Float, zn: Float, zf: Float) -> simd_float4x4 {
        simd_float4x4(rows: [
            [2 / (r - l), 0, 0, -(l + r) / (r - l)],
            [0, 2 / (t - b), 0, -(t + b) / (t - b)],
            [0, 0, 1 / (zf - zn), zn / (zn - zf)],
            [0, 0, 0, 1],
        ])
    }

    /// D3DX PerspectiveFovLH.
    /// `R vt+0x10` (0x14009a360): XMMatrixPerspectiveFovRH called as (fov, aspect, nearz, farz) into a function whose
    /// stack arguments are (FarZ, NearZ), so near and far are swapped: reverse-Z, depth 1 at `zn`, 0 at `zf`.
    /// Row-vector rows (w,0,0,0) (0,h,0,0) (0,0,f,−1) (0,0,f·zf,0), f = zn/(zf−zn).
    public static func perspectiveRHReversed(fovY: Float, aspect: Float, zn: Float, zf: Float) -> simd_float4x4 {
        let h = cos(fovY / 2) / sin(fovY / 2), w = h / aspect, f = zn / (zf - zn)
        return simd_float4x4(rows: [
            [w, 0, 0, 0],
            [0, h, 0, 0],
            [0, 0, f, f * zf],
            [0, 0, -1, 0],
        ])
    }

    public static func perspectiveLH(fovY: Float, aspect: Float, zn: Float, zf: Float) -> simd_float4x4 {
        let ys = 1 / tan(fovY / 2), xs = ys / aspect
        return simd_float4x4(rows: [
            [xs, 0, 0, 0],
            [0, ys, 0, 0],
            [0, 0, zf / (zf - zn), -zn * zf / (zf - zn)],
            [0, 0, 1, 0],
        ])
    }

    /// D3DX LookAtRH. For the ortho default camera (eye 0, center −Z, up +Y) this is the identity.
    public static func lookAtRH(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - center)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        return simd_float4x4(rows: [
            [x.x, x.y, x.z, -simd_dot(x, eye)],
            [y.x, y.y, y.z, -simd_dot(y, eye)],
            [z.x, z.y, z.z, -simd_dot(z, eye)],
            [0, 0, 0, 1],
        ])
    }

    public static func translate(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = identity
        m.columns.3 = SIMD4(t.x, t.y, t.z, 1)
        return m
    }

    public static func scale(_ s: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(s.x, s.y, s.z, 1))
    }

    /// Object rotation (docs/re/04 §4.2): v' = v·Rx(a)·Ry(b)·Rz(c) in row-vector form, i.e. Rz·Ry·Rx here.
    public static func rotation(_ a: SIMD3<Float>) -> simd_float4x4 {
        let (sa, ca) = (sin(a.x), cos(a.x)), (sb, cb) = (sin(a.y), cos(a.y)), (sc, cc) = (sin(a.z), cos(a.z))
        // Rows of the engine's row-vector matrix are the basis vectors; P = Mᵀ so they become columns.
        let row0 = SIMD3<Float>(cb * cc, cb * sc, -sb)
        let row1 = SIMD3<Float>(sa * sb * cc - ca * sc, sa * sb * sc + ca * cc, sa * cb)
        let row2 = SIMD3<Float>(ca * sb * cc + sa * sc, ca * sb * sc - sa * cc, ca * cb)
        return simd_float4x4(columns: (SIMD4(row0, 0), SIMD4(row1, 0), SIMD4(row2, 0), SIMD4(0, 0, 0, 1)))
    }
}

/// Built-in uniforms whose values live in render-context fields that only some draws write and that nothing resets
/// between draws or frames. `RenderContext_Ctor` 0x14017c6d0 zeroes them once (0x14017c799–0x14017c7bc: C+0xa8..+0xf7
/// g_RenderVar0–4; 0x14017c85c–0x14017c87d: C+0x184/+0x190/+0x19c g_OrientationForward/Right/Up; 0x14017c8be/0x14017c8cb:
/// C+0x1cc+16N / C+0x26c+8N g_TextureNRotation/Translation) and `ShaderProgram_FillConstants` 0x1400d8300 uploads
/// whatever is there (0x1400d972b–0x1400d9777, 0x1400d9eaa–0x1400d9f0c, 0x1400d979d/0x1400d97b7). The writers
/// (docs/re/evidence/session7-shaders2.md):
/// - particles `ParticleInstance_Draw` 0x1402366f0: orientation for every renderer (0x1402298b0); RenderVar0 per renderer
///   type, only some components (sprite none; spritetrail xyz 0x140236a4d; rope zw 0x140236a0c; ropetrail zw and x with
///   UV scrolling 0x14023697a–0x1402369d0); RenderVar1 only for sprite-sheet systems (0x140236869–0x1402368e7);
/// - volumetrics `Volumetrics_RenderLight` 0x140196ce0: RenderVar0–4 in full (0x1401985bd–0x1401987f5);
/// - HDR bloom `Bloom_Passes` 0x140183610: RenderVar0 in full; the combine replaces .xy only (device vt+0x158 0x14009b790);
/// - puppet clip masks `Puppet_RenderClipMask` 0x14020d6a0: RenderVar0.x only (0x14020d798);
/// - text 0x140258b80 (RenderVar0–3), sprite sheets (`Texture_UpdateSpriteUniforms` 0x14015f0d0, Rotation/Translation).
/// A caller writes a uniform by passing it; a NaN component means "this draw does not write that component".
public final class StaleBuiltins {
    /// `C+0x144`, the frame counter `Texture_UpdateSpriteUniforms` and the GIF update compare against (once per frame).
    public var frame = 0
    /// `C+0x132c`: ≥ 0 while a layer with a detached script texture animation renders (`Image_Render` 0x1402065a6); every
    /// sprite sheet then shows that frame index (frame 0 when out of range) and no texture clock steps (0x14015f129–0x14015f14f).
    public var spriteFrameOverride = -1
    private var values: [String: [Float]]

    static let names: [String: Int] = {
        var n: [String: Int] = ["g_OrientationForward": 3, "g_OrientationRight": 3, "g_OrientationUp": 3]
        for i in 0..<5 { n["g_RenderVar\(i)"] = 4 }
        for i in 0..<10 { n["g_Texture\(i)Rotation"] = 4; n["g_Texture\(i)Translation"] = 2 }
        return n
    }()

    public init() {
        values = Self.names.mapValues { [Float](repeating: 0, count: $0) }
    }

    /// Records the components `all` writes and fills everything else from the last written values.
    func apply(_ all: inout [String: UniformValue]) {
        for (name, count) in Self.names {
            var cur = values[name]!
            if case .floats(let f)? = all[name] {
                for i in 0..<min(count, f.count) where !f[i].isNaN { cur[i] = f[i] }
                values[name] = cur
            }
            all[name] = .floats(cur)
        }
    }
}

extension GPUTexture {
    /// `Texture_UpdateSpriteUniforms` 0x14015f0d0, animate branch (0x14015f154–0x14015f275): once per frame
    /// (texture +0xa4 ≠ C+0x144) the texture's own clock +0xa0 advances by the frame time C+0x14c; when it reaches the
    /// current frame's duration it moves **one** frame on (index +0x9c, wrapping) and keeps the remainder clamped to the
    /// new frame's duration (negative frame times step back the same way). The texture object is shared by every
    /// material that loads the same name, like the engine's TextureMgr cache.
    func advanceSprite(frame counter: Int, frametime: Float) -> TexFile.Frame? {
        guard !tex.frames.isEmpty else { return nil }
        let dt: Float = spriteLastFrame != counter ? frametime : 0
        let cur = Self.stepSprite(tex.frames, index: &spriteIndex, time: &spriteTime, dt: dt)
        spriteLastFrame = counter
        return cur
    }

    /// The single-step rule shared by the texture clock (0x14015f154–0x14015f275) and the detached script clock
    /// (`SpriteSheet_Step` 0x14015fdd0): at most one frame forward (dt > 0) or back (dt < 0) per call, the remainder
    /// clamped to the new frame's duration (≥ 0 going back); an out-of-range index reads frame 0. Returns the frame shown.
    @discardableResult
    static func stepSprite(_ frames: [TexFile.Frame], index: inout Int, time: inout Float, dt: Float) -> TexFile.Frame {
        var i = index
        var cur = (i >= 0 && i < frames.count) ? frames[i] : frames[0]
        if dt > 0 {
            time += dt
            if time >= cur.frameTime {
                time -= cur.frameTime
                i += 1
                if i >= frames.count { i = 0 }
                index = i
                cur = i >= 0 ? frames[i] : frames[0] // a negative script index: out of bounds in the engine
                time = min(time, cur.frameTime)
            }
        } else if dt < 0 {
            time += dt
            if time <= 0 {
                i -= 1
                if i < 0 { i = frames.count - 1 }
                index = i
                cur = i < frames.count ? frames[i] : frames[0] // a script index past the end: out of bounds in the engine
                time = max(time + cur.frameTime, 0)
            }
        }
        return cur
    }
}
