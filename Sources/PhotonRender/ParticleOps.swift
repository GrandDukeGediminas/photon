import Foundation
import PhotonCore
import simd

// Operator interpreter `0x14023fbc0` (docs/re/05 Part 3 §2–§3). Ops run in JSON order over every live
// slot. (The engine also runs them over dead slots; nothing of a dead slot is ever drawn, so they are
// skipped here.) `t` is the life fraction and `R` the per-particle random value.

extension ParticleInstance {
    func runOperators(_ dt: Float, _ dt2: Float) {
        guard PDump.want("ops\(def.path)") else { return runOperatorsBody(dt, dt2) }
        let n4 = (highWater + 3) & ~3
        let before = pdumpState(n4)
        runOperatorsBody(dt, dt2)
        PDump.write(["kind": "ops", "def": def.path, "before": before, "after": pdumpState(n4), "dt": dt.bitPattern,
                     "dt2": dt2.bitPattern, "frametime": frame.frameTime.bitPattern, "flags": Int(flags),
                     "scales": PDump.bits([scales.count, scales.speed, scales.lifetime, scales.size, scales.rate]),
                     "colorActive": scales.colorActive, "audio": host.audioBands.isEmpty ? 0 : 1, "frame": host.frameCounter])
    }

    func runOperatorsBody(_ dt: Float, _ dt2: Float) {
        let n = highWater
        // Prologue: base → working copies.
        for i in 0..<n {
            size[i] = size0[i]
            color[i] = color0[i]
        }
        let sc = scales
        let fr = frame
        for (opIndex, op) in def.operators.enumerated() {
            switch op {
            case let .movement(gravity, drag, mflags):
                var g = gravity * sc.speed
                if mflags & 1 != 0 && !worldSpace {
                    // World-space gravity into the system's local space (row-vector × M3 of the owner).
                    let m = top.m3
                    let r = simd_float3x3(simd_normalize(m.columns.0), simd_normalize(m.columns.1), simd_normalize(m.columns.2))
                    g = r.transpose * g
                }
                let k = min(drag * dt2, 1)
                let copyPrev = def.mask & 4 != 0
                for i in 0..<n where life[i] != 0 {
                    if copyPrev { prevPos[i] = pos[i] }
                    let v = vel[i] + g * dt
                    pos[i] += v * dt
                    vel[i] = v * (1 - k)
                }
            case let .angularMovement(force, drag, blend):
                let f = force * sc.speed
                let kd = min(drag * dt2, 1)
                for i in 0..<n where life[i] != 0 {
                    let b = blend.factor(age[i] * SSEApprox.rcp(life[i]))
                    angVel[i] += f * dt * b
                    rot[i] += (b * dt) * angVel[i] // 0x14024020a: (blend·dt)·av' + rot (variant 28)
                    angVel[i] *= 1 - b * kd
                }
            case let .alphaFade(fin, fout):
                // 0x14024029d: t = rcp(life)·age; in = t < fin → t·rcp(fin); out = fout < t → (1 − t)·rcp(1 − fout); else 1.
                // Both masks set (fin > fout) ORs the two products bitwise (andps/orps, no select).
                let rin = SSEApprox.rcp(fin), rout = SSEApprox.rcp(1 - fout) // rcpps 0x1402402b4 / 0x1402402c7
                for i in 0..<n where life[i] != 0 {
                    let t = SSEApprox.rcp(life[i]) * age[i] // rcpps 0x1402402e0
                    let isIn = t < fin, isOut = fout < t
                    var bits: UInt32 = isIn || isOut ? 0 : Float(1).bitPattern
                    if isIn { bits |= (t * rin).bitPattern }
                    if isOut { bits |= ((1 - t) * rout).bitPattern }
                    color[i].w *= Float(bitPattern: bits)
                }
            case let .sizeChange(c):
                // Record type 7 binds start/end to the size override (§5.3).
                let sv = c.sv * sc.size, ev = c.ev * sc.size
                for i in 0..<n where life[i] != 0 {
                    size[i] *= sv + (ev - sv) * clamp01((age[i] * SSEApprox.rcp(life[i]) - c.st) * c.rcp)
                }
            case let .alphaChange(c):
                for i in 0..<n where life[i] != 0 {
                    color[i].w *= c.sv + (c.ev - c.sv) * clamp01((age[i] * SSEApprox.rcp(life[i]) - c.st) * c.rcp)
                }
            case let .colorChange(start, end, st, rcp):
                let s = sc.shift(start), d = sc.shift(end) - s
                for i in 0..<n where life[i] != 0 {
                    let m = s + d * clamp01((age[i] * SSEApprox.rcp(life[i]) - st) * rcp)
                    color[i].x *= m.x; color[i].y *= m.y; color[i].z *= m.z
                }
            case let .oscillatePosition(mask, fMin, fMax, phMin, phMax, sMin, sMax, blend):
                // Type-7 speed record: f0 = min·ov, df = max·ov − min·ov. sin is the inlined Cephes sinps (PNoise.sinPS).
                let f0 = fMin * sc.speed, df = fMax * sc.speed - f0
                for i in 0..<n where life[i] != 0 {
                    let R = rnd[i]
                    let f = f0 + R * df, ph = phMin + R * (phMax - phMin)
                    let s = (sMin + R * (sMax - sMin)) * blend.factor(age[i] * SSEApprox.rcp(life[i]))
                    let a = age[i] + ph
                    let d1 = s * (PNoise.sinPS(f * a) - PNoise.sinPS(f * (a - dt)))
                    let b = a + R * pTwoPi // splat 0x40c90fdb (0x14024070f)
                    let d2 = s * (PNoise.sinPS(f * b) - PNoise.sinPS(f * (b - dt)))
                    pos[i] += SIMD3(mask.x * d1, mask.y * d2, mask.z * d1)
                }
            case let .oscillateAlpha(o), let .oscillateSize(o):
                var isAlpha = false
                if case .oscillateAlpha = op { isAlpha = true }
                // 0x140240f17 / 0x14024123a (ops 8/9): x = ((R·phR + phMin) + age)·(R·fR + fMin); A = R·(sR·0.5);
                // m = (sin x + 1)·A + sMin. Variants 30 (alpha, 0x140241080): m = 1 − ((1 − sMin) − (sin x + 1)·A)·b;
                // 31 (size, 0x1402413a0): m = ((sin x + 1)·A + (sMin − 1))·b + 1.
                let phR = o.phMax - o.phMin, fR = o.fMax - o.fMin, hsR = (o.sMax - o.sMin) * 0.5
                for i in 0..<n where life[i] != 0 {
                    let R = rnd[i]
                    let x = ((R * phR + o.phMin) + age[i]) * (R * fR + o.fMin)
                    let sA = (PNoise.sinPS(x) + 1) * (R * hsR)
                    let m: Float
                    if o.blend.active {
                        let b = o.blend.factor(SSEApprox.rcp(life[i]) * age[i])
                        m = isAlpha ? 1 - ((1 - o.sMin) - sA) * b : (sA + (o.sMin - 1)) * b + 1
                    } else {
                        m = sA + o.sMin
                    }
                    if isAlpha { color[i].w *= m } else { size[i] *= m }
                }
            case let .cpAttract(scale, threshold, del2, cpi, aflags, _):
                // 0x140241554: K = dt2·scale' (type-5 speed record), u = rcp(threshold); FLT_MIN < r < threshold:
                // k = (1 − r·u)·K, flags & 2 → k = r when r < k; vel −= (rcp(r)·d)·k. The parser never parses a life-blend
                // block for this op (no call to 0x1401c2a40), so the variant 32 is unreachable. Delete test 0x14022a150.
                let C = cps[cpi].world.translation
                let K = dt2 * (scale * sc.speed), u = SSEApprox.rcp(threshold) // rcpps 0x140241564
                for i in 0..<n where life[i] != 0 {
                    let d = pos[i] - C
                    let r = sqrtf((d.z * d.z + d.y * d.y) + d.x * d.x) // 0x14024166f: (dz² + dy²) + dx²
                    if Float.leastNormalMagnitude < r && r < threshold {
                        var k = (1 - r * u) * K
                        if aflags & 2 != 0 && r < k { k = r }
                        let ir = SSEApprox.rcp(r) // rcpps 0x14024168a
                        let v = vel[i]
                        vel[i] = SIMD3(v.x - (ir * d.x) * k, v.y - (ir * d.y) * k, v.z - (ir * d.z) * k)
                    }
                }
                if aflags & 1 != 0 {
                    for i in 0..<n where life[i] != 0 {
                        let a = prevPos[i], ab = pos[i] - a
                        let L = sqrtf((ab.z * ab.z + ab.y * ab.y) + ab.x * ab.x)
                        let ui: Float = 0 < L ? SSEApprox.rcp(L) : 1 // rcpps 0x14022a249
                        let dir = SIMD3(ui * ab.x, ui * ab.y, ui * ab.z)
                        let proj = ((C.z - a.z) * dir.z + (C.y - a.y) * dir.y) + (C.x - a.x) * dir.x
                        var t: Float = 0 <= proj ? proj : 0
                        if !(t <= L) { t = L }
                        let q = SIMD3(t * dir.x + a.x, t * dir.y + a.y, t * dir.z + a.z)
                        let e = C - q
                        let d2 = (e.z * e.z + e.y * e.y) + e.x * e.x
                        if !(del2 < d2) { age[i] = life[i] }
                    }
                }
            case let .maintainDistanceToCP(distance, variable, cpi, blend):
                // 0x14024197a (op 11) / 0x140241ccf (variant 33): D = C − Cprev; R = glm::inverse(world 3×3) (0x140228b00);
                // p' = p + D; d = p' − C; q = R·d summed (dy·R1 + dx·R0) + dz·R2; rs = rsqrt((qx² + qy²) + qz²);
                // p = ((rs·distance − 1)·s [·blend])·d + p'. No |q| = 0 guard (rsqrt(0) = inf, NaN position) as in the engine.
                let s: Float = variable == 0 ? 1 : clamp01(variable * dt)
                let C = cps[cpi].world.translation
                let D = C - cps[cpi].prev.translation
                let (R0, R1, R2) = PMat.inverse3(cps[cpi].world)
                for i in 0..<n where life[i] != 0 {
                    let p = SIMD3(D.x + pos[i].x, D.y + pos[i].y, D.z + pos[i].z)
                    let d = SIMD3(p.x - C.x, p.y - C.y, p.z - C.z)
                    let qx = (d.y * R1.x + d.x * R0.x) + d.z * R2.x
                    let qy = (d.y * R1.y + d.x * R0.y) + d.z * R2.y
                    let qz = (d.y * R1.z + d.x * R0.z) + d.z * R2.z
                    let rs = SSEApprox.rsqrt((qx * qx + qy * qy) + qz * qz) // rsqrtps 0x140241c68 / 0x140242000
                    var k = (rs * distance - 1) * s
                    if blend.active { k *= blend.factor(SSEApprox.rcp(life[i]) * age[i]) }
                    pos[i] = SIMD3(k * d.x + p.x, k * d.y + p.y, k * d.z + p.z)
                }
            case let .maintainDistanceBetweenCPs(si, ei, blend):
                // 0x140242058 (op 12) / 0x140242352 (variant 34): e = B − A, f = B0 − A0 (current / previous CP translations);
                // both (y² + x²) + z² must exceed 2⁻⁴⁶; rs = rsqrt(|e|²), rs0 = rsqrt(|f|²); n = rs·e, L = rs·|e|², u0 = rs0·f;
                // tp = ((py − A0y)·u0y + (px − A0x)·u0x) + (pz − A0z)·u0z; F = clamp01(tp·rs0)·L;
                // p += (((F·n − tp·u0) + (A − A0)) [·blend]).
                let A = cps[si].world.translation, B = cps[ei].world.translation
                let A0 = cps[si].prev.translation, B0 = cps[ei].prev.translation
                let e = B - A, f = B0 - A0
                let el2 = (e.y * e.y + e.x * e.x) + e.z * e.z, fl2 = (f.y * f.y + f.x * f.x) + f.z * f.z
                let lim = Float(bitPattern: 0x2980_0000) // 2⁻⁴⁶ (0x1404925d4)
                guard el2 > lim, fl2 > lim else { break }
                let rs = SSEApprox.rsqrt(el2), rs0 = SSEApprox.rsqrt(fl2) // rsqrtps 0x14024222d / 0x140242231
                let L = rs * el2, nn = SIMD3(rs * e.x, rs * e.y, rs * e.z), u0 = SIMD3(rs0 * f.x, rs0 * f.y, rs0 * f.z)
                let dA = SIMD3(A.x - A0.x, A.y - A0.y, A.z - A0.z)
                for i in 0..<n where life[i] != 0 {
                    let p = pos[i]
                    let tp = ((p.y - A0.y) * u0.y + (p.x - A0.x) * u0.x) + (p.z - A0.z) * u0.z
                    let F = sseClamp01(tp * rs0) * L
                    var m = SIMD3((F * nn.x - tp * u0.x) + dA.x, (F * nn.y - tp * u0.y) + dA.y, (F * nn.z - tp * u0.z) + dA.z)
                    if blend.active {
                        let b = blend.factor(SSEApprox.rcp(life[i]) * age[i])
                        m = SIMD3(m.x * b, m.y * b, m.z * b)
                    }
                    pos[i] = SIMD3(m.x + p.x, m.y + p.y, m.z + p.z)
                }
            case let .reduceMovementNearCP(inner, rcp, redIn, redOut, cpi, blend):
                // 0x14024268f (op 13) / 0x1402427b8 (variant 35): r = rsqrt(l²)·l² with l² = (dy² + dx²) + dz²;
                // k = clamp01((clamp01((r − inner)·rcp)·(out − in) + in)·dt) [·blend]; v *= 1 − k.
                let C = cps[cpi].world.translation
                let dRed = redOut - redIn
                for i in 0..<n where life[i] != 0 {
                    let d = pos[i] - C
                    let l2 = (d.y * d.y + d.x * d.x) + d.z * d.z
                    let r = SSEApprox.rsqrt(l2) * l2 // rsqrtps 0x140242749 / 0x1402428e4
                    let f = sseClamp01((r - inner) * rcp)
                    var k = sseClamp01((f * dRed + redIn) * dt)
                    if blend.active { k *= blend.factor(SSEApprox.rcp(life[i]) * age[i]) }
                    vel[i] *= 1 - k
                }
            case let .turbulence(t):
                // 0x14024295a: T = time·timescale' (type-2 rate record); o = R·phaseRange + T; P = (p + o)·scale;
                // spd = R·(ds'·a) + s0'·a; vel.k += (N·(dt2·mask.k))·spd with N = noise3 over the permuted axes. No life
                // blend is parsed for this op (variant 36 unreachable).
                let T = fr.time * (t.timescale * sc.rate)
                let audio = t.audio.mode != 0 ? t.audio.response(host.audioBands) : 1
                let s0 = t.speedMin * sc.speed, ds = t.speedMax * sc.speed - s0
                let sa = s0 * audio, da = ds * audio
                let mx = dt2 * t.mask.x, my = dt2 * t.mask.y, mz = dt2 * t.mask.z
                for i in 0..<n where life[i] != 0 {
                    let R = rnd[i]
                    let o = R * t.phaseRange + T
                    let p = pos[i]
                    let P = SIMD3((o + p.x) * t.scale, (o + p.y) * t.scale, (o + p.z) * t.scale)
                    let spd = R * da + sa
                    if t.axisBits & 1 != 0 { vel[i].x = (Simplex.noise3(P.x, P.y, P.z) * mx) * spd + vel[i].x }
                    if t.axisBits & 2 != 0 { vel[i].y = (Simplex.noise3(P.z, P.x, P.y) * my) * spd + vel[i].y }
                    if t.axisBits & 4 != 0 { vel[i].z = (Simplex.noise3(P.y, P.z, P.x) * mz) * spd + vel[i].z }
                }
            case let .vortex(v):
                // 0x1402431be: C = cp + offset; t = ((dy·Ay + dx·Ax) + dz·Az) when flags & 1; d −= t·A; rq = rsqrt(|d|²),
                // n = rq·d, r = rq·|d|²; f = clamp01((r − inner)·rcp); spd = f·(ds'·a·dt2) + si'·a·dt2; vel += cross(n, A)·spd.
                // No life blend for this op.
                let C = cps[v.cp].world.translation + v.offset
                let audio = v.audio.mode != 0 ? v.audio.response(host.audioBands) : 1
                let si0 = v.speedInner * sc.speed, ds0 = v.speedOuter * sc.speed - si0
                let si = (si0 * audio) * dt2, ds = (ds0 * audio) * dt2
                let A = v.axis
                for i in 0..<n where life[i] != 0 {
                    var d = pos[i] - C
                    if v.flags & 1 != 0 {
                        let t = (d.y * A.y + d.x * A.x) + d.z * A.z
                        d = SIMD3(d.x - t * A.x, d.y - t * A.y, d.z - t * A.z)
                    }
                    let l2 = (d.y * d.y + d.x * d.x) + d.z * d.z
                    let rq = SSEApprox.rsqrt(l2) // rsqrtps 0x14024334b
                    let nn = SIMD3(rq * d.x, rq * d.y, rq * d.z)
                    let r = rq * l2
                    let f = sseMax(0, sseMin((r - v.inner) * v.rcp, 1))
                    let spd = f * ds + si
                    let cr = SIMD3(nn.y * A.z - nn.z * A.y, nn.z * A.x - nn.x * A.z, nn.x * A.y - nn.y * A.x)
                    vel[i] = SIMD3(cr.x * spd + vel[i].x, cr.y * spd + vel[i].y, cr.z * spd + vel[i].z)
                }
            case let .vortexV2(v):
                // 0x1402433ea (op 16) / 0x140243a17 (variant 37): A = CP 3×3 · axis (0x14024f080, not renormalised); t = d·A
                // when flags & 1; d' = d − t·A; r = rsqrt(|d'|²)·|d'|²; n = rsqrt·d'; q = (v·dt + p) − C − t·A;
                // k = (rsqrt(|q|²)·r − 1)·(centerforce/dt) [+ ±(1 − ff)·(pullforce·dt) in ring mode]; spd = f·ds' + si' with
                // ds', si' pre-multiplied by audio·dt2; vel += cross(n, A)·spd + q·k (the variant multiplies spd and k by blend).
                let cpm = cps[v.cp].world
                let C = cpm.translation
                let A = rowMul(v.axis, cpm.m3)
                let audio = v.audio.response(host.audioBands)
                let si0 = v.speedInner * sc.speed, ds0 = v.speedOuter * sc.speed - si0
                let si = (si0 * audio) * dt2, ds = (ds0 * audio) * dt2
                let cf = (1 / dt) * v.centerForce
                let pull = dt * v.ringPullForce
                let ring = v.flags & 4 != 0, cyl = v.flags & 1 != 0
                @inline(__always) func rsq(_ x: Float) -> Float { SSEApprox.rsqrt(x) } // rsqrtps 0x140243634 / 0x14024373a / 0x1402438a8 / 0x140243961
                for i in 0..<n where life[i] != 0 {
                    let p = pos[i], vv = vel[i]
                    var d = p - C
                    let t = cyl ? (d.y * A.y + d.x * A.x) + d.z * A.z : 0
                    let tA = SIMD3(t * A.x, t * A.y, t * A.z)
                    d -= tA
                    let l2 = (d.y * d.y + d.x * d.x) + d.z * d.z
                    let rq = rsq(l2)
                    let r = rq * l2
                    let nn = SIMD3(rq * d.x, rq * d.y, rq * d.z)
                    let q = SIMD3(((vv.x * dt + p.x) - C.x) - tA.x, ((vv.y * dt + p.y) - C.y) - tA.y, ((vv.z * dt + p.z) - C.z) - tA.z)
                    let ql2 = (q.y * q.y + q.x * q.x) + q.z * q.z
                    var k = (rsq(ql2) * r - 1) * cf
                    let f: Float
                    if ring {
                        let e = v.ringRadius - r
                        let ff = sseMax(0, sseMin((abs(e) - v.ringWidth) * v.ringRcp, 1))
                        let om = 1 - ff
                        let mag: Float = om != 1 ? om : 0
                        k += Float(sign: e.sign, exponentBitPattern: mag.exponentBitPattern, significandBitPattern: mag.significandBitPattern) * pull
                        f = ff
                    } else {
                        f = sseMax(0, sseMin((r - v.inner) * v.rcp, 1))
                    }
                    var spd = f * ds + si
                    if v.blend.active {
                        let b = v.blend.factor(age[i] * SSEApprox.rcp(life[i]))
                        spd *= b; k *= b
                    }
                    let cr = SIMD3(nn.y * A.z - nn.z * A.y, nn.z * A.x - nn.x * A.z, nn.x * A.y - nn.y * A.x)
                    vel[i] = SIMD3((cr.x * spd + q.x * k) + vv.x, (cr.y * spd + q.y * k) + vv.y, (cr.z * spd + q.z * k) + vv.z)
                }
            case let .boids(sepT, neighT, maxSpeed, sepF, alignF, cohF, bflags):
                boids(sepT, neighT, maxSpeed, sepF, alignF, cohF, bflags, dt2)
            case let .capVelocity(maxSpeed, blend):
                // 0x1402446fd (op 18): rs = rsqrt((vy² + vx²) + vz²); v *= minps(1, rs·max). Variant 38 (0x140244790):
                // v *= minps(0, rs·max − 1)·blend + 1. No zero guard (rsqrt(0) = inf keeps v = 0).
                for i in 0..<n where life[i] != 0 {
                    let v = vel[i]
                    let rs = SSEApprox.rsqrt((v.y * v.y + v.x * v.x) + v.z * v.z) // rsqrtps 0x140244756 / 0x140244828
                    let k: Float
                    if blend.active {
                        let m = rs * maxSpeed - 1
                        k = (0 < m ? 0 : m) * blend.factor(SSEApprox.rcp(life[i]) * age[i]) + 1
                    } else {
                        let m = rs * maxSpeed
                        k = 1 < m ? 1 : m
                    }
                    vel[i] = SIMD3(k * v.x, k * v.y, k * v.z)
                }
            case let .remap(r):
                let dump = PDump.want("remap\(def.path)\(opIndex)") ? pdumpState((highWater + 3) & ~3) : nil
                remapOp(r)
                if let dump { PDump.write(["kind": "remap", "def": def.path, "op": opIndex, "before": dump, "after": pdumpState((highWater + 3) & ~3)]) }
            case let .inheritFromEvent(mode, blend):
                let dump = PDump.want("inherit\(def.path)") ? pdumpState((highWater + 3) & ~3) : nil
                for i in 0..<n where life[i] != 0 {
                    inheritFromParent(mode, i, initial: false, blend: blend.active ? blend.factor(age[i] * SSEApprox.rcp(life[i])) : nil)
                }
                if let dump, let p = parent {
                    PDump.write(["kind": "inherit", "def": def.path, "mode": mode, "blend": PDump.bits([blend.bis, blend.rcpIn, blend.boe, blend.rcpOut]),
                                 "active": blend.active, "follow": followIndex, "before": dump, "after": pdumpState((highWater + 3) & ~3),
                                 "parent": p.pdumpState((p.highWater + 3) & ~3)])
                }
            case let .collision(c):
                collide(c, n)
            case let .collisionQuad(q):
                let dump = PDump.want("quad\(def.path)\(opIndex)") ? pdumpState(highWater) : nil
                collideQuad(q, n)
                if let dump { PDump.write(["kind": "quad", "def": def.path, "op": opIndex, "before": dump, "after": pdumpState(highWater)]) }
            case let .collisionModel(c):
                let dump = PDump.want("model\(def.path)\(opIndex)") ? pdumpState((highWater + 3) & ~3) : nil
                let frame0 = modelFrame
                collideModel(c, opIndex: opIndex, n)
                if let dump {
                    let caps = collisionModels[opIndex].map { modelCapsules($0) } ?? []
                    PDump.write(["kind": "model", "def": def.path, "op": opIndex, "frame": frame0, "before": dump,
                                 "after": pdumpState((highWater + 3) & ~3),
                                 "caps": caps.map { a, d, l, r in PDump.bits([a.x, a.y, a.z, d.x, d.y, d.z, l, r]) },
                                 "capsin": collisionModels[opIndex].map { modelCapsuleInputs($0) } ?? [:]])
                }
            }
        }
    }

    /// collisionplane / collisionsphere / collisionbounds (ops 21/22/24, cases 0x14024afb2 / 0x14024b0f4 / 0x14024b1b9; SIMD
    /// responses 0x140251f30.. per behaviour × flags&2). Plane: d = (y·ny + x·nx) + z·nz; hit when d < dist; p −= (d − dist)·n.
    /// With flags & 1 the normal is the CP 3×3 times the parsed (normalised) plane, not renormalised, and dist = (ny·Ty + nz·Tz)
    /// + nx·Tx. Sphere: l² = |p − C|², hit when l² < r²; n = rsqrt(l²)·(p − C); p −= (rsqrt·l² − r)·n. Bounds: the four
    /// planes x ≥ 0, y ≥ 0, −x ≥ −W, −y ≥ −H, taken into particle space by inverse(Top) unless worldspace (normals not
    /// renormalised; distances = dot(inverse(Top)·corner, n')). Responses: bounce v += (dot(v, n)·k)·n with k = −1 − b; slide
    /// v −= dot(v, n)·n; stop v = 0; delete age = life; flags & 2 also zeroes the angular velocity.
    private func collide(_ c: POp.PCollision, _ n: Int) {
        @inline(__always) func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { (a.y * b.y + a.x * b.x) + a.z * b.z }
        func respond(_ i: Int, _ nrm: SIMD3<Float>) {
            let v = vel[i]
            switch c.behavior {
            case 0:
                let k = dot(v, nrm) * c.bounce
                vel[i] = SIMD3(k * nrm.x + v.x, k * nrm.y + v.y, k * nrm.z + v.z)
            case 1:
                let k = dot(v, nrm)
                vel[i] = SIMD3(v.x - k * nrm.x, v.y - k * nrm.y, v.z - k * nrm.z)
            case 2: vel[i] = .zero
            default: age[i] = life[i]
            }
            if c.flags & 2 != 0 { angVel[i] = .zero }
        }
        func plane(_ i: Int, _ nrm: SIMD3<Float>, _ dist: Float) {
            let p = pos[i]
            let d = dot(p, nrm)
            guard d < dist else { return }
            if c.behavior != 3 {
                let e = d - dist
                pos[i] = SIMD3(p.x - e * nrm.x, p.y - e * nrm.y, p.z - e * nrm.z)
            }
            respond(i, nrm)
        }
        switch c.shape {
        case .plane:
            var nrm = c.normal, dist = c.distance
            if c.flags & 1 != 0 {
                let m = cps[c.cp].world
                nrm = rowMul(c.normal, m.m3)
                let T = m.translation
                dist = (nrm.y * T.y + nrm.z * T.z) + nrm.x * T.x
            }
            for i in 0..<n where life[i] != 0 { plane(i, nrm, dist) }
        case .sphere:
            let C = c.flags & 1 != 0 ? cps[c.cp].world.translation : c.origin
            let r2 = c.radius * c.radius
            for i in 0..<n where life[i] != 0 {
                let p = pos[i], d = p - C
                let l2 = (d.y * d.y + d.x * d.x) + d.z * d.z
                guard l2 < r2 else { continue }
                let rq = SSEApprox.rsqrt(l2) // rsqrtps 0x140252ebe (CollideSphere_*: 0x14025312c / 0x1402533bf / 0x14025361e)
                let nrm = SIMD3(rq * d.x, rq * d.y, rq * d.z)
                if c.behavior != 3 {
                    let e = rq * l2 - c.radius
                    pos[i] = SIMD3(p.x - e * nrm.x, p.y - e * nrm.y, p.z - e * nrm.z)
                }
                respond(i, nrm)
            }
        case .bounds:
            let W = host.sceneSize.x, H = host.sceneSize.y
            var ns: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(-1, 0, 0), SIMD3(0, -1, 0)]
            var ds: [Float] = [0, 0, -W, -H]
            if !worldSpace {
                let m = PMat.inverse(top) // 0x14005f0d0 (same results as 0x14005f730 / glm SSE, emulator-checked)
                func xf(_ v: SIMD4<Float>) -> SIMD3<Float> {
                    let a = m.columns.0 * v.x + m.columns.1 * v.y, b = m.columns.2 * v.z + m.columns.3 * v.w
                    return SIMD3(a.x + b.x, a.y + b.y, a.z + b.z)
                }
                ns = ns.map { xf(SIMD4($0, 0)) }
                let p0 = xf(SIMD4(0, 0, 0, 1)), p1 = xf(SIMD4(W, H, 0, 1))
                @inline(__always) func dotXYZ(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { (a.x * b.x + a.y * b.y) + a.z * b.z }
                ds = [dotXYZ(p0, ns[0]), dotXYZ(p0, ns[1]), dotXYZ(p1, ns[2]), dotXYZ(p1, ns[3])]
            }
            for i in 0..<n where life[i] != 0 {
                for k in 0..<4 { plane(i, ns[k], ds[k]) }
            }
        }
    }

    /// boids (op 17, 0x140244121–0x1402446f2). S = highwater/200 + 1 and f = C+0x144 (the frame counter): groups of 4
    /// starting at (f mod S)·4 with stride 4S are updated, each scanning neighbour groups from ((f + g) mod S)·4 with stride 4S
    /// in the four lane rotations. The neighbour's alive mask is taken from the unrotated lanes of its group (engine quirk).
    /// sep: l² ≠ 0, r < sepT (r = rsqrt(l²)·l²) adds (sepT·rsqrt − 1)·d; neighbours (r < neighT, self included) sum v and p.
    /// dv = ((v̄ − v)·aK + sep·(sepK/sepN)) + (p̄ − p)·cK with K = S·factor·dt2; flags & 1 caps |v + dv| to maxspeed when it
    /// exceeds max(|v|², maxspeed²). Dead slots are updated too (harmless).
    func boids(_ sepT: Float, _ neighT: Float, _ maxSpeed: Float, _ sepF: Float, _ alignF: Float, _ cohF: Float, _ bflags: Int,
               _ dt2: Float) {
        let hw = highWater
        guard hw > 0 else { return }
        let S = hw / 200 + 1
        let fs = Float(S)
        let sepK = (fs * sepF) * dt2, alignK = (fs * alignF) * dt2, cohK = (fs * cohF) * dt2
        let ms2 = maxSpeed * maxSpeed
        let frame = host.frameCounter
        @inline(__always) func rsq(_ x: Float) -> Float { SSEApprox.rsqrt(x) } // rsqrtps 0x1402443cc / 0x140244691
        func slot(_ k: Int) -> (SIMD3<Float>, SIMD3<Float>, Bool) {
            k < cap ? (pos[k], vel[k], life[k] != 0) : (.zero, .zero, false)
        }
        var g = (frame % S) * 4
        while g < hw {
            let j0 = ((frame &+ g) % S) * 4
            var res: [(Int, SIMD3<Float>)] = []
            for l in 0..<4 {
                let i = g + l
                guard i < cap else { continue }
                let pi = pos[i], vi = vel[i]
                var sepN: Float = 0, nN: Float = 0
                var sepA = SIMD3<Float>(0, 0, 0), vS = sepA, pS = sepA
                var j = j0
                while j < hw {
                    for rot in [0, 3, 2, 1] { // shufps 0x93 / 0x4e / 0x39 after the unrotated pass
                        let (pj, vj, _) = slot(j + (l + rot) % 4)
                        let alive = slot(j + l).2
                        let d = pi - pj
                        let l2 = (d.y * d.y + d.x * d.x) + d.z * d.z
                        let rq = rsq(l2)
                        let r = rq * l2
                        if l2 != 0 && alive && r < sepT {
                            sepN += 1
                            let k = rq * sepT - 1
                            sepA += SIMD3(k * d.x, k * d.y, k * d.z)
                        }
                        if r < neighT && alive {
                            nN += 1
                            vS += vj; pS += pj
                        }
                    }
                    j += 4 * S
                }
                let sScale: Float = sepN != 0 ? SSEApprox.rcp(sepN) * sepK : 0 // rcpps 0x140244583
                let inv: Float = nN != 0 ? SSEApprox.rcp(nN) : 0 // rcpps 0x140244591
                let aK: Float = nN != 0 ? alignK : 0, cK: Float = nN != 0 ? cohK : 0
                var dv = SIMD3<Float>(0, 0, 0)
                for c in 0..<3 {
                    dv[c] = ((inv * vS[c] - vi[c]) * aK + sScale * sepA[c]) + (inv * pS[c] - pi[c]) * cK
                }
                var nv = SIMD3(vi.x + dv.x, vi.y + dv.y, vi.z + dv.z)
                if bflags & 1 != 0 {
                    let o2 = sseMax((vi.y * vi.y + vi.x * vi.x) + vi.z * vi.z, ms2)
                    let n2 = (nv.y * nv.y + nv.x * nv.x) + nv.z * nv.z
                    let k: Float = o2 < n2 ? rsq(n2) * maxSpeed : 1
                    nv = SIMD3(k * nv.x, k * nv.y, k * nv.z)
                }
                res.append((i, nv))
            }
            for (i, v) in res { vel[i] = v }
            g += 4 * S
        }
    }

    // MARK: - remapvalue operator (op 19 / life-blend op 39, case 0x140244874 / 0x140246ec0)

    /// gaps6/particles/remap_ref.py, float32 in instruction order (rcpps / rsqrtps through `SSEApprox`). Runs over every
    /// slot of every group of 4 below the high-water mark, alive or dead, like the engine: output 16 takes lane 0 of
    /// each group, so a dead slot can drive the control point.
    func remapOp(_ r: PRemap) {
        let hw = highWater
        let vecIn = r.input > 12, vecOut = r.output > 12
        func tr(_ k: Int) -> SIMD3<Float> { cps[k].world.translation }
        @inline(__always) func rcp(_ x: Float) -> Float { SSEApprox.rcp(x) }    // rcpps 0x140244b07 / 0x140244d7b / …
        @inline(__always) func rsq(_ x: Float) -> Float { SSEApprox.rsqrt(x) } // rsqrtps 0x140244faa / …
        var uni: SIMD3<Float>?
        switch r.input {
        case 9, 11: uni = SIMD3(repeating: frame.time) // ctx+0x130
        case 10: uni = SIMD3(repeating: frame.daytime) // ctx+0x140
        case 12: uni = SIMD3(repeating: host.layerTime) // obj+0x770
        case 19: uni = top.translation
        default: break
        }
        let s = r.inputScale, sPi = s * Float(bitPattern: 0x4049_0fdb), halfPi = Float(bitPattern: 0x3fc9_0fdb)
        let third = Float(bitPattern: 0x3eaa_aaab)
        let angular = def.mask & 2 != 0
        let blendOn = r.blend.active
        func blendf(_ i: Int) -> Float {
            let b = r.blend
            let t = rcp(life[i]) * age[i]
            let a = sseClamp01((b.boe - t) * b.rcpOut), c = sseClamp01((t - b.bis) * b.rcpIn)
            return a * c
        }
        func opApply(_ old: Float, _ o: Float) -> Float? {
            switch r.op {
            case 0: return o
            case 1: return o * old
            case 2: return o + old
            case 3: return old - o
            default: return nil
            }
        }
        let comps: [Int]
        switch r.outComp {
        case 0: comps = [0, 1, 2]
        case 1: comps = [0]
        case 2: comps = [1]
        case 3: comps = [2]
        default: comps = []
        }
        var stale = SIMD3<Float>(0, 0, 0)
        var g = 0
        while g < hw {
            var cpLane0: SIMD3<Float>?
            for i in g..<(g + 4) {
                let p = pos[i], v3 = vel[i]
                var X: Float, Y: Float, Z: Float
                if let u = uni {
                    X = u.x; Y = u.y; Z = u.z
                } else {
                    switch r.input {
                    case 0: X = rcp(life[i]) * age[i]; Y = X; Z = X
                    case 1: X = life[i]; Y = X; Z = X
                    case 2: X = size[i]; Y = X; Z = X
                    case 3: X = color[i].w; Y = X; Z = X
                    case 4: X = sqrtf((v3.y * v3.y + v3.x * v3.x) + v3.z * v3.z); Y = X; Z = X
                    case 5: X = rot[i].z; Y = X; Z = X
                    case 6: X = angular ? angVel[i].z : 0; Y = X; Z = X
                    case 7:
                        let d = p - tr(r.inCP0)
                        X = sqrtf((d.y * d.y + d.x * d.x) + d.z * d.z); Y = X; Z = X
                    case 8:
                        let A = tr(r.outCP0), B = tr(r.outCP1), D = B - A, q = p - A
                        let d2 = (D.y * D.y + D.x * D.x) + D.z * D.z
                        let num = (q.y * D.y + q.x * D.x) + q.z * D.z
                        X = 0 < d2 ? num * rcp(d2) : 0; Y = X; Z = X
                    case 13: X = color[i].x; Y = color[i].y; Z = color[i].z
                    case 14: X = p.x; Y = p.y; Z = p.z
                    case 15: X = v3.x; Y = v3.y; Z = v3.z
                    case 16: let c = tr(r.inCP0); X = c.x; Y = c.y; Z = c.z
                    case 17: let d = tr(r.inCP0) - p; X = d.x; Y = d.y; Z = d.z
                    case 18:
                        let d = tr(r.inCP0) - p
                        let d2 = (d.x * d.x + d.y * d.y) + d.z * d.z
                        let k: Float = 0 < d2 ? rsq(d2) : 0
                        X = k * d.x; Y = k * d.y; Z = k * d.z
                    default: X = stale.x; Y = stale.y; Z = stale.z // registers keep the previous lane's values
                    }
                }
                stale = SIMD3(X, Y, Z)
                var u: SIMD3<Float>
                if vecIn {
                    switch r.inComp {
                    case 1: Y = X; Z = X
                    case 2: X = Y; Z = Y
                    case 3: X = Z; Y = Z
                    case 4, 5:
                        var t = (Y + X) + Z
                        if r.inComp == 5 { t = t * third }
                        X = t; Y = t; Z = t
                    case 6: let t = sseMax(sseMax(X, Y), Z); X = t; Y = t; Z = t
                    case 7: let t = sseMin(sseMin(X, Y), Z); X = t; Y = t; Z = t
                    default: break
                    }
                    u = SIMD3((X - r.inMin.x) * r.inRcp.x, (Y - r.inMin.y) * r.inRcp.y, (Z - r.inMin.z) * r.inRcp.z)
                } else {
                    u = SIMD3(repeating: (X - r.inMin.x) * r.inRcp.x)
                }
                if r.flags & 1 != 0 { u = SIMD3(sseClamp01(u.x), sseClamp01(u.y), sseClamp01(u.z)) }
                let seed = rnd[i].bitPattern
                func T(_ v: Float, _ k: Int) -> Float {
                    switch r.transform {
                    case 1: return PNoise.sinPS(v * sPi - halfPi) * 0.5 + 0.5
                    case 2:
                        let x = v * s, f = x - truncf(x)
                        return f.rounded(.toNearestOrEven) + (x < 0 ? 1 : 0)
                    case 3:
                        let x = v * s, f = x - truncf(x)
                        return f + (v < 0 ? 1 : 0)
                    case 4:
                        let x = abs(v * s), f = x - truncf(x)
                        return 1 - abs(f * 2 - 1)
                    case 5, 6:
                        let sd = seed ^ (k == 0 ? 0 : k == 1 ? 0x0b39_24ad : 0x493a_8e83)
                        let n = r.transform == 5 ? PNoise.noise2(sd, v * s, 0) : PNoise.fbm(sd, v * s, 0, r.octaves, r.norm)
                        return n * 0.5 + 0.5
                    default: return v
                    }
                }
                let tv = SIMD3(T(u.x, 0), vecOut ? T(u.y, 1) : u.y, vecOut ? T(u.z, 2) : u.z)
                var o = SIMD3<Float>(r.outRange.x * tv.x + r.outMin.x, tv.y, tv.z)
                if r.flags & 2 != 0 { o.x = sseClamp01(o.x) }
                if vecOut {
                    for k in 1...2 {
                        var ok = tv[k] * r.outRange[k] + r.outMin[k]
                        if r.flags & 2 != 0 { ok = sseClamp01(ok) }
                        o[k] = ok
                    }
                }
                let b: Float? = blendOn ? blendf(i) : nil
                func apply(_ old: Float, _ oo: Float) -> Float {
                    guard let n = opApply(old, oo) else { return old }
                    guard let b else { return n }
                    return (n - old) * b + old
                }
                switch r.output {
                case 1: life[i] = apply(life[i], o.x)
                case 2: size[i] = apply(size[i], o.x)
                case 3: color[i].w = apply(color[i].w, o.x)
                case 5: rot[i].z = apply(rot[i].z, o.x)
                case 6: if angular { angVel[i].z = apply(angVel[i].z, o.x) }
                case 4:
                    let l = sqrtf((v3.x * v3.x + v3.y * v3.y) + v3.z * v3.z)
                    let nl = apply(l, o.x) // the life blend acts on the new length
                    let k = 0 < l ? rcp(l) * nl : nl
                    vel[i] = SIMD3(k * v3.x, k * v3.y, k * v3.z)
                case 7:
                    let C = tr(r.outCP0), d = p - C
                    let d2 = (d.y * d.y + d.x * d.x) + d.z * d.z
                    let rs = rsq(d2), dist = rs * d2
                    let k: Float = !(dist == 0) ? rs : 0
                    let nd = apply(dist, o.x)
                    pos[i] = SIMD3(nd * (k * d.x) + C.x, nd * (k * d.y) + C.y, nd * (k * d.z) + C.z)
                case 8:
                    let A = tr(r.outCP0), B = tr(r.outCP1), D = B - A
                    let d2 = (D.y * D.y + D.x * D.x) + D.z * D.z
                    let rs = rsq(d2), L = rs * d2
                    let m = !(L == 0)
                    let km: Float = m ? rs : 0
                    let nn = SIMD3(km * D.x, km * D.y, km * D.z)
                    let q = p - A
                    let proj = (q.y * nn.y + q.x * nn.x) + q.z * nn.z
                    let perp = SIMD3(q.x - proj * nn.x, q.y - proj * nn.y, q.z - proj * nn.z)
                    let t: Float = m ? proj * rs : 0
                    let x3 = apply(t, o.x) * L
                    pos[i] = SIMD3((x3 * nn.x + perp.x) + A.x, (x3 * nn.y + perp.y) + A.y, (x3 * nn.z + perp.z) + A.z)
                case 13, 14, 15:
                    var cur: SIMD3<Float> = r.output == 13 ? SIMD3(color[i].x, color[i].y, color[i].z) : r.output == 14 ? p : v3
                    // Life-blend variant only: operation remap + outputcomponent all blends every channel towards o.x
                    // (0x140248a16; same for position and velocity), an engine bug.
                    let bug = b != nil && r.op == 0 && r.outComp == 0
                    for a in comps { cur[a] = apply(cur[a], bug ? o.x : o[a]) }
                    if r.output == 13 { color[i] = SIMD4(cur, color[i].w) } else if r.output == 14 { pos[i] = cur } else { vel[i] = cur }
                case 16:
                    if i == g { cpLane0 = o }
                case 17:
                    let C = tr(r.outCP0)
                    var d = C - p
                    for a in comps { d[a] = apply(d[a], o[a]) }
                    pos[i] = C - d
                case 18:
                    let C = tr(r.outCP0), d = C - p
                    let d2 = (d.x * d.x + d.y * d.y) + d.z * d.z
                    let rs = rsq(d2), dist = rs * d2
                    let km: Float = 0 < dist ? rs : 0
                    var nn = SIMD3(km * d.x, km * d.y, km * d.z)
                    for a in comps { nn[a] = apply(nn[a], o[a]) }
                    let n2 = (nn.x * nn.x + nn.y * nn.y) + nn.z * nn.z
                    let rs2 = rsq(n2)
                    let k = (0 < rs2 * n2 ? rs2 : 0) * dist
                    pos[i] = SIMD3(C.x - k * nn.x, C.y - k * nn.y, C.z - k * nn.z)
                default: break
                }
            }
            if let o = cpLane0 {
                // Output 16: lane 0 of each group writes cp[outCP0].world row 3, compounding across groups. The three
                // 16-byte splat stores (0x1402469db..0x140246a4d) spill: w ends as C.z, and so do the first two floats
                // of the CP's previous matrix row 0.
                var C = tr(r.outCP0)
                for a in comps {
                    if let n = opApply(C[a], o[a]) { C[a] = blendOn ? (n - C[a]) * blendf(g) + C[a] : n }
                }
                cps[r.outCP0].world.columns.3 = SIMD4(C, C.z)
                cps[r.outCP0].prev.columns.0.x = C.z
                cps[r.outCP0].prev.columns.0.y = C.z
            }
            g += 4
        }
    }

    // MARK: - remapinitialvalue (InitParticle 0x14023b340, case 0x14023ce53)

    /// gaps6/particles/initremap_ref.py: exact divisions, CRT sinf / floorf / roundf, the 1-D Perlin-table simplex.
    func initRemap(_ r: PRemapInit, _ i: Int) {
        let x9 = Float(bitPattern: 0x3400_0000), halfPi = Float(bitPattern: 0x3fc9_0fdb), third = Float(bitPattern: 0x3eaa_aaab)
        func tr(_ c: Int) -> SIMD3<Float> { cps[c].world.translation }
        func length(_ a: SIMD3<Float>) -> Float { sqrtf((a.x * a.x + a.y * a.y) + a.z * a.z) }
        func sat(_ x: Float) -> Float { let m: Float = 0 > x ? 0 : x; return 1 < m ? 1 : m }
        func fract(_ x: Float) -> Float { x - floorf(x) }
        let p = pos[i], v = vel[i]
        var X: Float = 0, Y: Float = 0, Z: Float = 0
        let I = r.input
        switch I {
        case 0: X = phase[i]; Y = X; Z = X // the sprite phase array, not age/life
        case 1: X = life[i]; Y = X; Z = X
        case 2: X = size0[i]; Y = X; Z = X
        case 3: X = color0[i].w; Y = X; Z = X
        case 4: X = length(v); Y = X; Z = X
        case 5: X = rot[i].z; Y = X; Z = X
        case 6: if def.mask & 2 != 0 { X = angVel[i].z; Y = X; Z = X }
        case 7: X = length(p - tr(r.inCP0)); Y = X; Z = X
        case 8:
            let A = tr(r.outCP0), B = tr(r.outCP1)
            var D = B - A
            let L = length(D)
            if L > x9 { D = SIMD3(D.x / L, D.y / L, D.z / L) }
            let q = p - A
            let t = (q.x * D.x + q.y * D.y) + q.z * D.z
            if L > x9 { X = t / L; Y = X; Z = X }
        case 9: X = frame.time; Y = X; Z = X
        case 10: X = frame.daytime; Y = X; Z = X
        case 11: X = time; Y = X; Z = X // inst+0x3f0
        case 12: X = host.layerTime; Y = X; Z = X
        case 13: X = color0[i].x; Y = color0[i].y; Z = color0[i].z
        case 14: X = p.x; Y = p.y; Z = p.z
        case 15: X = v.x; Y = v.y; Z = v.z
        case 16, 17, 18:
            // Engine bug (0x14023d31d..): the still-zero input vector is written INTO cp[inCP0].world[3].xyz.
            cps[r.inCP0].world.columns.3.x = 0; cps[r.inCP0].world.columns.3.y = 0; cps[r.inCP0].world.columns.3.z = 0
            if I == 17 {
                let d = SIMD3<Float>(0, 0, 0) - p; X = d.x; Y = d.y; Z = d.z
            } else if I == 18 {
                let d = SIMD3<Float>(0, 0, 0) - p, inv = 1 / length(d)
                X = d.x * inv; Y = d.y * inv; Z = d.z * inv
            }
        case 19: let o = top.translation; X = o.x; Y = o.y; Z = o.z
        default: break
        }
        if I > 12 {
            switch r.inComp {
            case 1: Y = X; Z = X
            case 2: X = Y; Z = Y
            case 3: X = Z; Y = Z
            case 4: let t = (X + Y) + Z; X = t; Y = t; Z = t
            case 5: let t = ((X + Y) + Z) * third; X = t; Y = t; Z = t
            case 6: let r1 = Z > Y ? Z : Y; let t = r1 > X ? r1 : X; X = t; Y = t; Z = t
            case 7: let r1 = Z < Y ? Z : Y; let t = r1 < X ? r1 : X; X = t; Y = t; Z = t
            default: break
            }
        }
        var u = SIMD3((X - r.inMin.x) / r.inRange.x, (Y - r.inMin.y) / r.inRange.y, (Z - r.inMin.z) / r.inRange.z)
        if r.flags & 1 != 0 { u = SIMD3(sat(u.x), sat(u.y), sat(u.z)) }
        let s = r.inputScale, vecOut = r.output > 12
        switch r.transform {
        case 1:
            // xmm10 = 0x40490fdb (Swift's Float.pi rounds toward zero); CRT sinf modelled as correctly rounded.
            let pi = Float(bitPattern: 0x4049_0fdb)
            for k in 0..<3 { u[k] = Float(sin(Double(((u[k] * pi) * s) - halfPi))) * 0.5 + 0.5 }
        case 2:
            for k in 0..<3 { let x = u[k] * s; u[k] = fract(x).rounded() + (0 > x ? 1 : 0) }
        case 3:
            for k in 0..<3 { u[k] = fract(u[k] * s) + (0 > u[k] ? 1 : 0) }
        case 4:
            for k in 0..<3 { u[k] = 1 - abs(fract(abs(u[k] * s)) * 2 - 1) }
        case 5:
            for k in 0..<(vecOut ? 3 : 1) { u[k] = PNoise.snoise1(u[k] * s) * 0.5 + 0.5 }
        case 6:
            for k in 0..<(vecOut ? 3 : 1) {
                u[k] = PNoise.fbm1(u[k], r.octaves, freq: s, amp: 1, lac: 2, gain: 0.5) * 0.5 + 0.5
            }
        default: break
        }
        var o = SIMD3(u.x * r.outRange.x + r.outMin.x, u.y * r.outRange.y + r.outMin.y, u.z * r.outRange.z + r.outMin.z)
        if r.flags & 2 != 0 { o = SIMD3(sat(o.x), sat(o.y), sat(o.z)) }
        func ap(_ old: Float, _ x: Float) -> Float {
            switch r.op {
            case 0: return x
            case 1: return x * old
            case 2: return x + old
            case 3: return old - x
            default: return old
            }
        }
        let comps: [Int]
        switch r.outComp {
        case 0: comps = [0, 1, 2]
        case 1: comps = [0]
        case 2: comps = [1]
        case 3: comps = [2]
        default: comps = []
        }
        switch r.output {
        case 1: life[i] = ap(life[i], o.x)
        case 2: size0[i] = ap(size0[i], o.x)
        case 3: color0[i].w = ap(color0[i].w, o.x)
        case 5: rot[i].z = ap(rot[i].z, o.x)
        case 6: if def.mask & 2 != 0 { angVel[i].z = ap(angVel[i].z, o.x) }
        case 4:
            let l = length(v)
            var nl = ap(l, o.x)
            if l != 0 { nl = nl / l }
            vel[i] = SIMD3(nl * v.x, nl * v.y, nl * v.z)
        case 7:
            let C = tr(r.outCP0)
            var d = p - C
            let L = length(d)
            if L != 0 { d = SIMD3(d.x / L, d.y / L, d.z / L) }
            let nl = ap(L, o.x)
            pos[i] = SIMD3(d.x * nl + C.x, d.y * nl + C.y, d.z * nl + C.z)
        case 8:
            let A = tr(r.outCP0), B = tr(r.outCP1)
            var D = B - A
            let L = length(D)
            if L > x9 { D = SIMD3(D.x / L, D.y / L, D.z / L) }
            let q = p - A
            var t = (q.x * D.x + q.y * D.y) + q.z * D.z
            let perp = SIMD3(q.x - D.x * t, q.y - D.y * t, q.z - D.z * t)
            if L > x9 { t = t / L }
            let nt = ap(t, o.x)
            pos[i] = SIMD3((A.x + perp.x) + (D.x * nt) * L, (A.y + perp.y) + (D.y * nt) * L, (A.z + perp.z) + (D.z * nt) * L)
        case 13:
            for a in comps { color0[i][a] = ap(color0[i][a], o[a]) }
        case 14:
            for a in comps { pos[i][a] = ap(pos[i][a], o[a]) }
        case 15:
            for a in comps { vel[i][a] = ap(vel[i][a], o[a]) }
        case 16:
            var C = tr(r.outCP0)
            for a in comps { C[a] = ap(C[a], o[a]) }
            cps[r.outCP0].world.columns.3.x = C.x; cps[r.outCP0].world.columns.3.y = C.y; cps[r.outCP0].world.columns.3.z = C.z
        case 17:
            let C = tr(r.outCP0)
            var d = C - p
            for a in comps { d[a] = ap(d[a], o[a]) }
            pos[i] = C - d
        case 18:
            let C = tr(r.outCP0)
            var d = C - p
            let L = length(d)
            if L > x9 { d = SIMD3(d.x / L, d.y / L, d.z / L) }
            for a in comps { d[a] = ap(d[a], o[a]) }
            let inv = 1 / length(d)
            pos[i] = SIMD3(C.x - (d.x * inv) * L, C.y - (d.y * inv) * L, C.z - (d.z * inv) * L)
        default: break
        }
    }

    // MARK: - collisionquad (op 25) / collisionmodel (op 26)

    /// gaps6/particles/collision_ref.quad_op. With flags & 1 the quad follows its CP every frame (0x14024b653): origin =
    /// translation, n/U/V = raw·cp rows, not renormalised. Hit: s = (p−O)·n ≤ 0 < (prev−O)·n, |(p−O)·U| < half.y,
    /// |(p−O)·V| < half.x. bounce/slide/stop first push p −= n·1.05·s; delete sets age = life without moving.
    private func collideQuad(_ q: POp.PQuad, _ n: Int) {
        var O = q.origin, nn = q.n, uu = q.u, vv = q.v
        if q.flags & 1 != 0 {
            let M = cps[q.cp].world
            O = M.translation
            // Row-vector (x, 0)·M over rows 0..3 (simd columns are the engine rows).
            func rot(_ x: SIMD3<Float>) -> SIMD3<Float> {
                let c0 = M.columns.0, c1 = M.columns.1, c2 = M.columns.2, c3 = M.columns.3
                return SIMD3(((c0.x * x.x + c1.x * x.y) + c2.x * x.z) + c3.x * 0,
                             ((c0.y * x.x + c1.y * x.y) + c2.y * x.z) + c3.y * 0,
                             ((c0.z * x.x + c1.z * x.y) + c2.z * x.z) + c3.z * 0)
            }
            nn = rot(q.raw.n); uu = rot(q.raw.u); vv = rot(q.raw.v)
        }
        let k105 = Float(bitPattern: 0x3f86_6666)
        let angular = q.flags & 2 != 0
        for i in 0..<n {
            let p = pos[i], pp = prevPos[i]
            let d = p - O, dp = pp - O
            let sd = (d.y * nn.y + d.x * nn.x) + d.z * nn.z
            let sp = (dp.y * nn.y + dp.x * nn.x) + dp.z * nn.z
            let a = (d.y * uu.y + d.x * uu.x) + d.z * uu.z
            let b = (d.y * vv.y + d.x * vv.x) + d.z * vv.z
            guard sd <= 0, 0 < sp, abs(a) < q.halfU, abs(b) < q.halfV else { continue }
            if q.behavior < 3 {
                let s2 = sd * k105
                pos[i] = SIMD3(p.x - s2 * nn.x, p.y - s2 * nn.y, p.z - s2 * nn.z)
            }
            collisionRespond(i, nn, k: q.k, behavior: q.behavior)
            if angular { angVel[i] = .zero }
        }
    }

    @inline(__always) private func collisionRespond(_ i: Int, _ nrm: SIMD3<Float>, k: Float, behavior: Int) {
        let v = vel[i]
        let vn = (v.y * nrm.y + v.x * nrm.x) + v.z * nrm.z
        switch behavior {
        case 0: let w = vn * k; vel[i] = SIMD3(w * nrm.x + v.x, w * nrm.y + v.y, w * nrm.z + v.z)
        case 1: vel[i] = SIMD3(v.x - vn * nrm.x, v.y - vn * nrm.y, v.z - vn * nrm.z)
        case 2: vel[i] = .zero
        default: age[i] = life[i]
        }
    }

    /// One capsule per bone from the linked model's MDLS hit boxes (capsule builder 0x1401d4580, fit 0x1401d5880):
    /// T = S·Bone·World·M (row-vector), M = identity (worldspace) or inverse(Top). Amortised over frames when
    /// highwater ≥ 10000. Response: the last capsule hit gives n and pen = |d| − R; p −= n·pen (not for delete).
    private func collideModel(_ c: POp.PModelCollision, opIndex: Int, _ n: Int) {
        guard let obj = collisionModels[opIndex] else { return }
        let caps = modelCapsules(obj)
        guard !caps.isEmpty else { return }
        let S = highWater / 10000 + 1
        var g = (modelFrame % S) * 4
        modelFrame += 1
        while g < highWater {
            for i in g..<min(g + 4, cap) {
                let p = pos[i]
                var hit = false, nrm = SIMD3<Float>(0, 0, 0), pen: Float = 0
                for (A, D, L, R) in caps {
                    var t = ((p.y - A.y) * D.y + (p.x - A.x) * D.x) + (p.z - A.z) * D.z
                    t = t > 0 ? t : 0
                    t = t < L ? t : L
                    let cc = SIMD3(t * D.x + A.x, t * D.y + A.y, t * D.z + A.z)
                    let dd = p - cc
                    let d2 = (dd.y * dd.y + dd.x * dd.x) + dd.z * dd.z
                    let rs = SSEApprox.rsqrt(d2) // rsqrtps (collisionmodel capsule test, 0x1402508c0 / 0x140250e00 / 0x140251320)
                    if d2 < R * R {
                        hit = true
                        nrm = SIMD3(rs * dd.x, rs * dd.y, rs * dd.z)
                        pen = rs * d2 - R
                    }
                }
                guard hit else { continue }
                if c.behavior == 3 { age[i] = life[i]; continue }
                pos[i] = SIMD3(p.x - pen * nrm.x, p.y - pen * nrm.y, p.z - pen * nrm.z)
                let v = vel[i]
                let vn = (nrm.y * v.y + nrm.x * v.x) + nrm.z * v.z
                switch c.behavior {
                case 0: let w = vn * c.k; vel[i] = SIMD3(w * nrm.x + v.x, w * nrm.y + v.y, w * nrm.z + v.z)
                case 1: vel[i] = SIMD3(v.x - vn * nrm.x, v.y - vn * nrm.y, v.z - vn * nrm.z)
                default: vel[i] = .zero
                }
            }
            g += 4 * S
        }
        _ = n
    }

    /// collision_ref.capsule_fit: largest |component| is the axis, the second largest the radius, h = major − radius.
    static func capsuleFit(_ e: SIMD3<Float>) -> (axis: SIMD3<Float>, radius: SIMD3<Float>, h: Float) {
        let ex = e.x, ey = e.y, ez = e.z
        var maj: SIMD3<Float>, mnr: SIMD3<Float>, sec: SIMD3<Float>
        if ey * ey + 0 > ex * ex + 0 { maj = SIMD3(0, ey, 0); mnr = SIMD3(ex, 0, 0) } else { maj = SIMD3(ex, 0, 0); mnr = SIMD3(0, ey, 0) }
        let l2maj = (maj.x * maj.x + maj.y * maj.y) + 0
        if ez * ez + 0 > l2maj { sec = SIMD3(maj.x, maj.y, 0); maj = SIMD3(0, 0, ez) } else { sec = SIMD3(0, 0, ez) }
        let l2s = (sec.x * sec.x + sec.y * sec.y) + sec.z * sec.z
        let l2m = (mnr.x * mnr.x + mnr.y * mnr.y) + 0
        if !(l2s > l2m) { sec = SIMD3(mnr.x, mnr.y, 0) }
        let L = (maj.x + maj.y) + maj.z, r = (sec.x + sec.y) + sec.z
        return (SIMD3(maj.x / L, maj.y / L, maj.z / L), sec, L - r)
    }

    /// collision_ref.build_capsules in column-vector form: T = M · World · Bone · S. Returns (A, D, L, R) in particle space.
    func modelCapsules(_ obj: SceneObject) -> [(SIMD3<Float>, SIMD3<Float>, Float, Float)] {
        let mdl: MdlFile?, bones: [simd_float4x4]
        if let m = obj as? ModelObject {
            mdl = m.mdl; bones = m.skeleton?.boneWorld ?? []
        } else if let l = obj as? ImageLayer, let pup = l.puppet {
            mdl = l.puppetFile; bones = pup.boneWorld
        } else {
            return []
        }
        guard let mdl else { return [] }
        let Wn = (worldSpace ? matrix_identity_float4x4 : top.inverse) * obj.world
        var items: [(SIMD3<Float>, SIMD3<Float>, Float, SIMD3<Float>, simd_float4x4)] = []
        if !mdl.hitBoxes.isEmpty {
            for (k, box) in mdl.hitBoxes.enumerated() {
                let e = box.halfExtents
                let fit = (e.y * e.y + e.x * e.x) + e.z * e.z < 0.01 ? (SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 0), Float(0))
                    : Self.capsuleFit(e)
                let B = k < bones.count ? bones[k] : matrix_identity_float4x4
                let S = Puppet.matrix(rowMajorRowVector: box.matrix)
                items.append((fit.0, fit.1, fit.2, .zero, Wn * B * S))
            }
        } else {
            let b = mdl.bounds
            let half = (b.max - b.min) * 0.5, ctr = half + b.min
            let fit = Self.capsuleFit(half)
            items.append((fit.0, fit.1, fit.2, ctr, Wn))
        }
        return items.map { axis, rad, h, ctr, T in
            let a = axis * h
            let p0 = T * SIMD4(ctr - a, 1), p1 = T * SIMD4(ctr + a, 1)
            let A = SIMD3(p0.x, p0.y, p0.z), Bp = SIMD3(p1.x, p1.y, p1.z)
            let ax = T * SIMD4(axis, 0), rv = T * SIMD4(rad, 0)
            let D = simd_normalize(SIMD3(ax.x, ax.y, ax.z))
            return (A, D, simd_length(Bp - A), simd_length(SIMD3(rv.x, rv.y, rv.z)))
        }
    }
}

// MARK: - Debug dump (PHOTON_PDUMP=<file>): SoA state around the remap / collision ops and remapinitialvalue, as JSON lines
// of float bit patterns, for comparison with the gaps6/particles Python references.

enum PDump {
    static let path = ProcessInfo.processInfo.environment["PHOTON_PDUMP"]
    static let limit = Int(ProcessInfo.processInfo.environment["PHOTON_PDUMP_LIMIT"] ?? "") ?? 40
    static var counts: [String: Int] = [:]
    static var handle: FileHandle? = {
        guard let p = path else { return nil }
        FileManager.default.createFile(atPath: p, contents: nil)
        return FileHandle(forWritingAtPath: p)
    }()
    static func want(_ tag: String) -> Bool {
        guard path != nil else { return false }
        let c = counts[tag, default: 0]
        guard c < limit else { return false }
        counts[tag] = c + 1
        return true
    }
    static func write(_ obj: [String: Any]) {
        guard let h = handle, let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        h.write(d); h.write("\n".data(using: .utf8)!)
    }
    static func bits(_ a: [Float]) -> [UInt32] { a.map(\.bitPattern) }
    static func mat(_ m: simd_float4x4) -> [UInt32] {
        // Engine row-major rows = simd columns.
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }.map(\.bitPattern)
    }
}

extension ParticleInstance {
    func pdumpState(_ count: Int) -> [String: Any] {
        let n = min(count, cap)
        func col<T>(_ a: [T], _ f: (T) -> Float) -> [UInt32] { PDump.bits((0..<n).map { f(a[$0]) }) }
        return [
            "px": col(pos) { $0.x }, "py": col(pos) { $0.y }, "pz": col(pos) { $0.z },
            "vx": col(vel) { $0.x }, "vy": col(vel) { $0.y }, "vz": col(vel) { $0.z },
            "ppx": col(prevPos) { $0.x }, "ppy": col(prevPos) { $0.y }, "ppz": col(prevPos) { $0.z },
            "life": col(life) { $0 }, "age": col(age) { $0 }, "size": col(size) { $0 }, "size0": col(size0) { $0 },
            "alpha": col(color) { $0.w }, "r": col(color) { $0.x }, "g": col(color) { $0.y }, "b": col(color) { $0.z },
            "alpha0": col(color0) { $0.w }, "r0": col(color0) { $0.x }, "g0": col(color0) { $0.y }, "b0": col(color0) { $0.z },
            "rx": col(rot) { $0.x }, "ry": col(rot) { $0.y }, "rz": col(rot) { $0.z }, "avx": col(angVel) { $0.x }, "avy": col(angVel) { $0.y }, "avz": col(angVel) { $0.z },
            "rnd": col(rnd) { $0 }, "phase": col(phase) { $0 },
            "cps": cps.map { PDump.mat($0.world) }, "prev": cps.map { PDump.mat($0.prev) },
            "highwater": highWater, "mask": Int(def.mask),
            "time": frame.time.bitPattern, "daytime": frame.daytime.bitPattern, "layertime": host.layerTime.bitPattern,
            "insttime": time.bitPattern, "top": PDump.mat(top),
            "colorn": PDump.bits([def.colorn.x, def.colorn.y, def.colorn.z]), "alive": alive, "paused": paused,
        ]
    }
}

extension ParticleInstance {
    /// Debug: the capsule builder inputs (collision_ref.build_capsules arguments, engine row-major).
    func modelCapsuleInputs(_ obj: SceneObject) -> [String: Any] {
        var mdl: MdlFile?, bones: [simd_float4x4] = []
        if let m = obj as? ModelObject { mdl = m.mdl; bones = m.skeleton?.boneWorld ?? [] }
        else if let l = obj as? ImageLayer, let pup = l.puppet { mdl = l.puppetFile; bones = pup.boneWorld }
        guard let mdl else { return [:] }
        let b = mdl.bounds
        return [
            "shapes": mdl.hitBoxes.map { ["e": PDump.bits([$0.halfExtents.x, $0.halfExtents.y, $0.halfExtents.z]),
                                          "S": PDump.bits($0.matrix)] },
            "bones": bones.map { PDump.mat($0) }, "world": PDump.mat(obj.world),
            "M": PDump.mat(worldSpace ? matrix_identity_float4x4 : top.inverse),
            "aabb": PDump.bits([b.min.x, b.min.y, b.min.z, b.max.x, b.max.y, b.max.z]),
        ]
    }
}
