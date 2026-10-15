/// A column-major 4×4 float matrix for platforms without Apple's `simd` module. Same conventions as PhotonRender's
/// `Mat` (column-vector P; the engine's row-vector M = Pᵀ), and the same arithmetic: products are accumulated with
/// fused multiply-adds column by column, as `simd_mul` does on Apple silicon, so matrices round identically.
public struct Mat4: Equatable {
    public var columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

    public init(columns c0: SIMD4<Float>, _ c1: SIMD4<Float>, _ c2: SIMD4<Float>, _ c3: SIMD4<Float>) { columns = (c0, c1, c2, c3) }

    /// `simd_float4x4(rows:)`.
    public init(rows r: [SIMD4<Float>]) {
        columns = (SIMD4(r[0].x, r[1].x, r[2].x, r[3].x), SIMD4(r[0].y, r[1].y, r[2].y, r[3].y),
                   SIMD4(r[0].z, r[1].z, r[2].z, r[3].z), SIMD4(r[0].w, r[1].w, r[2].w, r[3].w))
    }

    public static let identity = Mat4(columns: SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))

    public subscript(c: Int) -> SIMD4<Float> {
        switch c { case 0: return columns.0; case 1: return columns.1; case 2: return columns.2; default: return columns.3 }
    }

    public static func == (a: Mat4, b: Mat4) -> Bool { (0..<4).allSatisfy { a[$0] == b[$0] } }

    public static func * (a: Mat4, v: SIMD4<Float>) -> SIMD4<Float> {
        var r = a.columns.0 * v.x
        r = r.addingProduct(a.columns.1, SIMD4(repeating: v.y))
        r = r.addingProduct(a.columns.2, SIMD4(repeating: v.z))
        return r.addingProduct(a.columns.3, SIMD4(repeating: v.w))
    }

    public static func * (a: Mat4, b: Mat4) -> Mat4 {
        Mat4(columns: a * b.columns.0, a * b.columns.1, a * b.columns.2, a * b.columns.3)
    }

    public var transpose: Mat4 { Mat4(rows: [columns.0, columns.1, columns.2, columns.3]) }

    /// General inverse by cofactors (only used for the *Inverse built-ins).
    public var inverse: Mat4 {
        let m = [columns.0, columns.1, columns.2, columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
        var inv = [Float](repeating: 0, count: 16)
        inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10]
        inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10]
        inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9]
        inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9]
        inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10]
        inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10]
        inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9]
        inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9]
        inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6]
        inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6]
        inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5]
        inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5]
        inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6]
        inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6]
        inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5]
        inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5]
        let det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12]
        let k: Float = det != 0 ? 1 / det : 0
        let r = inv.map { $0 * k }
        return Mat4(columns: SIMD4(r[0], r[1], r[2], r[3]), SIMD4(r[4], r[5], r[6], r[7]), SIMD4(r[8], r[9], r[10], r[11]),
                    SIMD4(r[12], r[13], r[14], r[15]))
    }

    // MARK: Engine matrices (Draw.swift `Mat`)

    public static func translate(_ t: SIMD3<Float>) -> Mat4 {
        var m = identity
        m.columns.3 = SIMD4(t.x, t.y, t.z, 1)
        return m
    }

    public static func scale(_ s: SIMD3<Float>) -> Mat4 {
        Mat4(columns: SIMD4(s.x, 0, 0, 0), SIMD4(0, s.y, 0, 0), SIMD4(0, 0, s.z, 0), SIMD4(0, 0, 0, 1))
    }

    /// D3DX OrthoOffCenterLH (docs/re/03 §2).
    public static func orthoLH(l: Float, r: Float, b: Float, t: Float, zn: Float, zf: Float) -> Mat4 {
        Mat4(rows: [
            SIMD4(2 / (r - l), 0, 0, -(l + r) / (r - l)),
            SIMD4(0, 2 / (t - b), 0, -(t + b) / (t - b)),
            SIMD4(0, 0, 1 / (zf - zn), zn / (zn - zf)),
            SIMD4(0, 0, 0, 1),
        ])
    }

    /// D3DX LookAtRH.
    public static func lookAtRH(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> Mat4 {
        func normalize(_ v: SIMD3<Float>) -> SIMD3<Float> { v / (v * v).sum().squareRoot() }
        func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        }
        func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { (a * b).sum() }
        let z = normalize(eye - center)
        let x = normalize(cross(up, z))
        let y = cross(z, x)
        return Mat4(rows: [
            SIMD4(x.x, x.y, x.z, -dot(x, eye)),
            SIMD4(y.x, y.y, y.z, -dot(y, eye)),
            SIMD4(z.x, z.y, z.z, -dot(z, eye)),
            SIMD4(0, 0, 0, 1),
        ])
    }

    /// Object rotation (docs/re/04 §4.2), as `Mat.rotation`.
    public static func rotation(_ a: SIMD3<Float>) -> Mat4 {
        let (sa, ca) = (sinf(a.x), cosf(a.x)), (sb, cb) = (sinf(a.y), cosf(a.y)), (sc, cc) = (sinf(a.z), cosf(a.z))
        let row0 = SIMD3<Float>(cb * cc, cb * sc, -sb)
        let row1 = SIMD3<Float>(sa * sb * cc - ca * sc, sa * sb * sc + ca * cc, sa * cb)
        let row2 = SIMD3<Float>(ca * sb * cc + sa * sc, ca * sb * sc - sa * cc, ca * cb)
        return Mat4(columns: SIMD4(row0, 0), SIMD4(row1, 0), SIMD4(row2, 0), SIMD4(0, 0, 0, 1))
    }
}

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
