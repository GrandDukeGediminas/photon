import Foundation
import PhotonCore
import PhotonGPU

/// Headless scene prototype for the Linux port (docs/linux-port.md §6): loads a scene through PhotonCore and draws the
/// clear plus its plain image layers (direct path of `Layer_Render`: no effects, no dedicated composite, no puppet)
/// through PhotonGPU only. It follows PhotonRender's ImageLayer/SceneRenderer/Draw code for that path line by line, so
/// its output can be compared pixel for pixel with `photon-tool render` on macOS. Everything else is skipped and logged.
/// It is a stand-in until PhotonRender itself renders through PhotonGPU (migration plan §3).
public final class ProtoScene {
    public struct Options {
        public var only: Set<Int>?
        public var time: Float = 1
        public var width = 1920
        public var height = 1080
        public init() {}
    }

    let device: GPUDevice
    let fs: AssetFileSystem
    let builder: ShaderBuilder
    let compiler: SPIRVCompiler
    let options: Options
    public private(set) var log: [String] = []
    var orthoSize = SIMD2<Float>(1920, 1080)
    var isOrtho = true
    var hdr = false
    var clearColor = SIMD3<Float>(0, 0, 0)
    var clearEnabled = true
    var general: [String: Any] = [:]
    var layers: [Layer] = []
    private var textureCache: [String: LoadedTexture] = [:]
    private var programCache: [String: Program] = [:]
    private var samplerCache: [GPUSamplerDescriptor: GPUSampler] = [:]

    struct LoadedTexture {
        let texture: GPUTextureResource
        let sampler: GPUSampler
        let tex: TexFile
        var resolution: SIMD4<Float> {
            SIMD4(Float(tex.textureWidth), Float(tex.textureHeight), Float(tex.imageWidth), Float(tex.imageHeight))
        }
        var mipInfo: Float { 1 } // file textures: 1 (BoundTexture.mipInfo)
    }

    final class Program {
        let vertex: GPUShaderModule
        let fragment: GPUShaderModule
        let info: ShaderSourceLoader.Info
        var pipelines: [GPUBlendDescriptor: GPURenderPipeline] = [:]
        init(vertex: GPUShaderModule, fragment: GPUShaderModule, info: ShaderSourceLoader.Info) {
            self.vertex = vertex
            self.fragment = fragment
            self.info = info
        }
    }

    struct Layer {
        let id: Int
        let program: Program
        let textures: [Int: LoadedTexture]
        let materialUniforms: [String: ProtoUniform]
        let vertices: [Float]
        let world: Mat4
        let blendMode: Int
        let cullNone: Bool
        let color: SIMD3<Float>
        let alpha: Float
    }

    public init(device: GPUDevice, wallpaper: URL, engineAssets: URL, options: Options = Options(),
                compiler: SPIRVCompiler = SPIRVCompiler()) throws {
        self.device = device
        self.options = options
        self.compiler = compiler
        fs = AssetFileSystem(engineAssets: engineAssets)
        builder = ShaderBuilder(sources: ShaderSourceLoader(fs: fs))

        let project = (try? Data(contentsOf: wallpaper.appendingPathComponent("project.json"))).flatMap(parseEngineJSON) as? [String: Any] ?? [:]
        let file = (project["file"] as? String) ?? "scene.json"
        let pkg = wallpaper.appendingPathComponent((file as NSString).deletingPathExtension + ".pkg")
        let scenePath = try fs.mountWallpaper(file: FileManager.default.fileExists(atPath: pkg.path) ? pkg : wallpaper.appendingPathComponent(file))
        guard let scene = fs.readJSON(scenePath) as? [String: Any] else { throw GPUError.failed("cannot read \(scenePath)") }
        try load(scene)
    }

    func note(_ s: String) { log.append(s) }

    // MARK: Load (SceneRenderer.load, subset)

    func load(_ scene: [String: Any]) throws {
        general = (scene["general"] as? [String: Any]) ?? [:]
        if let o = general["orthogonalprojection"] as? [String: Any] {
            orthoSize = SIMD2(Float(EngineValue.int(o["width"], default: 1920)), Float(EngineValue.int(o["height"], default: 1080)))
            if jsonBool(o["auto"], default: false) { note("orthogonalprojection.auto: not handled, using \(orthoSize)") }
        } else {
            isOrtho = false
            note("perspective scene: not handled by the prototype (drawn with an ortho camera)")
        }
        hdr = jsonBool(general["hdr"], default: false)
        clearColor = EngineValue.vec3(general["clearcolor"], default: SIMD3(0, 0, 0))
        clearEnabled = jsonBool(general["clearenabled"], default: true)
        if jsonBool(general["bloom"], default: false) { note("bloom: not handled") }
        if let camera = scene["camera"] as? [String: Any], !((camera["paths"] as? [Any]) ?? []).isEmpty {
            note("camera paths: not handled")
        }

        for (index, any) in ((scene["objects"] as? [Any]) ?? []).enumerated() {
            guard let o = any as? [String: Any] else { continue }
            let id = EngineValue.int(o["id"], default: index)
            if let only = options.only, !only.contains(id) { continue }
            guard let imagePath = o["image"] as? String else { note("object \(id): not an image layer, skipped"); continue }
            guard EngineValue.bool(o["visible"], default: true) else { continue }
            if !((o["effects"] as? [Any]) ?? []).isEmpty { note("object \(id): effects not handled, skipped"); continue }
            if o["parent"] != nil { note("object \(id): parented layer, skipped"); continue }
            let blendMode = EngineValue.int(o["colorBlendMode"], default: 0)
            if blendMode != 0 { note("object \(id): colorBlendMode \(blendMode) needs a composite, skipped"); continue }
            do {
                if let layer = try makeLayer(o, id: id, imagePath: imagePath) { layers.append(layer) }
            } catch {
                note("object \(id): \(error)")
            }
        }
    }

    func makeLayer(_ o: [String: Any], id: Int, imagePath: String) throws -> Layer? {
        guard let model = fs.readJSON(imagePath) as? [String: Any] else { note("object \(id): \(imagePath) missing"); return nil }
        if model["puppet"] != nil { note("object \(id): puppet, skipped"); return nil }
        let fullscreen = jsonBool(model["fullscreen"], default: false)
        let passthrough = jsonBool(model["passthrough"], default: false)
        if fullscreen || passthrough { note("object \(id): fullscreen/passthrough layer, skipped"); return nil }
        let noPadding = jsonBool(model["nopadding"], default: false), autosize = jsonBool(model["autosize"], default: false)
        let solidLayer = jsonBool(model["solidlayer"], default: false)
        guard let materialPath = model["material"] as? String, let mj = fs.readJSON(materialPath) as? [String: Any],
              let pass = (mj["passes"] as? [Any])?.first as? [String: Any] else {
            note("object \(id): material missing"); return nil
        }

        // Material (Material.init / resolve).
        let blending = (pass["blending"] as? String) ?? "normal"
        let cullNone = (pass["cullmode"] as? String) == "nocull"
        var combos: [String: Int] = [:]
        for (k, v) in (pass["combos"] as? [String: Any]) ?? [:] { combos[k.uppercased()] = (unwrapUserValue(v) as? NSNumber)?.intValue ?? 0 }
        if blending == "alphatocoverage" { combos["ALPHATOCOVERAGE"] = 1 }
        if blending == "additive" { combos["ADDITIVE"] = 1 }
        var constants = (pass["constantshadervalues"] as? [String: Any]) ?? [:]
        let shaderName = (pass["shader"] as? String) ?? "error"
        var textureNames: [Int: String] = [:]
        for (i, t) in ((pass["textures"] as? [Any]) ?? []).prefix(10).enumerated() {
            if let n = t as? String, !n.isEmpty { textureNames[i] = n }
        }
        if pass["usertextures"] != nil { note("object \(id): usertextures not handled") }
        let info = builder.sources.info(shader: shaderName)
        let explicitSlots = Set(textureNames.keys)
        for (slot, s) in info.samplers where textureNames[slot] == nil {
            textureNames[slot] = s.defaultTexture.flatMap { $0.isEmpty ? nil : $0 } ?? "error"
        }
        var textures: [Int: LoadedTexture] = [:]
        var bound: [Int: Int32] = [:], formats: [Int: Int32] = [:], flags: [Int: Int32] = [:]
        for (slot, name) in textureNames {
            if name.hasPrefix("_rt_") || name.hasPrefix("_alias_") {
                bound[slot] = 0
                note("object \(id): slot \(slot) \(name) (render target) not handled")
                continue
            }
            let t = try texture(named: name)
            textures[slot] = t
            bound[slot] = t.tex.rawFormat
            formats[slot] = t.tex.rawFormat
            flags[slot] = t.tex.flags.rawValue
        }
        var sceneCombos: [String: Int] = ["REVERSEDEPTH": 1]
        if isOrtho { sceneCombos["SCENE_ORTHO"] = 1 }
        if hdr { sceneCombos["HDR"] = 1 }
        let request = ShaderBuilder.Request(shader: shaderName, combos: combos, boundTextures: bound.filter { explicitSlots.contains($0.key) },
                                            textureFlags: flags, formatTextures: formats, sceneCombos: sceneCombos,
                                            lightConfig: 0, fogFlags: 0, shadowQuality: 0)
        let program = try self.program(request)
        for (_, v) in program.info.values where constants[v.materialKey] == nil {
            constants[v.materialKey] = v.components == 1 ? (Double(v.defaultValue) ?? 0) as Any : v.defaultValue as Any
        }
        var materialUniforms: [String: ProtoUniform] = [:]
        for (name, v) in program.info.values { // Material.materialUniforms
            var f = jsonFloats(constants[v.materialKey])
            if f.count == 1 && v.components == 2 { f = [f[0], f[0]] }
            if f.count == 1 && v.components > 2 { f = [] }
            if f.isEmpty { f = jsonFloats(v.defaultValue) }
            while f.count < v.components { f.append(0) }
            materialUniforms[name] = .floats(Array(f.prefix(v.components)))
        }

        // Geometry (ImageLayer.buildGeometry, direct path).
        let dims = textures[0].map { $0.resolution } ?? .zero
        let texW = dims.x, texH = dims.y, imgW = dims.z, imgH = dims.w
        var size = SIMD2<Float>(EngineValue.vec2(o["size"], default: SIMD2(0, 0)))
        if textures[0]?.tex.flags.contains(.spriteSheet) == true { note("object \(id): sprite sheet not handled") }
        if autosize { size = SIMD2(imgW, imgH) }
        let geom = SIMD2(Float(Int(size.x)), Float(Int(size.y)))
        let uvScale = SIMD2<Float>(texW > 0 ? imgW / texW : 1, texH > 0 ? imgH / texH : 1)
        let plain = noPadding || solidLayer
        let vertices = Self.quad(size: geom, textureSize: SIMD2(texW, texH), uvScale: uvScale, inset: !plain)

        let origin = EngineValue.vec3(o["origin"], default: .zero), scale = EngineValue.vec3(o["scale"], default: SIMD3(1, 1, 1))
        let angles = EngineValue.vec3(o["angles"], default: .zero)
        if (o["alignment"] as? String).map({ $0 != "center" }) ?? false { note("object \(id): alignment \(o["alignment"]!) not handled") }
        let world = Mat4.translate(origin) * Mat4.rotation(angles) * Mat4.scale(scale)
        let blendMode: Int = ["translucent": 1, "additive": 2, "alphatocoverage": 3][blending] ?? 0
        return Layer(id: id, program: program, textures: textures, materialUniforms: materialUniforms, vertices: vertices, world: world,
                     blendMode: blendMode, cullNone: cullNone, color: EngineValue.vec3(o["color"], default: SIMD3(1, 1, 1)),
                     alpha: EngineValue.float(o["alpha"], default: 1))
    }

    /// `Mesh_CreateQuad` centred (Quad in Draw.swift): float3 position + float2 uv; `inset` pulls UVs in by 0.15 texel.
    static func quad(size: SIMD2<Float>, textureSize: SIMD2<Float>, uvScale: SIMD2<Float>, inset: Bool) -> [Float] {
        let x0 = -size.x / 2, x1 = size.x / 2, y0 = -size.y / 2, y1 = size.y / 2
        let du: Float = inset && textureSize.x > 0 ? 0.15 / textureSize.x : 0
        let dv: Float = inset && textureSize.y > 0 ? 0.15 / textureSize.y : 0
        let u0 = du, u1 = uvScale.x - du, v0 = dv, v1 = uvScale.y - dv
        return [x0, y1, 0, u0, v0, x1, y1, 0, u1, v0, x0, y0, 0, u0, v1, x1, y0, 0, u1, v1]
    }

    // MARK: Resources

    func sampler(_ d: GPUSamplerDescriptor) throws -> GPUSampler {
        if let s = samplerCache[d] { return s }
        let s = try device.makeSampler(d)
        samplerCache[d] = s
        return s
    }

    static func pixelFormat(_ f: TexFile.Format) -> GPUPixelFormat {
        switch f {
        case .rgba8888: return .rgba8Unorm
        case .dxt5: return .bc3
        case .dxt3: return .bc2
        case .dxt1: return .bc1
        case .rg88: return .rg8Unorm
        case .r8: return .r8Unorm
        case .rg16f: return .rg16Float
        case .r16f: return .r16Float
        case .bc7: return .bc7
        case .rgb10a2: return .rgb10a2Unorm
        case .rgba16f: return .rgba16Float
        case .r32f: return .r32Float
        case .rgba16: return .rgba16Unorm
        case .rgba16s: return .rgba16Snorm
        }
    }

    /// TextureLoader.texture(named:) / makeTexture for still `.tex` files; missing or undecodable → the error texture.
    func texture(named name: String) throws -> LoadedTexture {
        if let t = textureCache[name] { return t }
        var tex: TexFile
        if name != "error", let data = fs.read(AssetFileSystem.texturePath(name)), let t = try? TexFile(data: data), !t.images.isEmpty {
            tex = t
        } else {
            if name != "error" { note("texture \(name) missing or unreadable, using the error texture") }
            tex = TexFile.errorTexture
        }
        if tex.flags.contains(.video) { note("texture \(name): video not handled"); tex = TexFile.errorTexture }
        if tex.flags.contains(.volume) { note("texture \(name): volume texture not handled"); tex = TexFile.errorTexture }
        guard let mips = tex.images.first, let mip0 = mips.first else { throw GPUError.failed("texture \(name) has no image") }
        let format = Self.pixelFormat(tex.pixelFormat)
        let gpu = try device.makeTexture(GPUTextureDescriptor(format: format, width: max(mip0.width, 1), height: max(mip0.height, 1),
                                                              mipLevels: mips.count, label: name))
        for (level, mip) in mips.enumerated() {
            let w = max(mip.width, 1), h = max(mip.height, 1)
            let bpr = format.bytesPerRow(width: w), bpi = format.bytesPerImage(width: w, height: h)
            guard mip.data.count >= bpi else { continue }
            try mip.data.withUnsafeBytes { raw in
                try gpu.replace(level: level, x: 0, y: 0, width: w, height: h, depth: 1, bytes: raw, bytesPerRow: bpr, bytesPerImage: bpi)
            }
        }
        let s = try sampler(.engine(point: tex.flags.contains(.noInterpolation), clamp: tex.flags.contains(.clampUVs),
                                    mipmapped: mips.count > 1, anisotropic: true))
        let loaded = LoadedTexture(texture: gpu, sampler: s, tex: tex)
        textureCache[name] = loaded
        return loaded
    }

    /// ShaderLibrary.program: PhotonCore builds the HLSL, glslang makes SPIR-V, the backend takes it as is.
    func program(_ request: ShaderBuilder.Request) throws -> Program {
        let built = try builder.build(request)
        let key = SPIRVCompiler.hash(built.vertex.hlsl + "\u{1}" + built.fragment.hlsl)
        if let p = programCache[key] { return p }
        if built.geometry != nil { note("\(request.shader): geometry stage not handled by the prototype") }
        let vs = try compiler.compile(hlsl: built.vertex.hlsl, stage: .vertex)
        let ps = try compiler.compile(hlsl: built.fragment.hlsl, stage: .fragment)
        let p = Program(vertex: try device.makeShaderModule(stage: .vertex, spirv: vs, entryPoint: "main", label: request.shader + ".vert"),
                        fragment: try device.makeShaderModule(stage: .fragment, spirv: ps, entryPoint: "main", label: request.shader + ".frag"),
                        info: built.info)
        programCache[key] = p
        return p
    }

    func pipeline(_ program: Program, blend: GPUBlendDescriptor, format: GPUPixelFormat) throws -> GPURenderPipeline {
        if let p = program.pipelines[blend] { return p }
        var d = GPURenderPipelineDescriptor(vertex: program.vertex, fragment: program.fragment, vertexLayout: .quad, colorFormat: format)
        d.blend = blend
        let p = try device.makeRenderPipeline(d)
        program.pipelines[blend] = p
        return p
    }

    // MARK: Render (SceneRenderer.render(into:) main pass, ortho, no post)

    /// `Renderer_SetupProjection` ortho branch with fit = cover and alignment position 0.5, then the general zoom.
    func projection(sw: Float, sh: Float) -> Mat4 {
        let W = orthoSize.x, H = orthoSize.y
        var cl: Float = 0, cr: Float = 0, cb: Float = 0, ct: Float = 0
        let sceneA = W / H, screenA = sw / sh, ap: Float = 0.5
        if sceneA > screenA { let e = (W - (H / sh) * sw) * 0.5; cl = 2 * (1 - ap) * e; cr = 2 * ap * e }
        else { let e = (H - (W / sw) * sh) * 0.5; cb = 2 * (1 - ap) * e; ct = 2 * ap * e }
        let P = Mat4.orthoLH(l: cl, r: W - cr, b: cb, t: H - ct, zn: -2000, zf: 2000)
        let zoom = jsonFloats(general["zoom"]).first ?? 1
        guard zoom != 1 else { return P }
        let c = SIMD3<Float>(W * 0.5, H * 0.5, 0)
        return P * Mat4.translate(c) * Mat4.scale(SIMD3(zoom, zoom, 1)) * Mat4.translate(-c)
    }

    /// Built-ins for one draw (FrameState.builtins), with the stale render-context fields at their initial zeros.
    func builtins(model: Mat4, proj: Mat4, color: SIMD3<Float>, alpha: Float) -> [String: ProtoUniform] {
        let view = Mat4.identity // ortho scene without camera paths: the JSON camera is ignored (docs/re/04 §2.2)
        let mvp = proj * view * model, vp = proj * view
        let w = Float(options.width), h = Float(options.height), t = options.time
        let eye = SIMD3<Float>(orthoSize.x * 0.5, orthoSize.y * 0.5, 2000)
        let zero16 = [Float](repeating: 0, count: 16), zero32 = [Float](repeating: 0, count: 32), zero64 = [Float](repeating: 0, count: 64)
        let ambient = EngineValue.vec3(general["ambientcolor"], default: SIMD3(0.2, 0.2, 0.2))
        let sky = EngineValue.vec3(general["skylightcolor"], default: SIMD3(0.3, 0.3, 0.3))
        var u: [String: ProtoUniform] = [
            "g_ModelViewProjectionMatrix": .matrix(mvp), "g_ModelViewProjectionMatrixInverse": .matrix(mvp.inverse),
            "g_ModelMatrix": .matrix(model), "g_ModelMatrixInverse": .matrix(model.inverse),
            "g_NormalModelMatrix": .matrix3(model), "g_ViewProjectionMatrix": .matrix(vp),
            "g_LayerModelMatrix": .matrix(model), "g_EffectModelMatrix": .matrix(model),
            "g_EffectModelViewProjectionMatrix": .matrix(mvp), "g_EffectModelViewProjectionMatrixInverse": .matrix(mvp.inverse),
            "g_EffectTextureProjectionMatrix": .matrix(mvp), "g_EffectTextureProjectionMatrixInverse": .matrix(mvp.inverse),
            "g_Time": .floats([t]), "g_Frametime": .floats([1 / 30]), "g_Daytime": .floats([0.5]),
            "g_Color": .floats([color.x, color.y, color.z]), "g_Alpha": .floats([alpha]),
            "g_Color4": .floats([color.x, color.y, color.z, alpha]),
            "g_Screen": .floats([w, h, w / h]), "g_TexelSize": .floats([1 / w, 1 / h]), "g_TexelSizeHalf": .floats([0.5 / w, 0.5 / h]),
            "g_TextureReductionScale": .floats([1]), "g_HDRParams": .floats([1, 1]),
            "g_PointerPosition": .floats([0.5, 0.5]), "g_PointerPositionLast": .floats([0.5, 0.5]), "g_PointerState": .floats([0, 0, 0, 0]),
            "g_ParallaxPosition": .floats([0.5, 0.5]), "g_EyePosition": .floats([eye.x, eye.y, eye.z]),
            "g_AudioSpectrum16Left": .floats(zero16), "g_AudioSpectrum16Right": .floats(zero16),
            "g_AudioSpectrum32Left": .floats(zero32), "g_AudioSpectrum32Right": .floats(zero32),
            "g_AudioSpectrum64Left": .floats(zero64), "g_AudioSpectrum64Right": .floats(zero64),
            "g_AltModelMatrix": .matrix(.identity), "g_AltNormalModelMatrix": .matrix3(.identity), "g_AltViewProjectionMatrix": .matrix(.identity),
            "g_LightAmbientColor": .floats([ambient.x, ambient.y, ambient.z]), "g_LightSkylightColor": .floats([sky.x, sky.y, sky.z]),
        ]
        for name in ["g_OrientationForward", "g_OrientationRight", "g_OrientationUp"] { u[name] = .floats([0, 0, 0]) }
        for i in 0..<5 { u["g_RenderVar\(i)"] = .floats([0, 0, 0, 0]) }
        for i in 0..<10 { u["g_Texture\(i)Rotation"] = .floats([0, 0, 0, 0]); u["g_Texture\(i)Translation"] = .floats([0, 0]) }
        return u
    }

    /// Renders one frame into a new rgba8 target the size of the output and returns its RGBA8 bytes.
    public func render() throws -> [UInt8] {
        let W = options.width, H = options.height
        let target = try device.makeTexture(.renderTarget(hdr ? .rgba16Float : .rgba8Unorm, W, H, label: "_rt_SceneMain"))
        let proj = projection(sw: Float(W), sh: Float(H))
        let cmd = try device.makeCommandBuffer()
        var pass = GPURenderPassDescriptor(color: target)
        if clearEnabled {
            pass.colorLoad = .clear
            pass.clearColor = GPUClearColor(red: Double(clearColor.x), green: Double(clearColor.y), blue: Double(clearColor.z), alpha: 1)
        }
        let enc = try cmd.beginRenderPass(pass)
        let indices: [UInt32] = [0, 2, 1, 1, 2, 3]
        for layer in layers {
            let blend = D3D11Conventions.blend(mode: layer.blendMode)
            enc.setPipeline(try pipeline(layer.program, blend: blend, format: target.format))
            enc.setFrontFace(D3D11Conventions.frontFace)
            enc.setCullMode(layer.cullNone ? .none : .back)
            var all = builtins(model: layer.world, proj: proj, color: layer.color, alpha: layer.alpha)
            for (k, v) in layer.materialUniforms where all[k] == nil { all[k] = v }
            for slot in 0..<10 {
                guard let t = layer.textures[slot] else {
                    if all["g_Texture\(slot)Texel"] == nil { all["g_Texture\(slot)Texel"] = .floats([0.5, 0.5, 2, 2]) }
                    if all["g_Texture\(slot)MipMapInfo"] == nil { all["g_Texture\(slot)MipMapInfo"] = .floats([1]) }
                    continue
                }
                let r = t.resolution
                all["g_Texture\(slot)Resolution"] = .floats([r.x, r.y, r.z, r.w])
                all["g_Texture\(slot)Texel"] = .floats([1 / r.x, 1 / r.y, r.x, r.y])
                all["g_Texture\(slot)MipMapInfo"] = .floats([t.mipInfo])
            }
            for (module, stage) in [(layer.program.vertex, GPUShaderStage.vertex), (layer.program.fragment, .fragment)] {
                for block in module.reflection.uniformBlocks {
                    let bytes = UniformPacker.pack(block, all)
                    bytes.withUnsafeBytes { enc.setUniformBytes($0, stage: stage, register: block.binding - HLSLRegisterMap.uniformBase(stage)) }
                }
            }
            for slot in 0..<10 {
                enc.setTexture(layer.textures[slot]?.texture, slot: slot)
                enc.setSampler(layer.textures[slot]?.sampler, slot: slot)
            }
            layer.vertices.withUnsafeBytes { enc.setVertexBytes($0) }
            indices.withUnsafeBytes { enc.drawIndexed(indices: $0, type: .uint32, indexCount: 6, instanceCount: 1) }
        }
        enc.end()
        let readback = try device.makeBuffer(length: W * H * (hdr ? 8 : 4))
        cmd.copyTextureToBuffer(target, level: 0, buffer: readback)
        cmd.commit()
        cmd.waitUntilCompleted()
        let p = readback.contents.bindMemory(to: UInt8.self, capacity: W * H * 4)
        return Array(UnsafeBufferPointer(start: p, count: W * H * 4))
    }

    public var layerCount: Int { layers.count }
}
