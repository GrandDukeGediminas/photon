import Foundation
import PhotonCore
import simd

/// The model object a skeleton moves with root motion: `Model_ApplyRootMotion` 0x140225900 reads the object's world matrix
/// (vt+0x80) and writes its `origin` (+0x128) and `angles` (+0x140, radians, through `Obj_SetAngles` 0x1401dd630).
protocol RootMotionHost: AnyObject {
    /// obj +0x310 bit 0 (`rootmotion`).
    var rootMotionEnabled: Bool { get }
    var rootMotionWorld: simd_float4x4 { get }
    var origin: SIMD3<Float> { get set }
    var angles: SIMD3<Float> { get set }
}

/// Root motion (docs/re/mdl-format.md §6.4). Matrices here are row-major, row-vector (the engine's layout):
/// a 4×4 is 16 floats, rows 0–2 the basis, row 3 the translation; a 3×3 is 9 floats.
/// Checked against the binary under emulation (docs/re/tools/rootmotion_replay.py; samplers alone in rootmotion_emu.py
/// and rootmotion_ref.py): pose, origin, angles and the stored matrix agree to float rounding (≤ 6e-6 relative).
extension Puppet {
    typealias M9 = [Float]

    /// Bone `bone`'s model matrix at one frame from the animation's tracks (0x140267580): per bone up the parent chain,
    /// local = rotation (the track's Euler angles as qZ·qY·qX) and translation, **scale ignored**; acc = acc × local.
    func rootBoneMatrix(_ a: MdlFile.Animation, bone: Int, frame: Int) -> [Float] {
        rootBoneMatrix(a, bone: bone, fa: frame, fb: frame, frac: 0, interpolate: false)
    }

    /// 0x140267f00: the same between frames a and b: positions lerp, rotations slerp (b flipped to a's hemisphere; plain
    /// lerp without renormalising when the cosine exceeds 0.99999988 = 0x3f7ffffe; else sin-weighted via acosf).
    func rootBoneMatrix(_ a: MdlFile.Animation, bone: Int, fa: Int, fb: Int, frac t: Float, interpolate: Bool = true) -> [Float] {
        var acc: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        var b = bone
        var guardCount = 0
        while b >= 0 && b < mdl.bones.count && guardCount <= mdl.bones.count {
            guardCount += 1
            func chan(_ f: Int) -> (SIMD3<Float>, SIMD4<Float>) {
                guard b < a.tracks.count, !a.tracks[b].samples.isEmpty else {
                    // A track without data keeps the SoA entries the loader never wrote (zero position, quaternion 0).
                    return (.zero, .zero)
                }
                let s = a.tracks[b].samples, o = max(0, min(f, s.count / 9 - 1)) * 9
                let q = Self.quat(SIMD3(s[o + 3], s[o + 4], s[o + 5]))
                return (SIMD3(s[o], s[o + 1], s[o + 2]), SIMD4(q.real, q.imag.x, q.imag.y, q.imag.z))
            }
            let (pa, qa) = chan(fa)
            var p = pa, q = qa
            if interpolate {
                let (pb, qb0) = chan(fb)
                p = pa * (1 - t) + pb * t
                var qb = qb0
                var d = simd_dot(qa, qb)
                if d < 0 { qb = -qb; d = -d }
                if d > Float(bitPattern: 0x3f7f_fffe) {
                    q = qa * (1 - t) + qb * t
                } else {
                    let th = Float(Foundation.acos(Double(d))), st = Float(Foundation.sin(Double(th)))
                    q = (qa * Float(Foundation.sin(Double((1 - t) * th))) + qb * Float(Foundation.sin(Double(t * th)))) / st
                }
            }
            let w = q.x, x = q.y, y = q.z, z = q.w
            let L: [Float] = [1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y), 0,
                              2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x), 0,
                              2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y), 0,
                              p.x, p.y, p.z, 1]
            acc = Self.mul4(acc, L)
            b = mdl.bones[b].parent
        }
        return acc
    }

    static func mul4(_ a: [Float], _ b: [Float]) -> [Float] {
        var o = [Float](repeating: 0, count: 16)
        for i in 0..<4 { for j in 0..<4 { o[4 * i + j] = a[4 * i] * b[j] + a[4 * i + 1] * b[4 + j] + a[4 * i + 2] * b[8 + j] + a[4 * i + 3] * b[12 + j] } }
        return o
    }
    /// 3×3 product `out = X × N` (0x1402163f0 with rdx = N, r8 = X).
    static func mul3(_ x: M9, _ n: M9) -> M9 {
        var o = M9(repeating: 0, count: 9)
        for i in 0..<3 { for j in 0..<3 { o[3 * i + j] = x[3 * i] * n[j] + x[3 * i + 1] * n[3 + j] + x[3 * i + 2] * n[6 + j] } }
        return o
    }
    static func top3(_ m: [Float]) -> M9 { [m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10]] }
    /// 0x140228b00: 3×3 inverse by cofactors over the determinant.
    static func inv3(_ m: M9) -> M9 {
        let s = simd_float3x3(rows: [SIMD3(m[0], m[1], m[2]), SIMD3(m[3], m[4], m[5]), SIMD3(m[6], m[7], m[8])]).inverse
        return [s[0][0], s[1][0], s[2][0], s[0][1], s[1][1], s[2][1], s[0][2], s[1][2], s[2][2]]
    }
    /// The yaw-only basis built three times in 0x140225900: forward f = normalize(r2.x, 0, r2.z), rows
    /// (f.z, 0, −f.x), (0, 1, 0), (f.x, 0, f.z).
    static func yawBasis(_ m: M9) -> M9 {
        let l = (m[6] * m[6] + m[8] * m[8]).squareRoot(), inv = 1 / l
        let fx = m[6] * inv, fz = m[8] * inv
        return [fz, 0, -fx, 0, 1, 0, fx, 0, fz]
    }
    /// glm::quat_cast as at 0x140218db0 (m[c][r] = row c of the stored 3×3), returned as (w, x, y, z).
    static func quatCast(_ m: M9) -> SIMD4<Float> {
        let m00 = m[0], m01 = m[1], m02 = m[2], m10 = m[3], m11 = m[4], m12 = m[5], m20 = m[6], m21 = m[7], m22 = m[8]
        let fW = m00 + m11 + m22, fX = m00 - m11 - m22, fY = m11 - m00 - m22, fZ = m22 - m00 - m11
        var bi = 0, big = fW
        if fX > big { big = fX; bi = 1 }
        if fY > big { big = fY; bi = 2 }
        if fZ > big { big = fZ; bi = 3 }
        let bv = (big + 1).squareRoot() * 0.5, mult = 0.25 / bv
        switch bi {
        case 0: return SIMD4(bv, (m12 - m21) * mult, (m20 - m02) * mult, (m01 - m10) * mult)
        case 1: return SIMD4((m12 - m21) * mult, bv, (m01 + m10) * mult, (m20 + m02) * mult)
        case 2: return SIMD4((m20 - m02) * mult, (m01 + m10) * mult, bv, (m12 + m21) * mult)
        default: return SIMD4((m01 - m10) * mult, (m20 + m02) * mult, (m12 + m21) * mult, bv)
        }
    }

    /// The loader's reference-record matrices (`Mdl_Load` 0x1402651a3–0x140265348): bone `ref.bone` at frameA (A, +0x1c)
    /// and frameB (B, +0x80) of the referenced animation, or of this animation at frames 0 and `frames` with flags 0x400;
    /// Ainv = inverse(A's 3×3) (+0x5c).
    func rootReference(_ a: MdlFile.Animation) -> (A: [Float], Ainv: M9, B: [Float])? {
        guard let ref = a.reference else { return nil }
        let key = a.id
        if let c = rootRefCache[key] { return c }
        let selfRef = a.flags & 0x400 != 0
        let data = selfRef ? a : (ref.index < mdl.animations.count ? mdl.animations[ref.index] : a)
        let A = rootBoneMatrix(data, bone: ref.bone, frame: selfRef ? 0 : ref.frameA)
        let B = rootBoneMatrix(data, bone: ref.bone, frame: selfRef ? a.frames : ref.frameB)
        let r = (A, Self.inv3(Self.top3(A)), B)
        rootRefCache[key] = r
        return r
    }

    /// `Model_Update` 0x14021cbf8–0x14021cd46 for layer `i`, after its kernels: when the object has `rootmotion` and the
    /// animation has flags & 0x1f800 (and a reference record), prod = Π(1 − weight) over the later visible non-additive
    /// layers (their AnimLayer_Weight runs here, side effects included); if prod > 0.0001 the root-motion step runs.
    /// Either way the layer is marked active (+0xd0 bit 31) and +0x148 = its time; otherwise bit 31 is cleared.
    func applyRootMotion(layer i: Int, src: MdlFile.Animation, fa: Int, fb: Int, frac: Float, weight w: Float, pose: inout [Pose]) {
        let anim = layers[i].animation
        guard let host = rootMotionHost, host.rootMotionEnabled, anim.flags & 0x1f800 != 0, let ref = anim.reference,
              let R = rootReference(anim) else {
            layers[i].rootActive = false
            return
        }
        var prod: Float = 1
        for j in (i + 1)..<layers.count where layers[j].visible && !layers[j].additive {
            prod = (1 - Self.weight(&layers[j])) * prod
        }
        if prod > 0.0001 { rootMotionStep(i, src: src, ref: ref, R: R, fa: fa, fb: fb, frac: frac, w: w, prod: prod, pose: &pose, host: host) }
        layers[i].rootActive = true
        layers[i].rootPrevTime = layers[i].time
    }

    func rootMotionStepForTest(_ i: Int, src: MdlFile.Animation, ref: MdlFile.Animation.Reference, R: (A: [Float], Ainv: M9, B: [Float]),
                               fa: Int, fb: Int, frac: Float, w: Float, prod: Float, pose: inout [Pose], host: RootMotionHost) {
        rootMotionStep(i, src: src, ref: ref, R: R, fa: fa, fb: fb, frac: frac, w: w, prod: prod, pose: &pose, host: host)
    }

    /// `Model_ApplyRootMotion` 0x140225900.
    private func rootMotionStep(_ i: Int, src: MdlFile.Animation, ref: MdlFile.Animation.Reference, R: (A: [Float], Ainv: M9, B: [Float]),
                                fa: Int, fb: Int, frac: Float, w: Float, prod: Float, pose: inout [Pose], host: RootMotionHost) {
        let bone = ref.bone
        guard bone >= 0, bone < pose.count else { return }
        let fl = layers[i].animation.flags
        let A = R.A, Ainv = R.Ainv, Bm = R.B
        // Current root matrix C (0x140267f00), D = Ainv × C₃, E = Ainv × A₃, their yaw bases, G = inverse(D') × E'.
        let C = rootBoneMatrix(src, bone: bone, fa: fa, fb: fb, frac: frac)
        let Dp = Self.yawBasis(Self.mul3(Ainv, Self.top3(C)))
        let Ep = Self.yawBasis(Self.mul3(Ainv, Self.top3(A)))
        let G = Self.mul3(Self.inv3(Dp), Ep)
        // 0x800 / 0x1000 / 0x2000: the bone's pose translation is pulled back to its start value on that axis.
        if fl & 0x800 != 0 { pose[bone].p.x += (A[12] - C[12]) * w }
        if fl & 0x1000 != 0 { pose[bone].p.y += (A[13] - C[13]) * w }
        if fl & 0x2000 != 0 { pose[bone].p.z += (A[14] - C[14]) * w }
        // 0x8000: the pose rotation is turned back by the yaw: q = quat(G) ⊗ q (0x140218db0, Hamilton, w first).
        if fl & 0x8000 != 0 {
            let g = Self.quatCast(G), q = pose[bone].q
            let gq = simd_quatf(ix: g.y, iy: g.z, iz: g.w, r: g.x)
            pose[bone].q = gq * q
        }
        // Rotation without x/z translation removal: the pose translation is rotated too (p × G).
        if fl & 0xa800 == 0x8000 {
            let p = pose[bone].p
            pose[bone].p = SIMD3(p.x * G[0] + p.y * G[3] + p.z * G[6], p.x * G[1] + p.y * G[4] + p.z * G[7],
                                 p.x * G[2] + p.y * G[5] + p.z * G[8])
        }
        // Previous root matrix: on the first applied update, A (rootFrame 0) or the frame `frameA + rootFrame` of the data
        // animation (frame 0 with flags 0x400).
        var Pm = layers[i].rootPrev
        if !layers[i].rootActive {
            Pm = ref.rootFrame == 0 ? A : rootBoneMatrix(src, bone: bone, frame: fl & 0x400 != 0 ? 0 : ref.frameA + Int(ref.rootFrame))
        }
        var P3 = Self.top3(Pm)
        var tw = SIMD3<Float>(0, 0, 0)
        // A wrap since the last update (previous time > current time): add the clip's whole displacement and rotation.
        if layers[i].rootPrevTime > layers[i].time {
            tw = SIMD3(Bm[12] - A[12], Bm[13] - A[13], Bm[14] - A[14])
            P3 = Self.mul3(Self.mul3(Self.top3(A), Self.inv3(Self.top3(Bm))), P3)
        }
        let Qp = Self.yawBasis(Self.mul3(Ainv, P3))
        let Qinv = Self.inv3(Qp)
        if fl & 0x3800 != 0 {
            let d = -SIMD3(A[12], A[13], A[14])
            func vm(_ v: SIMD3<Float>, _ m: M9) -> SIMD3<Float> {
                SIMD3(v.x * m[0] + v.y * m[3] + v.z * m[6], v.x * m[1] + v.y * m[4] + v.z * m[7], v.x * m[2] + v.y * m[5] + v.z * m[8])
            }
            let T = tw + SIMD3(C[12] - Pm[12], C[13] - Pm[13], C[14] - Pm[14]) + vm(d, Dp) - vm(d, Qp)
            var V = vm(T, G)
            if fl & 0x800 == 0 { V.x = 0 }
            if fl & 0x1000 == 0 { V.y = 0 }
            if fl & 0x2000 == 0 { V.z = 0 }
            // origin += (V × world₃) · prod · w (world = vt+0x80, row-vector; photon's column form: world₃ · V).
            let Wm = host.rootMotionWorld
            let dw = SIMD3(Wm.columns.0.x, Wm.columns.0.y, Wm.columns.0.z) * V.x + SIMD3(Wm.columns.1.x, Wm.columns.1.y, Wm.columns.1.z) * V.y
                + SIMD3(Wm.columns.2.x, Wm.columns.2.y, Wm.columns.2.z) * V.z
            host.origin += dw * prod * w
        }
        if fl & 0x8000 != 0 {
            let Rm = Self.mul3(Dp, Qinv)
            let ang = Float(Foundation.atan2(Double(-Rm[2]), Double((Rm[5] * Rm[5] + Rm[8] * Rm[8]).squareRoot())))
            var e = host.angles
            if abs(e.x) + abs(e.z) < 0.0001 {
                e.y = PuppetIK.fmodf(e.y + ang * prod * w, Float(bitPattern: 0x40c9_0fdb))   // fmodf(…, 6.2831855)
            } else {
                // 0x140215020 (z, y, x) → glm::rotate about (0, 1, 0) (0x1401e2500) → decompose 0x1401e23d0.
                let M = PuppetIK.axisAngle(PuppetIK.eulerToMatrix(e.z, e.y, e.x), ang * prod * w, PuppetIK.V(0, 1, 0))
                let (z, y, x) = PuppetIK.eulerFromMatrix(M)
                e = SIMD3(x, y, z)
            }
            host.angles = e
        }
        layers[i].rootPrev = C
    }
}

/// Test hook for `photon-tool rootmotion-replay`: runs `Model_ApplyRootMotion` on one skeleton with caller-supplied state
/// and returns what it wrote, for comparison with the emulated binary (docs/re/tools/rootmotion_replay.py, which emulates 0x140225900).
public enum RootMotionReplay {
    final class Host: RootMotionHost {
        var rootMotionEnabled = true
        var rootMotionWorld = matrix_identity_float4x4
        var origin = SIMD3<Float>(0, 0, 0)
        var angles = SIMD3<Float>(0, 0, 0)
    }

    /// Case keys: anim (index), bone, fa, fb, frac, flags, was, prevM[16], prevTime, time, w, prod, rootFrame, refFrameA,
    /// refFrameB, pose[[p3, q4 (w,x,y,z), s3]] per bone, world[16] (row-major row-vector), origin[3], angles[3].
    public static func run(mdl: MdlFile, cases: [[String: Any]]) -> [[String: Any]] {
        guard let pup = Puppet(mdl: mdl, layersJSON: [], uvScale: SIMD2(1, 1), allMeshMorphs: true) else { return [] }
        var out: [[String: Any]] = []
        for c in cases {
            func f(_ k: String) -> Float { (c[k] as? NSNumber)?.floatValue ?? 0 }
            func fa(_ k: String) -> [Float] { (c[k] as? [NSNumber])?.map(\.floatValue) ?? [] }
            func i(_ k: String) -> Int { (c[k] as? NSNumber)?.intValue ?? 0 }
            var a = mdl.animations[i("anim")]
            a.flags = UInt32(i("flags"))
            a.reference = MdlFile.Animation.Reference(index: a.reference?.index ?? 0, frameA: i("refFrameA"), frameB: i("refFrameB"),
                                                      rootFrame: UInt32(i("rootFrame")), bone: i("bone"))
            let src = a.isClip ? mdl.animations[a.reference!.index] : a
            pup.rootRefCache.removeAll()
            var L = Puppet.Layer(animation: a, rate: 1, blend: 1, visible: true, additive: false, blendIn: false, blendOut: false, blendTime: 0.5)
            L.time = f("time"); L.rootActive = (c["was"] as? Bool) ?? false; L.rootPrev = fa("prevM"); L.rootPrevTime = f("prevTime")
            pup.layers = [L]
            let host = Host()
            let W = fa("world")
            host.rootMotionWorld = simd_float4x4(columns: (SIMD4(W[0], W[1], W[2], W[3]), SIMD4(W[4], W[5], W[6], W[7]),
                                                           SIMD4(W[8], W[9], W[10], W[11]), SIMD4(W[12], W[13], W[14], W[15])))
            let o = fa("origin"), e = fa("angles")
            host.origin = SIMD3(o[0], o[1], o[2]); host.angles = SIMD3(e[0], e[1], e[2])
            var pose: [Puppet.Pose] = ((c["pose"] as? [[NSNumber]]) ?? []).map { v in
                let x = v.map(\.floatValue)
                return Puppet.Pose(p: SIMD3(x[0], x[1], x[2]), q: simd_quatf(ix: x[4], iy: x[5], iz: x[6], r: x[3]), s: SIMD3(x[7], x[8], x[9]))
            }
            pup.rootMotionHost = host
            // prod is supplied directly (no later layers here).
            if let R = pup.rootReference(a) {
                pup.rootMotionStepForTest(0, src: src, ref: a.reference!, R: R, fa: i("fa"), fb: i("fb"), frac: f("frac"), w: f("w"),
                                          prod: f("prod"), pose: &pose, host: host)
            }
            out.append(["pose": pose.map { [$0.p.x, $0.p.y, $0.p.z, $0.q.real, $0.q.imag.x, $0.q.imag.y, $0.q.imag.z].map(Double.init) },
                        "origin": [host.origin.x, host.origin.y, host.origin.z].map(Double.init),
                        "angles": [host.angles.x, host.angles.y, host.angles.z].map(Double.init),
                        "prevM": pup.layers[0].rootPrev.map(Double.init),
                        "A": (pup.rootReference(a)?.A ?? [Float]()).map { Double($0) }])
        }
        return out
    }
}
