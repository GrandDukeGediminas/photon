import Foundation
import PhotonCore
import simd

/// Puppet inverse kinematics: `ik_prepare` 0x14026f4c0, the rope Verlet step 0x14026eb60 and the chain solver 0x140271910,
/// run by `Puppet_Update` 0x1401fdf90 for each bone with a chain (0x14020365b–0x1402037a6), plus the per-bone constraint
/// blend (0x140200df2–0x1402011bf). Transcribed from the validated reference (gaps6/ik/ik_ref.py): every operation is IEEE
/// float32 in the binary's order; libm calls are evaluated in double and rounded, as the reference does.
///
/// Matrices are 16 floats, row-major, row-vector convention (translation in 12..14), exactly as the engine stores them.
/// The bone world array `BW` (puppet +0x2c8) is one flat buffer of `16 × boneCount` floats.
final class PuppetIK {
    // MARK: Constants

    static let PI: Float = 3.14159274
    static let TWO_PI: Float = 6.28318548
    static let HALF_PI: Float = 1.57079637
    static let DOT_EPS: Float = 0.99999988
    static let FLT_EPS: Float = 1.1920929e-07

    /// Quaternion as the engine stores it for these helpers: (w, x, y, z).
    struct Q { var w: Float; var x: Float; var y: Float; var z: Float }
    typealias V = SIMD3<Float>
    typealias M16 = [Float]

    static let IDENT: M16 = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

    /// The C+0x1510 scene interface: `general` gravity/wind, the scene time and the ortho width.
    struct Environment {
        var windEnabled = false
        var width: Float = 1920
        var time: Float = 0
        var gravityDirection = V(0, -1, 0)
        var gravityStrength: Float = 1
        var windDirection = V(0.7071, 0.7071, 0)
        var windStrength: Float = 1

        init() {}
        /// Reads the `general` keys (docs/re/04 table; defaults gravity (0,−1,0)×1, wind (0.7071, 0.7071, 0)×1, off).
        init(general: [String: Any], time: Float, orthoWidth: Float) {
            windEnabled = jsonBool(general["windenabled"], default: false)
            width = orthoWidth
            self.time = time
            if let v = SceneObject.vec3(general["gravitydirection"]) { gravityDirection = v }
            if let v = jsonFloats(general["gravitystrength"]).first { gravityStrength = v }
            if let v = SceneObject.vec3(general["winddirection"]) { windDirection = v }
            if let v = jsonFloats(general["windstrength"]).first { windStrength = v }
        }
    }

    /// Per-bone rope state (puppet +0x3b8 record +0x34 cur, +0x40 prev, +0x4c init byte).
    struct RopeState { var cur = V(0, 0, 0); var prev = V(0, 0, 0); var initialized = false }

    // MARK: Data (from the mdl)

    let chains: [MdlFile.IKChain]
    let handles: [MdlFile.Handle]
    let boneParent: [Int]
    let bone: [BonePhysics.IKParams]
    let D: [Float]
    let dirs: [[Int: V]]
    /// X+0x48 / X+0x88: bone → handle index for handles of type 0 / type 1 (later handles overwrite earlier ones).
    let map0: [Int: Int]
    let map1: [Int: Int]
    /// Puppet +0x328: bind-pose world matrices.
    let bind: [M16]

    // MARK: Per-frame state

    /// Puppet +0x2e0: handle matrices, model space.
    var HM: [M16]
    /// Puppet +0x250: per-constraint weights.
    var weights: [Float]
    var state: [RopeState]

    /// PHOTON_IKDEBUG=<frames> (default 3): dump the IK steps of the first frames to stderr.
    static let debug = ProcessInfo.processInfo.environment["PHOTON_IKDEBUG"] != nil
    static let debugFrames = Int(ProcessInfo.processInfo.environment["PHOTON_IKDEBUG"] ?? "") ?? 3
    var debugFrame = 0

    init(mdl: MdlFile, bindWorld: [M16]) {
        chains = mdl.ikChains
        handles = mdl.handles
        boneParent = mdl.bones.map { $0.parent }
        bone = mdl.bones.map { BonePhysics.ikParams(json: $0.physicsJSON) }
        D = mdl.segmentLength
        dirs = mdl.restDirections
        var m0: [Int: Int] = [:], m1: [Int: Int] = [:]
        for (i, h) in mdl.handles.enumerated() {
            if h.type == 0 { m0[h.bone] = i } else if h.type == 1 { m1[h.bone] = i }
        }
        map0 = m0; map1 = m1
        bind = bindWorld
        HM = Array(repeating: Self.IDENT, count: mdl.handles.count)
        weights = Array(repeating: 0, count: mdl.constraintCount)
        state = Array(repeating: RopeState(), count: mdl.bones.count)
    }

    // MARK: Accessors (bounds-safe stand-ins for the engine's unchecked/default-inserting lookups)

    @inline(__always) func d(_ b: Int) -> Float { b >= 0 && b < D.count ? D[b] : 0 }
    @inline(__always) func dir(_ a: Int, _ b: Int) -> V { a >= 0 && a < dirs.count ? (dirs[a][b] ?? V(0, 0, 0)) : V(0, 0, 0) }
    @inline(__always) func w(_ a: Int) -> Float { a >= 0 && a < weights.count ? weights[a] : 0 }
    @inline(__always) func pflags(_ b: Int) -> UInt32 { b >= 0 && b < bone.count ? bone[b].flags : 0 }
    @inline(__always) func parent(_ b: Int) -> Int { b >= 0 && b < boneParent.count ? boneParent[b] : -1 }
    /// `map0[bone]` (operator[]: a missing key reads handle 0).
    @inline(__always) func h0(_ b: Int) -> Int { map0[b] ?? 0 }
    @inline(__always) func hm(_ h: Int) -> M16 { h >= 0 && h < HM.count ? HM[h] : Self.IDENT }

    @inline(__always) static func t(_ BW: [Float], _ b: Int) -> V {
        let o = 16 * b
        return V(BW[o + 12], BW[o + 13], BW[o + 14])
    }
    @inline(__always) static func setT(_ BW: inout [Float], _ b: Int, _ p: V) {
        let o = 16 * b
        BW[o + 12] = p.x; BW[o + 13] = p.y; BW[o + 14] = p.z
    }
    @inline(__always) static func mat(_ BW: [Float], _ b: Int) -> M16 { Array(BW[(16 * b)..<(16 * b + 16)]) }
    @inline(__always) static func setMat(_ BW: inout [Float], _ b: Int, _ m: M16) {
        for k in 0..<16 { BW[16 * b + k] = m[k] }
    }
    @inline(__always) static func trans(_ M: M16) -> V { V(M[12], M[13], M[14]) }

    // MARK: Float32 helpers (exact order)

    @inline(__always) static func sinf(_ x: Float) -> Float { Float(Foundation.sin(Double(x))) }
    @inline(__always) static func cosf(_ x: Float) -> Float { Float(Foundation.cos(Double(x))) }
    @inline(__always) static func atan2f(_ y: Float, _ x: Float) -> Float { Float(Foundation.atan2(Double(y), Double(x))) }
    @inline(__always) static func acosf(_ x: Float) -> Float { Float(Foundation.acos(Double(x))) }
    @inline(__always) static func fmodf(_ x: Float, _ y: Float) -> Float { Float(Foundation.fmod(Double(x), Double(y))) }
    @inline(__always) static func sqrt(_ x: Float) -> Float { x.squareRoot() }

    /// 0x1401e24b0 and every inline row length: (v3² + v2²) + (v1² + v0²).
    @inline(__always) static func len4(_ M: M16, _ r: Int) -> Float {
        let o = 4 * r
        return sqrt((M[o + 3] * M[o + 3] + M[o + 2] * M[o + 2]) + (M[o + 1] * M[o + 1] + M[o] * M[o]))
    }
    @inline(__always) static func len3(_ x: Float, _ y: Float, _ z: Float) -> Float { sqrt((x * x + y * y) + z * z) }
    @inline(__always) static func len3(_ v: V) -> Float { len3(v.x, v.y, v.z) }
    /// p × M (affine): ((x·m0 + y·m1) + (z·m2 + m3)).
    @inline(__always) static func xform(_ p: V, _ M: M16) -> V {
        V((p.x * M[0] + p.y * M[4]) + (p.z * M[8] + M[12]),
          (p.x * M[1] + p.y * M[5]) + (p.z * M[9] + M[13]),
          (p.x * M[2] + p.y * M[6]) + (p.z * M[10] + M[14]))
    }

    /// 0x14005ecb0(out, X, Y): out = Y × X.
    static func matmul(_ X: M16, _ Y: M16) -> M16 {
        var o = M16(repeating: 0, count: 16)
        for i in 0..<4 {
            for j in 0..<4 {
                o[4 * i + j] = ((Y[4 * i] * X[j] + Y[4 * i + 1] * X[4 + j]) + Y[4 * i + 2] * X[8 + j]) + Y[4 * i + 3] * X[12 + j]
            }
        }
        return o
    }

    /// 0x1401e23d0 → (z, y, x).
    static func eulerFromMatrix(_ M: M16) -> (Float, Float, Float) {
        let z = atan2f(M[1], M[0])
        let y = atan2f(-M[2], sqrt(M[6] * M[6] + M[10] * M[10]))
        let sz = sinf(z), cz = cosf(z)
        let x = atan2f(sz * M[8] - cz * M[9], cz * M[5] - sz * M[4])
        return (z, y, x)
    }

    /// 0x140215020(out, &z, &y, &x).
    static func eulerToMatrix(_ z: Float, _ y: Float, _ x: Float) -> M16 {
        let cz = cosf(z), sz = sinf(z), cy = cosf(y), sy = sinf(y), cx = cosf(x), sx = sinf(x)
        var o = M16(repeating: 0, count: 16)
        o[0] = cy * cz; o[1] = cy * sz; o[2] = -sy
        o[4] = ((sy * cz) * sx) - (cx * sz); o[5] = ((sy * sz) * sx) + (cx * cz); o[6] = sx * cy
        o[8] = ((cx * cz) * sy) + (sx * sz); o[9] = ((cx * sz) * sy) - (sx * cz); o[10] = cx * cy
        o[15] = 1
        return o
    }

    /// 0x140215200.
    static func quatToMatrix(_ q: Q) -> M16 {
        let w = q.w, x = q.x, y = q.y, z = q.z
        var o = M16(repeating: 0, count: 16)
        var a: Float
        a = z * z + y * y; o[0] = 1 - (a + a)
        a = z * w + x * y; o[1] = a + a
        a = x * z - y * w; o[2] = a + a
        a = x * y - z * w; o[4] = a + a
        a = z * z + x * x; o[5] = 1 - (a + a)
        a = x * w + y * z; o[6] = a + a
        a = y * w + x * z; o[8] = a + a
        a = y * z - x * w; o[9] = a + a
        a = y * y + x * x; o[10] = 1 - (a + a)
        o[15] = 1
        return o
    }

    /// 0x140215730.
    static func matrixToQuat(_ m: M16) -> Q {
        let m00 = m[0], m01 = m[1], m02 = m[2], m10 = m[4], m11 = m[5], m12 = m[6], m20 = m[8], m21 = m[9], m22 = m[10]
        let fy = (m11 - m00) - m22, fz = (m22 - m00) - m11, fx = (m00 - m11) - m22, fw = (m00 + m11) + m22
        var big = fx > fw ? fx : fw
        var idx = fx > fw ? 1 : 0
        if fy > big { big = fy; idx = 2 }
        if fz > big {
            let s = sqrt(fz + 1) * 0.5, mult = 0.25 / s
            return Q(w: (m01 - m10) * mult, x: (m02 + m20) * mult, y: (m12 + m21) * mult, z: s)
        }
        let s = sqrt(big + 1) * 0.5, mult = 0.25 / s
        if idx == 0 { return Q(w: s, x: (m12 - m21) * mult, y: (m20 - m02) * mult, z: (m01 - m10) * mult) }
        if idx == 1 { return Q(w: (m12 - m21) * mult, x: s, y: (m01 + m10) * mult, z: (m02 + m20) * mult) }
        return Q(w: (m20 - m02) * mult, x: (m01 + m10) * mult, y: s, z: (m12 + m21) * mult)
    }

    /// 0x1402167c0 (also inlined at 0x140272f98): a, b unit vectors. Opposite vectors: half turn about cross(Z, a), or
    /// cross(X, a) when that is degenerate (unknown #41).
    static func rotationBetween(_ a: V, _ b: V) -> Q {
        let ax = a.x, ay = a.y, az = a.z, bx = b.x, by = b.y, bz = b.z
        let d = (ax * bx + ay * by) + az * bz
        if d >= DOT_EPS { return Q(w: 1, x: 0, y: 0, z: 0) }
        if -0.99999988 > d {
            let z0: Float = 0
            var x_ = az * z0 - ay, y_ = ax - az * z0, z_ = ay * z0 - ax * z0
            if FLT_EPS > (y_ * y_ + x_ * x_) + z_ * z_ {
                x_ = az * z0 - ay * z0; y_ = ax * z0 - az; z_ = ay - ax * z0
            }
            let inv = 1 / sqrt((x_ * x_ + y_ * y_) + z_ * z_)
            let sn = sinf(HALF_PI), cs = cosf(HALF_PI)
            return Q(w: cs, x: (x_ * inv) * sn, y: (y_ * inv) * sn, z: (z_ * inv) * sn)
        }
        var s = d + 1
        s = sqrt(s + s)
        let inv = 1 / s
        return Q(w: s * 0.5, x: (ay * bz - az * by) * inv, y: (az * bx - ax * bz) * inv, z: (ax * by - ay * bx) * inv)
    }

    /// 0x140268c50(out, a, b, t).
    static func slerp2(_ a: Q, _ b0: Q, _ t: Float) -> Q {
        var b = b0
        var d = (a.w * b.w + a.x * b.x) + (a.y * b.y + a.z * b.z)
        if 0 > d { b = Q(w: -b.w, x: -b.x, y: -b.y, z: -b.z); d = -d }
        let t1 = 1 - t
        if d > DOT_EPS { return Q(w: a.w * t1 + b.w * t, x: a.x * t1 + b.x * t, y: a.y * t1 + b.y * t, z: a.z * t1 + b.z * t) }
        let th = acosf(d), s = sinf(th), sb = sinf(th * t), sa = sinf(t1 * th)
        return Q(w: (a.w * sa + b.w * sb) / s, x: (a.x * sa + b.x * sb) / s, y: (a.y * sa + b.y * sb) / s, z: (a.z * sa + b.z * sb) / s)
    }

    /// 0x140214eb0: rsqrt with magic 0x5f375a86 and one Newton step.
    static func normalize4Fast(_ v: [Float]) -> [Float] {
        let s = (v[3] * v[3] + v[2] * v[2]) + (v[1] * v[1] + v[0] * v[0])
        let i = s.bitPattern
        let y = Float(bitPattern: 0x5f375a86 &- (i >> 1))
        let r = (1.5 - ((s * 0.5) * y) * y) * y
        return [v[0] * r, v[1] * r, v[2] * r, v[3] * r]
    }

    /// 0x14026dce0: closest points of the lines (pa + s·da) and (pb + t·db).
    static func lineClosest(_ pa: V, _ da: V, _ pb: V, _ db: V) -> (V, V)? {
        let a = (da.x * da.x + da.y * da.y) + da.z * da.z
        let b = (da.x * db.x + da.y * db.y) + da.z * db.z
        let c = (db.x * db.x + db.y * db.y) + db.z * db.z
        let den = a * c - b * b
        if den == 0 { return nil }
        let r = pa - pb
        let d = (da.x * r.x + da.y * r.y) + da.z * r.z
        let e = (db.y * r.y + db.x * r.x) + db.z * r.z
        let s = (e * b - d * c) / den, t = (e * a - d * b) / den
        return (da * s + pa, db * t + pb)
    }

    /// Rows 0..2 of R × B' (B' = B with row 3 = 0,0,0,1): the rotation rebuild's inline product.
    static func rotApplyBind(_ R: M16, _ B: M16) -> [Float] {
        var o = [Float](repeating: 0, count: 12)
        for i in 0..<3 {
            for j in 0..<4 {
                let last = j == 3 ? R[4 * i + 3] : R[4 * i + 3] * 0
                o[4 * i + j] = ((R[4 * i] * B[j] + R[4 * i + 1] * B[4 + j]) + R[4 * i + 2] * B[8 + j]) + last
            }
        }
        return o
    }

    /// fmod both Euler triples by 2π, subtract π from a target angle exceeding the source by more than π, then lerp.
    static func wrapLerpEuler(_ h: (Float, Float, Float), _ t: (Float, Float, Float), _ w: Float) -> (Float, Float, Float) {
        let hx = fmodf(h.0, TWO_PI), hy = fmodf(h.1, TWO_PI), hz = fmodf(h.2, TWO_PI)
        var tx = fmodf(t.0, TWO_PI), ty = fmodf(t.1, TWO_PI), tz = fmodf(t.2, TWO_PI)
        if tx - hx > PI { tx = tx - PI }
        if ty - hy > PI { ty = ty - PI }
        if tz - hz > PI { tz = tz - PI }
        let w1 = 1 - w
        return (tx * w + hx * w1, ty * w + hy * w1, tz * w + hz * w1)
    }

    /// The decompose/lerp/recompose block of 0x14026f4c0: Euler lerp, row-length lerp, translation lerp(Hm.t, posT).
    static func blendMatrix(_ Hm: M16, _ Tm: M16, _ w: Float, _ posT: V) -> M16 {
        let (hz, hy, hx) = eulerFromMatrix(Hm), (tz, ty, tx) = eulerFromMatrix(Tm)
        let hl = (0..<3).map { len4(Hm, $0) }, tl = (0..<3).map { len4(Tm, $0) }
        let (ex, ey, ez) = wrapLerpEuler((hx, hy, hz), (tx, ty, tz), w)
        let w1 = 1 - w
        let R = eulerToMatrix(ez, ey, ex)
        let Ht = trans(Hm)
        var Tr = IDENT
        Tr[12] = posT.x * w + Ht.x * w1; Tr[13] = posT.y * w + Ht.y * w1; Tr[14] = posT.z * w + Ht.z * w1; Tr[15] = 1
        let out = matmul(Tr, R)
        var res = out
        for r in 0..<3 {
            let s = tl[r] * w + hl[r] * w1
            for c in 0..<4 { res[4 * r + c] = out[4 * r + c] * s }
        }
        return res
    }

    /// 0x14005f730 (lifted, exact order).
    static func inverse4(_ m: M16) -> M16 {
        let t1 = m[15] * m[6], t2 = m[14] * m[11], t3 = m[10] * m[15], t4 = m[15] * m[9]
        let t5 = t3 - t2, t6 = m[14] * m[9], t7 = m[14] * m[7], t8 = t1 - t7
        let t9 = m[10] * m[7], t10 = m[11] * m[6], t11 = t10 - t9, t12 = m[11] * m[13]
        let t13 = t4 - t12, t14 = m[7] * m[13], t15 = m[15] * m[5], t16 = t15 - t14
        let t17 = m[7] * m[9], t18 = m[11] * m[5], t19 = t18 - t17, t20 = m[10] * m[13]
        let t21 = t6 - t20, t22 = m[6] * m[13], t23 = m[14] * m[5], t24 = t23 - t22
        let t25 = m[6] * m[9], t26 = m[10] * m[5], t27 = m[15] * m[8], t28 = t26 - t25
        let t29 = m[11] * m[12], t30 = t27 - t29, t31 = m[15] * m[4], t32 = m[7] * m[12]
        let t33 = m[11] * m[4], t34 = t31 - t32, t35 = m[7] * m[8], t36 = t33 - t35
        let t37 = m[14] * m[4], t38 = m[14] * m[8], t39 = m[10] * m[4], t40 = m[10] * m[12]
        let t41 = t38 - t40, t42 = m[6] * m[12], t43 = t37 - t42, t44 = m[6] * m[8]
        let t45 = t39 - t44, t46 = m[13] * m[4], t47 = m[13] * m[8], t48 = m[9] * m[12]
        let t49 = m[9] * m[4], t50 = t47 - t48, t51 = m[5] * m[12], t52 = m[7] * t21
        let t53 = t46 - t51, t54 = m[5] * t5, t55 = m[5] * m[8], t56 = m[7] * t41
        let t57 = t49 - t55, t58 = m[4] * t13, t59 = m[7] * t50, t60 = m[6] * t13
        let t61 = t54 - t60, t62 = m[5] * t30, t63 = m[5] * t41, t64 = m[4] * t5
        let t65 = t61 + t52, t66 = m[4] * t21, t67 = t58 - t62, t68 = m[6] * t30
        let t69 = m[6] * t50, t70 = t66 - t63, t71 = t64 - t68, t72 = t67 + t59
        let t73 = t70 + t69, t74 = t65 * m[0], t75 = t71 + t56, t76 = t73 * -1
        let t77 = t75 * -1, t78 = t77 * m[1], t79 = t78 + t74, t80 = t76 * m[3]
        let t81 = t72 * m[2], t82 = t80 + t81, t83 = m[3] * t21, t84 = t82 + t79
        let t85 = m[1] * t5, t86 = 1 / t84, t87 = t86 * t65, t88 = m[3] * t24
        let t89 = m[2] * t13, t90 = t85 - t89, t91 = t90 + t83, t92 = m[1] * t8
        let t93 = t91 * -1, t94 = t86 * t93, t95 = m[3] * t28, t96 = m[2] * t16
        let t97 = t92 - t96, t98 = t97 + t88, t99 = t86 * t98, t100 = m[1] * t11
        let t101 = m[2] * t19, t102 = t100 - t101, t103 = t102 + t95, t104 = m[3] * t41
        let t105 = t103 * -1, t106 = t86 * t105, t107 = t86 * t77, t108 = m[2] * t30
        let t109 = m[0] * t5, t110 = t109 - t108, t111 = t110 + t104, t112 = m[3] * t43
        let t113 = t86 * t111, t114 = m[0] * t8, t115 = m[2] * t34, t116 = t114 - t115
        let t117 = t116 + t112, t118 = m[3] * t45, t119 = t117 * -1, t120 = t86 * t119
        let t121 = m[2] * t36, t122 = m[0] * t11, t123 = t122 - t121, t124 = t123 + t118
        let t125 = m[3] * t50, t126 = t86 * t124, t127 = t86 * t72, t128 = m[0] * t13
        let t129 = m[1] * t30, t130 = t128 - t129, t131 = t130 + t125, t132 = m[3] * t53
        let t133 = t131 * -1, t134 = t86 * t133, t135 = m[0] * t16, t136 = m[1] * t34
        let t137 = t135 - t136, t138 = t137 + t132, t139 = t57 * m[3], t140 = t57 * m[2]
        let t141 = t86 * t138, t142 = m[0] * t19, t143 = m[1] * t36, t144 = t142 - t143
        let t145 = t144 + t139, t146 = m[2] * t50, t147 = t145 * -1, t148 = t86 * t147
        let t149 = t86 * t76, t150 = m[1] * t41, t151 = m[0] * t21, t152 = t151 - t150
        let t153 = t152 + t146, t154 = m[2] * t53, t155 = t86 * t153, t156 = m[0] * t24
        let t157 = m[0] * t28, t158 = m[1] * t43, t159 = m[1] * t45, t160 = t156 - t158
        let t161 = t157 - t159, t162 = t160 + t154, t163 = t161 + t140, t164 = t162 * -1
        let t165 = t86 * t163, t166 = t86 * t164
        return [t87, t94, t99, t106, t107, t113, t120, t126, t127, t134, t141, t148, t149, t155, t166, t165]
    }

    /// 0x1401e2500(m, angle, axis) (lifted, exact order).
    static func axisAngle(_ m: M16, _ ang: Float, _ ax: V) -> M16 {
        let t1 = cosf(ang), t2 = sinf(ang)
        let t3 = ax.x * ax.x, t4 = ax.y * ax.y, t5 = ax.z * ax.z
        let t6 = t3 + t4, t7 = t6 + t5, t8 = sqrt(t7), t9 = 1 - t1, t10 = 1 / t8
        let t11 = ax.y * t10, t12 = ax.z * t10, t13 = ax.x * t10
        let t14 = t12 * t2, t15 = t11 * t9, t16 = t13 * t9, t17 = t11 * t2
        let t18 = t13 * t16, t19 = t11 * t16, t20 = t18 + t1, t21 = t12 * t16
        let t22 = t19 + t14, t23 = t13 * t2, t24 = t21 - t17
        let t57 = (m[0] * t20 + m[4] * t22) + m[8] * t24
        let t58 = (m[1] * t20 + m[5] * t22) + m[9] * t24
        let t62 = (m[2] * t20 + m[6] * t22) + m[10] * t24
        let t63 = (m[3] * t20 + m[7] * t22) + m[11] * t24
        let t61 = t13 * t15, t66 = t12 * t15, t67 = t61 - t14, t68 = t12 * t9
        let t69 = t66 + t23, t70 = t11 * t15, t75 = t70 + t1
        let t104 = (m[0] * t67 + m[4] * t75) + m[8] * t69
        let t105 = (m[1] * t67 + m[5] * t75) + m[9] * t69
        let t108 = (m[2] * t67 + m[6] * t75) + m[10] * t69
        let t109 = (m[3] * t67 + m[7] * t75) + m[11] * t69
        let t112 = t13 * t68, t113 = t11 * t68, t114 = t12 * t68
        let t115 = t112 + t17, t116 = t113 - t23, t117 = t114 + t1
        let t150 = (m[0] * t115 + m[4] * t116) + m[8] * t117
        let t151 = (m[1] * t115 + m[5] * t116) + m[9] * t117
        let t154 = (m[2] * t115 + m[6] * t116) + m[10] * t117
        let t155 = (m[3] * t115 + m[7] * t116) + m[11] * t117
        return [t57, t58, t62, t63, t104, t105, t108, t109, t150, t151, t154, t155, m[12], m[13], m[14], m[15]]
    }

    // MARK: 0x14026f4c0 ik_prepare

    func prepare(_ BW: inout [Float], _ ch: MdlFile.IKChain) {
        for h in ch.handles where h < handles.count && h < HM.count {
            let H = handles[h]
            for c in H.constraints {
                if c.flags & 0x10000 != 0 {
                    for e in ch.entries { for l in e.links where l.bone == H.bone { reach(&BW, h, c, l) } }
                } else if c.flags & 2 != 0 {
                    for e in ch.entries {
                        for l in e.links where l.bone == H.bone {
                            let T = Self.mat(BW, c.b), inv = 1 / Self.len4(T, 0)
                            let Tt = Self.trans(T), Hm = HM[h], Ht = Self.trans(Hm)
                            let dv = Ht - Tt
                            let dr = V(T[0] * inv, T[1] * inv, T[2] * inv)
                            let pr = (dv.x * dr.x + dv.y * dr.y) + dv.z * dr.z
                            let perp = V(dv.x - pr * dr.x, dv.y - pr * dr.y, dv.z - pr * dr.z)
                            let inv2 = 1 / Self.len3(perp)
                            let n = V(inv2 * perp.x, inv2 * perp.y, inv2 * perp.z)
                            guard let (_, ptB) = Self.lineClosest(Ht, n, Tt, dr) else { continue }
                            let wt = w(c.a)
                            var tmp = Hm; tmp[12] = ptB.x; tmp[13] = ptB.y; tmp[14] = ptB.z; tmp[15] = 1
                            HM[h] = Self.blendMatrix(Hm, tmp, wt, ptB)
                        }
                    }
                } else {
                    let T = Self.mat(BW, c.b), wt = w(c.a), w1 = 1 - wt
                    if c.flags & 1 != 0 {
                        let q = Self.trans(HM[h]), p = Self.trans(T)
                        HM[h][12] = w1 * q.x + wt * p.x; HM[h][13] = w1 * q.y + wt * p.y; HM[h][14] = w1 * q.z + wt * p.z
                    } else {
                        HM[h] = Self.blendMatrix(HM[h], T, wt, Self.trans(T))
                    }
                }
            }
        }
    }

    private func reach(_ BW: inout [Float], _ h: Int, _ c: MdlFile.Constraint, _ l: MdlFile.IKLink) {
        guard !l.list.isEmpty else { return }
        let T = Self.mat(BW, c.b)
        let inv = 1 / Self.len4(T, 0)
        let dr = V(inv * T[0], inv * T[1], inv * T[2])
        var Tt = Self.trans(T)
        let Hm = HM[h], Ht = Self.trans(Hm)
        let B0 = Self.t(BW, l.list[0])
        let d0 = Self.len3(Tt.x - B0.x, Tt.y - B0.y, Tt.z - B0.z)
        let proj = ((Ht.y - Tt.y) * dr.y + (Ht.x - Tt.x) * dr.x) + (Ht.z - Tt.z) * dr.z
        let L = l.maxd, wt = w(c.a)
        if d0 >= L || 0 > proj {
            // Out of reach / behind: pull the handle translation toward the target origin, keep rotation and scale.
            var z = Self.atan2f(Hm[1], Hm[0])
            let sz = Self.sinf(z), cz = Self.cosf(z)
            let ln = (0..<3).map { Self.len4(Hm, $0) }
            let x = Self.fmodf(Self.atan2f(Hm[8] * sz - Hm[9] * cz, Hm[5] * cz - Hm[4] * sz), Self.TWO_PI)
            let y = Self.fmodf(Self.atan2f(-Hm[2], Self.sqrt(Hm[6] * Hm[6] + Hm[10] * Hm[10])), Self.TWO_PI)
            z = Self.fmodf(z, Self.TWO_PI)
            let w1 = 1 - wt
            // The binary compares each angle with itself (never true).
            let tx = x - x > Self.PI ? x - Self.PI : x
            let ty = y - y > Self.PI ? y - Self.PI : y
            let tz = z - z > Self.PI ? z - Self.PI : z
            let R = Self.eulerToMatrix(tz * wt + z * w1, ty * wt + y * w1, tx * wt + x * w1)
            var Tr = Self.IDENT
            Tr[12] = Tt.x * wt + Ht.x * w1; Tr[13] = Tt.y * wt + Ht.y * w1; Tr[14] = Tt.z * wt + Ht.z * w1
            let out = Self.matmul(Tr, R)
            var res = out
            for r in 0..<3 {
                let s = ln[r] * wt + ln[r] * w1
                for k in 0..<4 { res[4 * r + k] = out[4 * r + k] * s }
            }
            HM[h] = res
            return
        }
        var s_ = L - d0
        if s_ > proj { s_ = proj }
        let new = V(dr.x * s_ + Tt.x, dr.y * s_ + Tt.y, dr.z * s_ + Tt.z)
        var tmp = T; tmp[12] = new.x; tmp[13] = new.y; tmp[14] = new.z; tmp[15] = 1
        HM[h] = Self.blendMatrix(Hm, tmp, wt, new)
        let lst = l.list
        var k = lst.count - 2
        var x9 = proj
        while k > 0 {
            let Dn = d(lst[k + 1])
            x9 = x9 - Dn
            let saved = x9
            if 0 > x9 { break }
            x9 = x9 - c.f0
            let q = (x9 > 0 ? x9 : 0) / c.f1
            if 1 > q {
                x9 = (x9 > 0 ? x9 : 0) / c.f1
                if 0 >= x9 { break }
            } else {
                x9 = 1
            }
            s_ = s_ - Dn
            if 0 > s_ { break }
            let b = lst[k]
            Tt = Self.t(BW, c.b)
            let pos = V(dr.x * s_ + Tt.x, dr.y * s_ + Tt.y, dr.z * s_ + Tt.z)
            var tmp2 = Self.mat(BW, c.b); tmp2[12] = pos.x; tmp2[13] = pos.y; tmp2[14] = pos.z; tmp2[15] = 1
            let wk = x9 * wt
            Self.setMat(&BW, b, Self.blendMatrix(Self.mat(BW, b), tmp2, wk, pos))
            x9 = saved
            k -= 1
        }
    }

    // MARK: Scene callbacks (C+0x1510)

    static let PERM: [Int] = [151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225, 140, 36, 103, 30, 69, 142, 8, 99, 37, 240, 21, 10, 23, 190, 6, 148, 247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117, 35, 11, 32, 57, 177, 33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171, 168, 68, 175, 74, 165, 71, 134, 139, 48, 27, 166, 77, 146, 158, 231, 83, 111, 229, 122, 60, 211, 133, 230, 220, 105, 92, 41, 55, 46, 245, 40, 244, 102, 143, 54, 65, 25, 63, 161, 1, 216, 80, 73, 209, 76, 132, 187, 208, 89, 18, 169, 200, 196, 135, 130, 116, 188, 159, 86, 164, 100, 109, 198, 173, 186, 3, 64, 52, 217, 226, 250, 124, 123, 5, 202, 38, 147, 118, 126, 255, 82, 85, 212, 207, 206, 59, 227, 47, 16, 58, 17, 182, 189, 28, 42, 223, 183, 170, 213, 119, 248, 152, 2, 44, 154, 163, 70, 221, 153, 101, 155, 167, 43, 172, 9, 129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104, 218, 246, 97, 228, 251, 34, 242, 193, 238, 210, 144, 12, 191, 179, 162, 241, 81, 51, 145, 235, 249, 14, 239, 107, 49, 192, 214, 31, 181, 199, 106, 157, 184, 84, 204, 176, 115, 121, 50, 45, 127, 4, 150, 254, 138, 236, 205, 93, 222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66, 215, 61, 156, 180]   // 0x140484f40

    /// vt+0x30 = 0x1401988e0: gravitydirection × gravitystrength.
    static func gravity(_ sc: Environment) -> V {
        let g = sc.gravityStrength
        return V(sc.gravityDirection.x * g, sc.gravityDirection.y * g, g * sc.gravityDirection.z)
    }

    private static func floorI(_ v: Float) -> Int {
        let t = v.isFinite && abs(v) < 2147483648 ? Int(v) : Int(Int32.min)
        return Float(t) <= v ? t : t - 1
    }

    private static func grad(_ h: Int, _ u0: Float, _ v0: Float) -> Float {
        var u = u0, v = v0
        if h & 0x3c != 0 { swap(&u, &v) }
        if h & 1 != 0 { u = -u }
        v = h & 2 != 0 ? v * -2 : v + v
        return v + u
    }

    /// vt+0x38 = 0x140198910: 2D simplex noise of (time, p.x / width · 10), gated by `general.windenabled`.
    static func wind(_ sc: Environment, _ p: V) -> V? {
        guard sc.windEnabled else { return nil }
        let G2: Float = 0.211324871, F2: Float = 0.366025418, G22: Float = 0.422649741
        let xin = (p.x / sc.width) * 10
        let t = sc.time
        let sk = (t + xin) * F2
        let i = floorI(sk + t), j = floorI(sk + xin)
        let g = Float(i + j) * G2
        let x0 = t - (Float(i) - g), y0 = xin - (Float(j) - g)
        let i1 = x0 > y0 ? 1 : 0, j1 = x0 > y0 ? 0 : 1
        let x1 = (x0 - Float(i1)) + G2, y1 = (y0 - Float(j1)) + G2
        let x2 = (x0 - 1) + G22, y2 = (y0 - 1) + G22
        var n: [Float] = []
        for (xa, ya, ii, jj) in [(x0, y0, i, j), (x1, y1, i + i1, j + j1), (x2, y2, i + 1, j + 1)] {
            var tt = (0.5 - xa * xa) - ya * ya
            if 0 > tt { n.append(0); continue }
            let h = PERM[(ii + PERM[jj & 255]) & 255]
            tt = tt * tt
            n.append(grad(h, xa, ya) * (tt * tt))
        }
        let s = ((n[1] + n[0]) + n[2]) * 45.2306519
        let wv: Float = 0 > s ? 0 : s
        let st = sc.windStrength, wd = sc.windDirection
        return V(0 + (wv * wd.x) * st, 0 + (wd.y * wv) * st, 0 + (wd.z * wv) * st)
    }

    // MARK: 0x14026eb60 rope (Verlet)

    func rope(_ BW: inout [Float], _ ch: MdlFile.IKChain, _ M: M16, _ dt: Float, _ sc: Environment) {
        let v = Self.gravity(sc)
        let Mi = Self.inverse4(M)
        let dt2 = dt * dt
        for e in ch.entries.reversed() {
            for l in e.links where l.flags & 4 != 0 {
                let R = Self.t(BW, e.bone)
                let A = l.flags & 1 != 0 ? Self.trans(hm(h0(l.bone))) : Self.t(BW, l.bone)
                let lb = l.bone < bone.count ? bone[l.bone] : BonePhysics.IKParams()
                var Ap = A
                if lb.flags & 0x80 == 0 {   // ikse
                    let dv = A - R
                    let ln = Self.len3(dv)
                    if ln > l.maxd { Ap = V((dv.x / ln) * l.maxd + R.x, (dv.y / ln) * l.maxd + R.y, (dv.z / ln) * l.maxd + R.z) }
                }
                state[e.bone].cur = Self.xform(R, M)
                var r10 = l.list.count
                if lb.flags & 0x100 == 0 {   // ikfe
                    Self.setT(&BW, l.bone, Ap)
                    state[l.bone].cur = Self.xform(Ap, M)
                    r10 -= 1
                }
                if !state[e.bone].initialized {
                    state[e.bone].initialized = true
                    if r10 > 1 {
                        for i in 1..<r10 {
                            let b = l.list[i], p = Self.xform(Self.t(BW, b), M)
                            state[b].cur = p; state[b].prev = p
                        }
                    }
                }
                let ge = lb.flags & 4 != 0
                if r10 > 1 {
                    for i in 1..<r10 {
                        let b = l.list[i]
                        let cur = state[b].cur, prev = state[b].prev
                        var nw = V(cur.x + cur.x - prev.x, cur.y + cur.y - prev.y, cur.z + cur.z - prev.z)
                        if dt2 > Self.FLT_EPS && lb.tf > 0.01 {
                            let dd = prev - cur
                            if (dd.x * dd.x + dd.y * dd.y) + dd.z * dd.z > 0.0001 {
                                let inv = 1 / dt2
                                nw = V(((dd.x * dt2) * inv) * lb.tf + nw.x, ((dd.y * dt2) * inv) * lb.tf + nw.y,
                                       ((dd.z * dt2) * inv) * lb.tf + nw.z)
                            }
                        }
                        var f = ge ? V(lb.m * v.x + 0, lb.m * v.y + 0, lb.m * v.z + 0) : V(0, 0, 0)
                        if let wf = Self.wind(sc, nw) { f = f + wf }
                        nw = V(nw.x + f.x * dt2, nw.y + f.y * dt2, nw.z + f.z * dt2)
                        state[b].prev = cur; state[b].cur = nw
                        Self.setT(&BW, b, Self.xform(nw, Mi))
                    }
                }
            }
        }
    }

    // MARK: 0x140271910 solve

    /// 0x14026df30: clamp the 2D angle of v in the parent→bone frame to [ikrmin, ikrmax].
    private func angleLimit(_ BW: [Float], _ b: Int, _ l: MdlFile.IKLink, _ k: Int, _ v: V) -> V {
        let bi = l.list[k], pi = parent(bi)
        let pT = pi >= 0 ? Self.t(BW, pi) : Self.t(BW, bi)   // the engine reads BW[−1] for a root; unreachable for chains
        let u = Self.t(BW, bi) - pT
        let inv = 1 / Self.sqrt((u.y * u.y + u.x * u.x) + u.z * u.z)
        let un = V(u.x * inv, u.y * inv, u.z * inv)
        let Rq = Self.quatToMatrix(Self.rotationBetween(V(1, 0, 0), un))
        let l2 = Self.sqrt((v.x * v.x + v.y * v.y) + 0)
        let z = 0 / l2, vx = v.x / l2, vy = v.y / l2
        let I = Self.inverse4(Rq)
        let lx = (I[0] * vx + I[4] * vy) + (I[8] * z + I[12])
        let ly = (I[1] * vx + I[5] * vy) + (I[9] * z + I[13])
        let ang = Self.atan2f(ly, lx)
        let bp = b < bone.count ? bone[b] : BonePhysics.IKParams()
        let mn = bp.ikrmin, mx = bp.ikrmax
        var c: Float = mn > ang ? -(ang - mn) : 0
        if ang > mx {
            let c2 = mx - ang
            if c == 0 || abs(c) > abs(c2) { c = c2 }
        }
        if c == 0 { return v }
        let lz = (I[2] * vx + I[6] * vy) + (I[10] * z + I[14])
        let Rt = Self.axisAngle(Self.IDENT, c, V(0, 0, 1))
        let nx = (Rt[4] * ly + Rt[0] * lx) + Rt[8] * lz
        let ny = (Rt[5] * ly + Rt[1] * lx) + Rt[9] * lz
        let nz = (Rt[6] * ly + Rt[2] * lx) + Rt[10] * lz
        let wx = (Rq[0] * nx + Rq[4] * ny) + (Rq[8] * nz + Rq[12])
        let wy = (Rq[1] * nx + Rq[5] * ny) + (Rq[9] * nz + Rq[13])
        return V(wx * l2, wy * l2, v.z)
    }

    /// 0x14026e340: one distance-constraint sweep over a rope link, in model space.
    private func ropeLink(_ M: M16, _ l: MdlFile.IKLink, _ fwd: Bool) {
        guard !l.list.isEmpty else { return }
        let dv0 = state[l.bone].cur - state[l.list[0]].cur
        let dist = Self.len3(dv0)
        let Mi = Self.inverse4(M)
        var scale: Float = 1
        let lf = pflags(l.bone)
        if dist > l.maxd && lf & 0x80 != 0 { scale = dist / l.maxd }
        let ikfe = lf & 0x100 != 0
        let n = l.list.count
        let r13 = ikfe ? n : n - 1
        guard r13 > 1 else { return }
        for i in 1..<r13 {
            var firstF = false, firstB = false
            let a: Int, b: Int
            if fwd {
                b = l.list[i]; a = l.list[i - 1]; firstF = i == 1
            } else {
                let idx = r13 - i
                if !ikfe { b = l.list[idx + 1]; a = l.list[idx] } else { b = l.list[idx]; a = l.list[idx - 1] }
                firstB = i == 1
            }
            let rest = scale * d(b)
            let pb = Self.xform(state[b].cur, Mi), pa = Self.xform(state[a].cur, Mi)
            let dv = pb - pa
            let ln = Self.len3(dv)
            let err = rest - ln
            if !(abs(err) > 0.001) { continue }
            let dn = ln > 0.01 ? V(dv.x / ln, dv.y / ln, dv.z / ln) : V(0.707, 0.707, 0)
            if firstF && !firstB {
                state[b].cur = Self.xform(V(dn.x * err + pb.x, dn.y * err + pb.y, dn.z * err + pb.z), M)
            } else if firstB {
                state[a].cur = Self.xform(V(pa.x - dn.x * err, pa.y - dn.y * err, pa.z - dn.z * err), M)
            } else {
                let hf = err * 0.5
                state[b].cur = Self.xform(V(dn.x * hf + pb.x, dn.y * hf + pb.y, dn.z * hf + pb.z), M)
                state[a].cur = Self.xform(V(pa.x - dn.x * hf, pa.y - dn.y * hf, pa.z - dn.z * hf), M)
            }
        }
    }

    /// Iterative chain solver: backward pass (anchor → root, with bend plane), first-pass reach bends, forward pass
    /// (root → anchor), repeated until every handle-driven anchor is within √0.1 of its handle or `iters` passes ran;
    /// then each bone's rotation is rebuilt from its rest direction and the bind pose.
    func solve(_ BW: inout [Float], _ ch: MdlFile.IKChain, _ M: M16, iters: Int = 10) {
        let root0 = Self.t(BW, ch.bone)
        var pas = 0
        while true {
            for e in ch.entries.reversed() {
                var acc = V(0, 0, 0), cnt: Float = 0
                for l in e.links.reversed() {
                    if l.flags & 4 != 0 { ropeLink(M, l, false); continue }
                    let R = Self.t(BW, e.bone)
                    let A = l.flags & 1 != 0 ? Self.trans(hm(h0(l.bone))) : Self.t(BW, l.bone)
                    let dv = A - R
                    let ln = Self.len3(dv)
                    let dr = V(dv.x / ln, dv.y / ln, dv.z / ln)
                    var Pp: V, dist: Float
                    if l.mind > 0 && l.mind > ln {
                        let ext = l.mind - ln
                        Pp = V(ext * dr.x + A.x, ext * dr.y + A.y, ext * dr.z + A.z); dist = l.mind
                    } else {
                        Pp = A; dist = ln
                    }
                    var perp = V(0, 0, 0)
                    if let h1 = map1[l.bone] {
                        let Q = Self.trans(hm(h1))
                        let vv = Q - Pp
                        let pr = (vv.y * dr.y + vv.x * dr.x) + vv.z * dr.z
                        perp = V(vv.x - dr.x * pr, vv.y - dr.y * pr, vv.z - dr.z * pr)
                    }
                    Self.setT(&BW, l.bone, Pp)
                    if dist >= l.maxd && l.flags & 2 == 0 {
                        // Stretched: lay the chain out straight.
                        var k = l.list.count - 1
                        while k > 0 {
                            let c_ = l.list[k], p_ = l.list[k - 1]
                            let Bc = Self.t(BW, c_), Dc = d(c_)
                            Self.setT(&BW, p_, V(Bc.x - Dc * dr.x, Bc.y - Dc * dr.y, Bc.z - Dc * dr.z))
                            k -= 1
                        }
                    } else {
                        let n = l.list.count
                        var r15 = n - 1
                        if r15 > 0 {
                            let px = perp.x, py = perp.y, pz = perp.z
                            let pp = (px * px + py * py) + pz * pz
                            var accLen: Float = 0
                            let cr = V(dr.y * pz - dr.z * py, dr.z * px - dr.x * pz, dr.x * py - dr.y * px)
                            let cc = (cr.x * cr.x + cr.y * cr.y) + cr.z * cr.z
                            let p2 = V(px + px, py + py, pz + pz)
                            while r15 > 0 {
                                let cur = l.list[r15], prv = l.list[r15 - 1]
                                let C = Self.t(BW, cur), Bp = Self.t(BW, prv)
                                var v = Bp - C
                                if r15 > 1 && pflags(prv) & 0x8000 != 0 {
                                    let l2 = Self.len3(v), inv = 1 / l2
                                    var vn = V(-(v.x * inv), -(v.y * inv), -(v.z * inv))
                                    vn = angleLimit(BW, prv, l, r15 - 1, vn)
                                    v = V(-vn.x, -vn.y, -vn.z)
                                }
                                let Dcur = d(cur)
                                var bend = true
                                if r15 != n - 1 { bend = (l.maxd * 0.5) > (accLen + Dcur) }
                                if bend {
                                    if pp > 0.01 {
                                        let inv = 1 / Self.sqrt(cc)
                                        let cn = V(cr.x * inv, cr.y * inv, cr.z * inv)
                                        let dd = (v.x * cn.x + v.y * cn.y) + v.z * cn.z
                                        v = V(v.x - dd * cn.x, v.y - dd * cn.y, v.z - dd * cn.z)
                                    }
                                    let sd = (v.x * px + v.y * py) + v.z * pz
                                    if 0 > sd { v = V(v.x - p2.x * sd, v.y - p2.y * sd, v.z - p2.z * sd) }
                                }
                                let lv = Self.len3(v), inv = 1 / lv
                                Self.setT(&BW, prv, V((v.x * inv) * Dcur + C.x, (v.y * inv) * Dcur + C.y, (v.z * inv) * Dcur + C.z))
                                accLen = accLen + Dcur
                                r15 -= 1
                            }
                        }
                    }
                    let Bt = Self.t(BW, e.bone)
                    acc = V(acc.x + Bt.x, acc.y + Bt.y, acc.z + Bt.z); cnt = cnt + 1
                }
                if cnt > 0 { Self.setT(&BW, e.bone, V(acc.x / cnt, acc.y / cnt, acc.z / cnt)) }
            }
            if pas == 0 {
                for h in ch.handles where h < handles.count {
                    let H = handles[h]
                    for c in H.constraints where c.flags & 0x10000 != 0 {
                        for e in ch.entries { for l in e.links where l.bone == H.bone { reachBend(&BW, c, l) } }
                    }
                }
            }
            var conv = true
            for e in ch.entries {
                for l in e.links {
                    if l.flags & 4 != 0 { ropeLink(M, l, true); continue }
                    let start = ch.bone == e.bone && parent(ch.bone) != -1 ? root0 : Self.t(BW, e.bone)
                    Self.setT(&BW, e.bone, start)
                    let n = l.list.count
                    if n > 1 {
                        for k in 0..<(n - 1) {
                            let a = Self.t(BW, l.list[k]), b = Self.t(BW, l.list[k + 1])
                            let v = b - a
                            let inv = 1 / Self.len3(v)
                            var vn = V(inv * v.x, inv * v.y, inv * v.z)
                            if k > 0 && pflags(l.list[k]) & 0x8000 != 0 { vn = angleLimit(BW, l.list[k], l, k, vn) }
                            let Dn = d(l.list[k + 1])
                            Self.setT(&BW, l.list[k + 1], V(Dn * vn.x + a.x, Dn * vn.y + a.y, Dn * vn.z + a.z))
                        }
                    }
                    if l.flags & 1 != 0 {
                        let hb = Self.t(BW, l.bone), hh = Self.trans(hm(h0(l.bone)))
                        let dd = hb - hh
                        if (dd.y * dd.y + dd.x * dd.x) + dd.z * dd.z > 0.1 { conv = false }
                    }
                }
            }
            if conv { break }
            pas += 1
            if pas >= iters { break }
        }
        // Rotation rebuild.
        for e in ch.entries {
            let nl = e.links.count, start = nl != 1 ? 1 : 0
            for l in e.links {
                let n = l.list.count
                if n - 1 > start {
                    for k in start..<(n - 1) {
                        let a = Self.t(BW, l.list[k]), b = Self.t(BW, l.list[k + 1])
                        let v = b - a
                        let inv = 1 / Self.len3(v)
                        let vn = V(inv * v.x, inv * v.y, inv * v.z)
                        let Rq = Self.quatToMatrix(Self.rotationBetween(dir(l.list[k], l.list[k + 1]), vn))
                        setRows(&BW, l.list[k], Self.rotApplyBind(Rq, bindM(l.list[k])))
                    }
                }
                if l.flags & 1 != 0 {
                    let lf = pflags(l.bone)
                    if lf & 0x100 != 0 {
                        if n > 2 { setRows(&BW, l.bone, Array(Self.mat(BW, l.list[n - 2])[0..<12])) }
                    } else {
                        let Hm = hm(h0(l.bone))
                        var rows = (0..<3).map { Self.normalize4Fast(Array(Hm[(4 * $0)..<(4 * $0 + 4)])) }
                        if lf & 0x40 != 0 {
                            let hb = Self.t(BW, l.bone), ht = Self.trans(Hm)
                            let dd = ht - hb
                            let dsq = (dd.x * dd.x + dd.y * dd.y) + dd.z * dd.z
                            if dsq > 1 {
                                let ln = Self.sqrt(dsq)
                                let ikrd = l.bone < bone.count ? bone[l.bone].ikrd : 1
                                var f = (ln - 1) / ikrd
                                if !(1 > f) { f = 1 }
                                let dn = V(dd.x / ln, dd.y / ln, dd.z / ln)
                                let q = Self.rotationBetween(V(1, 0, 0), dn)
                                let qh = Self.matrixToQuat(rows[0] + rows[1] + rows[2] + [0, 0, 0, 1])
                                let Rm = Self.quatToMatrix(Self.slerp2(qh, q, f))
                                rows = [Array(Rm[0..<4]), Array(Rm[4..<8]), Array(Rm[8..<12])]
                            }
                        }
                        setRows(&BW, l.bone, rows[0] + rows[1] + rows[2])
                    }
                }
            }
            if nl != 1 {
                var qa = Q(w: 1, x: 0, y: 0, z: 0)
                let t = 1 / Float(nl)
                for l in e.links where l.list.count > 1 {
                    let B = Self.t(BW, e.bone), c_ = Self.t(BW, l.list[1])
                    let v = c_ - B
                    let inv = 1 / Self.len3(v)
                    let vn = V(inv * v.x, inv * v.y, inv * v.z)
                    let q = Self.rotationBetween(dir(e.bone, l.list[1]), vn)
                    qa = Self.slerp2(qa, q, t)
                }
                setRows(&BW, e.bone, Self.rotApplyBind(Self.quatToMatrix(qa), bindM(e.bone)))
            }
        }
    }

    @inline(__always) private func bindM(_ b: Int) -> M16 { b < bind.count ? bind[b] : Self.IDENT }
    @inline(__always) private func setRows(_ BW: inout [Float], _ b: Int, _ r: [Float]) {
        for k in 0..<12 { BW[16 * b + k] = r[k] }
    }

    /// 0x14027257c–0x14027290e: bend joints so the chain reaches along the target's x axis.
    private func reachBend(_ BW: inout [Float], _ c: MdlFile.Constraint, _ l: MdlFile.IKLink) {
        let T = Self.mat(BW, c.b)
        let inv = 1 / Self.len4(T, 0)
        let dx = inv * T[0], dy = inv * T[1], dz = inv * T[2]
        let lst = l.list, n = lst.count
        guard n > 2 else { return }
        let B0 = Self.t(BW, lst[0])
        let d0 = Self.len3(T[12] - B0.x, T[13] - B0.y, T[14] - B0.z)
        var x9 = d0
        var r15 = 1, counter = 32
        while counter > 0 {
            x9 = x9 - d(lst[r15])
            if 0 > x9 { break }
            let a = Self.t(BW, lst[r15 - 1]), b = Self.t(BW, lst[r15 + 1])
            let ux = b.x - a.x, uy = b.y - a.y, uz = b.z - a.z
            let c1x = dz * uy - dy * uz, c1y = dx * uz - dz * ux, c1z = dy * ux - dx * uy
            let c2x = c1y * uz - c1z * uy, c2y = c1z * ux - c1x * uz, c2z = c1x * uy - c1y * ux
            let cc2 = (c2x * c2x + c2y * c2y) + c2z * c2z
            if !(0.01 > cc2) {
                let m = Self.t(BW, lst[r15])
                let iv = 1 / Self.sqrt(cc2)
                let cnx = iv * c2x, cny = iv * c2y, cnz = iv * c2z
                let sd = (cnx * (m.x - a.x) + cny * (m.y - a.y)) + (m.z - a.z) * cnz
                if sd > Self.FLT_EPS {
                    let tx = cnx * sd, ty = cny * sd, tz = cnz * sd
                    Self.setT(&BW, lst[r15], V(m.x - (tx + tx), m.y - (ty + ty), m.z - (tz + tz)))
                    x9 = d0; r15 = 1
                }
            }
            counter -= 1
            let cont = r15 + 2 < n
            r15 += 1
            if !cont { break }
        }
    }

    // MARK: Per-bone constraints (0x140200e20)

    /// Constraints of a bone without flags bit 1 (bone +0xd8): blend BW[i] toward BW[rec.b] (Euler rotation, row-length
    /// scale, translation) by weights[rec.a]. Record flags are ignored.
    func boneConstraints(_ BW: inout [Float], _ i: Int, _ recs: [MdlFile.Constraint]) {
        for r in recs where r.b >= 0 && 16 * r.b + 16 <= BW.count {
            let T = Self.mat(BW, r.b), wt = w(r.a), B = Self.mat(BW, i)
            var (bz, by, bx) = Self.eulerFromMatrix(B)
            var (tz, ty, tx) = Self.eulerFromMatrix(T)
            let sB = (0..<3).map { Self.len4(B, $0) }, sT = (0..<3).map { Self.len4(T, $0) }
            bx = Self.fmodf(bx, Self.TWO_PI); by = Self.fmodf(by, Self.TWO_PI); bz = Self.fmodf(bz, Self.TWO_PI)
            tx = Self.fmodf(tx, Self.TWO_PI); ty = Self.fmodf(ty, Self.TWO_PI); tz = Self.fmodf(tz, Self.TWO_PI)
            if tx - bx > Self.PI { tx = tx + -3.14159274 }
            if ty - by > Self.PI { ty = ty + -3.14159274 }
            if tz - bz > Self.PI { tz = tz - Self.PI }
            let w1 = 1 - wt
            let s = (0..<3).map { sB[$0] * w1 + sT[$0] * wt }
            let ex = bx * w1 + tx * wt, ey = by * w1 + ty * wt, ez = bz * w1 + tz * wt
            let R = Self.eulerToMatrix(ez, ey, ex)
            let pB = Self.trans(B), pT = Self.trans(T)
            var Tr = Self.IDENT
            Tr[12] = pB.x * w1 + pT.x * wt; Tr[13] = pB.y * w1 + pT.y * wt; Tr[14] = pB.z * w1 + pT.z * wt; Tr[15] = 1
            let out = Self.matmul(Tr, R)
            var res = out
            for r_ in 0..<3 { for c in 0..<4 { res[4 * r_ + c] = out[4 * r_ + c] * s[r_] } }
            Self.setMat(&BW, i, res)
        }
    }

    // MARK: Driver

    /// The three calls of `Puppet_Update` 0x14020365b–0x1402037a6 for the chain of bone i.
    func step(_ BW: inout [Float], chain ci: Int, layer M: M16, dt: Float, env: Environment) {
        guard ci >= 0 && ci < chains.count else { return }
        let ch = chains[ci]
        let dump = Self.debug && debugFrame < Self.debugFrames
        if dump { debugDump("in", BW, ci, M, dt, env) }
        prepare(&BW, ch)
        if ch.flags & 1 != 0 { rope(&BW, ch, M, dt, env) }
        solve(&BW, ch, M, iters: 10)
        if dump { debugDump("out", BW, ci, M, dt, env) }
    }

    /// PHOTON_IKDEBUG=1: one JSON line per IK step with every input/output the reference needs (raw float bits).
    private func debugDump(_ tag: String, _ BW: [Float], _ ci: Int, _ M: M16, _ dt: Float, _ env: Environment) {
        func bits(_ a: [Float]) -> String { "[" + a.map { String($0.bitPattern) }.joined(separator: ",") + "]" }
        var s = "{\"tag\":\"\(tag)\",\"frame\":\(debugFrame),\"chain\":\(ci),\"dt\":\(dt.bitPattern),\"M\":\(bits(M))"
        s += ",\"BW\":\(bits(BW)),\"HM\":\(bits(HM.flatMap { $0 })),\"weights\":\(bits(weights))"
        s += ",\"cur\":\(bits(state.flatMap { [$0.cur.x, $0.cur.y, $0.cur.z] })),\"prev\":\(bits(state.flatMap { [$0.prev.x, $0.prev.y, $0.prev.z] }))"
        s += ",\"init\":[\(state.map { $0.initialized ? "1" : "0" }.joined(separator: ","))]"
        s += ",\"bind\":\(bits(bind.flatMap { $0 }))"
        s += ",\"bones\":[" + bone.enumerated().map { i, p in
            "[\(boneParent[i]),\(p.flags),\(p.tf.bitPattern),\(p.m.bitPattern),\(p.ikrd.bitPattern),\(p.ikrmin.bitPattern),\(p.ikrmax.bitPattern)]"
        }.joined(separator: ",") + "]"
        s += ",\"env\":{\"wind\":\(env.windEnabled),\"width\":\(env.width.bitPattern),\"time\":\(env.time.bitPattern)"
        s += ",\"gd\":\(bits([env.gravityDirection.x, env.gravityDirection.y, env.gravityDirection.z])),\"gs\":\(env.gravityStrength.bitPattern)"
        s += ",\"wd\":\(bits([env.windDirection.x, env.windDirection.y, env.windDirection.z])),\"ws\":\(env.windStrength.bitPattern)}}"
        FileHandle.standardError.write(("IKDEBUG " + s + "\n").data(using: .utf8)!)
        if PuppetIK.debug, BW.count % 16 == 0, tag == "out" {
            var t = "IKDEBUG BW translations:"
            for b in 0..<(BW.count / 16) { t += String(format: " [%d](%.6g, %.6g, %.6g)", b, BW[16 * b + 12], BW[16 * b + 13], BW[16 * b + 14]) }
            FileHandle.standardError.write((t + "\n").data(using: .utf8)!)
        }
    }

    // MARK: Conversions

    /// Column-vector simd matrix ↔ the engine's row-major row-vector layout (row j = column j).
    static func rows(_ m: simd_float4x4) -> M16 {
        [m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w, m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
         m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w, m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w]
    }
    static func simd(_ a: [Float], _ o: Int = 0) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(a[o], a[o + 1], a[o + 2], a[o + 3]), SIMD4(a[o + 4], a[o + 5], a[o + 6], a[o + 7]),
                                SIMD4(a[o + 8], a[o + 9], a[o + 10], a[o + 11]), SIMD4(a[o + 12], a[o + 13], a[o + 14], a[o + 15])))
    }

    /// P+0x2e0 from the handle pose P+0x248 (0x140200520–0x140200654): quaternion matrix (0x140215200) with row 3 =
    /// (p, 1); the pose scale is not used.
    static func handleMatrix(p: SIMD3<Float>, q: simd_quatf) -> M16 {
        var m = quatToMatrix(Q(w: q.real, x: q.imag.x, y: q.imag.y, z: q.imag.z))
        m[12] = p.x; m[13] = p.y; m[14] = p.z; m[15] = 1
        return m
    }
}
