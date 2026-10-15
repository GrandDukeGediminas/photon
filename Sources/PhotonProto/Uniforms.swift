import PhotonGPU

/// A uniform value as written into a constant buffer (PhotonRender's `UniformValue` without simd).
public enum ProtoUniform {
    case floats([Float])
    /// Column-vector matrix P; the buffer holds Pᵀ column-major, i.e. register r = row r of P.
    case matrix(Mat4)
    /// 3×3 (g_NormalModelMatrix): the upper-left of the matrix, three registers.
    case matrix3(Mat4)
    case uints([UInt32])
}

/// `RenderContext.pack` (Draw.swift) over SPIR-V reflection: members written in ascending offset order, the same
/// array/matrix rules, so the bytes match what the Metal path uploads for the same program.
enum UniformPacker {
    static func pack(_ block: SPIRVReflection.UniformBlock, _ values: [String: ProtoUniform]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: (block.size + 15) & ~15)
        func put(_ f: Float, _ offset: Int) {
            guard offset >= 0, offset + 4 <= bytes.count else { return }
            withUnsafeBytes(of: f) { src in for i in 0..<4 { bytes[offset + i] = src[i] } }
        }
        for m in block.members.sorted(by: { $0.offset < $1.offset }) {
            guard let v = values[m.name] else { continue }
            let stride = m.arrayStride > 0 ? m.arrayStride : 16
            switch v {
            case .floats(let f):
                if m.arrayCount > 0 && m.type.hasSuffix("vec4") {
                    for (i, x) in f.enumerated() { put(x, m.offset + (i / 4) * stride + (i % 4) * 4) }
                } else if m.arrayCount > 0 && m.type == "mat4" {
                    for (i, x) in f.enumerated() { put(x, m.offset + (i / 16) * max(stride, 64) + (i % 16) * 4) }
                } else if m.arrayCount > 0 {
                    let comps = components(m.type)
                    for (i, x) in f.enumerated() { put(x, m.offset + (i / comps) * stride + (i % comps) * 4) }
                } else {
                    for (i, x) in f.prefix(components(m.type)).enumerated() { put(x, m.offset + i * 4) }
                }
            case .uints(let list):
                let packedArray = m.arrayCount > 0 && components(m.type) == 4
                for (i, x) in list.enumerated() {
                    let o = packedArray ? m.offset + (i / 4) * stride + (i % 4) * 4
                        : m.arrayCount > 0 ? m.offset + i * max(stride, 4) : m.offset + i * 4
                    put(Float(bitPattern: x), o)
                }
            case .matrix(let p):
                // Always 64 bytes, even into a float3x3: the engine writes matrix ids whole (docs/re/07 §1.1).
                for r in 0..<4 { for c in 0..<4 { put(p[c][r], m.offset + r * 16 + c * 4) } }
            case .matrix3(let p):
                for r in 0..<3 { for c in 0..<3 { put(p[c][r], m.offset + r * 16 + c * 4) } }
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
