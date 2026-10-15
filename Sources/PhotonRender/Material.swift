import Foundation
import Metal
import PhotonCore
import simd

/// A uniform value as written into a constant buffer.
public enum UniformValue {
    case floats([Float])
    /// Column-vector matrix P (clip = P * v). The engine uses row-vector matrices M = Pᵀ with HLSL
    /// column_major packing, so the buffer holds Pᵀ column by column, i.e. P row by row.
    case matrix(simd_float4x4)
    case matrix3(simd_float3x3)
    /// `g_Bones`: mat4x3 array (docs/re/06 §3.5); column-vector skin matrices.
    case bones([simd_float4x4])
    /// Unsigned integer arrays (`g_MorphOffsets`), written as raw 32-bit values.
    case uints([UInt32])
}

/// A material instance: one pass of `materials/*.json`, after merging any override (docs/re/03 §1).
public final class Material {
    public enum Blending: String { case normal, translucent, additive, alphatocoverage }

    public let path: String
    public var blending: Blending = .normal
    public var alphaWriting = "default"
    public var depthTest = true
    public var depthWrite = true
    public var cullNone = false
    public var shaderName: String
    public var combos: [String: Int] = [:]
    /// Texture slot → loaded texture. Render targets are bound into slots at draw time.
    public var textures: [Int: BoundTexture] = [:]
    public var textureNames: [Int: String] = [:]
    /// Material key → raw JSON value (constantshadervalues + annotation defaults).
    public var constants: [String: Any] = [:]
    public private(set) var program: ShaderProgram?
    /// Samples `_rt_FullFrameBuffer` (material flag 2).
    public var readsFrameBuffer = false
    /// Samples `_rt_MipMappedFrameBuffer` (material flag 8, table 0x140002170).
    public var readsMipMappedFrameBuffer = false
    /// Material flag 1 (`+0x1fc & 1`, table 0x140002170): a slot the program declares holds `_rt_Reflection`.
    public var samplesReflection = false
    /// `material+0x2b0/+0x2b2` with `+0x1f8 & 4`: the reference size of a bound user texture; autosize image layers take
    /// their size from it (`Image_OnTextureChanged` 0x140209360).
    public var userTextureSize: SIMD2<Int>?
    /// `usershadervalues`: user property name → material constant key (MaterialPass_Parse step 9).
    var userShaderValues: [String: Any] = [:]
    /// Material `+0x1fc` lighting bits (docs/re/06 §2.1.1): 0x10 when the program was built with LIGHTING ≠ 0
    /// (`ShaderProgram_Create` 0x1400d5a4d), 0x08 when a declared texture is `_rt_MipMappedFrameBuffer`.
    public var litFlags: Int { ((program?.combos["LIGHTING"] ?? 0) != 0 ? 0x10 : 0) | (readsMipMappedFrameBuffer ? 8 : 0) }

    init(path: String, json: [String: Any], scene: SceneResources) {
        self.path = path
        // Enum setters: unknown strings become table[0]; note depthtest/depthwrite table[0] is "disabled".
        blending = Blending(rawValue: (json["blending"] as? String) ?? "normal") ?? .normal
        alphaWriting = (json["alphawriting"] as? String) ?? "default"
        if let d = json["depthtest"] { depthTest = (d as? String) == "enabled" }
        if let d = json["depthwrite"] { depthWrite = (d as? String) == "enabled" }
        cullNone = (json["cullmode"] as? String) == "nocull"
        for (k, v) in (json["combos"] as? [String: Any]) ?? [:] {
            combos[k.uppercased()] = (unwrapUserValue(v) as? NSNumber)?.intValue ?? 0
        }
        constants = (json["constantshadervalues"] as? [String: Any]) ?? [:]
        shaderName = (json["shader"] as? String) ?? "error"

        if let list = json["textures"] as? [Any] {
            for (i, t) in list.prefix(10).enumerated() {
                guard let name = t as? String, !name.isEmpty else { continue }
                textureNames[i] = name
            }
        }
        // `usertextures` (MaterialPass_Parse 0x140154480 step 4) and the binding in `Material_ParseTextures` 0x1401556e0
        // (0x140155820–0x140155e41): an entry is a property name or {name, type ("system" 1, "usershortcut" 2, else 0),
        // keepaspect}. A slot that has a `textures` name binds the user texture when the property value is a non-empty
        // string and, for type 0, the VFS can open it. The reference size is `usertexturereference {width, height}` when
        // both are non-zero, else the slot texture's header size (TEXS sheet size for sprite sheets); without one the
        // slot keeps its own texture. The texture is cached as `[usershortcut_]<value>x<round(10·refW/refH)>`, created
        // with sampler flags 8 | 2 (default clamps, or usershortcut) | 1 (default point), no anisotropy, and centre-
        // cropped to refW/refH unless `keepaspect` (then the reference size becomes the image size). A texture that fails
        // to load leaves the slot texture. material+0x2b0/+0x2b2 = reference size, +0x1f8 |= 4 (autosize reads both).
        if let list = json["usertextures"] as? [Any] {
            userTextureReference = (json["usertexturereference"] as? [String: Any]).map {
                SIMD2(($0["width"] as? NSNumber)?.intValue ?? 0, ($0["height"] as? NSNumber)?.intValue ?? 0)
            }
            for (i, u) in list.prefix(10).enumerated() {
                var name: String?, type = 0, keepAspect = false
                if let s = u as? String { name = s } else if let o = u as? [String: Any] {
                    name = o["name"] as? String
                    switch o["type"] as? String { case "system": type = 1; case "usershortcut": type = 2; default: type = 0 }
                    keepAspect = jsonBool(o["keepaspect"], default: false)
                }
                guard let name, let def = textureNames[i] else { continue }
                // Every entry registers a listener for its property (0x140154b1b → binding manager 0x140175880); a later
                // value change rebinds the slot (callback 0x1401538d0, `userPropertyChanged`).
                let b = UserTextureBinding(slot: i, name: name, type: type, keepAspect: keepAspect, defaultName: def)
                userTextureBindings.append(b)
                let value = scene.userTextures[name] ?? (UserProperties.current[name] as? String) ?? ""
                bindUserTexture(b, value: value, scene: scene)
            }
            if !userTextureBindings.isEmpty { scene.userTextureMaterials.append(WeakMaterial(self)) }
        }
        if blending == .alphatocoverage { combos["ALPHATOCOVERAGE"] = 1 }
        if blending == .additive { combos["ADDITIVE"] = 1 }
        userShaderValues = (json["usershadervalues"] as? [String: Any]) ?? [:]
        resolve(scene: scene)
    }

    /// Loads textures, compiles the program, fills defaults (Material_Load step 7, MaterialPass_Parse 7–8).
    func resolve(scene: SceneResources) {
        let info = scene.shaders.sources.info(shader: shaderName)
        // Bound-texture combos (MASK, …) see only the textures the material sets: the program is created in
        // MaterialPass_Parse before Material_Load fills empty slots with shader defaults (docs/re/03 §1).
        let explicitSlots = Set(textureNames.keys)
        // Material_Load step 7 (0x140151ac2–0x140151b87): an empty declared slot loads the shader's default texture,
        // or "error" when the sampler has none.
        for (slot, s) in info.samplers where textureNames[slot] == nil {
            textureNames[slot] = s.defaultTexture.flatMap { $0.isEmpty ? nil : $0 } ?? "error"
        }
        var bound: [Int: Int32] = [:]
        var formats: [Int: Int32] = [:]
        var flags: [Int: Int32] = [:]
        defer {
            let request = ShaderBuilder.Request(shader: shaderName, combos: combos, boundTextures: bound.filter { explicitSlots.contains($0.key) },
                                                textureFlags: flags, formatTextures: formats, sceneCombos: scene.sceneCombos,
                                                lightConfig: scene.lightConfig, fogFlags: scene.fogFlags,
                                                shadowQuality: scene.shadowQuality)
            program = scene.shaders.program(request)
            // Flags come from the textures of the slots the compiled program declares (step 7, 0x140151ac2).
            readsMipMappedFrameBuffer = textureNames.contains { $0.value == "_rt_MipMappedFrameBuffer" && program?.textureSlots.contains($0.key) == true }
            samplesReflection = textureNames.contains { $0.value == "_rt_Reflection" && program?.textureSlots.contains($0.key) == true }
            for (_, v) in info.values where constants[v.materialKey] == nil {
                constants[v.materialKey] = v.components == 1 ? (Double(v.defaultValue) ?? 0) as Any : v.defaultValue as Any
            }
            // MaterialPass_Parse step 9 (0x140154fd0–0x14015525b), after the shader defaults: for each member
            // `property: key`, constantshadervalues[key] = {"value": current value (its own "value" if it is an object),
            // "user": property}, so the constant follows the user property like any bound value (docs/re/03 §1).
            for (property, keyValue) in userShaderValues {
                guard let key = jsonAsString(keyValue) else { continue }
                var current: Any = constants[key] ?? NSNull()
                if let o = current as? [String: Any], let v = o["value"] { current = v }
                constants[key] = ["value": current, "user": property]
            }
        }
        for (slot, name) in textureNames {
            if name == "_rt_FullFrameBuffer" { readsFrameBuffer = true }
            // Render-target names and the alias set (`_alias_lightCookie`, 0x140002050) are placeholders resolved when
            // drawing (docs/re/03 §1.2); the slot still holds a texture object for the bound-texture combos.
            if name.hasPrefix("_rt_") || name.hasPrefix("_alias_") {
                bound[slot] = 0
                continue
            }
            // A missing or undecodable file is the error texture, not an empty slot (docs/re/03 §1.2).
            let gpu = scene.textures.textureOrError(named: name)
            textures[slot] = BoundTexture(gpu: gpu)
            bound[slot] = gpu.tex.rawFormat
            formats[slot] = gpu.tex.rawFormat // TEXnFORMAT: the raw TEXI code (texture +0x18), also from the default texture
            flags[slot] = gpu.tex.flags.rawValue
        }
    }

    struct UserTextureBinding { let slot: Int; let name: String; let type: Int; let keepAspect: Bool; let defaultName: String }
    var userTextureBindings: [UserTextureBinding] = []
    private var userTextureReference: SIMD2<Int>?

    /// One `usertextures` slot (Material_ParseTextures 0x1401556e0, 0x140155820–0x140155e41). Returns false when the slot
    /// keeps its texture (empty value, unopenable file, no reference size, failed load).
    @discardableResult
    func bindUserTexture(_ b: UserTextureBinding, value: String, scene: SceneResources) -> Bool {
        let i = b.slot, def = b.defaultName, type = b.type, keepAspect = b.keepAspect
        guard !value.isEmpty else { return false }
        // Type 0 values must open through the VFS (fs vt+0x60). `system` (1) values name an image of the scene's media
        // session (UserTexture ctor branch 0x1400ebbec: C+0x1848 = binding manager +0x140; its current image when the
        // name equals the session's current texture name, else its previous one; no session or an empty image fails).
        // usershortcut (2) values name a shortcut whose icon the host supplies (`TextureLoader.shortcutIcon`: the Finder icon
        // of an existing file/cmd target on macOS); no icon fails like the engine's pending request.
        let system = type == 1 ? scene.systemImage?(value) : nil
        let shortcut = type == 2 ? TextureLoader.shortcutIcon(value) : nil
        if type == 0 {
            guard value.hasPrefix("/") ? FileManager.default.fileExists(atPath: value) : scene.fs.read(value) != nil else { return false }
        } else if (type == 1 && system == nil) || (type == 2 && shortcut == nil) || type > 2 {
            return false
        }
        let header = scene.fs.read(AssetFileSystem.texturePath(def)).flatMap { try? TexFile(data: $0) }
        var ref = userTextureReference ?? SIMD2<Int>(0, 0)
        if ref.x == 0 || ref.y == 0, let h = header {
            ref = h.flags.contains(.spriteSheet) ? SIMD2(h.sheetWidth, h.sheetHeight) : SIMD2(h.imageWidth, h.imageHeight)
        }
        guard ref.x != 0, ref.y != 0 else { return false }
        var flags: TexFile.Flags = []
        if let h = header {
            if h.flags.contains(.clampUVs) { flags.insert(.clampUVs) }
            if h.flags.contains(.noInterpolation) { flags.insert(.noInterpolation) }
        }
        if type == 2 { flags.insert(.clampUVs) } // sampler flag 2 for usershortcut (0x140155ad1)
        let aspect = Float(ref.x) / Float(ref.y)
        let key = (type == 2 ? "usershortcut_" : "") + value + "x" + String(Int((aspect * 10).rounded()))
        if type == 0, TextureLoader.isVideoFile(value) {
            // Videos go to the player. keepaspect (the videoplayer scene's `videotex`) shows the whole frame under the file
            // name; otherwise the player crops to the reference aspect (`videoUserTexture`, cached under the engine key).
            scene.textures.userTextureFlags[value] = flags
            if keepAspect {
                textureNames[i] = value
            } else {
                guard scene.textures.videoUserTexture(key: key, path: value, aspect: aspect, flags: flags) != nil else { return false }
                textureNames[i] = key
            }
            userTextureSize = keepAspect ? nil : ref // keepaspect: the video's own size, read from the texture
            return true
        }
        // The key ignores keepaspect: a texture already registered under it is reused as is (TextureMgr_Load with
        // create = 0 at 0x140155be3), and then the reference size stays (the keepaspect size write at
        // 0x140155db5 is only on the create path).
        let cached = scene.textures.cachedTexture(key)
        var made: GPUTexture?
        if cached == nil {
            if let img = system {
                made = TexFile.systemUserImage(img.pixels, width: img.width, height: img.height, aspect: keepAspect ? 0 : aspect, flags: flags)
                    .flatMap { scene.textures.registerUserTexture(key: key, tex: $0, flags: flags) }
            } else if let icon = shortcut {
                let (px, w, h) = TexFile.letterbox(icon.pixels, width: icon.width, height: icon.height, aspect: keepAspect ? 0 : aspect)
                made = scene.textures.registerUserTexture(key: key, tex: TexFile.userRGBA(px, width: w, height: h, flags: flags), flags: flags)
            } else if (value as NSString).pathExtension.lowercased() == "gif" {
                made = scene.textures.userGIFTexture(key: key, path: value, aspect: keepAspect ? 0 : aspect, flags: flags)
            } else {
                made = scene.textures.userImageTexture(key: key, path: value, aspect: keepAspect ? 0 : aspect, flags: flags)
            }
        }
        guard let gpu = cached ?? made else { return false }
        textureNames[i] = key
        userTextureSize = keepAspect && cached == nil ? SIMD2(gpu.tex.imageWidth, gpu.tex.imageHeight) : ref
        return true
    }

    /// The listener callback 0x1401538d0: a changed value of a bound user property rebinds the slot and swaps its
    /// texture in place (the program keeps its combos).
    public func userPropertyChanged(_ property: String, value: String, scene: SceneResources) {
        for b in userTextureBindings where b.name == property {
            guard bindUserTexture(b, value: value, scene: scene), let name = textureNames[b.slot] else { continue }
            textures[b.slot] = BoundTexture(gpu: scene.textures.textureOrError(named: name))
        }
    }

    /// Value uniforms declared by the shader, as name → value (material keys resolved).
    func materialUniforms() -> [String: UniformValue] {
        guard let info = program?.info else { return [:] }
        var out: [String: UniformValue] = [:]
        for (name, v) in info.values {
            var f = jsonFloats(constants[v.materialKey])
            // Loader rules (docs/re/04 §0): a number into a vec2 sets x = y; vec3/vec4 accept strings only.
            if f.count == 1 && v.components == 2 { f = [f[0], f[0]] }
            if f.count == 1 && v.components > 2 { f = [] }
            if f.isEmpty { f = jsonFloats(v.defaultValue) }
            while f.count < v.components { f.append(0) }
            out[name] = .floats(Array(f.prefix(v.components)))
        }
        return out
    }

    public var blendMode: BlendState.Mode {
        switch blending {
        case .normal: return .normal
        case .translucent: return .translucent
        case .additive: return .additive
        case .alphatocoverage: return .alphaToCoverage
        }
    }
}

struct WeakMaterial { weak var material: Material?; init(_ m: Material) { material = m } }

/// Per-scene shared loaders.
public final class SceneResources {
    /// `createModelData` registry (scene map S+0x1bf8…0x1c38, keyed by token); a layer's `"model": <token>` uses it
    /// (`Model_Load` 0x14021ae58–0x14021aeb1).
    var modelData: [Int: MdlFile] = [:]
    var nextModelToken = 1
    public let device: MTLDevice
    public let fs: AssetFileSystem
    public let textures: TextureLoader
    public let shaders: ShaderLibrary
    public let targets: RenderTargetManager
    private var materialFiles: [String: [String: Any]] = [:]
    /// User-property values for material `usertextures` (e.g. `videotex` → the video file of a video wallpaper).
    public var userTextures: [String: String] = [:]
    /// `system` user-texture images (the media session's current/previous thumbnail, straight RGBA) by value name.
    public var systemImage: ((String) -> (pixels: Data, width: Int, height: Int)?)?
    /// Materials with `usertextures` slots (listeners for user-property changes).
    var userTextureMaterials: [WeakMaterial] = []
    /// Renderer HDR flag (`R+0x128 & 0x2000`, see SceneRenderer.hdr): layer composites and `*_backbuffer`
    /// effect FBOs use fp16 formats when it is set.
    public var hdr = false
    /// scene.json `version` (scene load 0x140187337 → +0x46c; getter 0x1401853b0 = S+0x1510 vt+0x40), 0 when absent.
    public var sceneVersion = 0
    /// `Image_ComposeMaterialPath` 0x1401ecae0: `effectpassthrough_4.json` (genericimage4) when the scene version is
    /// ≥ 3, else `effectpassthrough.json` (genericimage3).
    public var composeMaterialPath: String {
        sceneVersion >= 3 ? "materials/util/effectpassthrough_4.json" : "materials/util/effectpassthrough.json"
    }
    /// Ortho scene (`C+0x118 & 0x400`, set at scene load 0x14018768a): every program gets `SCENE_ORTHO=1`.
    public var sceneOrtho = false
    /// `C+0x1218` (1 or 2), see `SceneRenderer.textureReduction`.
    public var textureReduction = 1
    /// Packed `general.lightconfig` (`C+0x121c`); lit programs take their `LIGHTS_*` counts from it.
    public var lightConfig: UInt32 = 0
    /// `C+0x1ac` (app setting `shadows`), for `LIGHTS_SHADOW_MAPPING_QUALITY`.
    public var shadowQuality: Int = 0
    /// Scene fog flags (bit 0 `fogdistance`, bit 1 `fogheight`), docs/re/06 §6.5.
    public var fogFlags = 0
    /// Scene-level combos added to every program by `sub_1401a5c40`.
    var sceneCombos: [String: Int] {
        var c: [String: Int] = [:]
        if sceneOrtho { c["SCENE_ORTHO"] = 1 }
        if hdr { c["HDR"] = 1 }
        // `REVERSEDEPTH` (C+0x118 & 0x1000, sub_1401a5c40 0x1401a67b6). Inferred set on the D3D11 path: the projection
        // is reverse-Z (0x14009a360 with near/far swapped), depth compares GREATER against a 0 clear, and the
        // volumetrics shaders only produce output with it (docs/re/06 §6.5a).
        c["REVERSEDEPTH"] = 1
        return c
    }
    /// Host audio controls for this scene's sound objects. Only one scene per wallpaper should play sound.
    public var soundEnabled = true
    public var volume: Float = 1
    public var soundPaused = false
    /// C+0x154 = rate · pause fade (W+0x190 · W+0x170, 0x1401114dc), the divisor of the sound countdown (docs/re/09 §3).
    public var timeScale: Float = 1

    public init(device: MTLDevice, fs: AssetFileSystem) {
        self.device = device
        self.fs = fs
        textures = TextureLoader(device: device, fs: fs)
        shaders = ShaderLibrary(device: device, fs: fs)
        targets = RenderTargetManager(device: device)
    }

    /// `MaterialMgr_CreateInstance`: only `passes[0]` is used; the override merges into it.
    public func material(_ path: String, override: Any? = nil) -> Material {
        var root: [String: Any]
        if let cached = materialFiles[path] {
            root = cached
        } else {
            let doc = fs.readJSON(path) as? [String: Any] ?? [:]
            if let passes = doc["passes"] as? [[String: Any]], let first = passes.first { root = first } else { root = doc }
            if fs.read(path) == nil { NSLog("photon: Material %@ missing", path) }
            materialFiles[path] = root
        }
        if override is [String: Any], let merged = jsonMerge(root, override) as? [String: Any] { root = merged }
        return Material(path: path, json: root, scene: self)
    }
}
