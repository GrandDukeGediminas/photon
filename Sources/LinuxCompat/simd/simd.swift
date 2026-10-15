// Linux stand-in for Apple's simd module (docs/linux-port.md §4).
//
// Only the surface photon2 uses: vector typealiases, the float 3×3 / 4×4 matrices, simd_quatf and the simd_* free
// functions. Numerics follow Apple's headers (<simd/common.h>, geometry.h, matrix.h, quaternion.h) as compiled for
// arm64 macOS, so results match the Metal build bit for bit where possible:
// - clang contracts `a*b + c` inside one expression to an FMA (FP_CONTRACT ON); the same contractions are written out
//   here with `addingProduct` (a fused multiply-add);
// - simd_rsqrt / simd_recip are the NEON estimate + Newton-Raphson sequences (FRSQRTE/FRSQRTS, FRECPE/FRECPS),
//   with the estimate instructions emulated in software from the ARM ARM pseudocode;
// - scalar libm calls in the headers (sin, cos, sqrt, atan2) are the float versions (<tgmath.h>); Apple's are
//   (near) correctly rounded, reproduced here by the double function rounded to float.
// Matrix inverse is Apple's `__invert_f3/f4` (libsystem_m, not in the headers), transcribed instruction by instruction
// from its arm64 disassembly.

import Foundation

// MARK: - Vector typealiases

public typealias simd_float2 = SIMD2<Float>
public typealias simd_float3 = SIMD3<Float>
public typealias simd_float4 = SIMD4<Float>
public typealias simd_float8 = SIMD8<Float>
public typealias simd_float16 = SIMD16<Float>
public typealias simd_double2 = SIMD2<Double>
public typealias simd_double3 = SIMD3<Double>
public typealias simd_double4 = SIMD4<Double>
public typealias simd_int2 = SIMD2<Int32>
public typealias simd_int3 = SIMD3<Int32>
public typealias simd_int4 = SIMD4<Int32>
public typealias simd_uint2 = SIMD2<UInt32>
public typealias simd_uint3 = SIMD3<UInt32>
public typealias simd_uint4 = SIMD4<UInt32>
public typealias simd_uchar4 = SIMD4<UInt8>
public typealias simd_ushort2 = SIMD2<UInt16>
public typealias simd_short2 = SIMD2<Int16>
public typealias vector_float2 = SIMD2<Float>
public typealias vector_float3 = SIMD3<Float>
public typealias vector_float4 = SIMD4<Float>
public typealias float2 = SIMD2<Float>
public typealias float3 = SIMD3<Float>
public typealias float4 = SIMD4<Float>
public typealias double2 = SIMD2<Double>
public typealias double3 = SIMD3<Double>
public typealias double4 = SIMD4<Double>
public typealias int2 = SIMD2<Int32>
public typealias int3 = SIMD3<Int32>
public typealias int4 = SIMD4<Int32>
public typealias uint2 = SIMD2<UInt32>
public typealias uint3 = SIMD3<UInt32>
public typealias uint4 = SIMD4<UInt32>

@inlinable public func simd_make_float2(_ x: Float, _ y: Float) -> SIMD2<Float> { SIMD2(x, y) }
@inlinable public func simd_make_float3(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { SIMD3(x, y, z) }
@inlinable public func simd_make_float3(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }
@inlinable public func simd_make_float3(_ v: SIMD2<Float>, _ z: Float) -> SIMD3<Float> { SIMD3(v.x, v.y, z) }
@inlinable public func simd_make_float4(_ x: Float, _ y: Float, _ z: Float, _ w: Float) -> SIMD4<Float> { SIMD4(x, y, z, w) }
@inlinable public func simd_make_float4(_ v: SIMD3<Float>, _ w: Float) -> SIMD4<Float> { SIMD4(v.x, v.y, v.z, w) }

// MARK: - ARM estimate instructions (FRECPE / FRSQRTE / FRECPS / FRSQRTS), FPCR.FZ = 0, round to nearest

@usableFromInline enum _ARM {
    /// RecipEstimate (ARM ARM, shared/functions/float/fprecipestimate), 9-bit input → 9-bit result in [256, 511].
    @inlinable static func recipEstimate(_ a0: Int) -> Int {
        let a = a0 * 2 + 1
        let b = (1 << 19) / a
        return (b + 1) / 2
    }

    /// RecipSqrtEstimate: input in [128, 511], result in [256, 511].
    @inlinable static func recipSqrtEstimate(_ a0: Int) -> Int {
        var a = a0
        if a < 256 { a = a * 2 + 1 } else { a = (a >> 1) << 1; a = (a + 1) * 2 }
        var b = 512
        while a * (b + 1) * (b + 1) < (1 << 28) { b += 1 }
        return (b + 1) / 2
    }

    /// FRECPE, single precision.
    @inlinable static func frecpe(_ x: Float) -> Float {
        if x.isNaN { return .nan }
        if x.isInfinite { return x.sign == .minus ? -0.0 : 0.0 }
        if x == 0 { return x.sign == .minus ? -.infinity : .infinity }
        let bits = x.bitPattern
        let sign = bits & 0x8000_0000
        if abs(x) < 0x1p-128 { return Float(bitPattern: sign | 0x7f80_0000) } // overflow → ±inf (RN)
        var fraction = UInt64(bits & 0x007f_ffff) << 29 // 52-bit fraction field
        var exp = Int((bits >> 23) & 0xff)
        if exp == 0 {
            if (fraction >> 51) & 1 == 0 {
                exp = -1
                fraction = (fraction << 2) & ((1 << 52) - 1)
            } else {
                fraction = (fraction << 1) & ((1 << 52) - 1)
            }
        }
        let scaled = Int(1 << 8 | (fraction >> 44) & 0xff)
        var resultExp = 253 - exp
        let estimate = recipEstimate(scaled)
        fraction = UInt64(estimate & 0xff) << 44
        if resultExp == 0 {
            fraction = (1 << 51) | (fraction >> 1)
        } else if resultExp == -1 {
            fraction = (1 << 50) | (fraction >> 2)
            resultExp = 0
        }
        return Float(bitPattern: sign | UInt32(resultExp & 0xff) << 23 | UInt32(truncatingIfNeeded: fraction >> 29))
    }

    /// FRSQRTE, single precision.
    @inlinable static func frsqrte(_ x: Float) -> Float {
        if x.isNaN { return .nan }
        if x == 0 { return x.sign == .minus ? -.infinity : .infinity }
        if x.sign == .minus { return .nan }
        if x.isInfinite { return 0 }
        let bits = x.bitPattern
        var fraction = UInt64(bits & 0x007f_ffff) << 29
        var exp = Int((bits >> 23) & 0xff)
        if exp == 0 {
            while (fraction >> 51) & 1 == 0 {
                fraction = (fraction << 1) & ((1 << 52) - 1)
                exp -= 1
            }
            fraction = (fraction << 1) & ((1 << 52) - 1)
        }
        let scaled: Int = exp & 1 == 0 ? Int(1 << 8 | (fraction >> 44) & 0xff) : Int(1 << 7 | (fraction >> 45) & 0x7f)
        let resultExp = (380 - exp) / 2 // exp ≤ 254, so the dividend is positive: DIV = truncation
        let estimate = recipSqrtEstimate(scaled)
        return Float(bitPattern: UInt32(resultExp & 0xff) << 23 | UInt32(estimate & 0xff) << 15)
    }

    /// FRECPS: 2 − a·b, one rounding; (∞, 0) → 2.
    @inlinable static func frecps(_ a: Float, _ b: Float) -> Float {
        if (a.isInfinite && b == 0) || (a == 0 && b.isInfinite) { return 2 }
        return Float(2).addingProduct(-a, b)
    }

    /// FRSQRTS: (3 − a·b) / 2, one rounding; (∞, 0) → 1.5.
    @inlinable static func frsqrts(_ a: Float, _ b: Float) -> Float {
        if (a.isInfinite && b == 0) || (a == 0 && b.isInfinite) { return 1.5 }
        return Float(3).addingProduct(-a, b) * 0.5
    }
}

// MARK: - Scalar and lane-wise primitives (common.h)

/// simd_precise_rsqrt (arm64): FRSQRTE, then two FRSQRTS steps (simd_fast_rsqrt does the first).
@inlinable public func simd_precise_rsqrt(_ x: Float) -> Float {
    var r = _ARM.frsqrte(x)
    r = r * _ARM.frsqrts(x, r * r)
    return r * _ARM.frsqrts(x, r * r)
}
@inlinable public func simd_fast_rsqrt(_ x: Float) -> Float {
    let r = _ARM.frsqrte(x)
    return r * _ARM.frsqrts(x, r * r)
}
@inlinable public func simd_rsqrt(_ x: Float) -> Float { simd_precise_rsqrt(x) }

/// simd_precise_recip (arm64): FRECPE, then two FRECPS steps.
@inlinable public func simd_precise_recip(_ x: Float) -> Float {
    var r = _ARM.frecpe(x)
    r = r * _ARM.frecps(x, r)
    return r * _ARM.frecps(x, r)
}
@inlinable public func simd_fast_recip(_ x: Float) -> Float {
    let r = _ARM.frecpe(x)
    return r * _ARM.frecps(x, r)
}
@inlinable public func simd_recip(_ x: Float) -> Float { simd_precise_recip(x) }

@inlinable func _lanes<V: SIMD>(_ x: V, _ f: (V.Scalar) -> V.Scalar) -> V {
    var r = x
    for i in r.indices { r[i] = f(x[i]) }
    return r
}
@inlinable public func simd_precise_rsqrt<V: SIMD>(_ x: V) -> V where V.Scalar == Float { _lanes(x, simd_precise_rsqrt) }
@inlinable public func simd_rsqrt<V: SIMD>(_ x: V) -> V where V.Scalar == Float { _lanes(x, simd_precise_rsqrt) }
@inlinable public func simd_fast_rsqrt<V: SIMD>(_ x: V) -> V where V.Scalar == Float { _lanes(x, simd_fast_rsqrt) }
@inlinable public func simd_precise_recip<V: SIMD>(_ x: V) -> V where V.Scalar == Float { _lanes(x, simd_precise_recip) }
@inlinable public func simd_recip<V: SIMD>(_ x: V) -> V where V.Scalar == Float { _lanes(x, simd_precise_recip) }
@inlinable public func simd_fast_recip<V: SIMD>(_ x: V) -> V where V.Scalar == Float { _lanes(x, simd_fast_recip) }
@inlinable public func simd_rsqrt(_ x: Double) -> Double { 1 / x.squareRoot() }
@inlinable public func simd_recip(_ x: Double) -> Double { 1 / x }

/// fmin / fmax (FMINNM / FMAXNM): a NaN operand loses; −0 < +0.
@inlinable func _fmin<T: BinaryFloatingPoint>(_ a: T, _ b: T) -> T {
    if a.isNaN { return b }
    if b.isNaN { return a }
    if a == 0 && b == 0 { return a.sign == .minus ? a : b }
    return a < b ? a : b
}
@inlinable func _fmax<T: BinaryFloatingPoint>(_ a: T, _ b: T) -> T {
    if a.isNaN { return b }
    if b.isNaN { return a }
    if a == 0 && b == 0 { return a.sign == .minus ? b : a }
    return a > b ? a : b
}

@inlinable public func simd_min<V: SIMD>(_ a: V, _ b: V) -> V where V.Scalar: BinaryFloatingPoint {
    var r = a
    for i in r.indices { r[i] = _fmin(a[i], b[i]) }
    return r
}
@inlinable public func simd_max<V: SIMD>(_ a: V, _ b: V) -> V where V.Scalar: BinaryFloatingPoint {
    var r = a
    for i in r.indices { r[i] = _fmax(a[i], b[i]) }
    return r
}
@inlinable public func simd_min<V: SIMD>(_ a: V, _ b: V) -> V where V.Scalar: FixedWidthInteger { pointwiseMin(a, b) }
@inlinable public func simd_max<V: SIMD>(_ a: V, _ b: V) -> V where V.Scalar: FixedWidthInteger { pointwiseMax(a, b) }
@inlinable public func simd_min(_ a: Float, _ b: Float) -> Float { _fmin(a, b) }
@inlinable public func simd_max(_ a: Float, _ b: Float) -> Float { _fmax(a, b) }
@inlinable public func simd_min(_ a: Double, _ b: Double) -> Double { _fmin(a, b) }
@inlinable public func simd_max(_ a: Double, _ b: Double) -> Double { _fmax(a, b) }

@inlinable public func simd_clamp<V: SIMD>(_ x: V, _ lo: V, _ hi: V) -> V where V.Scalar: BinaryFloatingPoint {
    simd_min(simd_max(x, lo), hi)
}
@inlinable public func simd_clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float { _fmin(_fmax(x, lo), hi) }
@inlinable public func simd_clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { _fmin(_fmax(x, lo), hi) }

@inlinable public func simd_abs<V: SIMD>(_ x: V) -> V where V.Scalar: BinaryFloatingPoint { _lanes(x) { Swift.abs($0) } }
@inlinable public func simd_abs(_ x: Float) -> Float { Swift.abs(x) }

/// simd_mix: x + t·(y − x), contracted to fma(t, y − x, x).
@inlinable public func simd_mix<V: SIMD>(_ x: V, _ y: V, _ t: V) -> V where V.Scalar: FloatingPoint {
    let d = y - x
    var r = x
    for i in r.indices { r[i] = x[i].addingProduct(t[i], d[i]) }
    return r
}
@inlinable public func simd_mix(_ x: Float, _ y: Float, _ t: Float) -> Float { x.addingProduct(t, y - x) }

@inlinable public func simd_sign<V: SIMD>(_ x: V) -> V where V.Scalar: FloatingPoint {
    _lanes(x) { $0 > 0 ? 1 : ($0 < 0 ? -1 : 0) }
}
@inlinable public func simd_fract<V: SIMD>(_ x: V) -> V where V.Scalar: FloatingPoint {
    _lanes(x) { v in Swift.min(v - v.rounded(.down), V.Scalar(1) - V.Scalar.ulpOfOne / 2) }
}
@inlinable public func simd_step<V: SIMD>(_ edge: V, _ x: V) -> V where V.Scalar: FloatingPoint {
    var r = x
    for i in r.indices { r[i] = x[i] < edge[i] ? 0 : 1 }
    return r
}
@inlinable public func simd_smoothstep<V: SIMD>(_ e0: V, _ e1: V, _ x: V) -> V where V.Scalar: FloatingPoint {
    var r = x
    for i in r.indices {
        var t = (x[i] - e0[i]) / (e1[i] - e0[i])
        t = Swift.min(Swift.max(t, 0), 1)
        r[i] = t * t * (3 - 2 * t)
    }
    return r
}

@inlinable public func simd_reduce_add(_ x: SIMD2<Float>) -> Float { x.x + x.y }
@inlinable public func simd_reduce_add(_ x: SIMD3<Float>) -> Float { x.x + x.y + x.z }
/// reduce_add(x.lo + x.hi).
@inlinable public func simd_reduce_add(_ x: SIMD4<Float>) -> Float { (x.x + x.z) + (x.y + x.w) }
@inlinable public func simd_reduce_add(_ x: SIMD2<Double>) -> Double { x.x + x.y }
@inlinable public func simd_reduce_add(_ x: SIMD3<Double>) -> Double { x.x + x.y + x.z }
@inlinable public func simd_reduce_add(_ x: SIMD4<Double>) -> Double { (x.x + x.z) + (x.y + x.w) }

// MARK: - Geometry (geometry.h)

@inlinable public func simd_dot(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { simd_reduce_add(a * b) }
@inlinable public func simd_dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { simd_reduce_add(a * b) }
@inlinable public func simd_dot(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float { simd_reduce_add(a * b) }
@inlinable public func simd_dot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { simd_reduce_add(a * b) }
@inlinable public func simd_dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { simd_reduce_add(a * b) }
@inlinable public func simd_dot(_ a: SIMD4<Double>, _ b: SIMD4<Double>) -> Double { simd_reduce_add(a * b) }

@inlinable public func simd_length_squared(_ x: SIMD2<Float>) -> Float { simd_dot(x, x) }
@inlinable public func simd_length_squared(_ x: SIMD3<Float>) -> Float { simd_dot(x, x) }
@inlinable public func simd_length_squared(_ x: SIMD4<Float>) -> Float { simd_dot(x, x) }
@inlinable public func simd_length_squared(_ x: SIMD2<Double>) -> Double { simd_dot(x, x) }
@inlinable public func simd_length_squared(_ x: SIMD3<Double>) -> Double { simd_dot(x, x) }
@inlinable public func simd_length_squared(_ x: SIMD4<Double>) -> Double { simd_dot(x, x) }

@inlinable public func simd_length(_ x: SIMD2<Float>) -> Float { simd_length_squared(x).squareRoot() }
@inlinable public func simd_length(_ x: SIMD3<Float>) -> Float { simd_length_squared(x).squareRoot() }
@inlinable public func simd_length(_ x: SIMD4<Float>) -> Float { simd_length_squared(x).squareRoot() }
@inlinable public func simd_length(_ x: SIMD2<Double>) -> Double { simd_length_squared(x).squareRoot() }
@inlinable public func simd_length(_ x: SIMD3<Double>) -> Double { simd_length_squared(x).squareRoot() }
@inlinable public func simd_length(_ x: SIMD4<Double>) -> Double { simd_length_squared(x).squareRoot() }
@inlinable public func simd_precise_length(_ x: SIMD3<Float>) -> Float { simd_length(x) }
@inlinable public func simd_precise_length(_ x: SIMD4<Float>) -> Float { simd_length(x) }

@inlinable public func simd_distance(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { simd_length(a - b) }
@inlinable public func simd_distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { simd_length(a - b) }
@inlinable public func simd_distance(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float { simd_length(a - b) }
@inlinable public func simd_distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { simd_length(a - b) }
@inlinable public func simd_distance_squared(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { simd_length_squared(a - b) }

/// x · simd_precise_rsqrt(|x|²).
@inlinable public func simd_normalize(_ x: SIMD2<Float>) -> SIMD2<Float> { x * simd_precise_rsqrt(simd_length_squared(x)) }
@inlinable public func simd_normalize(_ x: SIMD3<Float>) -> SIMD3<Float> { x * simd_precise_rsqrt(simd_length_squared(x)) }
@inlinable public func simd_normalize(_ x: SIMD4<Float>) -> SIMD4<Float> { x * simd_precise_rsqrt(simd_length_squared(x)) }
@inlinable public func simd_normalize(_ x: SIMD2<Double>) -> SIMD2<Double> { x / simd_length(x) }
@inlinable public func simd_normalize(_ x: SIMD3<Double>) -> SIMD3<Double> { x / simd_length(x) }
@inlinable public func simd_normalize(_ x: SIMD4<Double>) -> SIMD4<Double> { x / simd_length(x) }
@inlinable public func simd_precise_normalize(_ x: SIMD3<Float>) -> SIMD3<Float> { simd_normalize(x) }
@inlinable public func simd_precise_normalize(_ x: SIMD4<Float>) -> SIMD4<Float> { simd_normalize(x) }

/// (x.zxy·y − x·y.zxy).zxy, contracted to fma(x.zxy, y, −(x·y.zxy)).
@inlinable public func simd_cross(_ x: SIMD3<Float>, _ y: SIMD3<Float>) -> SIMD3<Float> {
    let xs = SIMD3(x.z, x.x, x.y), ys = SIMD3(y.z, y.x, y.y)
    let p = x * ys
    let t = SIMD3((-p.x).addingProduct(xs.x, y.x), (-p.y).addingProduct(xs.y, y.y), (-p.z).addingProduct(xs.z, y.z))
    return SIMD3(t.z, t.x, t.y)
}
@inlinable public func simd_cross(_ x: SIMD3<Double>, _ y: SIMD3<Double>) -> SIMD3<Double> {
    let xs = SIMD3(x.z, x.x, x.y), ys = SIMD3(y.z, y.x, y.y)
    let p = x * ys
    let t = SIMD3((-p.x).addingProduct(xs.x, y.x), (-p.y).addingProduct(xs.y, y.y), (-p.z).addingProduct(xs.z, y.z))
    return SIMD3(t.z, t.x, t.y)
}

@inlinable public func simd_reflect(_ x: SIMD3<Float>, _ n: SIMD3<Float>) -> SIMD3<Float> { x - 2 * simd_dot(x, n) * n }
@inlinable public func simd_project(_ x: SIMD3<Float>, _ y: SIMD3<Float>) -> SIMD3<Float> { simd_dot(x, y) / simd_dot(y, y) * y }

// Unprefixed overlay spellings (Apple's simd Swift overlay exports these too).
@inlinable public func dot(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { simd_dot(a, b) }
@inlinable public func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { simd_dot(a, b) }
@inlinable public func dot(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float { simd_dot(a, b) }
@inlinable public func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> { simd_cross(a, b) }
@inlinable public func length(_ a: SIMD2<Float>) -> Float { simd_length(a) }
@inlinable public func length(_ a: SIMD3<Float>) -> Float { simd_length(a) }
@inlinable public func length(_ a: SIMD4<Float>) -> Float { simd_length(a) }
@inlinable public func length_squared(_ a: SIMD3<Float>) -> Float { simd_length_squared(a) }
@inlinable public func normalize(_ a: SIMD2<Float>) -> SIMD2<Float> { simd_normalize(a) }
@inlinable public func normalize(_ a: SIMD3<Float>) -> SIMD3<Float> { simd_normalize(a) }
@inlinable public func normalize(_ a: SIMD4<Float>) -> SIMD4<Float> { simd_normalize(a) }
@inlinable public func distance(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { simd_distance(a, b) }
@inlinable public func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { simd_distance(a, b) }
@inlinable public func mix<V: SIMD>(_ x: V, _ y: V, t: V) -> V where V.Scalar: FloatingPoint { simd_mix(x, y, t) }

// MARK: - Matrices

public struct simd_float3x3: Equatable, CustomDebugStringConvertible {
    public var columns: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)

    @inlinable public init() { columns = (.zero, .zero, .zero) }
    @inlinable public init(columns: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)) { self.columns = columns }
    @inlinable public init(_ c0: SIMD3<Float>, _ c1: SIMD3<Float>, _ c2: SIMD3<Float>) { columns = (c0, c1, c2) }
    @inlinable public init(_ scalar: Float) { self.init(diagonal: SIMD3(repeating: scalar)) }
    @inlinable public init(diagonal d: SIMD3<Float>) {
        columns = (SIMD3(d.x, 0, 0), SIMD3(0, d.y, 0), SIMD3(0, 0, d.z))
    }
    @inlinable public init(_ columns: [SIMD3<Float>]) {
        precondition(columns.count == 3, "Requires array of 3 vectors")
        self.columns = (columns[0], columns[1], columns[2])
    }
    @inlinable public init(rows: [SIMD3<Float>]) { self = simd_float3x3(rows).transpose }
    public init(_ q: simd_quatf) { self = simd_matrix3x3(q) }

    public subscript(column: Int) -> SIMD3<Float> {
        @inlinable get {
            switch column {
            case 0: return columns.0
            case 1: return columns.1
            case 2: return columns.2
            default: preconditionFailure("Column index out of range")
            }
        }
        @inlinable set {
            switch column {
            case 0: columns.0 = newValue
            case 1: columns.1 = newValue
            case 2: columns.2 = newValue
            default: preconditionFailure("Column index out of range")
            }
        }
    }
    public subscript(column: Int, row: Int) -> Float {
        @inlinable get { self[column][row] }
        @inlinable set { self[column][row] = newValue }
    }

    @inlinable public static func == (a: simd_float3x3, b: simd_float3x3) -> Bool {
        a.columns.0 == b.columns.0 && a.columns.1 == b.columns.1 && a.columns.2 == b.columns.2
    }
    public var debugDescription: String { "simd_float3x3([\(columns.0), \(columns.1), \(columns.2)])" }

    @inlinable public var transpose: simd_float3x3 { simd_transpose(self) }
    @inlinable public var inverse: simd_float3x3 { simd_inverse(self) }
    @inlinable public var determinant: Float { simd_determinant(self) }

    @inlinable public static func + (a: simd_float3x3, b: simd_float3x3) -> simd_float3x3 { simd_add(a, b) }
    @inlinable public static func - (a: simd_float3x3, b: simd_float3x3) -> simd_float3x3 { simd_sub(a, b) }
    @inlinable public static prefix func - (a: simd_float3x3) -> simd_float3x3 { simd_float3x3() - a }
    @inlinable public static func += (a: inout simd_float3x3, b: simd_float3x3) { a = a + b }
    @inlinable public static func -= (a: inout simd_float3x3, b: simd_float3x3) { a = a - b }
    @inlinable public static func * (a: Float, m: simd_float3x3) -> simd_float3x3 { simd_mul(a, m) }
    @inlinable public static func * (m: simd_float3x3, a: Float) -> simd_float3x3 { simd_mul(a, m) }
    @inlinable public static func *= (m: inout simd_float3x3, a: Float) { m = m * a }
    @inlinable public static func * (m: simd_float3x3, v: SIMD3<Float>) -> SIMD3<Float> { simd_mul(m, v) }
    @inlinable public static func * (v: SIMD3<Float>, m: simd_float3x3) -> SIMD3<Float> { simd_mul(v, m) }
    @inlinable public static func * (a: simd_float3x3, b: simd_float3x3) -> simd_float3x3 { simd_mul(a, b) }
    @inlinable public static func *= (a: inout simd_float3x3, b: simd_float3x3) { a = a * b }
}

public struct simd_float4x4: Equatable, CustomDebugStringConvertible {
    public var columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

    @inlinable public init() { columns = (.zero, .zero, .zero, .zero) }
    @inlinable public init(columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)) { self.columns = columns }
    @inlinable public init(_ c0: SIMD4<Float>, _ c1: SIMD4<Float>, _ c2: SIMD4<Float>, _ c3: SIMD4<Float>) {
        columns = (c0, c1, c2, c3)
    }
    @inlinable public init(_ scalar: Float) { self.init(diagonal: SIMD4(repeating: scalar)) }
    @inlinable public init(diagonal d: SIMD4<Float>) {
        columns = (SIMD4(d.x, 0, 0, 0), SIMD4(0, d.y, 0, 0), SIMD4(0, 0, d.z, 0), SIMD4(0, 0, 0, d.w))
    }
    @inlinable public init(_ columns: [SIMD4<Float>]) {
        precondition(columns.count == 4, "Requires array of 4 vectors")
        self.columns = (columns[0], columns[1], columns[2], columns[3])
    }
    @inlinable public init(rows: [SIMD4<Float>]) { self = simd_float4x4(rows).transpose }
    public init(_ q: simd_quatf) { self = simd_matrix4x4(q) }

    public subscript(column: Int) -> SIMD4<Float> {
        @inlinable get {
            switch column {
            case 0: return columns.0
            case 1: return columns.1
            case 2: return columns.2
            case 3: return columns.3
            default: preconditionFailure("Column index out of range")
            }
        }
        @inlinable set {
            switch column {
            case 0: columns.0 = newValue
            case 1: columns.1 = newValue
            case 2: columns.2 = newValue
            case 3: columns.3 = newValue
            default: preconditionFailure("Column index out of range")
            }
        }
    }
    public subscript(column: Int, row: Int) -> Float {
        @inlinable get { self[column][row] }
        @inlinable set { self[column][row] = newValue }
    }

    @inlinable public static func == (a: simd_float4x4, b: simd_float4x4) -> Bool {
        a.columns.0 == b.columns.0 && a.columns.1 == b.columns.1 && a.columns.2 == b.columns.2 && a.columns.3 == b.columns.3
    }
    public var debugDescription: String { "simd_float4x4([\(columns.0), \(columns.1), \(columns.2), \(columns.3)])" }

    @inlinable public var transpose: simd_float4x4 { simd_transpose(self) }
    @inlinable public var inverse: simd_float4x4 { simd_inverse(self) }
    @inlinable public var determinant: Float { simd_determinant(self) }

    @inlinable public static func + (a: simd_float4x4, b: simd_float4x4) -> simd_float4x4 { simd_add(a, b) }
    @inlinable public static func - (a: simd_float4x4, b: simd_float4x4) -> simd_float4x4 { simd_sub(a, b) }
    @inlinable public static prefix func - (a: simd_float4x4) -> simd_float4x4 { simd_float4x4() - a }
    @inlinable public static func += (a: inout simd_float4x4, b: simd_float4x4) { a = a + b }
    @inlinable public static func -= (a: inout simd_float4x4, b: simd_float4x4) { a = a - b }
    @inlinable public static func * (a: Float, m: simd_float4x4) -> simd_float4x4 { simd_mul(a, m) }
    @inlinable public static func * (m: simd_float4x4, a: Float) -> simd_float4x4 { simd_mul(a, m) }
    @inlinable public static func *= (m: inout simd_float4x4, a: Float) { m = m * a }
    @inlinable public static func * (m: simd_float4x4, v: SIMD4<Float>) -> SIMD4<Float> { simd_mul(m, v) }
    @inlinable public static func * (v: SIMD4<Float>, m: simd_float4x4) -> SIMD4<Float> { simd_mul(v, m) }
    @inlinable public static func * (a: simd_float4x4, b: simd_float4x4) -> simd_float4x4 { simd_mul(a, b) }
    @inlinable public static func *= (a: inout simd_float4x4, b: simd_float4x4) { a = a * b }
}

/// Four float3 columns (HLSL-style float4x3 in Apple's naming: 4 columns, 3 rows).
public struct simd_float4x3: Equatable {
    public var columns: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
    @inlinable public init() { columns = (.zero, .zero, .zero, .zero) }
    @inlinable public init(columns: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)) { self.columns = columns }
    @inlinable public init(_ c0: SIMD3<Float>, _ c1: SIMD3<Float>, _ c2: SIMD3<Float>, _ c3: SIMD3<Float>) { columns = (c0, c1, c2, c3) }
    @inlinable public static func == (a: simd_float4x3, b: simd_float4x3) -> Bool {
        a.columns.0 == b.columns.0 && a.columns.1 == b.columns.1 && a.columns.2 == b.columns.2 && a.columns.3 == b.columns.3
    }
}

/// Three float4 columns.
public struct simd_float3x4: Equatable {
    public var columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    @inlinable public init() { columns = (.zero, .zero, .zero) }
    @inlinable public init(columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)) { self.columns = columns }
    @inlinable public init(_ c0: SIMD4<Float>, _ c1: SIMD4<Float>, _ c2: SIMD4<Float>) { columns = (c0, c1, c2) }
    @inlinable public static func == (a: simd_float3x4, b: simd_float3x4) -> Bool {
        a.columns.0 == b.columns.0 && a.columns.1 == b.columns.1 && a.columns.2 == b.columns.2
    }
}

public typealias float3x3 = simd_float3x3
public typealias float4x4 = simd_float4x4
public typealias float4x3 = simd_float4x3
public typealias float3x4 = simd_float3x4
public typealias matrix_float3x3 = simd_float3x3
public typealias matrix_float4x4 = simd_float4x4

public let matrix_identity_float3x3 = simd_float3x3(diagonal: SIMD3(1, 1, 1))
public let matrix_identity_float4x4 = simd_float4x4(diagonal: SIMD4(1, 1, 1, 1))

// matrix.h: simd_mul(M, v) = c0·v0, then simd_muladd (FMA) for the other columns.
@inlinable public func simd_mul(_ m: simd_float3x3, _ v: SIMD3<Float>) -> SIMD3<Float> {
    var r = m.columns.0 * v.x
    r = r.addingProduct(m.columns.1, v.y)
    r = r.addingProduct(m.columns.2, v.z)
    return r
}
@inlinable public func simd_mul(_ m: simd_float4x4, _ v: SIMD4<Float>) -> SIMD4<Float> {
    var r = m.columns.0 * v.x
    r = r.addingProduct(m.columns.1, v.y)
    r = r.addingProduct(m.columns.2, v.z)
    r = r.addingProduct(m.columns.3, v.w)
    return r
}
@inlinable public func simd_mul(_ v: SIMD3<Float>, _ m: simd_float3x3) -> SIMD3<Float> { simd_mul(simd_transpose(m), v) }
@inlinable public func simd_mul(_ v: SIMD4<Float>, _ m: simd_float4x4) -> SIMD4<Float> { simd_mul(simd_transpose(m), v) }
@inlinable public func simd_mul(_ a: simd_float3x3, _ b: simd_float3x3) -> simd_float3x3 {
    simd_float3x3(simd_mul(a, b.columns.0), simd_mul(a, b.columns.1), simd_mul(a, b.columns.2))
}
@inlinable public func simd_mul(_ a: simd_float4x4, _ b: simd_float4x4) -> simd_float4x4 {
    simd_float4x4(simd_mul(a, b.columns.0), simd_mul(a, b.columns.1), simd_mul(a, b.columns.2), simd_mul(a, b.columns.3))
}
@inlinable public func simd_mul(_ a: Float, _ m: simd_float3x3) -> simd_float3x3 {
    simd_float3x3(m.columns.0 * a, m.columns.1 * a, m.columns.2 * a)
}
@inlinable public func simd_mul(_ a: Float, _ m: simd_float4x4) -> simd_float4x4 {
    simd_float4x4(m.columns.0 * a, m.columns.1 * a, m.columns.2 * a, m.columns.3 * a)
}
@inlinable public func matrix_multiply(_ a: simd_float4x4, _ b: simd_float4x4) -> simd_float4x4 { simd_mul(a, b) }
@inlinable public func matrix_multiply(_ a: simd_float4x4, _ v: SIMD4<Float>) -> SIMD4<Float> { simd_mul(a, v) }
@inlinable public func matrix_multiply(_ a: simd_float3x3, _ b: simd_float3x3) -> simd_float3x3 { simd_mul(a, b) }

/// simd_linear_combination(a, x, b, y): a·x + b·y per column, contracted to fma(a, x, b·y).
@inlinable func _lincomb<V: SIMD>(_ a: Float, _ x: V, _ b: Float, _ y: V) -> V where V.Scalar == Float {
    let by = y * b
    var r = x
    for i in r.indices { r[i] = by[i].addingProduct(a, x[i]) }
    return r
}
@inlinable public func simd_linear_combination(_ a: Float, _ x: simd_float4x4, _ b: Float, _ y: simd_float4x4) -> simd_float4x4 {
    simd_float4x4(_lincomb(a, x.columns.0, b, y.columns.0), _lincomb(a, x.columns.1, b, y.columns.1),
                  _lincomb(a, x.columns.2, b, y.columns.2), _lincomb(a, x.columns.3, b, y.columns.3))
}
@inlinable public func simd_linear_combination(_ a: Float, _ x: simd_float3x3, _ b: Float, _ y: simd_float3x3) -> simd_float3x3 {
    simd_float3x3(_lincomb(a, x.columns.0, b, y.columns.0), _lincomb(a, x.columns.1, b, y.columns.1),
                  _lincomb(a, x.columns.2, b, y.columns.2))
}
@inlinable public func simd_add(_ x: simd_float4x4, _ y: simd_float4x4) -> simd_float4x4 { simd_linear_combination(1, x, 1, y) }
@inlinable public func simd_sub(_ x: simd_float4x4, _ y: simd_float4x4) -> simd_float4x4 { simd_linear_combination(1, x, -1, y) }
@inlinable public func simd_add(_ x: simd_float3x3, _ y: simd_float3x3) -> simd_float3x3 { simd_linear_combination(1, x, 1, y) }
@inlinable public func simd_sub(_ x: simd_float3x3, _ y: simd_float3x3) -> simd_float3x3 { simd_linear_combination(1, x, -1, y) }

@inlinable public func simd_transpose(_ m: simd_float3x3) -> simd_float3x3 {
    let (a, b, c) = m.columns
    return simd_float3x3(SIMD3(a.x, b.x, c.x), SIMD3(a.y, b.y, c.y), SIMD3(a.z, b.z, c.z))
}
@inlinable public func simd_transpose(_ m: simd_float4x4) -> simd_float4x4 {
    let (a, b, c, d) = m.columns
    return simd_float4x4(SIMD4(a.x, b.x, c.x, d.x), SIMD4(a.y, b.y, c.y, d.y), SIMD4(a.z, b.z, c.z, d.z), SIMD4(a.w, b.w, c.w, d.w))
}

@inlinable func _r1(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(v.y, v.z, v.x) }
@inlinable func _r2(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(v.z, v.x, v.y) }
@inlinable func _r1(_ v: SIMD4<Float>) -> SIMD4<Float> { SIMD4(v.y, v.z, v.w, v.x) }
@inlinable func _r2(_ v: SIMD4<Float>) -> SIMD4<Float> { SIMD4(v.z, v.w, v.x, v.y) }
@inlinable func _r3(_ v: SIMD4<Float>) -> SIMD4<Float> { SIMD4(v.w, v.x, v.y, v.z) }
/// a·b − c·d contracted: fma(a, b, −(c·d)).
@inlinable func _fmsP<V: SIMD>(_ a: V, _ b: V, _ c: V, _ d: V) -> V where V.Scalar == Float {
    let cd = c * d
    var r = a
    for i in r.indices { r[i] = (-cd[i]).addingProduct(a[i], b[i]) }
    return r
}
/// fma(a, b, c) lane-wise.
@inlinable func _fma<V: SIMD>(_ a: V, _ b: V, _ c: V) -> V where V.Scalar == Float {
    var r = c
    for i in r.indices { r[i] = c[i].addingProduct(a[i], b[i]) }
    return r
}

@inlinable public func simd_determinant(_ m: simd_float3x3) -> Float {
    let (c0, c1, c2) = m.columns
    return simd_reduce_add(c0 * _fmsP(_r1(c1), _r2(c2), _r2(c1), _r1(c2)))
}
@inlinable public func simd_determinant(_ m: simd_float4x4) -> Float {
    let (c0, c1, c2, c3) = m.columns
    let i1 = _fmsP(_r2(c2), _r3(c3), _r3(c2), _r2(c3))
    let i2 = _fmsP(_r3(c2), _r1(c3), _r1(c2), _r3(c3))
    let i3 = _fmsP(_r1(c2), _r2(c3), _r2(c2), _r1(c3))
    // (r1(c1)·i1 + r2(c1)·i2) + r3(c1)·i3: the first add contracts on its left product, the second on its right.
    let s = _fma(_r3(c1), i3, _fma(_r1(c1), i1, _r2(c1) * i2))
    let codet = c0 * s
    let even = SIMD2(codet.x, codet.z), odd = SIMD2(codet.y, codet.w)
    return simd_reduce_add(even - odd)
}

/// `__invert_f3` (libsystem_m, arm64): cofactors with fnmul/fmla/fnmadd, determinant fma chain, then · (1 / det).
@inlinable public func simd_inverse(_ m: simd_float3x3) -> simd_float3x3 {
    let (c0, c1, c2) = m.columns
    let x0 = c0.x, x1 = c1.x, x2 = c2.x
    let s3 = c0.y, s4 = c0.z, s5 = c1.y, s6 = c1.z, s7 = c2.y, s16 = c2.z
    let s17 = (-(s7 * s6)).addingProduct(s16, c1.y)
    let s18a = -(s7 * s4)
    let s19 = -(s18a.addingProduct(s3, s16))
    let s18 = s18a.addingProduct(s16, c0.y)
    let s20 = (-(s5 * s4)).addingProduct(s6, c0.y)
    let s16b = -((-(x2 * s6)).addingProduct(x1, s16))
    let s21 = (-(x2 * s4)).addingProduct(x0, c2.z)
    let s4b = -((-(x1 * s4)).addingProduct(x0, s6))
    let s5b = (-(x2 * s5)).addingProduct(x1, c2.y)
    let s6b = -((-(x2 * s3)).addingProduct(x0, s7))
    let s3b = (-(x1 * s3)).addingProduct(x0, c1.y)
    let p = s18 * x1
    var det = (-p).addingProduct(x0, s17)
    det = det.addingProduct(x2, s20)
    let inv = 1 / det
    return simd_float3x3(SIMD3(s17, s19, s20) * inv, SIMD3(s16b, s21, s4b) * inv, SIMD3(s5b, s6b, s3b) * inv)
}

@inlinable func _rev64(_ v: SIMD4<Float>) -> SIMD4<Float> { SIMD4(v.y, v.x, v.w, v.z) }
@inlinable func _ext8(_ v: SIMD4<Float>) -> SIMD4<Float> { SIMD4(v.z, v.w, v.x, v.y) }
/// fmla: d + n·m fused.
@inlinable func _fmla(_ d: SIMD4<Float>, _ n: SIMD4<Float>, _ m: SIMD4<Float>) -> SIMD4<Float> { d.addingProduct(n, m) }
/// fmls: d − n·m fused.
@inlinable func _fmls(_ d: SIMD4<Float>, _ n: SIMD4<Float>, _ m: SIMD4<Float>) -> SIMD4<Float> { d.addingProduct(-n, m) }

/// `__invert_f4` (libsystem_m, arm64): Cramer's rule on the transposed rows (the SSE "inverse of a 4×4 matrix" shuffle
/// scheme), the determinant reduced (p0 + p2) + (p1 + p3), and the reciprocal by FRECPE + two FRECPS steps.
@inlinable public func simd_inverse(_ m: simd_float4x4) -> simd_float4x4 {
    let (c0, c1, c2, c3) = m.columns
    let row0 = SIMD4(c0.x, c1.x, c2.x, c3.x), row1 = SIMD4(c0.y, c1.y, c2.y, c3.y)
    let row2 = SIMD4(c0.z, c1.z, c2.z, c3.z), row3 = SIMD4(c0.w, c1.w, c2.w, c3.w)
    let v2 = row0
    var v5 = row1
    var v6 = row2
    let v3 = _ext8(row1)
    let v4 = _ext8(row3)

    var t = _rev64(v6 * v4)
    var v0 = -(v3 * t)
    var v1 = -(v2 * t)
    var v16 = _ext8(t)
    v0 = _fmla(v0, v16, v3)
    v1 = _ext8(_fmla(v1, v16, v2))

    var v7 = _rev64(v6 * v3)
    v0 = _fmla(v0, v7, v4)
    v16 = v2 * v7
    v7 = _ext8(v7)
    v0 = _fmls(v0, v7, v4)
    v16 = _fmla(-v16, v7, v2)
    v7 = _ext8(v16)

    v5 = _rev64(v5 * v4)
    v6 = _ext8(v6)
    v0 = _fmla(v0, v5, v6)
    v16 = v2 * v5
    v5 = _ext8(v5)
    v0 = _fmls(v0, v5, v6)
    v16 = _fmla(-v16, v5, v2)
    v5 = _ext8(v16)

    t = _rev64(v2 * v3)
    v5 = _fmla(v5, t, v4)
    v7 = _fmla(-v7, t, v6)
    t = _ext8(t)
    v5 = _fmla(-v5, t, v4)
    v7 = _fmls(v7, t, v6)

    t = _rev64(v2 * v4)
    v1 = _fmls(v1, t, v6)
    v5 = _fmla(v5, t, v3)
    t = _ext8(t)
    v1 = _fmla(v1, t, v6)
    v5 = _fmls(v5, t, v3)

    t = _rev64(v2 * v6)
    v1 = _fmla(v1, t, v4)
    v7 = _fmls(v7, t, v3)
    t = _ext8(t)
    v1 = _fmls(v1, t, v4)
    v7 = _fmla(v7, t, v3)

    let p = v2 * v0
    let det = (p.x + p.z) + (p.y + p.w)
    let r = simd_precise_recip(det)
    return simd_float4x4(v0 * r, v1 * r, v5 * r, v7 * r)
}

@inlinable public func simd_equal(_ a: simd_float4x4, _ b: simd_float4x4) -> Bool { a == b }
@inlinable public func simd_equal(_ a: simd_float3x3, _ b: simd_float3x3) -> Bool { a == b }
@inlinable public func simd_matrix(_ c0: SIMD3<Float>, _ c1: SIMD3<Float>, _ c2: SIMD3<Float>) -> simd_float3x3 { simd_float3x3(c0, c1, c2) }
@inlinable public func simd_matrix(_ c0: SIMD4<Float>, _ c1: SIMD4<Float>, _ c2: SIMD4<Float>, _ c3: SIMD4<Float>) -> simd_float4x4 {
    simd_float4x4(c0, c1, c2, c3)
}
@inlinable public func simd_diagonal_matrix(_ d: SIMD3<Float>) -> simd_float3x3 { simd_float3x3(diagonal: d) }
@inlinable public func simd_diagonal_matrix(_ d: SIMD4<Float>) -> simd_float4x4 { simd_float4x4(diagonal: d) }
@inlinable public func simd_matrix_from_rows(_ r0: SIMD4<Float>, _ r1: SIMD4<Float>, _ r2: SIMD4<Float>, _ r3: SIMD4<Float>) -> simd_float4x4 {
    simd_transpose(simd_float4x4(r0, r1, r2, r3))
}
@inlinable public func simd_matrix_from_rows(_ r0: SIMD3<Float>, _ r1: SIMD3<Float>, _ r2: SIMD3<Float>) -> simd_float3x3 {
    simd_transpose(simd_float3x3(r0, r1, r2))
}

// MARK: - Quaternions (quaternion.h)

public struct simd_quatf: Equatable, Hashable, CustomDebugStringConvertible {
    public var vector: SIMD4<Float>

    @inlinable public init() { vector = .zero }
    @inlinable public init(vector: SIMD4<Float>) { self.vector = vector }
    @inlinable public init(ix: Float, iy: Float, iz: Float, r: Float) { vector = SIMD4(ix, iy, iz, r) }
    @inlinable public init(real: Float, imag: SIMD3<Float>) { vector = SIMD4(imag.x, imag.y, imag.z, real) }
    @inlinable public init(angle: Float, axis: SIMD3<Float>) { self = simd_quaternion(angle, axis) }
    @inlinable public init(from: SIMD3<Float>, to: SIMD3<Float>) { self = simd_quaternion(from, to) }
    @inlinable public init(_ m: simd_float3x3) { self = simd_quaternion(m) }
    @inlinable public init(_ m: simd_float4x4) { self = simd_quaternion(m) }

    public var real: Float {
        @inlinable get { vector.w }
        @inlinable set { vector.w = newValue }
    }
    public var imag: SIMD3<Float> {
        @inlinable get { SIMD3(vector.x, vector.y, vector.z) }
        @inlinable set { vector = SIMD4(newValue.x, newValue.y, newValue.z, vector.w) }
    }
    @inlinable public var angle: Float { simd_angle(self) }
    @inlinable public var axis: SIMD3<Float> { simd_axis(self) }
    @inlinable public var conjugate: simd_quatf { simd_conjugate(self) }
    @inlinable public var inverse: simd_quatf { simd_inverse(self) }
    @inlinable public var normalized: simd_quatf { simd_normalize(self) }
    @inlinable public var length: Float { simd_length(self) }
    @inlinable public func act(_ v: SIMD3<Float>) -> SIMD3<Float> { simd_act(self, v) }

    public var debugDescription: String { "simd_quatf(real: \(real), imag: \(imag))" }

    @inlinable public static func + (a: simd_quatf, b: simd_quatf) -> simd_quatf { simd_add(a, b) }
    @inlinable public static func += (a: inout simd_quatf, b: simd_quatf) { a = a + b }
    @inlinable public static func - (a: simd_quatf, b: simd_quatf) -> simd_quatf { simd_sub(a, b) }
    @inlinable public static func -= (a: inout simd_quatf, b: simd_quatf) { a = a - b }
    @inlinable public static prefix func - (a: simd_quatf) -> simd_quatf { simd_sub(simd_quatf(), a) }
    @inlinable public static func * (a: simd_quatf, b: simd_quatf) -> simd_quatf { simd_mul(a, b) }
    @inlinable public static func * (a: Float, q: simd_quatf) -> simd_quatf { simd_mul(a, q) }
    @inlinable public static func * (q: simd_quatf, a: Float) -> simd_quatf { simd_mul(q, a) }
    @inlinable public static func *= (a: inout simd_quatf, b: simd_quatf) { a = a * b }
    @inlinable public static func *= (a: inout simd_quatf, b: Float) { a = a * b }
    @inlinable public static func / (a: simd_quatf, b: simd_quatf) -> simd_quatf { simd_mul(a, b.inverse) }
    @inlinable public static func / (q: simd_quatf, a: Float) -> simd_quatf { simd_quatf(vector: q.vector / a) }
    @inlinable public static func /= (a: inout simd_quatf, b: simd_quatf) { a = a / b }
    @inlinable public static func /= (a: inout simd_quatf, b: Float) { a = a / b }
}

@inlinable public func simd_quaternion(_ ix: Float, _ iy: Float, _ iz: Float, _ r: Float) -> simd_quatf { simd_quatf(vector: SIMD4(ix, iy, iz, r)) }
@inlinable public func simd_quaternion(_ v: SIMD4<Float>) -> simd_quatf { simd_quatf(vector: v) }
@inlinable public func simd_quaternion(_ r: Float, _ imag: SIMD3<Float>) -> simd_quatf {
    // simd_quaternion(float angle, simd_float3 axis): sin/cos of the half-angle. Apple's results are the correctly
    // rounded float values, which the double functions rounded to float reproduce (glibc's sinf/cosf do not always).
    let h = Double(r / 2)
    return simd_quatf(vector: SIMD4(imag * Float(sin(h)), Float(cos(h))))
}
@inlinable public func simd_real(_ q: simd_quatf) -> Float { q.vector.w }
@inlinable public func simd_imag(_ q: simd_quatf) -> SIMD3<Float> { SIMD3(q.vector.x, q.vector.y, q.vector.z) }
@inlinable func _quat(_ imag: SIMD3<Float>, _ real: Float) -> simd_quatf { simd_quatf(vector: SIMD4(imag, real)) }

@inlinable public func simd_angle(_ q: simd_quatf) -> Float {
    Float(2 * atan2(Double(simd_length(simd_imag(q))), Double(q.vector.w)))
}
@inlinable public func simd_axis(_ q: simd_quatf) -> SIMD3<Float> { simd_normalize(simd_imag(q)) }
@inlinable public func simd_add(_ p: simd_quatf, _ q: simd_quatf) -> simd_quatf { simd_quatf(vector: p.vector + q.vector) }
@inlinable public func simd_sub(_ p: simd_quatf, _ q: simd_quatf) -> simd_quatf { simd_quatf(vector: p.vector - q.vector) }
@inlinable public func simd_negate(_ q: simd_quatf) -> simd_quatf { simd_quatf(vector: -q.vector) }

/// (p.x·S1 + p.y·S2) + (p.z·S3 + p.w·q), each inner sum contracted on its left product.
@inlinable public func simd_mul(_ p: simd_quatf, _ q: simd_quatf) -> simd_quatf {
    let v = q.vector
    let s1 = SIMD4(v.w, -v.z, v.y, -v.x), s2 = SIMD4(v.z, v.w, -v.x, -v.y), s3 = SIMD4(-v.y, v.x, v.w, -v.z)
    let a = (s2 * p.vector.y).addingProduct(p.vector.x, s1)
    let b = (v * p.vector.w).addingProduct(p.vector.z, s3)
    return simd_quatf(vector: a + b)
}
@inlinable public func simd_mul(_ q: simd_quatf, _ a: Float) -> simd_quatf { simd_quatf(vector: a * q.vector) }
@inlinable public func simd_mul(_ a: Float, _ q: simd_quatf) -> simd_quatf { simd_mul(q, a) }
@inlinable public func simd_conjugate(_ q: simd_quatf) -> simd_quatf { simd_quatf(vector: q.vector * SIMD4(-1, -1, -1, 1)) }
@inlinable public func simd_inverse(_ q: simd_quatf) -> simd_quatf {
    simd_quatf(vector: simd_conjugate(q).vector * simd_recip(simd_length_squared(q.vector)))
}
@inlinable public func simd_dot(_ p: simd_quatf, _ q: simd_quatf) -> Float { simd_dot(p.vector, q.vector) }
@inlinable public func simd_length(_ q: simd_quatf) -> Float { simd_length(q.vector) }
@inlinable public func simd_normalize(_ q: simd_quatf) -> simd_quatf {
    let l2 = simd_length_squared(q.vector)
    if l2 == 0 { return simd_quatf(vector: SIMD4(0, 0, 0, 1)) }
    return simd_quatf(vector: q.vector * simd_rsqrt(l2))
}

/// arm64 path: simd_mul(q, _simd_mul_vq(v, conj(q))).xyz.
@inlinable public func simd_act(_ q: simd_quatf, _ v: SIMD3<Float>) -> SIMD3<Float> {
    let c = simd_conjugate(q).vector
    let s1 = SIMD4(c.w, -c.z, c.y, -c.x), s2 = SIMD4(c.z, c.w, -c.x, -c.y), s3 = SIMD4(-c.y, c.x, c.w, -c.z)
    // v.x·S1 + v.y·S2 + v.z·S3 = (fma(v.x, S1, v.y·S2)) then fma(v.z, S3, ·).
    let t = (s2 * v.y).addingProduct(v.x, s1).addingProduct(v.z, s3)
    let r = simd_mul(q, simd_quatf(vector: t)).vector
    return SIMD3(r.x, r.y, r.z)
}

@inlinable func _quatReduced(_ from: SIMD3<Float>, _ to: SIMD3<Float>) -> simd_quatf {
    let half = simd_normalize(from + to)
    return _quat(simd_cross(from, half), simd_dot(from, half))
}
@inlinable public func simd_quaternion(_ from: SIMD3<Float>, _ to: SIMD3<Float>) -> simd_quatf {
    if simd_dot(from, to) >= 0 { return _quatReduced(from, to) }
    var half = simd_normalize(from) + simd_normalize(to)
    if simd_length_squared(half) <= 0x1p-46 {
        let a = simd_abs(from)
        if a.x <= a.y && a.x <= a.z { return _quat(simd_normalize(simd_cross(from, SIMD3(1, 0, 0))), 0) }
        if a.y <= a.z { return _quat(simd_normalize(simd_cross(from, SIMD3(0, 1, 0))), 0) }
        return _quat(simd_normalize(simd_cross(from, SIMD3(0, 0, 1))), 0)
    }
    half = simd_normalize(half)
    return simd_mul(_quatReduced(from, half), _quatReduced(half, to))
}

/// simd_quaternion(simd_float3x3): `r = 2*sqrt(…)` (sqrtf through <tgmath.h>).
@inlinable func _quatFromRotation(_ m00: Float, _ m01: Float, _ m02: Float, _ m10: Float, _ m11: Float, _ m12: Float,
                                  _ m20: Float, _ m21: Float, _ m22: Float) -> simd_quatf {
    // mIJ = mat[I][J] = column I, row J.
    let trace = m00 + m11 + m22
    if trace >= 0 {
        let r = 2 * (1 + trace).squareRoot()
        let rinv = simd_recip(r)
        return simd_quaternion(rinv * (m12 - m21), rinv * (m20 - m02), rinv * (m01 - m10), r / 4)
    } else if m00 >= m11 && m00 >= m22 {
        let r = 2 * (1 - m11 - m22 + m00).squareRoot()
        let rinv = simd_recip(r)
        return simd_quaternion(r / 4, rinv * (m01 + m10), rinv * (m02 + m20), rinv * (m12 - m21))
    } else if m11 >= m22 {
        let r = 2 * (1 - m00 - m22 + m11).squareRoot()
        let rinv = simd_recip(r)
        return simd_quaternion(rinv * (m01 + m10), r / 4, rinv * (m12 + m21), rinv * (m20 - m02))
    } else {
        let r = 2 * (1 - m00 - m11 + m22).squareRoot()
        let rinv = simd_recip(r)
        return simd_quaternion(rinv * (m02 + m20), rinv * (m12 + m21), r / 4, rinv * (m01 - m10))
    }
}
@inlinable public func simd_quaternion(_ m: simd_float3x3) -> simd_quatf {
    let (a, b, c) = m.columns
    return _quatFromRotation(a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z)
}
@inlinable public func simd_quaternion(_ m: simd_float4x4) -> simd_quatf {
    let (a, b, c, _) = m.columns
    return _quatFromRotation(a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z)
}

/// simd_matrix4x4(simd_quatf) with clang's contractions written out.
@inlinable public func simd_matrix4x4(_ q: simd_quatf) -> simd_float4x4 {
    let v = q.vector, x = v.x, y = v.y, z = v.z, w = v.w
    // xx − yy − zz + ww → fma(w, w, fma(−z, z, fma(x, x, −(y·y))))
    let m00 = ((-(y * y)).addingProduct(x, x)).addingProduct(-z, z).addingProduct(w, w)
    let m01 = 2 * (z * w).addingProduct(x, y)
    let m02 = 2 * (-(y * w)).addingProduct(x, z)
    let m10 = 2 * (-(z * w)).addingProduct(x, y)
    // yy − zz + ww − xx → fma(−x, x, fma(w, w, fma(y, y, −(z·z))))
    let m11 = ((-(z * z)).addingProduct(y, y)).addingProduct(w, w).addingProduct(-x, x)
    let m12 = 2 * (x * w).addingProduct(y, z)
    let m20 = 2 * (y * w).addingProduct(z, x)
    let m21 = 2 * (-(x * w)).addingProduct(y, z)
    // zz + ww − xx − yy → fma(−y, y, fma(−x, x, fma(z, z, w·w)))
    let m22 = ((w * w).addingProduct(z, z)).addingProduct(-x, x).addingProduct(-y, y)
    return simd_float4x4(SIMD4(m00, m01, m02, 0), SIMD4(m10, m11, m12, 0), SIMD4(m20, m21, m22, 0), SIMD4(0, 0, 0, 1))
}
@inlinable public func simd_matrix3x3(_ q: simd_quatf) -> simd_float3x3 {
    let r = simd_matrix4x4(q)
    return simd_float3x3(SIMD3(r.columns.0.x, r.columns.0.y, r.columns.0.z), SIMD3(r.columns.1.x, r.columns.1.y, r.columns.1.z),
                         SIMD3(r.columns.2.x, r.columns.2.y, r.columns.2.z))
}

@inlinable func _quatAngle(_ p: simd_quatf, _ q: simd_quatf) -> Float {
    Float(2 * atan2(Double(simd_length(p.vector - q.vector)), Double(simd_length(p.vector + q.vector))))
}
@inlinable func _sinc(_ x: Float) -> Float {
    if x == 0 { return 1 }
    return Float(sin(Double(x))) / x
}
@inlinable func _slerpInternal(_ q0: simd_quatf, _ q1: simd_quatf, _ t: Float) -> simd_quatf {
    let s = 1 - t
    let a = _quatAngle(q0, q1)
    let r = simd_recip(_sinc(a))
    // _simd_sinc(s*a)*r*s*q0.vector + _simd_sinc(t*a)*r*t*q1.vector: the sum contracts on its left product.
    let k0 = _sinc(s * a) * r * s, k1 = _sinc(t * a) * r * t
    let v = (q1.vector * k1).addingProduct(k0, q0.vector)
    return simd_normalize(simd_quatf(vector: v))
}
@inlinable public func simd_slerp(_ q0: simd_quatf, _ q1: simd_quatf, _ t: Float) -> simd_quatf {
    simd_dot(q0, q1) >= 0 ? _slerpInternal(q0, q1, t) : _slerpInternal(q0, simd_negate(q1), t)
}
@inlinable public func simd_slerp_longest(_ q0: simd_quatf, _ q1: simd_quatf, _ t: Float) -> simd_quatf {
    simd_dot(q0, q1) >= 0 ? _slerpInternal(q0, simd_negate(q1), t) : _slerpInternal(q0, q1, t)
}
