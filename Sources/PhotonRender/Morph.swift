import Foundation
import Metal
import PhotonCore
import simd

/// Morph-target (blend shape) textures and uniforms, docs/re/06 §1.6 / §3.6.
/// The texture is format 0x13 (`rgba16161616S`, RGBA16 snorm), square, one mip, sampled at texel centres.
enum MorphGPU {
    /// Side of the smallest square holding `texels` (0x1401fbf88 / 0x1401d78fd: s = (int)sqrtf(n); if s·s < n: s+1).
    static func side(_ texels: Int) -> Int {
        let s = Int(sqrtf(Float(texels)))
        return s * s >= texels ? s : s + 1
    }

    static func makeTexture(device: MTLDevice, side: Int, halfs: [Int16]) -> BoundTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Snorm, width: max(side, 1), height: max(side, 1), mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        halfs.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: side * 8) }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .nearest; sd.magFilter = .nearest
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        let s = device.makeSamplerState(descriptor: sd)!
        let f = Float(side)
        return BoundTexture(texture: t, sampler: s, resolution: [f, f, f, f])
    }

    /// Puppet morph texture "morph_<n>" (`Image_LoadModel` 0x1401fbf44–0x1401fc14b), from mdl mesh 0:
    /// texels = targets·nv + 1; texel 0 = (0, 0, 0, 0x7fff). Only when the mesh has `mflags & 0x1000` are the
    /// targets written, each vertex as one texel (dx, dy, dz, alpha); otherwise the rest stays zero.
    /// `genericimage4.vert` indexes it with `a_PositionVec4.w + g_MorphOffsets[1+k]`.
    static func puppetTexture(device: MTLDevice, mesh: MdlFile.Mesh) -> BoundTexture? {
        let nv = mesh.morphVertexCount, n = mesh.morphTargets.count
        guard n > 0 else { return nil }
        let side = side(n * nv + 1)
        var h = [Int16](repeating: 0, count: side * side * 4)
        h[3] = 0x7fff
        if mesh.flags & 0x1000 != 0 {
            var o = 4
            for t in mesh.morphTargets {
                for v in 0..<nv {
                    for c in 0..<3 { h[o + c] = 3 * v + c < t.positions.count ? t.positions[3 * v + c] : 0 }
                    h[o + 3] = v < t.alpha.count ? Int16(bitPattern: t.alpha[v]) : 0
                    o += 4
                }
            }
        }
        return makeTexture(device: device, side: side, halfs: h)
    }

    /// Model morph texture "morph" (`ModelResource_Build` 0x1401d7760), per mesh, only for skinned mdls.
    /// Components are packed back to back, 4 per texel: per target either the positions (3·nv int16), or,
    /// with `mflags & 0x400` and without 0x800, per vertex (pos.xyz, normal.xyz). With 0x800 nothing is copied.
    /// The size counts 3·(targets·nv·(1 + [0x400] + [0x800])) components. `generic4.vert` reads 3 (or 6)
    /// components at `(gl_VertexID + g_MorphOffsets[1+k])·3 (or 6)`.
    static func modelTexture(device: MTLDevice, mesh: MdlFile.Mesh, vertexCount nv: Int) -> BoundTexture? {
        let n = mesh.morphTargets.count
        guard n > 0 else { return nil }
        let base = n * nv
        var comps = mesh.flags & 0x400 != 0 ? 2 * base : base
        if mesh.flags & 0x800 != 0 { comps += base }
        let c3 = comps * 3
        let side = side(c3 / 4 + (c3 % 4 != 0 ? 1 : 0))
        var h = [Int16](repeating: 0, count: side * side * 4)
        var o = 0
        for t in mesh.morphTargets {
            if mesh.flags & 0xc00 == 0 {
                for i in 0..<(3 * nv) where o + i < h.count { h[o + i] = i < t.positions.count ? t.positions[i] : 0 }
                o += 3 * nv
            } else if mesh.flags & 0x800 == 0 {
                for v in 0..<nv {
                    for c in 0..<3 where o + c + 3 < h.count {
                        h[o + c] = 3 * v + c < t.positions.count ? t.positions[3 * v + c] : 0
                        h[o + 3 + c] = 3 * v + c < t.normals.count ? t.normals[3 * v + c] : 0
                    }
                    o += 6
                }
            }
        }
        return makeTexture(device: device, side: side, halfs: h)
    }

    /// `g_MorphOffsets` (id 0x74) = [count, offset₀…offset₁₀] and `g_MorphWeights` (0x75) = [scale, w₀…w₁₀]
    /// (FillConstants 0x1400d9fa3 / 0x1400d9fea copy S+0x12ea, S+0x1334[11] and S+0x1330, S+0x1360[11]).
    /// offset = target index × `stride` (puppets: mesh +0x64 morph vertex count; models: obj +0x2e0 = mesh vertex count).
    static let debugDisabled = ProcessInfo.processInfo.environment["PHOTON_NOMORPH"] != nil

    static func uniforms(_ state: MorphState, scale: Float, stride: Int) -> [String: UniformValue] {
        let active = debugDisabled ? [] : state.activeTargets()
        var offsets = [UInt32](repeating: 0, count: 12), weights = [Float](repeating: 0, count: 12)
        offsets[0] = UInt32(active.count)
        weights[0] = scale
        for (k, a) in active.enumerated() {
            offsets[1 + k] = UInt32(a.index * stride)
            weights[1 + k] = a.weight
        }
        return ["g_MorphOffsets": .uints(offsets), "g_MorphWeights": .floats(weights)]
    }

    /// `MORPHING_MODIFIERS` (puppet mesh `mflags & 0x2000`), 0x14020d2c0–0x14020d5a8: per active target k,
    /// `g_MorphBoneTransform[k]` = inverse(animated bone world[target bone]) and `g_MorphBoneRules[k]` =
    /// (flags & 2 ? 1 : 0, range.x, range.y); unused slots get identity and (0, −1, 0).
    static func modifierUniforms(_ state: MorphState, mesh: MdlFile.Mesh, boneWorld: [simd_float4x4]) -> [String: UniformValue] {
        let active = state.activeTargets()
        var transforms = [simd_float4x4](repeating: matrix_identity_float4x4, count: 11)
        var rules = [Float](repeating: 0, count: 33)
        for k in 0..<11 { rules[3 * k + 1] = -1 }
        for (k, a) in active.enumerated() where a.index < mesh.morphTargets.count {
            let t = mesh.morphTargets[a.index]
            if t.modifierBone >= 0 && t.modifierBone < boneWorld.count { transforms[k] = boneWorld[t.modifierBone].inverse }
            rules[3 * k] = t.modifierFlags & 2 != 0 ? 1 : 0
            rules[3 * k + 1] = t.modifierRange.x
            rules[3 * k + 2] = t.modifierRange.y
        }
        return ["g_MorphBoneTransform": .bones(transforms), "g_MorphBoneRules": .floats(rules)]
    }
}
