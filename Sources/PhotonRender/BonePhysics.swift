import PhotonCore
import Foundation
import simd

/// Per-bone secondary motion ("bone physics"), decoded from the inlined step in `Puppet_Update` 0x1401fdf90
/// (0x14020136e–0x14020364e; a second copy for the no-visible-layer path at 0x140203c32) and the parameter
/// parser `BonePhysics_Parse` 0x140265c30. docs/re/06 §6.7.
///
/// The engine works in row-vector matrices. Here a row-vector 3×3 is kept as its three rows, so
/// `v × M = v.x·M[0] + v.y·M[1] + v.z·M[2]`, which keeps the formulas identical to the listing.
struct BonePhysics {
    /// Bone record +0x68: `se` 1, `re` 2, `ge` 4, `la` 8, `lt` 0x10, `r` 0x1000, `t` 0x2000, `ik` 0x4000,
    /// axis-disable bits 0x100000/0x200000/0x400000 (`rax/ray/raz` false) and 0x800000/0x1000000/0x2000000 (`tax..taz`).
    var flags: UInt32 = 0
    var rs: Float = 0          // +0x6c rotation spring stiffness
    var ts: Float = 0          // +0x70 translation spring stiffness
    var rf: Float = 0          // +0x74 rotation friction
    var tf: Float = 0          // +0x78 translation friction (raw for physics bones; IK-only bones store min((tf/100)², 1))
    var ri: Float = 1          // +0x7c = 1 − ri/100
    var ti: Float = 1          // +0x80 = 1 − ti/100
    var gd = SIMD3<Float>(0, 0, 0) // +0x84 gravity direction
    var m: Float = 1000        // +0x90 mass (bone ctor default 1000.0, 0x14026b8ef)
    var tp = SIMD3<Float>(0, 0, 0) // +0x94 tip point, bone-local
    var tm: Float = 0          // +0xa4 translation limit
    var lamin = SIMD3<Float>(0, 0, 0), lamax = SIMD3<Float>(0, 0, 0) // +0xa8 / +0xb4, radians
    var ltmax: Float = 0       // +0xc0 twist limit, degrees

    var enabled: Bool { flags & 0x3000 != 0 }

    /// `BonePhysics_Parse` 0x140265c30. Returns nil unless the bone passes the enable rule
    /// `((flags & 0x3000) && (flags & 3)) || (flags & 0x4000)` (0x140265f0b) with physics (`r`/`t`) on.
    init?(json text: String) {
        guard !text.isEmpty, let d = text.data(using: .utf8),
              let j = parseEngineJSON(d) as? [String: Any] else { return nil }
        func isBool(_ v: Any?) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
        func bool(_ k: String) -> Bool { isBool(j[k]) && (j[k] as! NSNumber).boolValue }
        func num(_ k: String) -> Float? {
            guard let n = j[k] as? NSNumber, !isBool(n) else { return nil }
            return n.floatValue
        }
        // "x y z" strings read with strtod, space separated (0x14026602e–0x1402660e5); missing parts stay 0.
        func vec(_ k: String) -> SIMD3<Float>? {
            guard let s = j[k] as? String else { return nil }
            let p = s.split(separator: " ", omittingEmptySubsequences: true).map { Float($0) ?? 0 }
            return SIMD3(p.count > 0 ? p[0] : 0, p.count > 1 ? p[1] : 0, p.count > 2 ? p[2] : 0)
        }
        if bool("ik") { flags |= 0x4000 }
        if bool("ikce") { flags |= 0x8000 }
        if bool("r") { flags |= 0x1000 }
        if bool("t") { flags |= 0x2000 }
        if bool("se") { flags |= 1 }
        if bool("re") { flags |= 2 }
        let physics = flags & 0x3000 != 0 && flags & 3 != 0
        guard physics || flags & 0x4000 != 0 else { return nil }
        if bool("ge") { flags |= 4 }
        if let v = vec("gd") { gd = v }
        if let v = num("m") { m = v }
        if let v = num("tf") { tf = v }
        guard physics else {
            tf = tf / 100 * (tf / 100); tf = tf < 1 ? max(tf, 0) : 1   // 0x140266195–0x1402661c2
            return nil   // IK-only bones carry no secondary motion here
        }
        if let v = num("rs") { rs = v }
        if let v = num("ts") { ts = v }
        if let v = num("rf") { rf = v }
        if let v = vec("tp") { tp = v }
        if let v = num("tm") { tm = v }
        if let v = num("ri") { ri = 1 - v / 100 }
        if let v = num("ti") { ti = 1 - v / 100 }
        // `la` must be the JSON literal true (type word 0xa, 0x140266ab2).
        if bool("la") {
            flags |= 8
            if let v = vec("lamin") { lamin = v }
            if let v = vec("lamax") { lamax = v }
        }
        if bool("lt") { flags |= 0x10 }
        if let v = num("ltmax") { ltmax = v }
        // All three axis keys must be present and boolean; each false one sets its disable bit.
        if isBool(j["rax"]), isBool(j["ray"]), isBool(j["raz"]) {
            if !bool("rax") { flags |= 0x100000 }
            if !bool("ray") { flags |= 0x200000 }
            if !bool("raz") { flags |= 0x400000 }
        }
        if isBool(j["tax"]), isBool(j["tay"]), isBool(j["taz"]) {
            if !bool("tax") { flags |= 0x800000 }
            if !bool("tay") { flags |= 0x1000000 }
            if !bool("taz") { flags |= 0x2000000 }
        }
    }

    /// The IK fields of the bone record that `BonePhysics_Parse` 0x140265c30 fills: +0x68 flags (`ge` 4, `ikg` 0x20,
    /// `ikr` 0x40, `ikse` 0x80, `ikfe` 0x100, `ik` 0x4000, `ikce` 0x8000), +0x78 tf, +0x90 m, +0xc8 ikrd, +0xcc/+0xd0
    /// ikrminl/ikrmaxl (radians, read only for bones with neither physics nor `ik`, 0x140266475).
    struct IKParams {
        var flags: UInt32 = 0
        var tf: Float = 0
        var m: Float = 1000
        var ikrd: Float = 1
        var ikrmin: Float = 0
        var ikrmax: Float = 0
    }

    static func ikParams(json text: String) -> IKParams {
        var p = IKParams()
        guard !text.isEmpty, let d = text.data(using: .utf8),
              let j = parseEngineJSON(d) as? [String: Any] else { return p }
        func isBool(_ v: Any?) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
        func bool(_ k: String) -> Bool { isBool(j[k]) && (j[k] as! NSNumber).boolValue }
        func num(_ k: String) -> Float? {
            guard let n = j[k] as? NSNumber, !isBool(n) else { return nil }
            return n.floatValue
        }
        var f: UInt32 = 0
        if bool("ik") { f |= 0x4000 }
        if bool("ikce") { f |= 0x8000 }
        if bool("se") { f |= 1 }
        if bool("re") { f |= 2 }
        if bool("r") { f |= 0x1000 }
        if bool("t") { f |= 0x2000 }
        let physics = f & 0x3000 != 0 && f & 3 != 0
        if physics || f & 0x4000 != 0 {
            if bool("ge") { f |= 4 }
            if let v = num("m") { p.m = v }
            if let v = num("tf") { p.tf = v }
            if !physics {
                var t = p.tf / 100; t = t * t
                p.tf = 1 > t ? (0 > t ? 0 : min(t, 1)) : min(t, 1)   // 0x140266195–0x1402661c2
                if bool("ikg") { f |= 0x20 }
                if bool("ikr") {
                    f |= 0x40
                    if let v = num("ikrd") { p.ikrd = v > 1 ? v : 1 }
                }
                if bool("ikse") { f |= 0x80 }
                if bool("ikfe") { f |= 0x100 }
            }
        } else if f & 0x8000 != 0 {
            if let v = num("ikrminl") { p.ikrmin = v }
            if let v = num("ikrmaxl") { p.ikrmax = v }
        } else {
            f = 0
        }
        p.flags = f
        return p
    }

    /// Puppet +0x3b8, 0x50 bytes per bone; default (resize 0x140215ba0): q = (1,0,0,0), everything else 0.
    struct State {
        var q = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)   // +0x00 angular velocity per 1/60 s
        var e = SIMD3<Float>(0, 0, 0)                     // +0x10 rotation offset, Euler radians
        var p = SIMD3<Float>(0, 0, 0)                     // +0x1c translation offset (scene space)
        var w = SIMD3<Float>(0, 0, 0)                     // +0x28 translation velocity
    }

    typealias Rows = (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)

    static func mul(_ v: SIMD3<Float>, _ m: Rows) -> SIMD3<Float> { v.x * m.0 + v.y * m.1 + v.z * m.2 }

    /// Euler → row-vector rotation matrix, built inline at 0x140201623–0x14020182a. `v × R(e)` rotates v by
    /// q = qZ·qY·qX (the same convention as the animation tracks).
    static func eulerRows(_ e: SIMD3<Float>) -> Rows {
        let cx = cos(e.x), sx = sin(e.x), cy = cos(e.y), sy = sin(e.y), cz = cos(e.z), sz = sin(e.z)
        return (SIMD3(cy * cz, cy * sz, -sy),
                SIMD3(sx * sy * cz - cx * sz, sx * sy * sz + cx * cz, sx * cy),
                SIMD3(cx * sy * cz + sx * sz, cx * sy * sz - sx * cz, cx * cy))
    }

    /// Row-vector matrix → Euler (0x140201e04–0x140201fe2): z = atan2(M01, M00), y = atan2(−M02, √(M12² + M22²)),
    /// x = atan2(sin z·M20 − cos z·M21, cos z·M11 − sin z·M10).
    static func euler(_ M: Rows) -> SIMD3<Float> {
        let z = atan2(M.0.y, M.0.x)
        let y = atan2(-M.0.z, (M.1.z * M.1.z + M.2.z * M.2.z).squareRoot())
        let s = sin(z), c = cos(z)
        let x = atan2(s * M.2.x - c * M.2.y, c * M.1.y - s * M.1.x)
        return SIMD3(x, y, z)
    }

    /// Row-vector matrix of a quaternion (0x140216280): row k = q rotating axis k.
    static func rows(_ q: simd_quatf) -> Rows {
        (q.act(SIMD3(1, 0, 0)), q.act(SIMD3(0, 1, 0)), q.act(SIMD3(0, 0, 1)))
    }

    /// Euler → quaternion with half angles (0x1402020b4–0x140202191): qZ·qY·qX.
    static func quat(_ e: SIMD3<Float>) -> simd_quatf {
        let h = e * 0.5
        let cx = cos(h.x), sx = sin(h.x), cy = cos(h.y), sy = sin(h.y), cz = cos(h.z), sz = sin(h.z)
        return simd_quatf(ix: sx * cy * cz - cx * sy * sz, iy: cx * sy * cz + sx * cy * sz,
                          iz: cx * cy * sz - sx * sy * cz, r: cx * cy * cz + sx * sy * sz)
    }

    /// 0x140216070: slerp with hemisphere flip on b; plain lerp (no renormalisation) when cos > 0.99999.
    static func slerp(_ a: simd_quatf, _ b: simd_quatf, _ t: Float) -> simd_quatf {
        var bv = b.vector
        var c = simd_dot(a.vector, bv)
        if c < 0 { bv = -bv; c = -c }
        if c > 0.99999 { return simd_quatf(vector: a.vector * (1 - t) + bv * t) }
        let th = acos(c), s = sin(th)
        return simd_quatf(vector: (a.vector * sin((1 - t) * th) + bv * sin(t * th)) / s)
    }

    /// 0x1402167c0: shortest rotation taking unit vector a onto unit vector b (float32 order of the binary, see
    /// `PuppetIK.rotationBetween`).
    static func rotation(from a: SIMD3<Float>, to b: SIMD3<Float>) -> simd_quatf {
        let q = PuppetIK.rotationBetween(a, b)
        return simd_quatf(ix: q.x, iy: q.y, iz: q.z, r: q.w)
    }

    static func normalize4(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let l = simd_length(v)
        return l > 0 ? v / l : v    // sqrtps/divps: 0-length gives NaN in the engine; keep 0 here
    }

    /// `lt`: clamp each twist component to ±ltmax degrees (0x140201a94–0x140201b98).
    static func limitTwist(_ q: inout simd_quatf, _ ltmax: Float) {
        let w = q.real
        var v = q.imag / w
        for k in 0..<3 {
            let a = min(max(2 * atan(v[k]) * 57.2958, -ltmax), ltmax)
            v[k] = tan(a * 0.0174533 * 0.5)
        }
        let n = simd_length(SIMD4(v, 1))
        q = n > 0 ? simd_quatf(vector: SIMD4(v, 1) / n) : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    }

    /// One step for one bone. `L` = this frame's animated bone matrix in layer space (puppet +0x340: bone world ×
    /// layer world, row-vector), `B` = last frame's final +0x340 (the +0x340/+0x348 swap at 0x1402003f0). Both are
    /// column-vector simd matrices here. Returns the row-vector offset O (rows: R(e) and the local translation offset)
    /// as a column-vector matrix to post-multiply the model-space bone world with: world' = world · O.
    func step(_ s: inout State, L: simd_float4x4, B: simd_float4x4, dt: Float, avgScale: Float) -> simd_float4x4 {
        let I = identityQ
        // Columns 0..2 of the column-vector matrix are the rows of the engine's row-vector matrix.
        let A = simd_float3x3(SIMD3(L.columns.0.x, L.columns.0.y, L.columns.0.z),
                              SIMD3(L.columns.1.x, L.columns.1.y, L.columns.1.z),
                              SIMD3(L.columns.2.x, L.columns.2.y, L.columns.2.z))
        let Ainv = A.inverse   // v × inverse(L3×3), built from row cross products / det at 0x140201446
        let Lt = SIMD3(L.columns.3.x, L.columns.3.y, L.columns.3.z)
        let Bt = SIMD3(B.columns.3.x, B.columns.3.y, B.columns.3.z)
        let rowsL: Rows = (A.columns.0, A.columns.1, A.columns.2)
        // D: last frame's tip, relative to the current bone origin, in the bone frame.
        let tipB = B * SIMD4(tp, 1)
        let D = Ainv * (SIMD3(tipB.x, tipB.y, tipB.z) - Lt)
        let Dn = Self.normalize4(D)
        var V = Ainv * s.p
        let T0 = Self.mul(tp, Self.eulerRows(s.e))
        var T = T0 + V
        var W = s.w
        if flags & 4 != 0 {   // ge (0x14020185d)
            let g = (Ainv * gd) * (m * avgScale)
            let n = Self.normalize4(T0)
            T -= g - n * simd_dot(n, g)
            if flags & 0x2000 != 0 { W += gd * (m * dt * 1000) }   // 0x14020192f
        }
        let dist = min(simd_length(T - D), 900 * dt)   // [rsp+0x68] = 900·dt (0x140200692)
        let qd = Self.rotation(from: Self.normalize4(T), to: Dn)
        let frames = min(dt / 0.0166667, 1)
        let re = flags & 2 != 0, se = flags & 1 != 0, rot = flags & 0x1000 != 0, trans = flags & 0x2000 != 0
        var P = s.p
        if (re || se) && rot {
            s.q = s.q * Self.slerp(I, qd, min(dist * ri * 0.0174533, 1))
            if !re {   // se: spring back toward e = 0 (0x140202aa4–0x140202bee)
                s.q = s.q * Self.slerp(I, Self.quat(-s.e), min(rs * 0.0174533 * dt, 1))
            }
            if flags & 0x10 != 0 { Self.limitTwist(&s.q, ltmax) }
            let qf = Self.slerp(I, s.q, frames)
            let R = Self.eulerRows(s.e)
            let Q = Self.rows(qf)
            s.e = Self.euler((Self.mul(R.0, Q), Self.mul(R.1, Q), Self.mul(R.2, Q)))
            if !re {   // se: zero disabled axes, wrap the rest into [−π, π) (0x1402031b4–0x140203273)
                for k in 0..<3 {
                    if flags & (0x100000 << UInt32(k)) != 0 { s.e[k] = 0; continue }
                    let a = s.e[k]
                    s.e[k] = a < 0 ? fmodf(a - .pi, 2 * .pi) + .pi : fmodf(a + .pi, 2 * .pi) - .pi
                }
            }
            if flags & 8 != 0 {   // la: clamp, and take the clamped excess out of the velocity
                let old = s.e
                s.e = simd_min(simd_max(s.e, lamin), lamax)
                s.q = Self.quat(old - s.e).conjugate * s.q
            }
            if re {   // re: zero disabled axes after the limit (0x1402021c7)
                for k in 0..<3 where flags & (0x100000 << UInt32(k)) != 0 { s.e[k] = 0 }
            }
            s.q = Self.slerp(s.q, I, min(dt * rf, 1))   // rotation friction (0x1402021f4 / 0x140203448)
        }
        if trans && (re || se) {
            P = P - (P + Lt - Bt) * ti
            if se { W -= P * (dt * ts) }                  // 0x1402034ca
            P += W * dt
            for k in 0..<3 where flags & (0x800000 << UInt32(k)) != 0 {
                let a = k == 0 ? rowsL.0 : k == 1 ? rowsL.1 : rowsL.2
                P -= a * (simd_dot(P, a) / simd_dot(a, a))
            }
            let lim = avgScale * tm
            if lim > 0, lim * lim < simd_length_squared(P) { P *= lim / simd_length(P) }
            W -= W * min(dt * tf, 1)
        }
        if trans {
            s.p = P; s.w = W
            V = Ainv * P
        }
        let R = Self.eulerRows(s.e)
        return simd_float4x4(columns: (SIMD4(R.0, 0), SIMD4(R.1, 0), SIMD4(R.2, 0), SIMD4(V, 1)))
    }

    private var identityQ: simd_quatf { simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
}
