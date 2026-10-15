/// Reflection read straight from a SPIR-V module: everything photon2 takes from `spirv-cross --reflect` today
/// (ShaderProgram.layouts), without SPIRV-Cross. Member type names follow spirv-cross's GLSL spelling ("float", "vec4",
/// "mat4", "mat4x3", "ivec2", "uint" …) so the uniform packer (Draw.pack) works unchanged on either source.
public struct SPIRVReflection: Sendable {
    public struct Member: Hashable, Sendable {
        public var name: String
        public var offset: Int
        public var type: String
        /// Outermost array length, 0 for non-arrays (spirv-cross "array"[0]).
        public var arrayCount: Int
        public var arrayStride: Int
        public var matrixStride: Int
        public var rowMajor: Bool
    }

    public struct UniformBlock: Sendable {
        public var name: String
        public var set: Int
        public var binding: Int
        /// spirv-cross "block_size": offset of the last member plus its declared size.
        public var size: Int
        public var members: [Member]
    }

    public struct Resource: Hashable, Sendable {
        public var name: String
        public var set: Int
        public var binding: Int
    }

    public struct Input: Hashable, Sendable {
        public var name: String
        public var location: Int
        public var type: String
    }

    public var entryPoint = ""
    public var executionModel = 0
    public var uniformBlocks: [UniformBlock] = []
    /// Separate images (HLSL Texture2D/Texture3D).
    public var images: [Resource] = []
    /// Separate samplers (HLSL SamplerState / SamplerComparisonState).
    public var samplers: [Resource] = []
    public var inputs: [Input] = []

    public enum Error: Swift.Error { case notSPIRV, truncated }

    public init(words: [UInt32]) throws {
        guard words.count >= 5, words[0] == 0x0723_0203 else { throw Error.notSPIRV }
        var names: [UInt32: String] = [:]
        var memberNames: [UInt32: [Int: String]] = [:]
        var decorations: [UInt32: [UInt32: [UInt32]]] = [:] // id → decoration → literals
        var memberDecorations: [UInt32: [Int: [UInt32: [UInt32]]]] = [:]
        var types: [UInt32: TypeInfo] = [:]
        var constants: [UInt32: UInt32] = [:]
        var variables: [(type: UInt32, id: UInt32, storage: UInt32)] = []

        var i = 5
        while i < words.count {
            let wc = Int(words[i] >> 16), op = words[i] & 0xFFFF
            guard wc > 0, i + wc <= words.count else { throw Error.truncated }
            let w = Array(words[(i + 1)..<(i + wc)])
            switch op {
            case 15: // OpEntryPoint model id name interface…
                executionModel = Int(w[0])
                entryPoint = Self.string(w, from: 2).0
            case 5: names[w[0]] = Self.string(w, from: 1).0
            case 6: memberNames[w[0], default: [:]][Int(w[1])] = Self.string(w, from: 2).0
            case 71: decorations[w[0], default: [:]][w[1]] = Array(w.dropFirst(2))
            case 72: memberDecorations[w[0], default: [:]][Int(w[1]), default: [:]][w[2]] = Array(w.dropFirst(3))
            case 20: types[w[0]] = .bool
            case 21: types[w[0]] = .int(width: Int(w[1]), signed: w[2] != 0)
            case 22: types[w[0]] = .float(width: Int(w[1]))
            case 23: types[w[0]] = .vector(component: w[1], count: Int(w[2]))
            case 24: types[w[0]] = .matrix(column: w[1], columns: Int(w[2]))
            case 25: types[w[0]] = .image
            case 26: types[w[0]] = .sampler
            case 27: types[w[0]] = .sampledImage
            case 28: types[w[0]] = .array(element: w[1], lengthId: w[2])
            case 29: types[w[0]] = .runtimeArray(element: w[1])
            case 30: types[w[0]] = .structure(members: Array(w.dropFirst()))
            case 32: types[w[0]] = .pointer(storage: w[1], pointee: w[2])
            case 43: constants[w[1]] = w.count > 2 ? w[2] : 0 // OpConstant type id value
            case 59: variables.append((w[0], w[1], w[2]))
            default: break
            }
            i += wc
        }

        func resolvePointer(_ t: UInt32) -> UInt32 {
            if case .pointer(_, let p)? = types[t] { return p }
            return t
        }
        func glslName(_ t: UInt32) -> String {
            switch types[t] {
            case .bool?: return "bool"
            case .int(_, let signed)?: return signed ? "int" : "uint"
            case .float(let width)?: return width == 64 ? "double" : (width == 16 ? "float16_t" : "float")
            case .vector(let c, let n)?:
                switch types[c] {
                case .int(_, let s)?: return (s ? "ivec" : "uvec") + "\(n)"
                case .bool?: return "bvec\(n)"
                default: return "vec\(n)"
                }
            case .matrix(let col, let cols)?:
                var rows = 4
                if case .vector(_, let n)? = types[col] { rows = n }
                return cols == rows ? "mat\(cols)" : "mat\(cols)x\(rows)"
            case .array(let e, _)?, .runtimeArray(let e)?: return glslName(e)
            case .structure?: return names[t] ?? "_\(t)"
            default: return "?"
            }
        }
        func scalarBytes(_ t: UInt32) -> Int {
            switch types[t] {
            case .int(let w, _)?: return w / 8
            case .float(let w)?: return w / 8
            default: return 4
            }
        }
        /// spirv-cross `get_declared_struct_member_size`.
        func memberSize(structId: UInt32, index: Int, type t: UInt32) -> Int {
            let deco = memberDecorations[structId]?[index] ?? [:]
            switch types[t] {
            case .array(_, let lenId)?:
                let stride = Int(decorations[t]?[6]?.first ?? 16) // ArrayStride
                return stride * Int(constants[lenId] ?? 1)
            case .runtimeArray?: return 0
            case .structure(let ms)?:
                return structSize(t, members: ms)
            case .matrix(let col, let cols)?:
                var rows = 4, comp: UInt32 = 0
                if case .vector(let c, let n)? = types[col] { rows = n; comp = c }
                let stride = Int(deco[7]?.first ?? 16) // MatrixStride
                let rowMajor = deco[4] != nil
                // The last column (row) only takes its own components, as spirv-cross counts it.
                return rowMajor ? stride * (rows - 1) + cols * scalarBytes(comp) : stride * (cols - 1) + rows * scalarBytes(comp)
            case .vector(let c, let n)?: return n * scalarBytes(c)
            default: return scalarBytes(t)
            }
        }
        func structSize(_ id: UInt32, members: [UInt32]) -> Int {
            guard let last = members.indices.last else { return 0 }
            let off = Int(memberDecorations[id]?[last]?[35]?.first ?? 0) // Offset
            return off + memberSize(structId: id, index: last, type: members[last])
        }

        for v in variables {
            let pointee = resolvePointer(v.type)
            let set = Int(decorations[v.id]?[34]?.first ?? 0), binding = Int(decorations[v.id]?[33]?.first ?? 0)
            switch v.storage {
            case 2: // Uniform
                guard case .structure(let ms)? = types[pointee], decorations[pointee]?[2] != nil else { continue } // Block
                var members: [Member] = []
                for (k, mt) in ms.enumerated() {
                    let deco = memberDecorations[pointee]?[k] ?? [:]
                    var count = 0, stride = 0
                    if case .array(_, let lenId)? = types[mt] {
                        count = Int(constants[lenId] ?? 0)
                        stride = Int(decorations[mt]?[6]?.first ?? 0)
                    }
                    members.append(Member(name: memberNames[pointee]?[k] ?? "_m\(k)", offset: Int(deco[35]?.first ?? 0),
                                          type: glslName(mt), arrayCount: count, arrayStride: stride,
                                          matrixStride: Int(deco[7]?.first ?? 0), rowMajor: deco[4] != nil))
                }
                uniformBlocks.append(UniformBlock(name: names[pointee] ?? names[v.id] ?? "", set: set, binding: binding,
                                                  size: structSize(pointee, members: ms), members: members))
            case 0: // UniformConstant
                var base = pointee
                if case .array(let e, _)? = types[base] { base = e }
                switch types[base] {
                case .image?, .sampledImage?: images.append(Resource(name: names[v.id] ?? "", set: set, binding: binding))
                case .sampler?: samplers.append(Resource(name: names[v.id] ?? "", set: set, binding: binding))
                default: break
                }
            case 1: // Input
                guard let loc = decorations[v.id]?[30]?.first else { continue } // Location (built-ins have none)
                inputs.append(Input(name: names[v.id] ?? "", location: Int(loc), type: glslName(pointee)))
            default: break
            }
        }
        uniformBlocks.sort { ($0.set, $0.binding) < ($1.set, $1.binding) }
        images.sort { ($0.set, $0.binding) < ($1.set, $1.binding) }
        samplers.sort { ($0.set, $0.binding) < ($1.set, $1.binding) }
        inputs.sort { $0.location < $1.location }
    }

    private indirect enum TypeInfo {
        case bool, int(width: Int, signed: Bool), float(width: Int)
        case vector(component: UInt32, count: Int), matrix(column: UInt32, columns: Int)
        case image, sampler, sampledImage
        case array(element: UInt32, lengthId: UInt32), runtimeArray(element: UInt32)
        case structure(members: [UInt32]), pointer(storage: UInt32, pointee: UInt32)
    }

    /// A nul-terminated UTF-8 literal string starting at word `from`; returns it and the word after it.
    private static func string(_ w: [UInt32], from: Int) -> (String, Int) {
        var bytes: [UInt8] = []
        var k = from
        outer: while k < w.count {
            for s in stride(from: 0, to: 32, by: 8) {
                let b = UInt8((w[k] >> UInt32(s)) & 0xFF)
                if b == 0 { k += 1; break outer }
                bytes.append(b)
            }
            k += 1
        }
        return (String(decoding: bytes, as: UTF8.self), k)
    }
}

extension SPIRVReflection {
    /// Little-endian SPIR-V file bytes → words.
    public static func words(_ bytes: [UInt8]) -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity(bytes.count / 4)
        var i = 0
        while i + 3 < bytes.count {
            let b0 = UInt32(bytes[i]), b1 = UInt32(bytes[i + 1]) << 8
            let b2 = UInt32(bytes[i + 2]) << 16, b3 = UInt32(bytes[i + 3]) << 24
            out.append(b0 | b1 | b2 | b3)
            i += 4
        }
        return out
    }
}
