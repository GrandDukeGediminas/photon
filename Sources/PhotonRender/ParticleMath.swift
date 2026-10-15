import Foundation
import PhotonCore
import simd

// Shared maths for the particle system (docs/re/05 Part 2 §2, Part 3 §3.14).

/// `std::mt19937` (MSVC), re-seeded with Unix-epoch milliseconds like the engine (docs/re/05 §9 "RNG").
struct MT19937 {
    private var mt = [UInt32](repeating: 0, count: 624)
    private var index = 624

    init(seed: UInt32) {
        mt[0] = seed
        for i in 1..<624 { mt[i] = 1_812_433_253 &* (mt[i - 1] ^ (mt[i - 1] >> 30)) &+ UInt32(i) }
    }

    mutating func next() -> UInt32 {
        if index >= 624 {
            for i in 0..<624 {
                let y = (mt[i] & 0x8000_0000) | (mt[(i + 1) % 624] & 0x7fff_ffff)
                var v = mt[(i + 397) % 624] ^ (y >> 1)
                if y & 1 != 0 { v ^= 0x9908_b0df }
                mt[i] = v
            }
            index = 0
        }
        var y = mt[index]
        index += 1
        y ^= y >> 11
        y ^= (y << 7) & 0x9d2c_5680
        y ^= (y << 15) & 0xefc6_0000
        y ^= y >> 18
        return y
    }
}

/// The engine's π constants: 0x40490fdb (π rounded to nearest; Swift's `Float.pi` is 0x40490fda, rounded toward zero) at
/// 0x140492834, used by the sphere emitter (0x140237db8), the cone parse (0x1401c61ba) and turbulentvelocityrandom
/// (0x14023b592); 2π = 0x40c90fdb at 0x140492864 / splat 0x140492f50 (phasemax defaults, mapsequencearoundcontrolpoint
/// 0x14023c656, oscillateposition 0x14024070f).
let pPi = Float(bitPattern: 0x4049_0fdb)
let pTwoPi = Float(bitPattern: 0x40c9_0fdb)

/// The engine's global particle RNG (ctx+0x1cd0) plus the MSVC CRT `rand()` used by hsvcolorrandom.
enum PRand {
    /// `PHOTON_SEED=<n>` fixes the seed (debug aid for comparing offline renders).
    static var engine = MT19937(seed: ProcessInfo.processInfo.environment["PHOTON_SEED"].flatMap { UInt32($0) }
        ?? UInt32(truncatingIfNeeded: UInt64(Date().timeIntervalSince1970 * 1000)))
    static var crtState: UInt32 = 1
    /// Debug (PHOTON_PDUMP): when set, every raw engine output / CRT `rand()` value drawn is appended, so a dump can be
    /// replayed under the emulator with the same draws.
    static var tape: [UInt32]?
    static var crtTape: [Int32]?

    @inline(__always) static func raw() -> UInt32 {
        let v = engine.next()
        if tape != nil { tape!.append(v) }
        return v
    }
    /// `(x>>8)·2^-24`, in [0, 1−2^-24].
    @inline(__always) static func unit() -> Float { Float(raw() >> 8) * (1.0 / 16_777_216.0) }
    /// Distribution A = {0, 1}.
    @inline(__always) static func a() -> Float { unit() }
    /// Distribution B = {1e-5, 1}, used by the sphere and box emitters.
    @inline(__always) static func b() -> Float { 1e-5 + (1 - 1e-5) * unit() }
    /// `std::uniform_int_distribution<u32>(0, n−1)`: `0x14024f410` (colorlist) and inlined at 0x140238f2f (layerimage), Lemire
    /// multiply-shift with rejection: m = x·b; while low32(m) < (2³² − b) mod b, redraw.
    static func uniformIndex(_ n: Int) -> Int {
        let r = UInt32(truncatingIfNeeded: n - 1)
        if r == 0xffff_ffff { return Int(raw()) }
        let b = r &+ 1
        var m = UInt64(raw()) * UInt64(b)
        if UInt32(truncatingIfNeeded: m) < b {
            let thr = (~r) % b
            while UInt32(truncatingIfNeeded: m) < thr { m = UInt64(raw()) * UInt64(b) }
        }
        return Int(m >> 32)
    }
    /// MSVC LCG `rand()` (0x1402c97a0).
    static func crt() -> Int32 {
        crtState = crtState &* 214_013 &+ 2_531_011
        let v = Int32((crtState >> 16) & 0x7fff)
        if crtTape != nil { crtTape!.append(v) }
        return v
    }
    /// Exponent-shaped random (Part 2 §2): exact `== 1` test, then powf.
    @inline(__always) static func exp(_ e: Float) -> Float { e == 1 ? unit() : powf(unit(), e) }
}

/// Gustavson simplex noise (simplexnoise1234 / SimplexNoise), with Ken Perlin's permutation table.
enum Simplex {
    static let p: [Int] = [151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225, 140, 36, 103, 30, 69, 142,
                           8, 99, 37, 240, 21, 10, 23, 190, 6, 148, 247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117,
                           35, 11, 32, 57, 177, 33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171, 168, 68, 175, 74, 165, 71,
                           134, 139, 48, 27, 166, 77, 146, 158, 231, 83, 111, 229, 122, 60, 211, 133, 230, 220, 105, 92, 41,
                           55, 46, 245, 40, 244, 102, 143, 54, 65, 25, 63, 161, 1, 216, 80, 73, 209, 76, 132, 187, 208, 89,
                           18, 169, 200, 196, 135, 130, 116, 188, 159, 86, 164, 100, 109, 198, 173, 186, 3, 64, 52, 217, 226,
                           250, 124, 123, 5, 202, 38, 147, 118, 126, 255, 82, 85, 212, 207, 206, 59, 227, 47, 16, 58, 17, 182,
                           189, 28, 42, 223, 183, 170, 213, 119, 248, 152, 2, 44, 154, 163, 70, 221, 153, 101, 155, 167, 43,
                           172, 9, 129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104, 218, 246, 97,
                           228, 251, 34, 242, 193, 238, 210, 144, 12, 191, 179, 162, 241, 81, 51, 145, 235, 249, 14, 239,
                           107, 49, 192, 214, 31, 181, 199, 106, 157, 184, 84, 204, 176, 115, 121, 50, 45, 127, 4, 150, 254,
                           138, 236, 205, 93, 222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66, 215, 61, 156, 180]
    static let perm: [Int] = (0..<512).map { p[$0 & 255] }
    static let permMod12: [Int] = perm.map { $0 % 12 }
    static let grad3: [SIMD3<Float>] = [[1, 1, 0], [-1, 1, 0], [1, -1, 0], [-1, -1, 0], [1, 0, 1], [-1, 0, 1], [1, 0, -1], [-1, 0, -1],
                                        [0, 1, 1], [0, -1, 1], [0, 1, -1], [0, -1, -1]]

    /// cvttss2si, then −1 when the truncation is above x (0x14027b1dd–0x14027b1f1): a true floor.
    @inline(__always) static func floorI(_ x: Float) -> Int32 {
        let i: Int32 = (x.isFinite && abs(x) < 2_147_483_648) ? Int32(x) : Int32.min
        return Float(i) > x ? i &- 1 : i
    }

    /// `0x14027b170` snoise2 (positionoffsetrandom), float32 in instruction order (session 7, r7/particles/emu/
    /// emu_posoff via the InitParticle replay): byte-wrapped perm lookups, u/v swapped when `hash & 0x3c` (not `& 7 ≥ 4`),
    /// bit 0 negates u, bit 1 negates v (·−2, else v + v), × 0x4234ec30.
    static func noise2(_ x: Float, _ y: Float) -> Float {
        let F2 = Float(bitPattern: 0x3ebb_67ae), G2 = Float(bitPattern: 0x3e58_658c), G2x2 = Float(bitPattern: 0x3ed8_658c)
        let s = (x + y) * F2
        let i = floorI(s + x), j = floorI(s + y)
        let t = Float(j &+ i) * G2
        let x0 = x - (Float(i) - t), y0 = y - (Float(j) - t)
        let i1: Int32 = x0 > y0 ? 1 : 0, j1: Int32 = 1 - i1
        let ib = Int(UInt8(truncatingIfNeeded: i)), jb = Int(UInt8(truncatingIfNeeded: j))
        @inline(__always) func g(_ h: Int, _ px: Float, _ py: Float) -> Float {
            var u = px, v = py
            if h & 0x3c != 0 { u = py; v = px }
            if h & 1 != 0 { u = -u }
            v = h & 2 != 0 ? v * -2 : v + v
            return v + u
        }
        var n0: Float = 0, n1: Float = 0, n2: Float = 0
        var t0 = (0.5 - x0 * x0) - y0 * y0
        if !(0 > t0) {
            t0 *= t0
            n0 = g(p[(ib + p[jb]) & 0xff], x0, y0) * (t0 * t0)
        }
        let x1 = (x0 - Float(i1)) + G2, y1 = (y0 - Float(j1)) + G2
        var t1 = (0.5 - x1 * x1) - y1 * y1
        if !(0 > t1) {
            t1 *= t1
            n1 = g(p[(Int(i1) + p[(jb + Int(j1)) & 0xff] + ib) & 0xff], x1, y1) * (t1 * t1)
        }
        let x2 = (x0 - 1) + G2x2, y2 = (y0 - 1) + G2x2
        var t2 = (0.5 - x2 * x2) - y2 * y2
        if !(0 > t2) {
            t2 *= t2
            n2 = g(p[(ib + 1 + p[(jb + 1) & 0xff]) & 0xff], x2, y2) * (t2 * t2)
        }
        return ((n1 + n0) + n2) * Float(bitPattern: 0x4234_ec30)
    }

    /// `0x1400fd010` 3-D simplex (turbulence operator; noise singleton vt+0x10 0x1400fbe40), one SIMD lane. Validated
    /// bit-exact against the binary (session 7, r7/particles/emu/emu_noise3.py, 1304 lanes incl. ties and integers).
    /// Differences from Gustavson's reference: the corner masks below (ties go to x, then strict y / z), the dot product
    /// summed z, y, x, and the last corner hashing perm[kk] instead of perm[kk + 1] (0x1400fd682).
    static func noise3(_ xin: Float, _ yin: Float, _ zin: Float) -> Float {
        let F3 = Float(bitPattern: 0x3eaa_aaab), G3 = Float(bitPattern: 0x3e2a_aaab), G3x2 = Float(bitPattern: 0x3eaa_aaab)
        let s = ((yin + zin) + xin) * F3
        let i = floorI(xin + s), j = floorI(yin + s), k = floorI(zin + s)
        let t = Float((k &+ j) &+ i) * G3
        let x0 = xin - (Float(i) - t), y0 = yin - (Float(j) - t), z0 = zin - (Float(k) - t)
        let A = y0 <= x0 && z0 <= x0, B = x0 < y0 && z0 < y0, C = x0 < z0 && y0 < z0
        let D = A || (x0 < y0 && z0 <= x0) || (x0 < z0 && y0 <= x0)
        let E = B || (y0 < z0 && x0 < y0) || (z0 <= y0 && y0 <= x0)
        let Fz = C || (z0 <= y0 && x0 < z0) || (y0 < z0 && z0 <= x0)
        @inline(__always) func b(_ v: Bool) -> Int { v ? 1 : 0 }
        let ii = Int(i & 255), jj = Int(j & 255), kk = Int(k & 255)
        @inline(__always) func c(_ x: Float, _ y: Float, _ z: Float, _ gi: Int) -> Float {
            let tt = ((0.6 - x * x) - y * y) - z * z
            let g = grad3[gi]
            let d = ((g.z * z) + (g.y * y)) + (g.x * x)
            let t2 = tt * tt
            return 0 > tt ? 0 : d * (t2 * t2)
        }
        let n0 = c(x0, y0, z0, permMod12[ii + perm[jj + perm[kk]]])
        let n1 = c((x0 - Float(b(A))) + G3, (y0 - Float(b(B))) + G3, (z0 - Float(b(C))) + G3,
                   permMod12[ii + b(A) + perm[jj + b(B) + perm[kk + b(C)]]])
        let n2 = c((x0 - Float(b(D))) + G3x2, (y0 - Float(b(E))) + G3x2, (z0 - Float(b(Fz))) + G3x2,
                   permMod12[ii + b(D) + perm[jj + b(E) + perm[kk + b(Fz)]]])
        let n3 = c((x0 - 1) + 0.5, (y0 - 1) + 0.5, (z0 - 1) + 0.5, permMod12[ii + 1 + perm[jj + 1 + perm[kk]]])
        return (((n3 + n2) + n1) + n0) * 32
    }
}

/// Colour conversion, hue in turns: rgb2hsv 0x1401b8b90 / hsv2rgb 0x1401b8c70 (gaps6/particles/dis/hsv.s).
enum HSV {
    /// `max − min < 1e-5` or `max ≤ 0` gives (0, 0, max).
    static func fromRGB(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let mx = sseMax(sseMax(c.x, c.y), c.z), mn = sseMin(sseMin(c.x, c.y), c.z)
        let d = mx - mn
        guard !(Float(1e-5) > d), mx > 0 else { return SIMD3(0, 0, mx) }
        var h: Float
        if c.x >= mx { h = (c.y - c.z) / d } else if c.y >= mx { h = Float(Double((c.z - c.x) / d) + 2) } else {
            h = Float(Double((c.x - c.y) / d) + 4)
        }
        h /= 6
        if 0 > h { h += 1 }
        return SIMD3(h, d / mx, mx)
    }

    /// h6 = fmod(h·6, 6) (double); a negative or NaN h6 leaves only the grey m = v − v·s.
    static func toRGB(_ hsv: SIMD3<Float>) -> SIMD3<Float> {
        let v = hsv.z, c = v * hsv.y
        let h6 = Float(fmod(Double(hsv.x * 6), 6))
        let x = Float((1 - abs(fmod(Double(h6), 2) - 1)) * Double(c))
        let m = v - c
        var r: Float = 0, g: Float = 0, b: Float = 0
        if h6 >= 0 && 1 > h6 { r = c; g = x } else if h6 >= 1 && 2 > h6 { r = x; g = c } else if h6 >= 2 && 3 > h6 { g = c; b = x }
        else if h6 >= 3 && 4 > h6 { g = x; b = c } else if h6 >= 4 && 5 > h6 { r = x; b = c } else if h6 >= 5 && 6 > h6 { r = c; b = x }
        return SIMD3(r + m, g + m, b + m)
    }
}

/// SSE `maxss a, b` / `minss a, b`: the second operand when either is NaN.
@inline(__always) func sseMax(_ a: Float, _ b: Float) -> Float { a > b ? a : b }
@inline(__always) func sseMin(_ a: Float, _ b: Float) -> Float { a < b ? a : b }
/// `minps(x, 1)` then `maxps(0, ·)`: NaN → 1.
@inline(__always) func sseClamp01(_ x: Float) -> Float { sseMax(0, sseMin(x, 1)) }

/// The particle noise object (singleton *0x1404e52d8, SSE4.1 vtable 0x140488440) used by the remapvalue transforms:
/// gain 0.5, weight 0, lacunarity 2. Ported from gaps6/particles/noise_ref.py (bit-exact against the binary).
enum PNoise {
    static let F2 = Float(bitPattern: 0x3ebb_67ae), G2 = Float(bitPattern: 0x3e58_658c)
    static let G2x2m1 = Float(bitPattern: 0xbf13_cd3a), R2P1 = Float(bitPattern: 0x401a_827a)
    static let scale = Float(bitPattern: 0x4219_227f)
    static let xPrime: UInt32 = 0x1DDE_90C9, yPrime: UInt32 = 0x43C4_2E4D, hashMul: UInt32 = 0x27D4_EB2D

    /// cvtps2dq: round to nearest even; NaN / ±inf / out of range → 0x80000000.
    @inline(__always) static func cvt(_ x: Float) -> UInt32 {
        guard x.isFinite else { return 0x8000_0000 }
        let v = x.rounded(.toNearestOrEven)
        guard v >= -2_147_483_648, v < 2_147_483_648 else { return 0x8000_0000 }
        return UInt32(bitPattern: Int32(v))
    }

    @inline(__always) static func hash(_ seed: UInt32, _ i: UInt32, _ j: UInt32) -> UInt32 {
        let h = (seed ^ i ^ j) &* hashMul
        return h ^ UInt32(bitPattern: Int32(bitPattern: h) >> 15)
    }

    @inline(__always) static func grad(_ h: UInt32, _ x: Float, _ y: Float) -> Float {
        let gx = h & 1 != 0 ? -x : x, gy = h & 2 != 0 ? -y : y
        return h & 4 != 0 ? gy * R2P1 + gx : gx * R2P1 + gy
    }

    @inline(__always) static func falloff(_ a: Float, _ b: Float) -> Float {
        var t = (0.5 - b * b) - a * a
        t = t > 0 ? t : 0
        t = t * t
        return t * t
    }

    /// `0x1400fbe90` Noise2D (one lane).
    static func noise2(_ seed: UInt32, _ x: Float, _ y: Float) -> Float {
        let s = (x + y) * F2
        let fy = floorf(s + y), fx = floorf(s + x)
        let j = cvt(fy) &* yPrime, i = cvt(fx) &* xPrime
        let t = G2 * (fy + fx)
        let y0 = y - (fy - t), x0 = x - (fx - t)
        let i1 = y0 < x0
        let x1 = (x0 - (i1 ? 1 : 0)) + G2, y1 = (y0 - (i1 ? 0 : 1)) + G2
        let x2 = x0 + G2x2m1, y2 = y0 + G2x2m1
        let t0 = falloff(x0, y0), t1 = falloff(x1, y1), t2 = falloff(x2, y2)
        let n0 = grad(hash(seed, i, j), x0, y0)
        let n1 = grad(hash(seed, i &+ (i1 ? xPrime : 0), j &+ (i1 ? 0 : yPrime)), x1, y1)
        let n2 = grad(hash(seed, i &+ xPrime, j &+ yPrime), x2, y2)
        return ((n2 * t2 + n1 * t1) + n0 * t0) * scale
    }

    /// `0x1400fb740`: 1 / Σ_{k<n} 0.5^k (n ≤ 1 → 1).
    static func fbmNorm(_ octaves: Int) -> Float {
        let g: Float = 0.5
        var acc: Float = 1, p = g
        var k = 1
        while k < octaves { acc += p; p *= g; k += 1 }
        return 1 / acc
    }

    /// `0x1400fbc70`: seed + 1, x and y × 2, amplitude × 0.5 per octave; `amp` is the first-octave amplitude.
    static func fbm(_ seed0: UInt32, _ x0: Float, _ y0: Float, _ octaves: Int, _ amp0: Float) -> Float {
        let gain: Float = 0.5, lac: Float = 2, weight: Float = 0
        var x = x0, y = y0, seed = seed0, amp = amp0
        var n = noise2(seed, x, y)
        var s = n * amp
        var k = 1
        while k < octaves {
            x *= lac; y *= lac; seed &+= 1
            let w = (((1 + n) * 0.5) - 1) * weight + 1
            amp = (amp * w) * gain
            n = noise2(seed, x, y)
            s += n * amp
            k += 1
        }
        return s
    }

    /// `0x14027b090`: 1-D simplex over Ken Perlin's permutation bytes (0x140484f40), × 0.395 (initremap_ref.snoise1).
    static func snoise1(_ x: Float) -> Float {
        var i0: Int32
        if x.isFinite && abs(x) < 2_147_483_648 { i0 = Int32(x) } else { i0 = Int32.min }
        if Float(i0) > x { i0 &-= 1 }
        let x0 = x - Float(i0), x1 = x0 - 1
        let h0 = Simplex.p[Int(i0 & 0xff)], h1 = Simplex.p[Int((i0 &+ 1) & 0xff)]
        var g0 = Float((h0 & 7) + 1); if h0 & 8 != 0 { g0 = -g0 }
        var g1 = Float((h1 & 7) + 1); if h1 & 8 != 0 { g1 = -g1 }
        var t0 = 1 - x0 * x0; t0 = t0 * t0; t0 = t0 * t0
        var t1 = 1 - x1 * x1; t1 = t1 * t1; t1 = t1 * t1
        let n0 = (g0 * x0) * t0, n1 = (g1 * x1) * t1
        return (n1 + n0) * Float(bitPattern: 0x3eca_3d71)
    }

    /// `0x14027b4b0`: Σ noise(f·x)·a / Σ a, f ×= lac, a ×= gain (0 octaves → 0/0).
    static func fbm1(_ x: Float, _ octaves: Int, freq: Float, amp: Float, lac: Float, gain: Float) -> Float {
        var s: Float = 0, norm: Float = 0, f = freq, a = amp
        var k = 0
        while k < octaves {
            let v = f * x
            norm += a; f *= lac
            let n = snoise1(v)
            s += n * a; a *= gain
            k += 1
        }
        return s / norm
    }

    /// Cephes 4-wide sinf inlined in the remapvalue operator (0x140245150..0x14024524d), one lane.
    static func sinPS(_ x: Float) -> Float {
        let fopi = Float(bitPattern: 0x3fa2_f983)
        let dp1 = Float(bitPattern: 0xbf49_0000), dp2 = Float(bitPattern: 0xb97d_a000), dp3 = Float(bitPattern: 0xb322_2169)
        let cos0 = Float(bitPattern: 0x37cc_f5ce), cos1 = Float(bitPattern: 0xbab6_061a), cos2 = Float(bitPattern: 0x3d2a_aaa5)
        let sin0 = Float(bitPattern: 0xb94c_a1f9), sin1 = Float(bitPattern: 0x3c08_839e), sin2 = Float(bitPattern: 0xbe2a_aaa3)
        let sign = x.bitPattern & 0x8000_0000
        let ax = abs(x)
        let prod = ax * fopi
        let jt: UInt32 = (prod.isFinite && prod < 2_147_483_648) ? UInt32(bitPattern: Int32(prod)) : 0x8000_0000
        let j = (jt &+ 1) & 0xffff_fffe
        let y = Float(Int32(bitPattern: j))
        let swap = (j & 4) << 29
        let xr = ((y * dp1 + ax) + y * dp2) + y * dp3
        let z = xr * xr
        var c = ((((z * cos0 + cos1) * z) + cos2) * z) * z - z * 0.5
        c = c + 1
        var s = (((z * sin0 + sin1) * z) + sin2) * z * xr
        s = s + xr
        let r = (j & 2) == 0 ? s : c
        return Float(bitPattern: r.bitPattern ^ (sign ^ swap))
    }
}

@inline(__always) func clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }

/// `0x140184440`: v·M for a 3×3 of engine rows (simd columns), summed (x·r0 + y·r1) + z·r2 without fused multiply-adds.
@inline(__always) func rowMul(_ v: SIMD3<Float>, _ m: simd_float3x3) -> SIMD3<Float> {
    let a = m.columns.0, b = m.columns.1, c = m.columns.2
    return SIMD3((v.x * a.x + v.y * b.x) + v.z * c.x, (v.x * a.y + v.y * b.y) + v.z * c.y, (v.x * a.z + v.y * b.z) + v.z * c.z)
}

/// glm::rotate(mat4(1), angle, axis) (0x1401e2500) applied to `v` as the engine does (mat3 rows, 0x140184440): axis scaled
/// by 1/sqrt((x² + y²) + z²), temp = (1 − c)·axis, R[0] = (c + temp.x·x, temp.x·y + s·z, temp.x·z − s·y), …
func glmRotateApply(angle: Float, axis v: SIMD3<Float>, _ p: SIMD3<Float>) -> SIMD3<Float> {
    let c = cosf(angle), s = sinf(angle)
    let l = sqrtf((v.x * v.x + v.y * v.y) + v.z * v.z)
    let inv = 1 / l
    let x = v.x * inv, y = v.y * inv, z = v.z * inv
    let k = 1 - c
    let tx = x * k, ty = y * k, tz = z * k
    let r0 = SIMD3<Float>(tx * x + c, tx * y + z * s, tx * z - y * s)
    let r1 = SIMD3<Float>(ty * x - z * s, ty * y + c, ty * z + x * s)
    let r2 = SIMD3<Float>(tz * x + y * s, tz * y - x * s, tz * z + c)
    return rowMul(p, simd_float3x3(r0, r1, r2))
}

extension simd_float4x4 {
    var translation: SIMD3<Float> { SIMD3(columns.3.x, columns.3.y, columns.3.z) }
    var m3: simd_float3x3 {
        simd_float3x3(SIMD3(columns.0.x, columns.0.y, columns.0.z), SIMD3(columns.1.x, columns.1.y, columns.1.z),
                      SIMD3(columns.2.x, columns.2.y, columns.2.z))
    }
    func point(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let r = self * SIMD4(p, 1)
        return SIMD3(r.x, r.y, r.z)
    }
}

/// Typed access to a particle JSON object. `null` and missing keys both take the default, like the
/// engine's default fillers (Part 2 §0).
struct PJ {
    let d: [String: Any]
    init(_ d: Any?) { self.d = (d as? [String: Any]) ?? [:] }

    func has(_ k: String) -> Bool { d[k] != nil && !(d[k] is NSNull) }
    func f(_ k: String, _ def: Float) -> Float {
        guard has(k) else { return def }
        if let b = d[k] as? Bool { return b ? 1 : 0 }
        return jsonFloats(d[k]).first ?? def
    }
    func i(_ k: String, _ def: Int) -> Int {
        guard has(k) else { return def }
        return Int(jsonFloats(d[k]).first ?? Float(def))
    }
    func b(_ k: String, _ def: Bool) -> Bool { has(k) ? jsonBool(d[k], default: def) : def }
    func s(_ k: String, _ def: String) -> String {
        guard has(k) else { return def }
        return (unwrapUserValue(d[k]) as? String) ?? def
    }
    /// Vector strings: up to three `strtod` values; missing components stay 0. A number fills `scalarAs`.
    func v3(_ k: String, _ def: SIMD3<Float>, scalar: ((Float) -> SIMD3<Float>)? = nil) -> SIMD3<Float> {
        guard has(k) else { return def }
        if let n = unwrapUserValue(d[k]) as? NSNumber {
            let x = n.floatValue
            return scalar?(x) ?? SIMD3(x, x, x)
        }
        let f = jsonFloats(d[k])
        if f.isEmpty { return def }
        return SIMD3(f[0], f.count > 1 ? f[1] : 0, f.count > 2 ? f[2] : 0)
    }
}

/// Euler rotation shared by control-point angle overrides and child transforms (docs/re/05 §5.2): rows of
/// the engine's row-vector matrix, returned as a column-vector simd matrix (rows become columns).
func particleEulerMatrix(_ a: SIMD3<Float>) -> simd_float3x3 {
    let cx = cos(a.x), sx = sin(a.x), cy = cos(a.y), sy = sin(a.y), cz = cos(a.z), sz = sin(a.z)
    let r0 = SIMD3<Float>(cy * cz, cy * sz, -sy)
    let r1 = SIMD3<Float>(sx * sy * cz - cx * sz, sx * sy * sz + cx * cz, sx * cy)
    let r2 = SIMD3<Float>(cx * sy * cz + sx * sz, cx * sy * sz - sx * cz, cx * cy)
    return simd_float3x3(r0, r1, r2)
}

/// Engine-exact 4×4 helpers for the particle system's matrix stack (simd columns hold the engine's rows).
enum PMat {
    /// `0x14005ecb0(out, A, B)`: engine B × A (row vectors), i.e. simd A * B, summed in the binary's order.
    static func mul(_ a: simd_float4x4, _ b: simd_float4x4) -> simd_float4x4 {
        var o = simd_float4x4()
        for i in 0..<4 {
            for j in 0..<4 {
                o[i][j] = ((b[i][0] * a[0][j] + b[i][1] * a[1][j]) + b[i][2] * a[2][j]) + b[i][3] * a[3][j]
            }
        }
        return o
    }

    /// `0x14005f730` / `0x14005f0d0`: the engine's other two 4×4 inverses give the same bits as glm's SSE inverse
    /// 0x1402290d0 (emulator, 200 random matrices each; scratchpad r7/particles2/emu/inv_cmp.py), so one port serves all.
    static func inverse(_ m: simd_float4x4) -> simd_float4x4 { inverseSSE(m) }

    /// `0x140228b00` (via 0x140228390): glm::inverse of the upper 3×3 (`0x1400dd7d0` packs it), scalar, in the binary's
    /// order; `divss` for 1/det. Returns glm's columns inv[k] (= simd columns of `m`'s convention). maintaindistance op 11.
    static func inverse3(_ M: simd_float4x4) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        let m00 = M[0][0], m01 = M[0][1], m02 = M[0][2], m10 = M[1][0], m11 = M[1][1], m12 = M[1][2]
        let m20 = M[2][0], m21 = M[2][1], m22 = M[2][2]
        let c00 = m22 * m11 - m21 * m12
        let det = (c00 * m00 - (m22 * m01 - m21 * m02) * m10) + (m01 * m12 - m11 * m02) * m20
        let inv = 1 / det
        let i00 = c00 * inv
        let i10 = -(m22 * m10 - m20 * m12) * inv
        let i20 = (m21 * m10 - m20 * m11) * inv
        let i01 = -(m22 * m01 - m21 * m02) * inv
        let i11 = (m22 * m00 - m20 * m02) * inv
        let i21 = -(m21 * m00 - m20 * m01) * inv
        let i02 = (m12 * m01 - m11 * m02) * inv
        let i12 = -(m12 * m00 - m10 * m02) * inv
        let i22 = (m11 * m00 - m10 * m01) * inv
        return (SIMD3(i00, i01, i02), SIMD3(i10, i11, i12), SIMD3(i20, i21, i22))
    }

    /// `0x1402290d0`: glm's SSE `glm_mat4_inverse` (the CP resolve / override path), lane for lane; checked against the
    /// binary under the emulator on 300 random matrices (scratchpad r7/particles2/emu/glm_inv.py). Rows in = simd columns.
    static func inverseSSE(_ m: simd_float4x4) -> simd_float4x4 {
        typealias V = SIMD4<Float>
        let i0 = m.columns.0, i1 = m.columns.1, i2 = m.columns.2, i3 = m.columns.3
        // _mm_shuffle_ps(a, b, _MM_SHUFFLE(z, y, x, w)) = (a[w], a[x], b[y], b[z])
        @inline(__always) func sh(_ a: V, _ b: V, _ z: Int, _ y: Int, _ x: Int, _ w: Int) -> V { V(a[w], a[x], b[y], b[z]) }
        @inline(__always) func fac(_ a3: Int, _ b3: Int, _ s00: Int, _ s03: Int) -> V {
            let swp0a = sh(i3, i2, a3, a3, a3, a3), swp0b = sh(i3, i2, b3, b3, b3, b3)
            let swp00 = sh(i2, i1, s00, s00, s00, s00), swp01 = sh(swp0a, swp0a, 2, 0, 0, 0)
            let swp02 = sh(swp0b, swp0b, 2, 0, 0, 0), swp03 = sh(i2, i1, s03, s03, s03, s03)
            return swp00 * swp01 - swp02 * swp03
        }
        let f0 = fac(3, 2, 2, 3), f1 = fac(3, 1, 1, 3), f2 = fac(2, 1, 1, 2)
        let f3 = fac(3, 0, 0, 3), f4 = fac(2, 0, 0, 2), f5 = fac(1, 0, 0, 1)
        let signA = V(-1, 1, -1, 1), signB = V(1, -1, 1, -1)
        @inline(__always) func vec(_ k: Int) -> V { let t = sh(i1, i0, k, k, k, k); return sh(t, t, 2, 2, 2, 0) }
        let v0 = vec(0), v1 = vec(1), v2 = vec(2), v3 = vec(3)
        let inv0 = signB * ((v1 * f0 - v2 * f1) + v3 * f2)
        let inv1 = signA * ((v0 * f0 - v2 * f3) + v3 * f4)
        let inv2 = signB * ((v0 * f1 - v1 * f3) + v3 * f5)
        let inv3 = signA * ((v0 * f2 - v1 * f4) + v2 * f5)
        let r0 = sh(inv0, inv1, 0, 0, 0, 0), r1 = sh(inv2, inv3, 0, 0, 0, 0), r2 = sh(r0, r1, 2, 0, 2, 0)
        let mul0 = i0 * r2, swp0 = sh(mul0, mul0, 2, 3, 0, 1), add0 = mul0 + swp0
        let swp1 = sh(add0, add0, 0, 1, 2, 3), add1 = add0 + swp1
        let rcp = V(repeating: 1) / add1
        return simd_float4x4(inv0 * rcp, inv1 * rcp, inv2 * rcp, inv3 * rcp)
    }

    /// A translation matrix built the way 0x14022a360 builds it (identity rows, row 3 = (p, 1)).
    static func translate(_ p: SIMD3<Float>) -> simd_float4x4 {
        var o = matrix_identity_float4x4
        o.columns.3 = SIMD4(p, 1)
        return o
    }
}
