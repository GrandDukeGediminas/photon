import Foundation
import Metal
import PhotonCore

/// One compiled material shader: Metal functions plus constant-buffer layouts from SPIRV-Cross reflection.
public final class ShaderProgram {
    public struct Member {
        public let offset: Int
        public let type: String // "float", "vec2", "vec3", "vec4", "mat4", "mat3", "mat4x3"…
        public let arrayCount: Int
        public let arrayStride: Int
    }

    /// Buffer index (cbuffer register) → size and members by name.
    public struct BufferLayout {
        public var size: Int
        public var members: [String: Member]
    }

    public let vertex: MTLFunction
    public let fragment: MTLFunction
    public let vertexBuffers: [Int: BufferLayout]
    public let fragmentBuffers: [Int: BufferLayout]
    public let info: ShaderSourceLoader.Info
    public let combos: [String: Int]
    /// Texture slots sampled by either stage.
    public let textureSlots: Set<Int>
    public let isFallback: Bool
    /// The program has a geometry stage (engine program flag 1, `program+0x10`): `vertex` is the emulated vertex +
    /// geometry function (GeometryEmulation) and draws take one point per instance.
    public var geometry: GeometryEmulation.Result?
    #if os(Linux)
    /// A native vertex + geometry stage pair, used instead of the emulation when the Vulkan device has a geometry stage
    /// and `PHOTON_NATIVE_GS=1` (GeometryEmulation.buildNative). `vertex` stays the emulated function: its reflection
    /// gives the cbuffer layouts both native stages declare.
    public var nativeGeometry: (vertex: MTLFunction, geometry: MTLFunction)?
    /// `PHOTON_NATIVE_GS=passthrough`: `nativeGeometry` is the emulated vertex function plus a pass-through geometry stage.
    var nativeGeometryPassThrough = false
    #endif
    private var pipelines: [PipelineKey: MTLRenderPipelineState] = [:]

    init(vertex: MTLFunction, fragment: MTLFunction, vertexBuffers: [Int: BufferLayout], fragmentBuffers: [Int: BufferLayout],
         info: ShaderSourceLoader.Info, combos: [String: Int], textureSlots: Set<Int>, isFallback: Bool,
         geometry: GeometryEmulation.Result? = nil) {
        self.geometry = geometry
        self.vertex = vertex
        self.fragment = fragment
        self.vertexBuffers = vertexBuffers
        self.fragmentBuffers = fragmentBuffers
        self.info = info
        self.combos = combos
        self.textureSlots = textureSlots
        self.isFallback = isFallback
    }

    struct PipelineKey: Hashable {
        let blend: BlendState
        let pixelFormat: MTLPixelFormat
        let depthFormat: MTLPixelFormat
        let layout: VertexLayout
        let sampleCount: Int
    }

    func pipeline(device: MTLDevice, blend: BlendState, pixelFormat: MTLPixelFormat, depthFormat: MTLPixelFormat = .invalid,
                  layout: VertexLayout = .quad, sampleCount: Int = 1) -> MTLRenderPipelineState? {
        let key = PipelineKey(blend: blend, pixelFormat: pixelFormat, depthFormat: depthFormat, layout: layout, sampleCount: sampleCount)
        if let p = pipelines[key] { return p }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vertex
        d.fragmentFunction = fragment
        d.vertexDescriptor = layout.descriptor(for: vertex)
        #if os(Linux)
        if let n = nativeGeometry {
            d.vertexFunction = n.vertex
            d.geometryFunction = n.geometry
            if nativeGeometryPassThrough { d.geometryInput = .triangle }
        }
        #endif
        let ca = d.colorAttachments[0]!
        ca.pixelFormat = pixelFormat
        d.depthAttachmentPixelFormat = depthFormat
        d.rasterSampleCount = sampleCount // the MSAA scene target (Multisample.swift)
        blend.apply(to: ca)
        d.isAlphaToCoverageEnabled = blend.alphaToCoverage
        do {
            let p = try device.makeRenderPipelineState(descriptor: d)
            pipelines[key] = p
            return p
        } catch {
            NSLog("photon: pipeline error: \(error)")
            return nil
        }
    }

    static func layouts(from reflection: [String: Any]) -> [Int: BufferLayout] {
        guard let ubos = reflection["ubos"] as? [[String: Any]], let types = reflection["types"] as? [String: Any] else { return [:] }
        var result: [Int: BufferLayout] = [:]
        for ubo in ubos {
            guard let binding = ubo["binding"] as? Int, let typeName = ubo["type"] as? String,
                  let type = types[typeName] as? [String: Any], let members = type["members"] as? [[String: Any]] else { continue }
            var layout = BufferLayout(size: (ubo["block_size"] as? Int) ?? 0, members: [:])
            for m in members {
                guard let name = m["name"] as? String, let offset = m["offset"] as? Int else { continue }
                let arr = (m["array"] as? [Int])?.first ?? 0
                layout.members[name] = Member(offset: offset, type: (m["type"] as? String) ?? "float",
                                              arrayCount: arr, arrayStride: (m["array_stride"] as? Int) ?? 16)
            }
            result[binding] = layout
        }
        return result
    }
}

/// A vertex buffer layout. Attribute ids are the engine's attribute table indices (docs/re/02 §6), which the
/// translator pins as SPIR-V locations, so Metal attribute index = id.
public struct VertexLayout: Hashable {
    public struct Attribute: Hashable {
        public let id: Int
        public let format: MTLVertexFormat
        public let offset: Int
        public init(id: Int, format: MTLVertexFormat, offset: Int) {
            self.id = id
            self.format = format
            self.offset = offset
        }
    }

    public let stride: Int
    public let attributes: [Attribute]
    /// One element per instance: the point lists the engine feeds its geometry shaders (docs/re/05 §5.3), drawn through
    /// the emulated geometry stage (GeometryEmulation) as one instance per point.
    public let stepPerInstance: Bool

    public init(stride: Int, attributes: [Attribute], stepPerInstance: Bool = false) {
        self.stride = stride
        self.attributes = attributes
        self.stepPerInstance = stepPerInstance
    }

    /// float3 a_Position + float2 a_TexCoord (docs/re/03 §5).
    public static let quad = VertexLayout(stride: 20, attributes: [
        Attribute(id: 0, format: .float3, offset: 0), Attribute(id: 7, format: .float2, offset: 12),
    ])

    var descriptor: MTLVertexDescriptor { descriptor(for: nil) }

    /// Engine attribute ids sharing a D3D semantic (docs/re/02 §6): a_Position/a_PositionVec4 are both POSITION0,
    /// a_TexCoord/Vec3/Vec4 are TEXCOORD0, and so on.
    static func semanticGroup(_ id: Int) -> Int {
        switch id {
        case 0, 1: return 0
        case 7...24: return 100 + (id - 7) / 3
        default: return 1000 + id
        }
    }

    /// D3D11 binds vertex inputs by semantic and fills missing components with (0,0,0,1). A shader asking for an
    /// attribute the mesh lacks (e.g. a_PositionVec4 on the float3 quad) is aliased to the mesh attribute with the
    /// same semantic; Metal expands the components the same way.
    func descriptor(for function: MTLFunction?) -> MTLVertexDescriptor {
        let v = MTLVertexDescriptor()
        func set(_ index: Int, _ a: Attribute) {
            v.attributes[index].format = a.format
            v.attributes[index].offset = a.offset
            v.attributes[index].bufferIndex = ShaderCompiler.vertexBufferIndex
        }
        for a in attributes { set(a.id, a) }
        for fa in function?.vertexAttributes ?? [] where fa.isActive && !attributes.contains(where: { $0.id == fa.attributeIndex }) {
            if let src = attributes.first(where: { Self.semanticGroup($0.id) == Self.semanticGroup(fa.attributeIndex) }) {
                set(fa.attributeIndex, src)
            }
        }
        v.layouts[ShaderCompiler.vertexBufferIndex].stride = stride
        if stepPerInstance {
            v.layouts[ShaderCompiler.vertexBufferIndex].stepFunction = .perInstance
            v.layouts[ShaderCompiler.vertexBufferIndex].stepRate = 1
        }
        return v
    }
}

/// Geometry for one draw.
public struct Mesh {
    public var layout: VertexLayout
    public var vertices: [Float]
    public var indices: [UInt32]?
    public var vertexCount: Int

    public init(layout: VertexLayout, vertices: [Float], indices: [UInt32]? = nil, vertexCount: Int? = nil) {
        self.layout = layout
        self.vertices = vertices
        self.indices = indices
        self.vertexCount = vertexCount ?? (vertices.count * 4 / max(layout.stride, 1))
    }
}

/// Blend state from the renderer's mode byte and modifiers (docs/re/03 §2).
public struct BlendState: Hashable {
    public enum Mode: Int { case normal = 0, translucent = 1, additive = 2, alphaToCoverage = 3 }
    public var mode: Mode = .normal
    public var colorWrite = true
    public var alphaWrite = false
    public var alphaMax = false
    /// State bit 0x100 (renderer vt+0x108, `R_FlushState` 0x140099f60): colour SrcBlend = DEST_COLOR.
    public var destColor = false

    public init(mode: Mode = .normal, colorWrite: Bool = true, alphaWrite: Bool = false, alphaMax: Bool = false) {
        self.mode = mode
        self.colorWrite = colorWrite
        self.alphaWrite = alphaWrite
        self.alphaMax = alphaMax
    }

    var alphaToCoverage: Bool { colorWrite && mode == .alphaToCoverage }

    func apply(to ca: MTLRenderPipelineColorAttachmentDescriptor) {
        guard colorWrite else {
            ca.writeMask = .alpha // pseudo-mode 4: WriteMask = 8
            ca.isBlendingEnabled = false
            return
        }
        switch mode {
        case .normal, .alphaToCoverage:
            ca.isBlendingEnabled = false
        case .translucent:
            ca.isBlendingEnabled = true
            ca.sourceRGBBlendFactor = .sourceAlpha; ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.sourceAlphaBlendFactor = .sourceAlpha; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        case .additive:
            ca.isBlendingEnabled = true
            ca.sourceRGBBlendFactor = .sourceAlpha; ca.destinationRGBBlendFactor = .one
            ca.sourceAlphaBlendFactor = .sourceAlpha; ca.destinationAlphaBlendFactor = .one
        }
        if destColor && ca.isBlendingEnabled { ca.sourceRGBBlendFactor = .destinationColor }
        ca.rgbBlendOperation = .add
        ca.alphaBlendOperation = .add
        ca.writeMask = [.red, .green, .blue]
        if alphaWrite || alphaMax { ca.writeMask = .all }
        if alphaMax {
            ca.isBlendingEnabled = true
            if mode == .normal || mode == .alphaToCoverage {
                ca.sourceRGBBlendFactor = .one; ca.destinationRGBBlendFactor = .zero
            }
            ca.alphaBlendOperation = .max
            ca.sourceAlphaBlendFactor = .one; ca.destinationAlphaBlendFactor = .one
        }
    }
}

/// Builds and caches `ShaderProgram`s; on any compile error uses `shaders/HLSL/dx11fallback`, like the engine.
public final class ShaderLibrary {
    let device: MTLDevice
    let builder: ShaderBuilder
    let compiler: ShaderCompiler
    let fs: AssetFileSystem
    private var cache: [ShaderBuilder.Request: ShaderProgram] = [:]
    private var fallbackProgram: ShaderProgram?

    public init(device: MTLDevice, fs: AssetFileSystem, compiler: ShaderCompiler = ShaderCompiler()) {
        self.device = device
        self.fs = fs
        self.builder = ShaderBuilder(sources: ShaderSourceLoader(fs: fs))
        self.compiler = compiler
    }

    public var sources: ShaderSourceLoader { builder.sources }
    static let dumpDirectory = ProcessInfo.processInfo.environment["PHOTON_DUMP_HLSL"]

    public func program(_ request: ShaderBuilder.Request) -> ShaderProgram? {
        if let hit = cache[request] { return hit }
        let program: ShaderProgram?
        do {
            let built = try builder.build(request)
            if let dir = Self.dumpDirectory {
                // PHOTON_DUMP_HLSL=<dir>: every program's translated stages, for cross-checks against FXC.
                let name = "\(request.shader.replacingOccurrences(of: "/", with: "_"))_\(abs((built.vertex.hlsl + built.fragment.hlsl).hashValue))"
                try? built.vertex.hlsl.write(toFile: dir + "/" + name + ".vs.hlsl", atomically: true, encoding: .utf8)
                try? built.fragment.hlsl.write(toFile: dir + "/" + name + ".ps.hlsl", atomically: true, encoding: .utf8)
                if let g = built.geometry { try? g.hlsl.write(toFile: dir + "/" + name + ".gs.hlsl", atomically: true, encoding: .utf8) }
                // The emulated vertex function is photon2's, not a stage the engine compiles: no `.hlsl` suffix for fxc-check.
                if let e = built.emulation { try? e.hlsl.write(toFile: dir + "/" + name + ".vsgs.txt", atomically: true, encoding: .utf8) }
            }
            let vsKey = FXCVerdicts.key(hlsl: built.vertex.hlsl, stage: "vs"), psKey = FXCVerdicts.key(hlsl: built.fragment.hlsl, stage: "ps")
            if let observe = FXCVerdicts.observer {
                let combos = built.combos.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
                observe(vsKey, "vs", built.vertex.hlsl, request.shader, combos)
                observe(psKey, "ps", built.fragment.hlsl, request.shader, combos)
                if let g = built.geometry { observe(FXCVerdicts.key(hlsl: g.hlsl, stage: "gs"), "gs", g.hlsl, request.shader, combos) }
            }
            // PHOTON_FXC_STRICT=1: the engine's per-stage dx11fallback for stages WE's FXC rejects (FXCVerdicts).
            let vsRejected = FXCVerdicts.strict ? FXCVerdicts.failing[vsKey] : nil
            let psRejected = FXCVerdicts.strict ? FXCVerdicts.failing[psKey] : nil
            if let r = vsRejected ?? psRejected {
                NSLog("photon: FXC strict: %@ %@ stage rejected by FXC (%@), using dx11fallback", request.shader, r.stage, r.error)
            }
            if vsRejected != nil {
                // 0x1400d569f: the VS becomes dx11fallback.vert, which outputs only SV_POSITION. D3D11 still links it with
                // the program's own PS (undefined varyings); Metal refuses a fragment input the vertex stage does not
                // write, so the whole program falls back here (no corpus program has a rejected VS).
                program = fallback()
            } else {
                // Geometry stage (ShaderProgram_Compile 0x1400d5070): kept only when no stage fell back (0x1400d58ab–0x1400d58c6).
                // On Metal it is folded into the vertex function (GeometryEmulation); a program whose GS cannot be emulated
                // is built without one, like a program whose GS failed to compile in the engine.
                var emulation = psRejected == nil ? built.emulation : nil
                if built.geometry != nil, emulation == nil, psRejected == nil {
                    NSLog("photon: %@ geometry stage not emulated: %@", request.shader, built.emulationError ?? "?")
                }
                var vs: ShaderCompiler.CompiledStage
                if let e = emulation {
                    do {
                        vs = try compiler.compile(hlsl: e.hlsl, stage: .vertex)
                    } catch {
                        NSLog("photon: %@ geometry emulation compile error:\n%@", request.shader, "\(error)")
                        emulation = nil
                        vs = try compiler.compile(hlsl: built.vertex.hlsl, stage: .vertex)
                    }
                } else {
                    vs = try compiler.compile(hlsl: built.vertex.hlsl, stage: .vertex)
                }
                // 0x1400d57bd: a rejected PS alone becomes dx11fallback.frag (solid (0.5, 0, 0, 1)) behind the program's VS.
                let ps = try psRejected != nil ? fallbackStage(.fragment) : compiler.compile(hlsl: built.fragment.hlsl, stage: .fragment)
                var textures = Set(built.vertex.textures.keys).union(psRejected != nil ? Set<Int>() : Set(built.fragment.textures.keys))
                if emulation != nil, let g = built.geometry { textures.formUnion(g.textures.keys) }
                program = try make(vs: vs, ps: ps, info: built.info, combos: built.combos, textures: textures,
                                   fallback: psRejected != nil, geometry: emulation)
                #if os(Linux)
                if emulation != nil, let g = built.geometry, let p = program, let mode = Self.nativeGeometryMode(device) {
                    p.nativeGeometry = nativeStages(vertex: built.vertex, geometry: g, macros: built.geometryMacros, emulated: p.vertex,
                                                    passThrough: mode == "passthrough", shader: request.shader)
                    p.nativeGeometryPassThrough = mode == "passthrough"
                }
                #endif
            }
        } catch {
            NSLog("photon: %@ shader %@ error:\n%@", "fragment", request.shader, "\(error)")
            program = fallback()
        }
        cache[request] = program
        return program
    }

    private func make(vs: ShaderCompiler.CompiledStage, ps: ShaderCompiler.CompiledStage, info: ShaderSourceLoader.Info,
                      combos: [String: Int], textures: Set<Int>, fallback: Bool, geometry: GeometryEmulation.Result? = nil) throws -> ShaderProgram {
        let vlib = try device.makeLibrary(source: vs.msl, options: nil)
        let flib = try device.makeLibrary(source: ps.msl, options: nil)
        guard let vf = vlib.makeFunction(name: vs.entryPoint), let ff = flib.makeFunction(name: ps.entryPoint) else {
            throw ShaderCompiler.Error.tool("metal", "missing entry point")
        }
        return ShaderProgram(vertex: vf, fragment: ff, vertexBuffers: ShaderProgram.layouts(from: vs.reflection),
                             fragmentBuffers: ShaderProgram.layouts(from: ps.reflection), info: info, combos: combos,
                             textureSlots: textures, isFallback: fallback, geometry: geometry)
    }

    #if os(Linux)
    /// `PHOTON_NATIVE_GS=1` (or `passthrough`, the check) on a device with a geometry stage: GS programs run on the
    /// device's geometry stage (GeometryEmulation.buildNative) instead of the emulation alone.
    static func nativeGeometryMode(_ device: MTLDevice) -> String? {
        guard let mode = ProcessInfo.processInfo.environment["PHOTON_NATIVE_GS"], mode == "1" || mode == "passthrough",
              device.gpuDevice.capabilities.geometryShaders else { return nil }
        return mode
    }

    /// Compiles the native pair; nil (the emulation stays) when a stage does not compile.
    func nativeStages(vertex: HLSLTranslator.Output, geometry: HLSLTranslator.Output, macros: [String: String], emulated: MTLFunction,
                      passThrough: Bool, shader: String) -> (vertex: MTLFunction, geometry: MTLFunction)? {
        do {
            let st = try GeometryEmulation.buildNative(vertex: vertex, geometry: geometry, geometryMacros: macros, passThrough: passThrough)
            let gs = try compiler.compile(hlsl: st.hlsl, stage: .geometry)
            guard let gf = try device.makeLibrary(source: gs.msl, options: nil).makeFunction(name: gs.entryPoint) else { return nil }
            var vf = emulated
            if let text = st.nativeVertexHLSL {
                let vs = try compiler.compile(hlsl: text, stage: .vertex)
                guard let f = try device.makeLibrary(source: vs.msl, options: nil).makeFunction(name: vs.entryPoint) else { return nil }
                vf = f
            }
            NSLog("photon: %@ uses the native geometry stage%@", shader, passThrough ? " (pass-through check)" : "")
            return (vf, gf)
        } catch {
            NSLog("photon: %@ native geometry stage not used: %@", shader, "\(error)")
            return nil
        }
    }
    #endif

    /// One raw-HLSL fallback stage (`shaders/HLSL/dx11fallback.vert` / `.frag`), for the per-stage fallback.
    func fallbackStage(_ stage: HLSLTranslator.Stage) throws -> ShaderCompiler.CompiledStage {
        let path = stage == .vertex ? "shaders/HLSL/dx11fallback.vert" : "shaders/HLSL/dx11fallback.frag"
        guard let d = fs.read(path) else { throw ShaderCompiler.Error.tool("fallback", "\(path) missing") }
        return try compiler.compile(hlsl: String(decoding: d, as: UTF8.self), stage: stage)
    }

    /// `shaders/HLSL/dx11fallback.{vert,frag}` are raw HLSL and bypass the translator (docs/re/02 §2.9).
    func fallback() -> ShaderProgram? {
        if let f = fallbackProgram { return f }
        guard let v = fs.read("shaders/HLSL/dx11fallback.vert"), let p = fs.read("shaders/HLSL/dx11fallback.frag"),
              let vs = try? compiler.compile(hlsl: String(decoding: v, as: UTF8.self), stage: .vertex),
              let ps = try? compiler.compile(hlsl: String(decoding: p, as: UTF8.self), stage: .fragment),
              let prog = try? make(vs: vs, ps: ps, info: .init(), combos: [:], textures: [], fallback: true) else { return nil }
        fallbackProgram = prog
        return prog
    }
}
