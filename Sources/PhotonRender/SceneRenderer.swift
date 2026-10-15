import AppKit
import Foundation
import Metal
import PhotonCore
import simd

/// Loads a scene wallpaper and renders frames (docs/re/04).
public final class SceneRenderer {
    public enum Fit: Int { case cover = 0, contain = 1, stretch = 2, center = 3, free = 4 }

    public let resources: SceneResources
    let frame = FrameState()
    var objects: [SceneObject] = []
    var general: [String: Any] = [:]
    public private(set) var orthoSize = SIMD2<Float>(1920, 1080)
    public private(set) var isOrtho = true
    var clearColor = SIMD3<Float>(0, 0, 0)
    /// `clearenabled` (S+0xe0 bit 5, default true): `0x140183550` clears colour and depth only when it is set.
    var clearEnabled = true
    var cameraParallax = false, cameraShake = false
    var parallaxAmount: Float = 0.5, parallaxDelay: Float = 0.1, parallaxMouseInfluence: Float = 0.5
    var shakeSpeed: Float = 3, shakeAmplitude: Float = 0.5, shakeRoughness: Float = 1
    var parallaxP = SIMD2<Float>(0, 0)
    var cameraEye = SIMD3<Float>(0, 0, 0), cameraCenter = SIMD3<Float>(0, 0, -1), cameraUp = SIMD3<Float>(0, 1, 0)
    /// The spot light whose cookie is bound as `_alias_lightCookie` this frame.
    var lightCookieLight: LightObject?
    /// The scene's render-context fields that persist across draws and frames (g_RenderVar*, g_Orientation*, sprite uniforms).
    let builtinState = StaleBuiltins()
    /// Base camera zoom S+0x13c (1.0), used when no camera object is active. `setCameraTransforms` writes it.
    var cameraZoom: Float = 1
    /// `camera.paths` (CameraPath.swift); S+0x114 takes the path zoom while they play.
    var cameraPaths: SceneCameraPaths?
    var pathZoom: Float?
    /// C+0x144 frame counter (sound spatialisation treats frame 0 specially).
    var renderedFrames = 0
    /// `materials/util/fade.json` (R+0x3180), loaded when `camerafade` and paths exist (0x140181bb5).
    var fadeMaterial: Material?
    public var fit = Fit.cover
    /// The wallpaper's general alignment properties (`0x140181f30`: `alignmentx/y/z` and `alignmentposition` are the UI
    /// slider value · 0.01 → R+0x31bc/0x31c0/0x31c4/0x31c8; `alignmentfliph` → R+0x128 bit 0x800; docs/re/09 §5).
    public var alignmentX: Float = 0.5, alignmentY: Float = 0.5, alignmentZ: Float = 1
    public var flipHorizontal = false
    /// General `schemecolor` ("r g b" → R+0x31b0..0x31b8). Renderer_Frame 0x14017fc4c clears with it instead of the scene
    /// `clearcolor` when the fit mode is not 0 (cover) or 2 (stretch), i.e. when the projection can leave bars.
    public var barColor = SIMD3<Float>(0, 0, 0)
    var frameClearColor: SIMD3<Float> { (fit == .cover || fit == .stretch) ? clearColor : barColor }
    /// General `cameraparallax` (default true): Wallpaper_ApplySettings 0x140115458 sets or clears R+0x128 bit 0x200.
    /// Off disables the scene's own parallax (Inferred: the bit's reader is not traced).
    public var userParallax = true

    /// The wallpaper's general (UI-injected) properties, `{ name: value }` with UI slider units (docs/re/09 §5):
    /// `0x140181f30` reads `alignment` (int) → fit, `alignmentposition`/`alignmentx`/`alignmenty`/`alignmentz` · 0.01,
    /// `alignmentfliph`, `schemecolor` ("r g b" → bar colour); 0x140115458 reads `cameraparallax`.
    public func applyGeneralProperties(_ p: [String: Any]) {
        func num(_ k: String) -> Float? { (p[k] as? NSNumber)?.floatValue ?? (p[k] as? String).flatMap(Float.init) }
        if let a = num("alignment"), let f = Fit(rawValue: Int(a)) { fit = f }
        if let v = num("alignmentposition") { alignmentPosition = v * 0.01 }
        if let v = num("alignmentx") { alignmentX = v * 0.01 }
        if let v = num("alignmenty") { alignmentY = v * 0.01 }
        if let v = num("alignmentz") { alignmentZ = v * 0.01 }
        if let b = p["alignmentfliph"] { flipHorizontal = (b as? Bool) ?? ((b as? NSNumber)?.boolValue ?? false) }
        if let c = p["schemecolor"] as? String {
            let f = c.split(separator: " ").compactMap { Float($0) }
            barColor = SIMD3(f.count > 0 ? f[0] : 0, f.count > 1 ? f[1] : 0, f.count > 2 ? f[2] : 0)
        }
        if let b = p["cameraparallax"] { userParallax = (b as? Bool) ?? ((b as? NSNumber)?.boolValue ?? true) }
        colorCorrection.apply(p) // wec_* / wcc_* (ColorCorrection.swift, docs/re/09 §5.1)
    }
    /// The general colour options pass (R+0x3188, drawn last by Renderer_Frame 0x140180bd2).
    public let colorCorrection = ColorCorrection()
    /// `_rt_FullFrameBufferMultiSampled` (R+0x3100) for the main pass (Multisample.swift, docs/re/09 §8.1).
    let multisample = Multisample()
    /// Workshop item id (wallpaper directory name), keys SceneScript localStorage.
    var wallpaperID = ""
    /// SceneScript runtime (docs/re/08); nil when the scene has no scripts.
    var scripts: SceneScriptEngine?
    /// Animated effect constants (binding-manager animations on `constantshadervalues`, ScriptConstantAnimations.swift).
    var constantAnimations: ScriptConstantAnimations?
    /// Left mouse button state for SceneScript cursor hooks and `input.cursorLeftDown`; set by the host.
    public var pointerDown = false {
        didSet { frame.pointerDown = pointerDown }
    }
    private var nextScriptLayerID = 2_000_000

    /// Sound objects play only when enabled (off for offline rendering).
    public static var soundEnabled: Bool {
        get { SoundObject.playbackEnabled }
        set { SoundObject.playbackEnabled = newValue }
    }
    public var alignmentPosition: Float = 0.5

    var sceneTarget: RenderTarget!
    var fullFrameBuffer: RenderTarget!
    var mipFrameBuffer: RenderTarget?
    /// `_rt_Reflection` (0x140181c51): scene size, colour format 1 (RGBA8), no depth on the D3D path (0x16 + 4·(C+0x118 & 1)
    /// = 0x1a), clamp. Created at load when an object has `+0x120 & 8` (scene flag S+0xe0 bit 0, 0x14018b230).
    var reflectionTarget: RenderTarget?
    /// S+0x1c8: the objects the reflection pass draws (Scene_CreateObject 0x14019091b).
    var reflectionObjects: [SceneObject] = []
    /// The engine's `reflection` setting (Wallpaper_ApplySettings 0x14011559c → C+0x118 bit 0x80; default true,
    /// 0x140047427). `PHOTON_REFLECTION=0` turns it off.
    static let reflectionSetting = ProcessInfo.processInfo.environment["PHOTON_REFLECTION"] != "0"
    var depthTexture: MTLTexture?
    /// Scene volumetrics renderer (scene sub-object +0x50, docs/re/06 §6.5a).
    let volumetrics = Volumetrics()
    /// Shadow atlas and caster pass (docs/re/06 §6.5b), at the `shadows` quality.
    lazy var shadows = ShadowMaps(quality: volumetrics.shadowQuality)
    var mipFrameBufferNeedsClear = false
    /// LDR bloom (docs/re/04 §6): downsample_quarter_bloom → _rt_4FrameBuffer, downsample_eighth_blur_v →
    /// _rt_8FrameBuffer, blur_h_bloom → _rt_Bloom, then combine_ldr(FullFrameBuffer, Bloom).
    var bloom = true
    var bloomPasses: [(Material, RenderTarget)] = []
    var combine: Material?

    /// The user's `postprocessing` setting. The UI quality presets write "disabled" (low), "enabled"
    /// (medium/high) or "ultra"; the engine's own fallback when the key is missing is "disabled" (0x14004732b).
    /// Prescan 0x14010ed73: anything but "disabled" sets renderer flag 0x40, which gates the whole bloom/combine
    /// post pass (Renderer_Frame 0x140180a41). Override with PHOTON_POSTPROCESSING=disabled|enabled|ultra.
    /// `displayhdr` (Project_Prescan 0x14010e6c7) sets 0x4000 on top of the ultra HDR flag 0x2000.
    public enum PostProcessing: String { case disabled, enabled, ultra, displayhdr }
    /// The user's `fps` setting (frame-rate limit). `Wallpaper_ApplySettings` 0x1401154c0 stores it at W+0x18c (ctor
    /// default 20, 0x14010dc14; the config loader's default when the key is missing is 15, 0x1400474ac, the same as the
    /// UI's medium preset, which matches the other photon2 quality defaults). Every frame 0x1401114e5 copies it to
    /// C+0x148, where particles read it: operators run as two half-steps when it is 1...20 (0x140237754) and rope UVs
    /// clamp their spawn estimate with it (0x1402309b5). Override with PHOTON_FPS=<n>.
    public static var fpsSetting: Int = Int(ProcessInfo.processInfo.environment["PHOTON_FPS"] ?? "") ?? 15
    /// The user's `resolution` setting (`Wallpaper_ApplySettings` 0x1401155be–0x14011562c via `Wallpaper_SetFlags`
    /// 0x140115a90): "full" clears C+0x118 bits 0x30, "half" sets 0x20, any other string sets 0x10 (automatic); the config
    /// filler writes "full" when the key is missing (0x1400472cb). Override with PHOTON_RESOLUTION=full|half|auto.
    public static var resolutionSetting = ProcessInfo.processInfo.environment["PHOTON_RESOLUTION"] ?? "full"
    /// Screen size the automatic setting tests (C+0x74 × C+0x78 at scene load); nil = the main display.
    public static var resolutionScreenSize: SIMD2<Int>?
    /// `C+0x1218 = 1 + TextureReduction(C)` (scene load 0x140187e3c; `TextureReduction` 0x14017e6f0): 2 for "half", or
    /// for "auto" when the screen area is below 1969920 pixels; else 1. Drives TEXB mip dropping (`TexFile.loadReduction`),
    /// the layer composite size (`Image_GetCompositeInfo` 0x140209310) and `g_TextureReductionScale`.
    public static func textureReduction(setting: String, screen: SIMD2<Int>) -> Int {
        switch setting {
        case "full": return 1
        case "half": return 2
        default: return screen.x * screen.y < 1969920 ? 2 : 1
        }
    }
    public private(set) var textureReduction = 1
    public static var postProcessing = PostProcessing(rawValue: ProcessInfo.processInfo.environment["PHOTON_POSTPROCESSING"] ?? "") ?? .enabled
    /// Renderer flag 0x2000 (`R+0x128`). Project_Prescan 0x14010e612..0x14010e6ba sets it only when the scene
    /// JSON's general `bloom` and `hdr` are both JSON booleans that are true and postprocessing is "ultra"
    /// ("displayhdr" also sets 0x4000, which has no macOS equivalent here). A bound `{"user":…}` bloom fails the
    /// JSON-bool test, so those scenes never take the HDR path.
    public private(set) var hdr = false
    /// Renderer flag 0x4000 (display HDR): only with 0x2000 (`displayhdr` → `|= 0x6000`). The device keeps it only when
    /// DXGI reports an ST.2084 output (0x14012af44; otherwise params+0x15 is cleared at 0x14012b5e7). Final combine =
    /// combine_dhdr_upsample (`DISPLAYHDR=1`), Renderer_Frame init 0x14017fb49.
    public private(set) var displayHDR = false
    /// Display-HDR output: the host presents an extended-range linear (EDR) fp16 drawable. The engine's swap chain is
    /// R16G16B16A16_FLOAT whenever the HDR flag is set (0x14012b651–0x14012b668; R8G8B8A8_UNORM otherwise), i.e. scRGB.
    /// `edrHeadroom` is the display's EDR headroom (peak / SDR white), used for `D+0x44`.
    public var edrHeadroom: Float = 1
    /// True when the host should give this scene an fp16 extended-linear-sRGB drawable.
    public var wantsEDROutput: Bool { displayHDR }
    /// HDR bloom (0x140183610): mip chain `_rt_<2<<i>FrameBuffer`, materials hdr_downsample_bloom (R+0x3190),
    /// hdr_downsample (0x3198), hdr_upsample (0x31a0), hdr_upsample_cubic (0x31a8); combine_hdr_upsample (0x3150)
    /// and combine_srgb (0x3158).
    var hdrMips: [RenderTarget] = []
    var hdrDownBloom: Material?, hdrDown: Material?, hdrUp: Material?, hdrUpCubic: Material?, hdrCombineSRGB: Material?
    var hdrStrength: Float = 2, hdrScatter: Float = 1.619, hdrIterations = 8
    /// The engine presents the HDR path through a linear fp16 (scRGB) swap chain, so combine_hdr and
    /// passthroughsrgb write linear light. Our outputs are 8-bit non-sRGB, so those passes render into an sRGB
    /// view of this texture (encoding on store), which is then copied to the output unchanged.
    private var hdrOutput: MTLTexture?
    let screenQuad = Quad(size: SIMD2(2, 2), textureSize: SIMD2(1, 1), uvScale: SIMD2(1, 1), flags: .centered)
    private var effectCounter = 0
    private var lastTime: Double?
    private let queue: MTLCommandQueue
    /// Starts system-audio capture when the scene needs it (see `updateAudio`). photon-tool's offline
    /// render turns this off so it never triggers a permission prompt.
    public static var audioCaptureEnabled = true
    /// Offline renders: SceneScript `Date.now()` follows scene time (see SceneScriptEngine.simulatedClock).
    public static var simulatedScriptClock: Bool {
        get { SceneScriptEngine.simulatedClock }
        set { SceneScriptEngine.simulatedClock = newValue }
    }
    /// project.json general.supportsaudioprocessing.
    var supportsAudio = false
    let audioSmoother = AudioSpectrumSmoother()

    public enum LoadError: Error, CustomStringConvertible {
        case missingDependency(String)
        /// The project's `file` classifies (`Project_ClassifyFile` 0x14011e520) as something other than a scene or video.
        case unsupportedKind(ProjectKind, String)
        public var description: String {
            switch self {
            case .missingDependency(let d): return "preset for workshop item \(d), which isn't downloaded"
            case .unsupportedKind(let k, let f):
                switch k {
                case .web: return "web wallpaper (\(f)): runs in the engine's separate web host, not the scene renderer"
                case .application: return "application wallpaper (\(f)): a Windows executable"
                case .image: return "image file wallpaper (\(f))"
                default: return "unknown wallpaper type (file \"\(f)\")"
                }
            }
        }
    }

    /// `propertyOverrides` are the user's property values from the host UI, applied over the project
    /// defaults and any preset.
    public init(device: MTLDevice, wallpaperDirectory requestedDirectory: URL, engineAssets: URL,
                propertyOverrides: [String: Any] = [:]) throws {
        let fs = AssetFileSystem(engineAssets: engineAssets)
        var wallpaperDirectory = requestedDirectory
        var project = Self.readProject(wallpaperDirectory)
        var preset: [String: Any] = [:]
        // Presets: `dependency` names another workshop item; `preset` overrides its property values
        // (Project reader 0x140063cb0; dependency → <workshop>/<id>/ is inferred).
        if let dep = project["dependency"] as? String, project["file"] == nil {
            preset = (project["preset"] as? [String: Any]) ?? [:]
            wallpaperDirectory = requestedDirectory.deletingLastPathComponent().appendingPathComponent(dep)
            guard FileManager.default.fileExists(atPath: wallpaperDirectory.appendingPathComponent("project.json").path) else {
                throw LoadError.missingDependency(dep)
            }
            project = Self.readProject(wallpaperDirectory)
        }
        wallpaperID = wallpaperDirectory.lastPathComponent
        // The engine classifies the project by its `file` and ignores the `type` key (Project_Load 0x14011d7d0).
        let file = (project["file"] as? String) ?? ""
        let kind = ProjectKind.classify(file: file)
        guard kind == .scene || kind == .video else { throw LoadError.unsupportedKind(kind, file) }
        UserProperties.current = UserProperties.load(project: project)
            .merging(preset.filter { !($0.value is NSNull) }) { _, b in b }
            .merging(propertyOverrides) { _, b in b }
        supportsAudio = jsonBool((project["general"] as? [String: Any])?["supportsaudioprocessing"], default: false)
        // Project_Load (0x14011d7d0, ev_ddb96b88…): when the `file` isn't on disk, its extension is swapped to "pkg"
        // (string 0x140489cd8) and, if that file exists, it becomes the wallpaper file: `scene.json` → `scene.pkg`,
        // `gifscene.json` → `gifscene.pkg`. A loose file that exists wins over the package.
        let loose = wallpaperDirectory.appendingPathComponent(file)
        let pkg = loose.pathExtension.lowercased() == "pkg" ? loose : loose.deletingPathExtension().appendingPathExtension("pkg")
        let scenePath: String
        var videoFile: URL?
        var gifTexture: TexFile?
        if kind == .video {
            // Video wallpapers run the built-in scene with the file bound to user texture `videotex` (docs/re/01 §3.8).
            videoFile = wallpaperDirectory.appendingPathComponent(file)
            fs.addSearchDirectory(wallpaperDirectory)
            fs.addSearchDirectory(engineAssets.appendingPathComponent("scenes/videoplayer"))
            scenePath = "scenes/videoplayer/scene.json"
        } else if file.hasSuffix(".gif") {
            // GIF scenes (Project_Load 0x140114304–0x14011457f): the engine copies the file next to the template
            // `assets/scenes/gifs/gifscene.json` (one autosize, nopadding image; material `background` with SPRITESHEET)
            // and its resource compiler turns it into `materials/background.tex` with `background.tex-json`
            // (rgba8888, point, clamp, no mips, non-power-of-two). photon2 builds that sprite sheet in memory.
            fs.addSearchDirectory(engineAssets.appendingPathComponent("scenes/gifs"))
            scenePath = "scenes/gifs/gifscene.json"
            gifTexture = (try? Data(contentsOf: wallpaperDirectory.appendingPathComponent(file))).flatMap(TexFile.spriteSheet(gif:))
            if gifTexture == nil { throw PackageFile.Error.unreadable(wallpaperDirectory) }
        } else if !FileManager.default.fileExists(atPath: loose.path) && FileManager.default.fileExists(atPath: pkg.path) {
            scenePath = try fs.mountWallpaper(file: pkg)
        } else {
            scenePath = try fs.mountWallpaper(file: loose)
        }
        resources = SceneResources(device: device, fs: fs)
        let screen = Self.resolutionScreenSize ?? NSScreen.main.map {
            SIMD2(Int($0.frame.width * $0.backingScaleFactor), Int($0.frame.height * $0.backingScaleFactor))
        } ?? SIMD2(1920, 1080)
        textureReduction = Self.textureReduction(setting: Self.resolutionSetting, screen: screen)
        resources.textureReduction = textureReduction
        TexFile.loadReduction = textureReduction
        if let videoFile { resources.userTextures["videotex"] = videoFile.path }
        if let gifTexture { resources.textures.preloaded["background"] = gifTexture }
        queue = device.makeCommandQueue()!
        guard let scene = fs.readJSON(scenePath) as? [String: Any] else { throw PackageFile.Error.unreadable(wallpaperDirectory) }
        load(scene)
    }

    /// Host audio controls: whether this scene plays its sounds, the host volume (0–1) and pause.
    public func setSound(enabled: Bool, volume: Float, paused: Bool) {
        let changed = resources.soundEnabled != enabled || resources.soundPaused != paused
        resources.soundEnabled = enabled
        resources.volume = volume
        resources.soundPaused = paused
        for case let s as SoundObject in objects {
            // The renderer volume setter (0x1401816d0) runs the volume rule of every sound object on a change.
            s.rendererVolumeMaybeChanged()
            if changed { if enabled { s.setPaused(paused) } else { s.setPaused(true) } }
        }
    }

    deinit {
        if ProcessInfo.processInfo.environment["PHOTON_LIFETIME"] != nil { NSLog("photon: scene %@ released", wallpaperID) }
    }

    public static func readProject(_ dir: URL) -> [String: Any] {
        ((try? Data(contentsOf: dir.appendingPathComponent("project.json"))).flatMap(parseEngineJSON)) as? [String: Any] ?? [:]
    }

    func load(_ scene: [String: Any]) {
        general = (scene["general"] as? [String: Any]) ?? [:]
        var autoOrtho = false
        if let op = general["orthogonalprojection"] as? [String: Any] {
            autoOrtho = (op["auto"] as? Bool) == true
            if autoOrtho {
                isOrtho = true
            } else if let w = (op["width"] as? NSNumber)?.floatValue, let h = (op["height"] as? NSNumber)?.floatValue {
                orthoSize = SIMD2(w, h)
                isOrtho = w != 0 || h != 0
            }
        } else {
            isOrtho = false
        }
        if let c = SceneObject.vec3(general["clearcolor"]) { clearColor = c }
        clearEnabled = jsonBool(general["clearenabled"], default: true)
        multisample.sceneHasModel = Multisample.sceneHasModel(scene) // W+0x1b8 bit 0x100 (0x14010e7c7)
        bloom = jsonBool(general["bloom"], default: true)
        hdr = (Self.postProcessing == .ultra || Self.postProcessing == .displayhdr) && Self.isJSONTrue(general["bloom"])
            && Self.isJSONTrue(general["hdr"])
        displayHDR = hdr && Self.postProcessing == .displayhdr
        resources.hdr = hdr
        frame.hdr = hdr
        // SCENE_ORTHO (C+0x118 & 0x400, 0x14018768a) and the packed light counts (C+0x121c) feed program combos.
        resources.sceneOrtho = isOrtho
        resources.sceneVersion = (scene["version"] as? NSNumber)?.intValue ?? 0
        resources.lightConfig = Self.packLightConfig(general["lightconfig"], shadowQuality: volumetrics.shadowQuality)
        resources.shadowQuality = volumetrics.shadowQuality
        applyGeneralLighting()
        defer { parallaxP = orthoSize * 0.5 } // steady state with the pointer centred
        cameraParallax = jsonBool(general["cameraparallax"], default: false)
        cameraShake = jsonBool(general["camerashake"], default: false)
        parallaxAmount = jsonFloats(general["cameraparallaxamount"]).first ?? 0.5
        parallaxDelay = jsonFloats(general["cameraparallaxdelay"]).first ?? 0.1
        parallaxMouseInfluence = jsonFloats(general["cameraparallaxmouseinfluence"]).first ?? 0.5
        shakeSpeed = jsonFloats(general["camerashakespeed"]).first ?? 3
        shakeAmplitude = jsonFloats(general["camerashakeamplitude"]).first ?? 0.5
        shakeRoughness = jsonFloats(general["camerashakeroughness"]).first ?? 1

        // Ortho scenes without camera paths ignore the JSON camera (docs/re/04 §2.2).
        let camera = (scene["camera"] as? [String: Any]) ?? [:]
        let hasPaths = !((camera["paths"] as? [Any]) ?? []).isEmpty
        if !isOrtho || hasPaths {
            cameraEye = SceneObject.vec3(camera["eye"]) ?? SIMD3(2, 2, 2)
            cameraCenter = SceneObject.vec3(camera["center"]) ?? .zero
            cameraUp = SceneObject.vec3(camera["up"]) ?? SIMD3(0, 1, 0)
        }
        // SceneData_Load: every string in `paths` → CameraPath_Load 0x140198e20.
        let pathFiles = ((camera["paths"] as? [Any]) ?? []).compactMap { $0 as? String }
        if !pathFiles.isEmpty {
            let paths = SceneCameraPaths(files: pathFiles, fs: resources.fs)
            if !paths.isEmpty {
                cameraPaths = paths
                if jsonBool(general["camerafade"], default: true) { fadeMaterial = resources.material("materials/util/fade.json") }
            }
        }

        let device = resources.device
        let w = Int(orthoSize.x), h = Int(orthoSize.y)
        // The scene draws into the back buffer, which is fp16 on the HDR path. _rt_FullFrameBuffer is format
        // rgb161616f (0xF) with HDR, else rgb888 (1) (RT setup 0x14017f33d / 0x14017f5ac).
        sceneTarget = resources.targets.acquire("_rt_SceneMain", width: w, height: h, format: renderTargetFormat(hdr: hdr), samplerFlags: 2)
        fullFrameBuffer = resources.targets.acquire("_rt_FullFrameBuffer", width: w, height: h, format: renderTargetFormat(hdr: hdr), samplerFlags: 2)
        _ = device
        if hdr {
            // Bloom constants (0x14017f7cb..0x14017f98f): `blend` is the soft knee from threshold T and feather f.
            // `bloomstrength` depends on the level count, so `updateHDRMips` sets it.
            let T = EngineValue.float(general["bloomhdrthreshold"], default: 1)
            let f = EngineValue.float(general["bloomhdrfeather"], default: 0.1)
            let tint = SceneObject.vec3(general["bloomtint"]) ?? SIMD3(1, 1, 1)
            hdrStrength = EngineValue.float(general["bloomhdrstrength"], default: 2)
            hdrScatter = EngineValue.float(general["bloomhdrscatter"], default: 1.619)
            hdrIterations = EngineValue.int(general["bloomhdriterations"], default: 8)
            let blend = "\(T) \(T - T * f) \(2 * T * f) \(0.25 / (T * f + 1e-5))"
            hdrDownBloom = resources.material("materials/util/hdr_downsample_bloom.json", override: ["constantshadervalues": [
                "blend": blend, "bloomtint": "\(tint.x) \(tint.y) \(tint.z)"]])
            hdrDown = resources.material("materials/util/hdr_downsample.json")
            hdrUp = resources.material("materials/util/hdr_upsample.json", override: ["constantshadervalues": ["scatter": hdrScatter]])
            hdrUpCubic = resources.material("materials/util/hdr_upsample_cubic.json", override: ["constantshadervalues": ["scatter": hdrScatter]])
            combine = resources.material(displayHDR ? "materials/util/combine_dhdr_upsample.json" : "materials/util/combine_hdr_upsample.json")
            hdrCombineSRGB = resources.material("materials/util/combine_srgb.json")
        } else if bloom {
            // Float loader 0x1401a4b00: `null` is not a number and keeps the default (docs/re/loader-keys.md §1).
            let strength = EngineValue.float(general["bloomstrength"], default: 2)
            let threshold = EngineValue.float(general["bloomthreshold"], default: 0.65)
            let tint = SceneObject.vec3(general["bloomtint"]) ?? SIMD3(1, 1, 1)
            let consts: [String: Any] = ["bloomstrength": strength, "bloomthreshold": threshold, "bloomtint": "\(tint.x) \(tint.y) \(tint.z)"]
            let fmt = renderTargetFormat(hdr: false)
            let t4 = resources.targets.acquire("_rt_4FrameBuffer", width: w, height: h, scale: 4, format: fmt, samplerFlags: 2)
            let t8 = resources.targets.acquire("_rt_8FrameBuffer", width: w, height: h, scale: 8, format: fmt, samplerFlags: 2)
            let tb = resources.targets.acquire("_rt_Bloom", width: w, height: h, scale: 8, format: fmt, samplerFlags: 2)
            bloomPasses = [
                (resources.material("materials/util/downsample_quarter_bloom.json", override: ["constantshadervalues": consts]), t4),
                (resources.material("materials/util/downsample_eighth_blur_v.json"), t8),
                (resources.material("materials/util/blur_h_bloom.json"), tb),
            ]
            combine = resources.material("materials/util/combine_ldr.json")
        }

        var byID: [Int: SceneObject] = [:]
        var autoID = 1_000_000
        for o in (scene["objects"] as? [[String: Any]]) ?? [] {
            let id = (o["id"] as? NSNumber)?.intValue ?? { autoID += 1; return autoID }()
            let obj = makeObject(o, id: id)
            objects.append(obj)
            byID[id] = obj
        }
        for o in objects { if let p = o.parentID { o.parent = byID[p] } }
        // Scratch composite names count passthrough ancestors (`SceneObject.scratchName`, 0x1401eade4): allocate those
        // layers' targets again now that parents are linked.
        for case let l as ImageLayer in objects where l.hasPassthroughAncestor { l.allocateTargets() }
        // `SceneData_Load` 0x14018803a–0x1401881d1: the ids in every object's `dependencies` (numbers only, the object
        // ctor 0x1401dde99) are collected; each image (type 1) or text (type 4) object with such an id gets
        // flags304 |= 0x1010: a dedicated composite `_rt_imageLayerComposite_<id>_a`, rendered even while hidden.
        var dependencyIDs = Set<Int>()
        for o in objects {
            for d in (o.json["dependencies"] as? [Any]) ?? [] {
                if let n = d as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { dependencyIDs.insert(n.intValue) }
            }
        }
        for o in objects where dependencyIDs.contains(o.id) {
            if let l = o as? ImageLayer { l.markDependency() } else if let t = o as? TextObject { t.markDependency() }
        }
        // `Scene_ApplyAutoOrtho` 0x14018b2c0 (docs/re/04 §2.1): ortho size = first image's size, image centred in it.
        if autoOrtho, let img = objects.first(where: { $0 is ImageLayer }) as? ImageLayer, img.size.x > 0, img.size.y > 0 {
            orthoSize = img.size
            img.origin = SIMD3(img.size.x * 0.5, img.size.y * 0.5, 0)
        }
        // `_rt_MipMappedFrameBuffer` (0x140181cec): scene-sized, full mip chain, fp16 with HDR; created when a
        // material samples it (reflection with a normal map) and cleared to (0, 0, 0, 1).
        let mipUsers = objects.compactMap { $0 as? ImageLayer }.flatMap { [$0.material, $0.prelitMaterial].compactMap { $0 } }
        if mipUsers.contains(where: \.readsMipMappedFrameBuffer) {
            mipFrameBuffer = resources.targets.acquire("_rt_MipMappedFrameBuffer", width: w, height: h,
                                                       format: renderTargetFormat(hdr: hdr), samplerFlags: 2, mipmapped: true)
            mipFrameBufferNeedsClear = true
        }
        // Reflection list and `_rt_Reflection` (docs/re/04 §6.5): S+0xe0 bit 0 is set when any object has `+0x120 & 8`.
        reflectionObjects = objects.filter(\.inReflectionList)
        if objects.contains(where: \.needsReflection) {
            reflectionTarget = resources.targets.acquire("_rt_Reflection", width: w, height: h, format: .rgba8Unorm, samplerFlags: 2)
        }
        // SceneScript bindings compile after every object exists (thisScene.getLayer at init time).
        constantAnimations = ScriptConstantAnimations(objects: objects)
        scripts = SceneScriptEngine.make(scene: self, sceneJSON: scene)
    }

    /// `general.lightconfig` → `C+0x121c` (SceneData_Load 0x140187b52–0x140187d00): counts of point (bits 0–3),
    /// spot (4–7), tube (8–11) and directional (12–15) lights; `spotcookie` in bits 18–19. With shadows enabled
    /// (`C+0x1ac` ≠ 0) the engine also packs `spotshadow << 16`, `spotshadowcookie << 20`, `directionalshadow << 22` and
    /// `pointshadow << 24`; with shadows off `spotshadowcookie` is ORed into the cookie bits instead.
    /// photon2 implements point-light shadows only, so the spot and directional shadow counts are dropped (they would
    /// need `g_LFeature_ShadowProjection` data, docs/re/06 §6.5b).
    static func packLightConfig(_ v: Any?, shadowQuality: Int = 0) -> UInt32 {
        guard let lc = v as? [String: Any] else { return 0 }
        func n(_ k: String) -> UInt32 { (lc[k] as? NSNumber).map { UInt32(truncatingIfNeeded: $0.intValue) } ?? 0 }
        var c = (n("point") & 0xf) | (n("spot") & 0xf) << 4 | (n("tube") & 0xf) << 8 | (n("directional") & 0xf) << 12
        c |= (n("spotcookie") & 3) << 18
        if shadowQuality != 0 {
            // SceneData_Load 0x140187c39–0x140187cdc.
            c |= (n("spotshadowcookie") & 3) << 20 | (n("spotshadow") & 3) << 16 | (n("directionalshadow") & 3) << 22
            c |= (n("pointshadow") & 3) << 24
        } else {
            c |= (n("spotshadowcookie") & 3) << 18
        }
        return c
    }


    /// `ambientcolor`/`skylightcolor` (change callback 0x1401863f0 → C+0x1298/C+0x12a4) and fog (0x140186440 → C+0x12b0…,
    /// flags C+0x118 bits 23/24): run at load and again when a script writes one of these `general` properties.
    func applyGeneralLighting() {
        frame.ambientColor = SceneObject.vec3(general["ambientcolor"]) ?? .zero
        frame.skylightColor = SceneObject.vec3(general["skylightcolor"]) ?? .zero
        // `Scene_UpdateFog` 0x140186440 (defaults from the scene ctor 0x140186fd4–0x1401870a1): colours (0,0,0),
        // distance start 1 / end 5, density 0 → 1; height start 1 / end −3, density 0 → 1. Params are
        // (start, end − start, startDensity, endDensity − startDensity).
        func f(_ k: String, _ d: Float) -> Float { jsonFloats(general[k]).first ?? d }
        let dc = SceneObject.vec3(general["fogdistancecolor"]) ?? .zero, hc = SceneObject.vec3(general["fogheightcolor"]) ?? .zero
        let ds = f("fogdistancestart", 1), de = f("fogdistanceend", 5), dsd = f("fogdistancestartdensity", 0), ded = f("fogdistanceenddensity", 1)
        let hs = f("fogheightstart", 1), he = f("fogheightend", -3), hsd = f("fogheightstartdensity", 0), hed = f("fogheightenddensity", 1)
        frame.fog = [
            "g_FogDistanceColor": .floats([dc.x, dc.y, dc.z]), "g_FogDistanceParams": .floats([ds, de - ds, dsd, ded - dsd]),
            "g_FogHeightColor": .floats([hc.x, hc.y, hc.z]), "g_FogHeightParams": .floats([hs, he - hs, hsd, hed - hsd]),
        ]
        // general +0xe0 bit 14 (`fogdistance`, setter 0x14019bb40) → C+0x118 bit 23; bit 15 (`fogheight`, 0x14019bd70) → bit 24.
        resources.fogFlags = (jsonBool(general["fogdistance"], default: false) ? 1 : 0) | (jsonBool(general["fogheight"], default: false) ? 2 : 0)
    }

    var lightObjects: [LightObject] { objects.compactMap { $0 as? LightObject } }

    /// `SceneGraph_DrawList` 0x14018aac0. Scene flags S+0xe0: `transparentsorting` = 0x1000 (setter 0x14019c1c0),
    /// `customsortorder` = 0x2000 (0x14019c3f0), ortho = 0x8.
    /// - customsortorder without transparentsorting: the list is stable-sorted by object `sortorder` (+0x124,
    ///   comparator 0x140186980, ascending).
    /// - perspective with transparentsorting (`e0 & 0x1008 == 0x1000`): objects flagged transparent at creation
    ///   (`+0x120 & 0x100`, collected into S+0x170 by Scene_CreateObject 0x140190952) are skipped in list order, then
    ///   drawn after everything else sorted by descending dot(world position, C+0x160) (0x1401865c0, insertion sort
    ///   0x14019ee60): farthest along the view direction first.
    /// - otherwise load order.
    /// `pass` 1 (the reflection pass) starts from the reflection list S+0x1c8 instead of S+0x158; the sorted transparent
    /// objects (S+0x170) are all transparent objects in either pass (0x14018ae2a). `forward` is C+0x160.
    func drawList(pass: Int = 0, forward: SIMD3<Float>? = nil) -> [SceneObject] {
        let transparentSorting = jsonBool(general["transparentsorting"], default: false)
        let customSort = jsonBool(general["customsortorder"], default: false)
        var list = pass == 1 ? reflectionObjects : objects
        if customSort && !transparentSorting {
            list = list.enumerated().sorted { a, b in
                let x = a.element.sortOrder, y = b.element.sortOrder
                return x != y ? x < y : a.offset < b.offset
            }.map(\.element)
        }
        guard !isOrtho, transparentSorting else { return list }
        // C+0x160 (g_ViewForward): the camera's forward axis = −(view row 2) for the RH view.
        let v = frame.view
        let forward = forward ?? -SIMD3(v[0][2], v[1][2], v[2][2])
        let opaque = list.filter { !$0.isTransparent }
        var keyed: [(key: Float, index: Int, obj: SceneObject)] = []
        // 0x140186686: the key reads the object's own `origin` property (+0x128), not its world position.
        for (i, o) in objects.filter(\.isTransparent).enumerated() {
            // 0x14018665a–0x140186681: objects with +0x120 & 0x200 (fullscreen / projectlayer images) key −∞.
            let last = (o as? ImageLayer)?.sortsLast ?? false
            keyed.append((last ? -Float.infinity : simd_dot(o.origin, forward), i, o))
        }
        keyed.sort { a, b in a.key != b.key ? a.key > b.key : a.index < b.index }
        let transparent = keyed.map { $0.obj }
        return opaque + transparent
    }

    /// Type decision order from Scene_CreateObject (docs/re/04 §4.1): first match wins.
    func makeObject(_ o: [String: Any], id: Int) -> SceneObject {
        if o["model"] != nil && !(o["model"] is NSNull) {
            // PHOTON_MODELS=0 disables model objects (debugging).
            if ProcessInfo.processInfo.environment["PHOTON_MODELS"] == "0" { return SceneObject(json: o, id: id) }
            return ModelObject(json: o, id: id, resources: resources)
        } else if o["particle"] is String {
            let p = ParticleSystemObject(json: o, id: id, resources: resources)
            p.scene = self
            return p
        } else if o["image"] is String {
            if let layer = ImageLayer(json: o, id: id, resources: resources, nextEffectID: { self.effectCounter += 1; return self.effectCounter }) {
                layer.scene = self
                return layer
            }
            return SceneObject(json: o, id: id)
        } else if o["sprite"] is String {
            // Scene_CreateObject 0x14018ff60 rule 4: sprite (0x270 bytes, ctor 0x140256560; Sprite.swift).
            return SpriteObject(json: o, id: id, resources: resources)
        } else if o["light"] is String, o["text"] == nil {
            let light = LightObject(json: o, id: id)
            let used = lightObjects.reduce(0) { $0 | (1 << ($1.legacySlot & 31)) }
            light.legacySlot = (0..<4).first { used & (1 << $0) == 0 } ?? 0
            return light
        } else if let snd = o["sound"], !(snd is NSNull), o["text"] == nil {
            return SoundObject(json: o, id: id, resources: resources)
        } else if o["text"] != nil {
            let t = TextObject(json: o, id: id, resources: resources)
            t.scene = self
            return t
        } else if o["camera"] is String {
            let cam = CameraObject(json: o, id: id)
            cam.ortho = isOrtho
            // Camera_Load 0x1401f2030: `path` (string, `find`) → path file; `queuemode` enum 0x1401f3a20 (random 0, sequential 1).
            if let file = o["path"] as? String, let root = resources.fs.readJSON(file) as? [String: Any],
               let list = root["paths"] as? [Any] {
                let paths = list.compactMap { ($0 as? [String: Any]).flatMap(CameraPathAnimation.init) }
                if !paths.isEmpty {
                    let mode = (unwrapUserValue(o["queuemode"]) as? String) == "sequential" ? 1 : 0
                    cam.pathPlayer = CameraPathPlayer(paths: paths, queueMode: mode)
                }
            }
            return cam
        } else if o["shape"] is String {
            // Scene_CreateObject 0x1401907ca (type 10): effect-only layer drawn straight into the scene (Shape.swift).
            return ShapeObject(json: o, id: id, resources: resources, projectionHeight: Int(orthoSize.y),
                               nextEffectID: { self.effectCounter += 1; return self.effectCounter })
        }
        return SceneObject(json: o, id: id)
    }

    /// `thisScene.createLayer` (docs/re/08 §3.9): appends a new object built from a scene.json-style config.
    func addScriptLayer(_ conf: [String: Any]) -> SceneObject? {
        nextScriptLayerID += 1
        let id = (conf["id"] as? NSNumber)?.intValue ?? nextScriptLayerID
        let obj = makeObject(conf, id: id)
        if let p = obj.parentID { obj.parent = objects.first { $0.id == p } }
        objects.append(obj)
        return obj
    }

    // MARK: - Frame

    /// Renders one frame into `drawable` (sized to the output display).
    public func render(to drawable: CAMetalDrawable, time: Double, outputSize: CGSize, pointer: CGPoint?) {
        guard let cb = render(into: drawable.texture, time: time, outputSize: outputSize, pointer: pointer) else { return }
        cb.present(drawable)
        cb.commit()
    }

    /// Encodes one frame into `output`. The caller commits the returned command buffer.
    public func render(into output: MTLTexture, time: Double, outputSize: CGSize, pointer: CGPoint?) -> MTLCommandBuffer? {
        if let cb = colorCorrection.render(self, into: output, time: time, outputSize: outputSize, pointer: pointer) { return cb }
        // dt clamped to [0.0001, 0.25]; g_Time resets after 432000 s; daytime from local clock (docs/re/07 §3.1).
        frame.pointerWasDown = pointerDownLastFrame
        pointerDownLastFrame = frame.pointerDown
        let dt = Float(min(max(lastTime.map { time - $0 } ?? 0.0001, 0.0001), 0.25))
        lastTime = time
        frame.frameTime = dt
        frame.time = Float(time.truncatingRemainder(dividingBy: 432000))
        let comps = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: Date())
        // Split into terms only so swift-corelibs' type checker finishes (same operations, same order).
        let dayHours: Double = Double(comps.hour ?? 0) / 24, dayMinutes: Double = Double(comps.minute ?? 0) / 1440
        let daySeconds: Double = Double(comps.second ?? 0) / 86400, dayMillis: Double = Double((comps.nanosecond ?? 0) / 1_000_000) / 86_400_000
        frame.daytime = Float(dayHours + dayMinutes + daySeconds + dayMillis)
        if let p = pointer {
            frame.pointerLast = frame.pointer
            frame.pointer = SIMD2(Float(p.x), Float(p.y))
        }

        let sw = Float(outputSize.width), sh = Float(outputSize.height)
        frame.screen = SIMD2(max(sw, 2), max(sh, 2))
        frame.textureReduction = Float(textureReduction)
        resizeTargets(Int(sw), Int(sh))
        updateAudio(dt)
        // Sound_Update reads the context's camera (last frame's): eye C+0x68, g_ViewRight/Up/Forward C+0x16c/0x178/0x160.
        let lv = frame.view
        let listener = SoundSpatial.Listener(eye: frame.eye, right: SIMD3(lv.columns.0.x, lv.columns.1.x, lv.columns.2.x),
                                              up: SIMD3(lv.columns.0.y, lv.columns.1.y, lv.columns.2.y),
                                              forward: -SIMD3(lv.columns.0.z, lv.columns.1.z, lv.columns.2.z),
                                              ortho: isOrtho, projectionSize: orthoSize, frameIndex: renderedFrames)
        renderedFrames += 1
        for case let snd as SoundObject in objects where snd.spatialization { snd.listener = listener }
        for obj in objects { obj.update(dt) }
        // SceneScript Bindings_Tick (docs/re/08 §2.3) after animations so script results win this frame.
        // It uses last frame's projection to unproject the cursor.
        constantAnimations?.update(dt)
        scripts?.tick(dt: dt)
        updateCamera(dt)
        frame.proj = projection(sw: sw, sh: sh)
        // C+0x68 (g_EyePosition) and C+0x160 (g_ViewForward = −(view row 2)) for the directional cascades.
        let vfw = -SIMD3(frame.view[0][2], frame.view[1][2], frame.view[2][2])
        var lightBuffer = LightBuffer(lights: lightObjects, config: resources.lightConfig, shadowQuality: shadows.quality, ortho: isOrtho,
                                      eye: frame.eye, viewForward: vfw)
        var shadowRecords = lightBuffer.shadowRecords
        let renderShadows = shadows.pack(&shadowRecords, device: resources.device)
        lightBuffer.setShadowTransforms(shadowRecords, shadows)
        frame.lights = lightBuffer.uniforms
        frame.legacyLights = LegacyLights.uniforms(lightObjects)
        lightCookieLight = lightBuffer.cookieLight
        if ProcessInfo.processInfo.environment["PHOTON_CAMDEBUG"] != nil {
            NSLog("photon: camera eye %@ center %@ up %@", "\(cameraEye)", "\(cameraCenter)", "\(cameraUp)")
        }

        guard let cb = queue.makeCommandBuffer() else { return nil }
        resources.textures.updateVideos(time: time, commandBuffer: cb)
        let ctx = RenderContext(device: resources.device, commandBuffer: cb, backBuffer: sceneTarget.texture)
        // Stale render-context uniforms and the frame counter C+0x144 persist across frames (StaleBuiltins, Draw.swift).
        builtinState.frame += 1
        ctx.builtinState = builtinState
        // `alignmentfliph` mirrors the projection (l/r swapped), which reverses the winding; the engine's cull push for
        // the flag (0x1401806ee) keeps front faces visible. Inferred for the main pass (docs/re/09 §5).
        ctx.cullFront = flipHorizontal
        ctx.errorTexture = BoundTexture(gpu: resources.textures.errorTexture)
        if ProcessInfo.processInfo.environment["PHOTON_NODEPTH"] == nil {
            // Every scene draws into a back buffer with a D32_FLOAT depth view: the swap-chain targets are built with
            // depth format 0x18 (0x1400992cc, 0x140099932, 0x14011122f, 0x14011ff41) and the MSAA scene target too
            // (0x140181e0c). `Renderer_InitStates` 0x14017eae0 sets the clear depth to 0 for every scene, ortho or not,
            // and depth compares GREATER (docs/re/03 "Depth"). Layer composites and effect FBOs have no depth (format 0x1b).
            if depthTexture?.width != sceneTarget.texture.width || depthTexture?.height != sceneTarget.texture.height {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: sceneTarget.texture.width,
                                                                 height: sceneTarget.texture.height, mipmapped: false)
                d.usage = [.renderTarget, .shaderRead]
                d.storageMode = .private
                depthTexture = resources.device.makeTexture(descriptor: d)
            }
            ctx.depth = depthTexture
            if clearEnabled { ctx.clearDepth() }
        }
        clearFreshTargets(ctx)
        multisample.begin(ctx, device: resources.device) // Scene_DrawObjects 0x140183550 binds R+0x3100 for pass 0
        if mipFrameBufferNeedsClear, let mip = mipFrameBuffer {
            mipFrameBufferNeedsClear = false
            ctx.bind(mip.texture)
            ctx.clear(MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.unbind()
        }
        // `Lights_Update` 0x140190c80 renders the shadow atlas (`Shadow_RenderView` 0x140196530) before the draw list.
        if renderShadows { shadows.render(shadowRecords, ctx, frame, self) }
        ctx.shadowAtlas = shadows.bound(device: resources.device)
        // `_alias_lightCookie` (0x14019359b–0x1401935d8): the last cookie spot of this frame's light buffer.
        ctx.lightCookie = lightCookieLight.flatMap { volumetrics.cookieTexture($0, self) }
        renderReflection(ctx)
        if clearEnabled {
            let c = frameClearColor
            ctx.clear(MTLClearColor(red: Double(c.x), green: Double(c.y), blue: Double(c.z), alpha: 1))
        }
        drawObjects(ctx, pass: 0)
        multisample.end(ctx) // unbind and resolve (RT vt+0x10, 0x1401835fb)

        // Post (docs/re/03 §9 step 5): snapshot, bloom chain, combine to the output. `_rt_FullFrameBuffer ← current` runs
        // only on the bloom path (0x140180a7f), the HDR path (0x140180b9c) and before the colour pass (0x140180bdc); the
        // plain LDR path leaves the last layer snapshot in it, which children of passthrough groups read (0x1401e8f63).
        if hdr || (bloom && Self.postProcessing != .disabled && !objects.isEmpty) || colorCorrection.isActive {
            ctx.copyCurrent(into: fullFrameBuffer.texture)
        }
        // Renderer_Frame 0x140180a8c: then the mip-mapped snapshot (CopyFromCurrent + GenerateMips), which lit
        // reflective materials sample on the next frame.
        if let mip = mipFrameBuffer {
            ctx.copyCurrent(into: mip.texture)
            if let blit = cb.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: mip.texture)
                blit.endEncoding()
            }
        }
        let ident = FrameState()
        ident.screen = frame.screen
        ident.proj = Mat.orthoLH(l: -1, r: 1, b: -1, t: 1, zn: -1000, zf: 1000)
        if hdr, ProcessInfo.processInfo.environment["PHOTON_SHOW"] == nil {
            renderHDRPost(ctx, ident, output: output, bloomPass: Self.postProcessing != .disabled && bloom && !objects.isEmpty)
            drawCameraFade(ctx, ident, output: output)
            ctx.endEncoder()
            lastDrawCount = ctx.drawCount
            return cb
        }
        // 0x140180a41: post runs when postprocessing != "disabled" (flag 0x40), scene bloom, and objects exist.
        if bloom, Self.postProcessing != .disabled, !objects.isEmpty, let combine {
            for (m, rt) in bloomPasses {
                ctx.bind(rt.texture)
                drawFullscreen(m, ctx, ident)
                ctx.unbind()
            }
            if ProcessInfo.processInfo.environment["PHOTON_SHOW"] == nil {
                ctx.bind(output)
                drawFullscreen(combine, ctx, ident)
                ctx.unbind()
                drawCameraFade(ctx, ident, output: output)
                ctx.endEncoder()
                lastDrawCount = ctx.drawCount
                return cb
            }
        }
        ctx.endEncoder()
        let shown = ProcessInfo.processInfo.environment["PHOTON_SHOW"].flatMap { resources.targets.find($0) }?.texture ?? sceneTarget.texture
        Blitter.shared(resources.device).draw(shown, into: output, commandBuffer: cb)
        if fadeMaterial != nil {
            drawCameraFade(ctx, ident, output: output)
            ctx.endEncoder()
        }
        lastDrawCount = ctx.drawCount
        return cb
    }

    /// `SceneGraph_DrawList` 0x14018aac0 body for `pass` 0 (main) or 1 (reflection; caller binds `_rt_Reflection`).
    func drawObjects(_ ctx: RenderContext, pass: Int, forward: SIMD3<Float>? = nil) {
        let baseView = frame.view
        let savedCameraView = frame.cameraView
        frame.cameraView = baseView
        defer { frame.cameraView = savedCameraView }
        let parallax = cameraParallax && userParallax && isOrtho
        // 0x14018ac5c–0x14018ac7f: C+0xec0 = planes of the current view-projection, once per draw list.
        let savedPlanes = frame.cullPlanes
        frame.cullFlags = isOrtho ? 1 : 3
        frame.cullPlanes = Self.cullingDisabled ? nil : Frustum.planes(frame.proj * frame.view)
        defer { frame.cullPlanes = savedPlanes }
        for obj in drawList(pass: pass, forward: forward)
        where debugSkip.contains(obj.id) == false && (debugOnly.isEmpty || debugOnly.contains(obj.id)) {
            // The parallax path ((S+0xe0 & 0x108) == 0x108, 0x14018af5d) tests visibility and the pending volumetrics
            // first and skips `+0x120 & 2` objects only at the draw; the other paths skip them first (0x14018adb9).
            if !parallax && obj.drawnByGroup { continue }
            if let layer = obj as? ImageLayer { layer.refreshIfScreenChanged(frame) }
            if RenderTargetManager.hasFresh { clearFreshTargets(ctx) }
            if parallax {
                let r = obj.root
                let off = SIMD3<Float>(parallaxAmount * (r.origin.x - parallaxP.x) * r.parallaxDepth.x,
                                       parallaxAmount * (r.origin.y - parallaxP.y) * r.parallaxDepth.y, 0)
                frame.view = baseView * Mat.translate(off)
            }
            // 0x14018ade4: in the main pass (C+0x468 bit 0 = pass 0) a pending volumetrics buffer is combined before
            // the next visible object that is not a light (type 6); invisible objects (vt+0x68) are skipped first.
            if let l = obj as? LightObject {
                if !l.drawsVolumetrics { continue }
            } else if pass == 0 && volumetrics.pending && obj.renderVisible {
                volumetrics.combine(ctx, frame, self)
            }
            if parallax && obj.drawnByGroup { continue }
            obj.render(ctx, frame, self)
        }
        frame.view = baseView
        if volumetrics.pending { volumetrics.combine(ctx, frame, self) } // 0x14018b1e2, either pass
    }

    /// Reflection pass (`Renderer_Frame` 0x140180357–0x1401808ff), when S+0xe0 bit 0 is set. With the `reflection`
    /// setting on: push view = diag(1, −1, 1, 1) × view (row-vector, 0x1401844f0 + 0x1401842d0), negate projection
    /// [1][1] (C+0x118 bit 0, always set: params 0x100d|… at 0x140110a9d), mirror g_EyePosition, g_ViewRight and g_ViewUp
    /// (y → −y with the 3×3 from 0x140184630; g_ViewForward keeps its value), keep cull BACK (push fliph = 0), bind
    /// `_rt_Reflection`, `0x140183550(R, 1)` = clear colour and depth when clearenabled, then the draw list over S+0x1c8;
    /// restore everything. With the setting off it only clears `_rt_Reflection` to the clear colour each frame.
    /// `PHOTON_NOFRUSTUM=1` turns frustum culling off (debug only; the engine always culls).
    static let cullingDisabled = ProcessInfo.processInfo.environment["PHOTON_NOFRUSTUM"] == "1"

    func renderReflection(_ ctx: RenderContext) {
        guard let rt = reflectionTarget else { return }
        let cc = frameClearColor
        let clear = MTLClearColor(red: Double(cc.x), green: Double(cc.y), blue: Double(cc.z), alpha: 1)
        ctx.bind(rt.texture)
        guard Self.reflectionSetting else {
            ctx.clear(clear)
            ctx.unbind()
            return
        }
        let v = frame.view, p = frame.proj, e = frame.eye, f = frame.viewForward
        let forward = -SIMD3(v[0][2], v[1][2], v[2][2])
        frame.view = v * Mat.scale(SIMD3(1, -1, 1))
        frame.proj[1][1] = -frame.proj[1][1]
        frame.eye = SIMD3(e.x, -e.y, e.z)
        frame.viewForward = forward
        if clearEnabled { ctx.clear(clear) }
        drawObjects(ctx, pass: 1, forward: forward)
        frame.view = v; frame.proj = p; frame.eye = e; frame.viewForward = f
        ctx.unbind()
    }

    /// HDR post (Renderer_Frame 0x140180a41..0x140180bcb, pass driver 0x140183610).
    /// Bloom on: downsample FullFrameBuffer into `_rt_2FrameBuffer` with hdr_downsample_bloom, then each level i
    /// into level i with hdr_downsample; upsample additively from level n-1 back to level 0 (cubic for the two
    /// coarsest steps), then combine_hdr_upsample(FullFrameBuffer, _rt_2FrameBuffer) to the back buffer.
    /// Bloom off: combine_srgb(FullFrameBuffer). g_RenderVar0 (`R+0xb8`) carries each pass's source texel
    /// offsets, then for the combine its .xy is replaced by the device's scRGB scale (`D+0x40/+0x44`, read by
    /// device vt+0x158 = 0x14009b790).
    func renderHDRPost(_ ctx: RenderContext, _ ident: FrameState, output: MTLTexture, bloomPass: Bool) {
        // An fp16 output (display HDR / EDR) takes the linear combine directly, like the engine's scRGB swap chain.
        let linearOutput = output.pixelFormat == .rgba16Float
        let view = linearOutput ? output : hdrOutputView(width: output.width, height: output.height)
        let base = SIMD4<Float>(1 / frame.screen.x, 1 / frame.screen.y, -1 / frame.screen.x, -1 / frame.screen.y)
        var renderVar0 = base
        let n = min(hdrIterationCount, hdrMips.count)
        if bloomPass, n > 0, let downBloom = hdrDownBloom, let down = hdrDown, let up = hdrUp, let upCubic = hdrUpCubic, let combine {
            ctx.bind(hdrMips[0].texture)
            drawFullscreen(downBloom, ctx, ident, renderVar0: renderVar0, textures: [0: BoundTexture(target: fullFrameBuffer)])
            ctx.unbind()
            for i in 1..<max(n, 1) {
                renderVar0 = base * Float(1 << i)
                ctx.bind(hdrMips[i].texture)
                drawFullscreen(down, ctx, ident, renderVar0: renderVar0, textures: [0: BoundTexture(target: hdrMips[i - 1])])
                ctx.unbind()
            }
            var level = n - 1
            while level > 0 {
                // cmovl at 0x140183822: levels below n-2 use hdr_upsample, the two coarsest use the cubic one.
                let m = level < n - 2 ? up : upCubic
                renderVar0 = base * Float(2 << (level - 1))
                ctx.bind(hdrMips[level - 1].texture)
                drawFullscreen(m, ctx, ident, renderVar0: renderVar0, textures: [0: BoundTexture(target: hdrMips[level])],
                               blend: BlendState(mode: m.blendMode))
                ctx.unbind()
                level -= 1
            }
            // D+0x40 / D+0x44 (device vt+0x158 = 0x14009b790). The device-wrapper struct (app +0x1e8) is initialised
            // to (1.0, 1.0) at 0x140110885–0x1401108bd, so SDR outputs use x = 1, y = 1 (y is only read by the
            // DISPLAYHDR branch). With an ST.2084 output 0x14012b5d9 writes white/80 and (peak − white)/80 (scRGB units).
            // On macOS EDR, 1.0 is SDR white, so the display-HDR values are (1, headroom − 1).
            renderVar0.x = 1
            renderVar0.y = displayHDR && linearOutput ? max(edrHeadroom - 1, 0) : 1
            ctx.bind(view)
            drawFullscreen(combine, ctx, ident, renderVar0: renderVar0, textures: [1: BoundTexture(target: hdrMips[0])])
            ctx.unbind()
        } else if let srgb = hdrCombineSRGB {
            ctx.bind(view)
            // Bloom off: combine_srgb is drawn without touching g_RenderVar0 (0x140180b3e path); NaN = not written.
            drawFullscreen(srgb, ctx, ident, renderVar0: SIMD4(repeating: .nan), textures: [:])
            ctx.unbind()
        }
        ctx.endEncoder()
        if !linearOutput { Blitter.shared(resources.device).draw(hdrOutput!, into: output, commandBuffer: ctx.commandBuffer) }
    }

    /// `R+0x3108` (Bloom constants 0x14017f7f7): n = (int)min(iterations, levels), at least 1.
    var hdrIterationCount: Int { max(1, min(hdrIterations, hdrMips.count)) }

    /// RT setup 0x14017f346..0x14017f544: level i (`_rt_<2<<i>FrameBuffer`, divisor 2<<i, format rgb161616f,
    /// clamp sampler) exists while min(w, h) >> (i + 1) > 0, for i < 8; missing levels are released.
    func updateHDRMips(_ w: Int, _ h: Int) {
        var m = max(min(max(w, 2), max(h, 2)), 0)
        var levels = 0
        for _ in 0..<8 {
            m /= 2
            if m > 0 { levels += 1 } else { break }
        }
        if levels != hdrMips.count {
            hdrMips.forEach { resources.targets.release($0) }
            hdrMips = (0..<levels).map { i in
                resources.targets.acquire("_rt_\(2 << i)FrameBuffer", width: w, height: h, scale: 2 << i,
                                          format: .rgba16Float, samplerFlags: 2)
            }
        }
        for rt in hdrMips { rt.resize(device: resources.device, width: w, height: h) }
        // bloomstrength = bloomhdrstrength / (scatter^(max(n, 2) - 2) + 1) (0x14017f84c..0x14017f893).
        let n = hdrIterationCount
        hdrDownBloom?.constants["bloomstrength"] = hdrStrength / (powf(hdrScatter, Float(max(n, 2) - 2)) + 1)
    }

    private func hdrOutputView(width: Int, height: Int) -> MTLTexture {
        if hdrOutput == nil || hdrOutput!.width != width || hdrOutput!.height != height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead, .pixelFormatView]
            d.storageMode = .private
            hdrOutput = resources.device.makeTexture(descriptor: d)
            hdrOutputSRGB = hdrOutput!.makeTextureView(pixelFormat: .bgra8Unorm_srgb)
        }
        return hdrOutputSRGB!
    }
    private var hdrOutputSRGB: MTLTexture?

    /// True only for a JSON boolean `true` (the prescan's type test at 0x14010e63b, rapidjson kBoolFlag).
    static func isJSONTrue(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return false }
        return n.boolValue
    }

    public private(set) var lastDrawCount = 0
    private var pointerDownLastFrame = false

    /// Capture starts once a program actually reads g_AudioSpectrum* (flag set while packing uniforms)
    /// or the project declares supportsaudioprocessing. Smoothing runs every frame (docs/re/06 §5.3).
    /// General `audioprocessing` property (Wallpaper_ApplySettings 0x140115370 → +0x1b8 bit 3; off zeroes the three
    /// spectrum arrays, 0x140115403–0x14011543a, and Wallpaper_Frame skips the audio block, 0x140111654).
    public var audioProcessing = true {
        didSet { if !audioProcessing { audioSmoother.reset() } }
    }

    func updateAudio(_ dt: Float) {
        guard audioProcessing else { frame.audio = audioSmoother.arrays; return }
        let audio = AudioSystem.shared
        let demand = supportsAudio || AudioSystem.shaderDemand || (scripts?.wantsAudio ?? false)
        if Self.audioCaptureEnabled && !audio.isRunning && demand { audio.start() }
        audioSmoother.update(input: audio.latestSpectrum(), dt: dt)
        frame.audio = audioSmoother.arrays
    }

    /// Debugging: PHOTON_ONLY / PHOTON_SKIP = comma-separated object ids.
    let debugOnly = Set((ProcessInfo.processInfo.environment["PHOTON_ONLY"] ?? "").split(separator: ",").compactMap { Int($0) })
    let debugSkip = Set((ProcessInfo.processInfo.environment["PHOTON_SKIP"] ?? "").split(separator: ",").compactMap { Int($0) })

    func drawFullscreen(_ m: Material, _ ctx: RenderContext, _ f: FrameState) {
        var tex: [Int: BoundTexture] = [:]
        for (slot, name) in m.textureNames where name.hasPrefix("_rt_") {
            if let rt = namedTarget(name) { tex[slot] = BoundTexture(target: rt) }
        }
        ctx.draw(material: m, quad: screenQuad, uniforms: f.builtins(color: SIMD3(1, 1, 1), alpha: 1, target: ctx.current),
                 textures: tex, blend: BlendState(mode: .normal))
    }

    /// Fullscreen pass with g_RenderVar0 and per-slot texture overrides (the engine writes the material's texture
    /// slots directly, `material+0xd0 + 8·slot`).
    func drawFullscreen(_ m: Material, _ ctx: RenderContext, _ f: FrameState, renderVar0: SIMD4<Float>,
                        textures: [Int: BoundTexture], blend: BlendState = BlendState(mode: .normal)) {
        var tex: [Int: BoundTexture] = [:]
        for (slot, name) in m.textureNames where name.hasPrefix("_rt_") {
            if let rt = namedTarget(name) { tex[slot] = BoundTexture(target: rt) }
        }
        tex.merge(textures) { _, b in b }
        var u = f.builtins(color: SIMD3(1, 1, 1), alpha: 1, target: ctx.current)
        u["g_RenderVar0"] = .floats([renderVar0.x, renderVar0.y, renderVar0.z, renderVar0.w])
        ctx.draw(material: m, quad: screenQuad, uniforms: u, textures: tex, blend: blend)
    }

    /// Camera-path fade (`Renderer_Frame` 0x140180c0b–0x140180cc5): `fade.json` over the finished frame with
    /// g_Alpha = the path fade alpha (SceneCameraPaths.fadeAlpha), only while it is > 0.
    func drawCameraFade(_ ctx: RenderContext, _ ident: FrameState, output: MTLTexture, afterColorPass: Bool = false) {
        // With the colour pass on, the fade is drawn after it (ColorCorrection.render), not into its input.
        guard afterColorPass || !colorCorrection.inPass else { return }
        guard let m = fadeMaterial, let paths = cameraPaths else { return }  // also with an active camera (elapsed stays 0 → alpha 1)
        let a = paths.fadeAlpha
        guard a > 0 else { return }
        ctx.bind(output)
        var tex: [Int: BoundTexture] = [:]
        for (slot, name) in m.textureNames where name.hasPrefix("_rt_") {
            if let rt = namedTarget(name) { tex[slot] = BoundTexture(target: rt) }
        }
        ctx.draw(material: m, quad: screenQuad, uniforms: ident.builtins(color: SIMD3(1, 1, 1), alpha: a, target: ctx.current),
                 textures: tex, blend: BlendState(mode: .translucent))
        ctx.unbind()
    }

    func clearFreshTargets(_ ctx: RenderContext) {
        for t in RenderTargetManager.takeFresh() {
            ctx.bind(t)
            ctx.clear(MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
            ctx.unbind()
        }
    }

    /// Offline rendering: advances object state (animations, puppets, particles) from the current time to
    /// `time` in fixed steps without drawing, so a single rendered frame shows the state at `time`.
    public func simulate(to time: Double, step: Double = 1.0 / 30) {
        var t = lastTime ?? 0
        while t + step < time {
            t += step
            frame.time = Float(t)
            frame.frameTime = Float(step)
            for obj in objects { obj.update(Float(step)) }
            constantAnimations?.update(Float(step))
            scripts?.tick(dt: Float(step))
            updateCamera(Float(step))
        }
        lastTime = t
    }

    func resizeTargets(_ w: Int, _ h: Int) {
        guard w > 0, h > 0 else { return }
        sceneTarget.resize(device: resources.device, width: w, height: h)
        fullFrameBuffer.resize(device: resources.device, width: w, height: h)
        mipFrameBuffer?.resize(device: resources.device, width: w, height: h)
        reflectionTarget?.resize(device: resources.device, width: w, height: h)
        for (_, rt) in bloomPasses { rt.resize(device: resources.device, width: w, height: h) }
        if hdr { updateHDRMips(w, h) }
    }

    /// `Scene_Update` camera part (docs/re/04 §3.1, §3.5, §3.6).
    func updateCamera(_ dt: Float) {
        var eye = cameraEye, center = cameraCenter, up = cameraUp
        pathZoom = nil
        // Scene_Update 0x14018942a / 0x1401894a9: without an active camera object, scene camera paths drive the view.
        if activeCamera == nil, let paths = cameraPaths, let r = paths.step(dt) {
            eye = r.eye; center = r.center; up = r.up
            pathZoom = r.zoom
        }
        // Scene_Update 0x1401892d3–0x140189361: with an active camera object its world matrix gives the view:
        // eye = row 3, centre = row 3 − row 2, up = row 1 (engine rows = simd columns here).
        if let cam = activeCamera {
            let w = cam.world
            let r1 = SIMD3(w.columns.1.x, w.columns.1.y, w.columns.1.z), r2 = SIMD3(w.columns.2.x, w.columns.2.y, w.columns.2.z)
            eye = SIMD3(w.columns.3.x, w.columns.3.y, w.columns.3.z)
            center = eye - r2
            up = r1
        }
        if cameraShake {
            let s = shakeSpeed * shakeSpeed * frame.time
            var v = SIMD3<Float>(cos(s), sin(1.333 * s), sin(s))
            let amp = shakeAmplitude * 0.1
            var scale = amp
            if isOrtho { v.z = 0; scale = orthoSize.y * 0.1 * amp }
            let r = pow(shakeRoughness, 3)
            let len = simd_length(v)
            if r > 0.001 && r != 1 && len > 0 { v *= pow(len, r) / len }
            eye += v * scale
            center += v * scale
        }
        if cameraParallax && userParallax {
            let infl = parallaxMouseInfluence
            let mx = min(max(frame.pointer.x, 0), 1), my = min(max(1 - frame.pointer.y, 0), 1)
            let W = orthoSize.x, H = orthoSize.y
            let target = SIMD2<Float>(W * 0.5 * (1 - infl) + W * mx * infl + eye.x, H * 0.5 * (1 - infl) + H * my * infl + eye.y)
            if parallaxDelay > 0 {
                let k = min(1, (1 - parallaxDelay / 3) * 10 * dt)
                parallaxP += (target - parallaxP) * k
            } else {
                parallaxP = target
            }
            frame.parallax = simd_clamp(parallaxP / orthoSize, SIMD2(0, 0), SIMD2(1, 1))
        }
        frame.view = Mat.lookAtRH(eye: eye, center: center, up: up)
        frame.eye = eye
        if isOrtho { frame.eye = SIMD3(eye.x + orthoSize.x * 0.5, eye.y + orthoSize.y * 0.5, 2000) }
    }

    /// `Renderer_SetupProjection` 0x140183a70 (docs/re/04 §3.2).
    func projection(sw: Float, sh: Float) -> simd_float4x4 {
        guard isOrtho else {
            // S+0x148 = the active camera's fov (+0x2d8) in perspective scenes, else general `fov` (0x140189402).
            let fov = min(max(activeCamera?.currentFov ?? jsonFloats(general["fov"]).first ?? 50, 0.1), 179.9)
            let P = Mat.perspectiveRHReversed(fovY: fov * .pi / 180, aspect: sw / sh, zn: jsonFloats(general["nearz"]).first ?? 0.1,
                                              zf: jsonFloats(general["farz"]).first ?? 10000)
            // alignmentfliph: the X basis is negated (docs/re/04 §3.2).
            return flipHorizontal ? Mat.scale(SIMD3(-1, 1, 1)) * P : P
        }
        let W = orthoSize.x, H = orthoSize.y
        var cl: Float = 0, cr: Float = 0, cb: Float = 0, ct: Float = 0
        let sceneA = W / H, screenA = sw / sh, ap = alignmentPosition
        let ax = alignmentX, ay = alignmentY, az = alignmentZ
        switch fit {
        case .cover:
            if sceneA > screenA { let e = (W - (H / sh) * sw) * 0.5; cl = 2 * (1 - ap) * e; cr = 2 * ap * e }
            else { let e = (H - (W / sw) * sh) * 0.5; cb = 2 * (1 - ap) * e; ct = 2 * ap * e }
        case .contain:
            if screenA > sceneA { let e = (W - (H / sh) * sw) * 0.5; cl = 2 * (1 - ap) * e; cr = 2 * ap * e }
            else { let e = (H - (W / sw) * sh) * 0.5; cb = 2 * (1 - ap) * e; ct = 2 * ap * e }
        case .stretch:
            break
        case .center:
            // 1:1 scene units per output pixel, placed by alignmentx/y (docs/re/04 §3.2).
            cl = ax * (W - sw); cr = (1 - ax) * (W - sw); cb = (1 - ay) * (H - sh); ct = ay * (H - sh)
        case .free:
            cl = W - ax * (sw + W); cr = W - (1 - ax) * (sw + W); ct = H - ay * (sh + H); cb = H - (1 - ay) * (sh + H)
            let k = max(-0.99, powf(2 - az, 4) - 1)
            let vw = W - cl - cr, vh = H - ct - cb
            cr -= vw * k * (1 - ax); cl -= vw * k * ax; ct -= vh * k * ay; cb -= vh * k * (1 - ay)
        }
        let P = flipHorizontal ? Mat.orthoLH(l: W - cl, r: cr, b: cb, t: H - ct, zn: -2000, zf: 2000)
            : Mat.orthoLH(l: cl, r: W - cr, b: cb, t: H - ct, zn: -2000, zf: 2000)
        // R+0x108/+0x10c × (W, H): the visible centre in scene units, used by the perspective push 0x1401e5b60.
        visibleCentre = SIMD2((cl + W - cr) * 0.5, (cb + H - ct) * 0.5)
        // Scene_Frame 0x14017fd3f–0x1401800a7 (ortho scenes only, S+0xe0 & 8): zoom = general `zoom` (S+0x154) ×
        // S+0x114 (the active camera object's zoom, else the base zoom S+0x13c), applied about the scene centre:
        // row-vector P' = T(−W/2, −H/2) · S(zoom, zoom, 1) · T(W/2, H/2) · P.
        let zoom = (jsonFloats(general["zoom"]).first ?? 1) * (activeCamera?.currentZoom ?? pathZoom ?? cameraZoom)
        guard zoom != 1 else { return P }
        let c = SIMD3<Float>(W * 0.5, H * 0.5, 0)
        return P * Mat.translate(c) * Mat.scale(SIMD3(zoom, zoom, 1)) * Mat.translate(-c)
    }

    /// Visible centre of the ortho projection (`Renderer_SetupProjection` 0x140183a70: R+0x108·W, R+0x10c·H).
    var visibleCentre = SIMD2<Float>(960, 540)

    /// S+0x148 in an ortho scene (`Scene_Update` 0x140189278–0x1401892c4): `perspectiveoverridefov` (S+0x144, ctor
    /// default 95.0 at 0x140186d67), clamped to [0.1, 179.9]; `Renderer_SetupProjection` turns it into R+0x120 (radians,
    /// 0x140183dc9), the fov of every perspective push (0x1401e5b60: `perspective` layers, particle flag 4).
    var orthoPerspectiveFOV: Float {
        min(max(EngineValue.float(general["perspectiveoverridefov"], default: 95), 0.1), 179.9)
    }

    /// `Camera_PushPerspective` 0x1401e5b60 for an ortho scene: d = 1/(tan(fov/2)·P[1][1]) (P = the current, zoomed
    /// projection), view translation x −= visible centre x, y −= visible centre y, z = −d, and
    /// P = PerspectiveFov(fov, screen aspect C+0x74/C+0x78, near 5, far max(15000, d + 1000)). So the z = 0 plane keeps its
    /// ortho framing and depth gets a real perspective. Callers save and restore `frame.view` / `frame.proj`.
    func pushPerspective(_ fr: FrameState) {
        guard isOrtho else { return }
        // The engine multiplies by the float constant π/180 (0x3c8efa35 at 0x140183dd1), not by π then divides.
        let fov = orthoPerspectiveFOV * Float(bitPattern: 0x3c8e_fa35)
        let sy = fr.proj.columns.1.y
        guard sy != 0 else { return }
        let d = 1 / (tanf(fov / 2) * sy)
        let far = max(15000, d + 1000)
        var v = fr.view
        v.columns.3.x -= visibleCentre.x
        v.columns.3.y -= visibleCentre.y
        v.columns.3.z = -d
        fr.view = v
        fr.proj = Mat.perspectiveRHReversed(fovY: fov, aspect: fr.screen.x / fr.screen.y, zn: 5, zf: far)
    }

    /// `Scene_Update` 0x1401891a0: the last camera object in load order that is visible with a visible parent chain.
    var activeCamera: CameraObject? {
        objects.reversed().lazy.compactMap { $0 as? CameraObject }.first { $0.effectiveVisible }
    }

    // MARK: - Helpers used by layers

    func namedTarget(_ name: String) -> RenderTarget? {
        if name == "_rt_FullFrameBuffer" { return fullFrameBuffer }
        if name == "_rt_MipMappedFrameBuffer" { return mipFrameBuffer }
        return resources.targets.find(name)
    }

    /// `spritesheetrefreshsync` (general, hand-read bool → S+0xe0 bit 6, 0x140187674; the host copies it to W+0x1b8 bit 2
    /// at 0x140114d17). Each host frame (0x140113510–0x1401135e8) then sleeps until the first image object's
    /// (type 1) texture-0 sprite frame ends: remaining = frames[+0x9c].frametime − elapsed +0xa0 (0 if not positive or
    /// not a sprite sheet), divided by the playback rate when rate > 0.001, capped at 0.25 s, Sleep(ms); the normal fps
    /// cap still follows. Returns that delay in seconds, nil when the flag is off (for the host's frame pacing).
    public func spriteSheetRefreshDelay(rate: Float) -> Double? {
        guard jsonBool(general["spritesheetrefreshsync"], default: false) else { return nil }
        var d: Float = 0
        if let img = objects.first(where: { $0 is ImageLayer }) as? ImageLayer, let gpu = img.material.textures[0]?.gpu,
           gpu.tex.flags.contains(.spriteSheet), !gpu.tex.frames.isEmpty {
            let i = gpu.spriteIndex >= 0 && gpu.spriteIndex < gpu.tex.frames.count ? gpu.spriteIndex : 0
            d = max(gpu.tex.frames[i].frameTime - gpu.spriteTime, 0)
        }
        if rate > 0.001 { d /= rate }
        return Double(min(d, 0.25))
    }

    func spriteFrame(_ tex: TexFile, time: Float) -> TexFile.Frame {
        let total = tex.frames.reduce(Float(0)) { $0 + $1.frameTime }
        guard total > 0 else { return tex.frames[0] }
        var t = time.truncatingRemainder(dividingBy: total)
        for f in tex.frames {
            if t < f.frameTime { return f }
            t -= f.frameTime
        }
        return tex.frames.last!
    }
}
