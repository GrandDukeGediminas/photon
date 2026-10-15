import AppKit
import Foundation
import Metal
import PhotonCore

/// A GPU texture created from a `.tex` file, plus the metadata shaders need.
public final class GPUTexture {
    /// The texture created for the file. An animated GIF user texture keeps its frames apart (`gif`); `texture` returns the
    /// current one, so every consumer (draws, the layerimage capture, script attachment textures) sees the frame the engine's
    /// single D3D texture holds after its Map/WRITE_DISCARD rewrite (0x1400ee9e0; session8-leftovers MI7).
    public let baseTexture: MTLTexture
    public var texture: MTLTexture {
        if let gif { return gif.current }
        return imageIndex > 0 && imageIndex < images.count ? images[imageIndex] : baseTexture
    }
    /// Every image of the file (`baseTexture` first). A sprite sheet's frames name the image they are cut from.
    var images: [MTLTexture] = []
    /// The image the current sprite frame uses: texture +0x98, written with the frame's image index by
    /// `Texture_UpdateSpriteUniforms` (0x14015f0d0, ev_47fe8883…) and read when the texture is bound.
    var imageIndex = 0
    public let sampler: MTLSamplerState
    public let tex: TexFile
    /// Set for video textures (flag 0x20, or a bound video file): `texture` receives each decoded frame.
    public private(set) var video: VideoTexture?
    /// Animated GIF user texture (UserTexture +0xe0): the frame bound in place of `texture`.
    var gif: AnimatedGIF?
    /// Sprite-sheet clock: texture +0x9c frame index, +0xa0 time in the frame, +0xa4 frame counter of the last step
    /// (zeroed by the texture base ctor 0x14015eb90; `advanceSprite` in Draw.swift).
    var spriteIndex = 0
    var spriteTime: Float = 0
    var spriteLastFrame = 0
    /// (textureWidth, textureHeight, imageWidth, imageHeight)
    public var resolution: SIMD4<Float> {
        [Float(tex.textureWidth), Float(tex.textureHeight), Float(tex.imageWidth), Float(tex.imageHeight)]
    }

    init(texture: MTLTexture, sampler: MTLSamplerState, tex: TexFile) {
        self.baseTexture = texture
        self.sampler = sampler
        self.tex = tex
    }

    init(video: VideoTexture, sampler: MTLSamplerState, tex: TexFile) {
        self.baseTexture = video.texture
        self.sampler = sampler
        self.tex = tex
        self.video = video
    }

    /// A video shown through its own texture (the cropped video user texture).
    init(video: VideoTexture, texture: MTLTexture, sampler: MTLSamplerState, tex: TexFile) {
        self.baseTexture = texture
        self.sampler = sampler
        self.tex = tex
        self.video = video
    }
}

/// `AdvanceGIF` (resourceutil64.dll 0x1800021d0, called by UserTexture vt+0x38 0x1400ee9e0 with the frame time C+0x14c,
/// and once with 0 by the ctor): unless it is the first call, the frame's remaining time (+0x8968) is reduced by dt and
/// nothing changes while it stays above 0; otherwise the next frame is decoded (stb_image GIF, looping forever: the end
/// sentinel rewinds to the first frame, 0x18000225f) and its delay (+0x8960, ms = 10 × the GIF's centiseconds; /1000 at
/// 0x180002316) is added to the remaining time. At most one frame per call; a zero delay steps every frame. vt+0x38 runs
/// from `Texture_UpdateSpriteUniforms` 0x14015f317 (every slot Material_Apply binds) and returns early when the GIF
/// object's frame stamp (+0x18) already equals C+0x144 (0x1400ee9f6–0x1400eea0c): one step per frame in which some draw
/// uses the texture, none in frames where nothing draws it, and no catch-up afterwards.
/// photon2 uploads every frame once and binds the current one (`current`, RenderContext.draw) instead of the engine's
/// Map/WRITE_DISCARD rewrite, so an in-flight frame never sees the next GIF frame.
final class AnimatedGIF {
    let frames: [MTLTexture]
    let delays: [Float]
    private var index = 0
    private var remaining: Float
    private var stamp = Int.min
    var current: MTLTexture { frames[index] }

    init(frames: [MTLTexture], delays: [Float]) {
        self.frames = frames
        self.delays = delays
        remaining = delays.first ?? 0 // the ctor's AdvanceGIF(0) shows frame 0
    }

    func advance(frame counter: Int, dt: Float) {
        guard stamp != counter else { return }
        stamp = counter
        guard frames.count > 1 else { return }
        if remaining > 0 {
            remaining -= dt
            if remaining > 0 { return }
        }
        index = (index + 1) % frames.count
        remaining += delays[index]
    }
}

/// Creates Metal textures for `.tex` files (docs/re/01 §3.3–3.5) and caches them by name.
public final class TextureLoader {
    public let device: MTLDevice
    private let fs: AssetFileSystem
    private var cache: [String: GPUTexture] = [:]
    private var missingLogged: Set<String> = []
    private var samplers: [Int32: MTLSamplerState] = [:]
    /// Sampler flags of user-bound files (`usertextures`): the slot default texture's point/clamp bits.
    public var userTextureFlags: [String: TexFile.Flags] = [:]
    /// Textures built in memory (the GIF scene's compiled `background`), used before the file system.
    public var preloaded: [String: TexFile] = [:]
    /// Live video textures, advanced by `updateVideos` once per frame.
    public private(set) var videos: [VideoTexture] = []

    public init(device: MTLDevice, fs: AssetFileSystem) {
        self.device = device
        self.fs = fs
    }

    /// Loads `materials/<name>.tex`. Returns nil if missing or undecodable.
    public func texture(named name: String) -> GPUTexture? {
        if let hit = cache[name] { return hit }
        if let t = preloaded[name], let gpu = makeTexture(t, label: name) {
            cache[name] = gpu
            return gpu
        }
        if Self.isVideoFile(name) {
            let gpu = videoFileTexture(name) ?? failedVideoTexture(name)
            cache[name] = gpu
            return gpu
        }
        guard let data = fs.read(AssetFileSystem.texturePath(name)),
              let tex = try? TexFile(data: data),
              let gpu = makeTexture(tex, label: name) else { return nil }
        cache[name] = gpu
        return gpu
    }

    /// The built-in error texture (`TexFile.errorTexture`), created once per loader.
    public private(set) lazy var errorTexture: GPUTexture = makeTexture(TexFile.errorTexture, label: "error")!

    /// `TextureMgr_Load` 0x14014cf90 with create = true never returns null: `"error"`, a missing file and a file that
    /// fails to decode all give the error texture object (`Texture_load` 0x1400ec220), and that object is what the
    /// material slot holds (so bound-texture combos see a texture).
    public func textureOrError(named name: String) -> GPUTexture {
        if name == "error" { return errorTexture }
        if let t = texture(named: name) { return t }
        if missingLogged.insert(name).inserted { NSLog("photon: texture %@ missing or unreadable, using the error texture", name) }
        return errorTexture
    }

    func makeTexture(_ tex: TexFile, label: String) -> GPUTexture? {
        if tex.flags.contains(.video) { return makeVideoTexture(tex, label: label) }
        guard let mips = tex.images.first, let texture = makeImage(tex, mips: mips, label: label) else { return nil }
        let gpu = GPUTexture(texture: texture, sampler: sampler(flags: tex.flags, mipmapped: mips.count > 1), tex: tex)
        // Further images (sprite sheets too large for one image, e.g. a 75-frame GIF over 4096×2048 + 4096×1024).
        if tex.images.count > 1 {
            gpu.images = [texture] + tex.images.dropFirst().enumerated().compactMap { i, m in
                makeImage(tex, mips: m, label: "\(label) #\(i + 1)")
            }
        }
        return gpu
    }

    private func makeImage(_ tex: TexFile, mips: [TexFile.Mip], label: String) -> MTLTexture? {
        guard let mip0 = mips.first else { return nil }
        let (pixelFormat, blockBytes, blockSize) = Self.metalFormat(tex.pixelFormat)
        let desc = MTLTextureDescriptor()
        desc.textureType = tex.flags.contains(.volume) ? .type3D : .type2D
        desc.pixelFormat = pixelFormat
        desc.width = max(mip0.width, 1)
        desc.height = max(mip0.height, 1)
        desc.depth = tex.flags.contains(.volume) ? max(mip0.depth, 1) : 1
        desc.mipmapLevelCount = mips.count
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        texture.label = label

        for (level, mip) in mips.enumerated() {
            let w = max(mip.width, 1), h = max(mip.height, 1), d = max(mip.depth, 1)
            let blocksWide = (w + blockSize - 1) / blockSize
            let blocksHigh = (h + blockSize - 1) / blockSize
            let bytesPerRow = blocksWide * blockBytes
            let bytesPerImage = bytesPerRow * blocksHigh
            guard mip.data.count >= bytesPerImage * d else { continue }
            mip.data.withUnsafeBytes { raw in
                texture.replace(region: MTLRegionMake3D(0, 0, 0, w, h, d), mipmapLevel: level, slice: 0,
                                withBytes: raw.baseAddress!, bytesPerRow: bytesPerRow, bytesPerImage: bytesPerImage)
            }
        }
        return texture
    }

    // MARK: - Video (docs/re/01 §3.8)

    /// Decodes the frame for `time` of every video texture into its Metal texture. Call before drawing.
    public func updateVideos(time: Double, commandBuffer: MTLCommandBuffer) {
        for v in videos { v.update(time: time, commandBuffer: commandBuffer) }
        // Cropped video user textures: the engine's player renders the crop rect into a texture of the cropped size.
        if !croppedVideos.isEmpty, let blit = commandBuffer.makeBlitCommandEncoder() {
            for c in croppedVideos {
                blit.copy(from: c.video.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: c.origin,
                          sourceSize: MTLSize(width: c.texture.width, height: c.texture.height, depth: 1),
                          to: c.texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            }
            blit.endEncoding()
        }
        // GIF user textures step when drawn (`AnimatedGIF.advance` from RenderContext.draw).
    }

    private struct CroppedVideo { let video: VideoTexture; let texture: MTLTexture; let origin: MTLOrigin }
    private var croppedVideos: [CroppedVideo] = []

    /// A video user texture without `keepaspect` (UserTexture ctor 0x1400eb570, video branch 0x1400eb705–0x1400eb8f0):
    /// with crop aspect `a` ≠ 0 the player gets the normalised source rect (vt+0x28): when w/h > a, newW = trunc(a·h) and
    /// rect = (d, 0, 1 − d, 1) with d = ½(w − newW)/w; otherwise newH = trunc(w/a) and rect = (0, d, 1, 1 − d) with
    /// d = ½(h − newH)/h; the texture is newW × newH. photon2 blits that pixel rect out of the decoded frame each frame.
    /// A player that fails to open gives the 64×64 empty texture (`failedVideoTexture`).
    public func videoUserTexture(key: String, path: String, aspect: Float, flags: TexFile.Flags) -> GPUTexture? {
        if let hit = cache[key] { return hit }
        userTextureFlags[path] = flags
        guard let full = texture(named: path) else { return nil }
        guard let video = full.video else {
            cache[key] = full // a player that failed to open: the 64×64 texture, uncropped (0x1400eb7d3)
            return full
        }
        let w = video.width, h = video.height
        var cw = w, ch = h
        if aspect != 0, w > 0, h > 0 {
            if Float(w) / Float(h) > aspect { cw = Int(aspect * Float(h)) } else { ch = Int(Float(w) / aspect) }
        }
        guard cw > 0, ch > 0 else { return nil }
        if cw == w && ch == h {
            cache[key] = full
            return full
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: video.texture.pixelFormat, width: cw, height: ch, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .private
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        tex.label = key
        croppedVideos.append(CroppedVideo(video: video, texture: tex, origin: MTLOrigin(x: (w - cw) / 2, y: (h - ch) / 2, z: 0)))
        let info = TexFile(videoWidth: cw, height: ch, flags: flags)
        let gpu = GPUTexture(video: video, texture: tex, sampler: sampler(flags: flags, mipmapped: false, anisotropic: false), tex: info)
        cache[key] = gpu
        return gpu
    }

    /// A video user texture whose player fails to open (UserTexture ctor 0x1400eb784–0x1400eb7be, 0x1400eb8be–0x1400eb908):
    /// the player is released (+0xd8 = null), the size becomes 64×64, no crop is applied (0x1400eb7d3), and the texture is
    /// created from a zero-filled buffer (memset 0x1400eb908; RGBA8, 4 bytes per pixel without the HDR player path) with
    /// the video flag 0x20 (0x1400eb705): transparent black, and g_TextureNResolution reads 64×64.
    func failedVideoTexture(_ name: String) -> GPUTexture? {
        NSLog("photon: video %@ failed to open, using the engine's 64x64 empty texture", name)
        let flags = (userTextureFlags[name] ?? []).union(.video)
        let tex = TexFile.userRGBA(Data(count: 64 * 64 * 4), width: 64, height: 64, flags: flags)
        guard let mip = tex.images.first?.first else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        texture.label = name
        mip.data.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 256) }
        return GPUTexture(texture: texture, sampler: sampler(flags: flags, mipmapped: false, anisotropic: false), tex: tex)
    }

    /// An animated GIF user texture (UserTexture ctor `.gif` branch 0x1400eb9c5–0x1400ebb98, any case: the extension is
    /// lower-cased by 0x1400eaf10): media services OpenGIF/AdvanceGIF (resourceutil64.dll), centre crop like still images
    /// (offsets `trunc(½(w − newW))`, 0x1400eba99–0x1400ebae3), one RGBA8 mip of the cropped size, texture flag 1 added
    /// (0x1400ebaed), so the sampler (0x140099980 at 0x1400ebf5b) is point-filtered.
    public func userGIFTexture(key: String, path: String, aspect: Float, flags: TexFile.Flags) -> GPUTexture? {
        if let hit = cache[key] { return hit }
        let data = path.hasPrefix("/") ? FileManager.default.contents(atPath: path) : fs.read(path)
        guard let data, let anim = TexFile.gifFrames(data), !anim.frames.isEmpty else { return nil }
        var frames: [Data] = []
        var cw = 0, ch = 0
        for f in anim.frames {
            let (px, w, h) = TexFile.centerCrop(f, width: anim.width, height: anim.height, aspect: aspect)
            frames.append(px); cw = w; ch = h
        }
        guard cw > 0, ch > 0 else { return nil }
        let texFlags = flags.union([.noInterpolation, .singleMip])
        let info = TexFile.userRGBA(frames[0], width: cw, height: ch, flags: texFlags)
        guard let gpu = registerUserTexture(key: key, tex: info, flags: texFlags) else { return nil }
        var textures = [gpu.baseTexture]
        for px in frames.dropFirst() {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: cw, height: ch, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .shared
            guard px.count >= cw * ch * 4, let t = device.makeTexture(descriptor: d) else { return gpu }
            t.label = key
            px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: cw * 4) }
            textures.append(t)
        }
        gpu.gif = AnimatedGIF(frames: textures, delays: anim.delays)
        return gpu
    }

    /// Flag 0x20: mip 0 of image 0 is an MP4. The engine passes file + data offset/size to its video player;
    /// AVFoundation needs a standalone file, so the MP4 is written to the cache once.
    func makeVideoTexture(_ tex: TexFile, label: String) -> GPUTexture? {
        guard let mp4 = tex.images.first?.first?.data, let url = VideoTexture.cacheFile(for: mp4),
              let video = VideoTexture(device: device, url: url, label: label) else { return nil }
        if video.width != tex.imageWidth || video.height != tex.imageHeight {
            NSLog("photon: video %@ is %dx%d, .tex says %dx%d", label, video.width, video.height, tex.imageWidth, tex.imageHeight)
        }
        var info = tex
        info.images = [] // drop the MP4 bytes; the decoder reads the cache file
        videos.append(video)
        return GPUTexture(video: video, sampler: sampler(flags: tex.flags, mipmapped: false), tex: info)
    }

    /// A user texture whose value is a video file path (the `videotex` property of video wallpapers).
    func videoFileTexture(_ path: String) -> GPUTexture? {
        var candidates = [URL(fileURLWithPath: path)]
        if !path.hasPrefix("/") { candidates = fs.searchDirectories.map { $0.appendingPathComponent(path) } }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let video = VideoTexture(device: device, url: url, label: url.lastPathComponent) else { return nil }
        // User-texture sampler (Material_ParseTextures → 0x140099980 without anisotropy): flags 8 | the slot default
        // texture's clamp (2) and point (1) bits; linear, single mip. The video wallpaper slot's default is `util/black`
        // (flags 0), so the video wraps.
        let tex = TexFile(videoWidth: video.width, height: video.height, flags: userTextureFlags[path] ?? [.clampUVs])
        videos.append(video)
        return GPUTexture(video: video, sampler: sampler(flags: tex.flags, mipmapped: false, anisotropic: false), tex: tex)
    }

    /// A still-image user texture (`UserTexture` ctor 0x1400eb570), cached under the engine's key. Absolute paths are read
    /// from disk, relative ones through the VFS. nil when the file cannot be decoded (the ctor's failure flag 0x40000000).
    public func cachedTexture(_ name: String) -> GPUTexture? { cache[name] }

    public func userImageTexture(key: String, path: String, aspect: Float, flags: TexFile.Flags) -> GPUTexture? {
        if let hit = cache[key] { return hit }
        let data = path.hasPrefix("/") ? FileManager.default.contents(atPath: path) : fs.read(path)
        guard let data, let tex = TexFile.userImage(data, aspect: aspect, flags: flags) else { return nil }
        return registerUserTexture(key: key, tex: tex, flags: flags)
    }

    /// Uploads a one-mip RGBA8 user texture and caches it under `key` (shared by file and `system` user textures).
    public func registerUserTexture(key: String, tex: TexFile, flags: TexFile.Flags) -> GPUTexture? {
        guard let mip = tex.images.first?.first else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: mip.width, height: mip.height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        texture.label = key
        mip.data.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, mip.width, mip.height), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: mip.width * 4)
        }
        let gpu = GPUTexture(texture: texture, sampler: sampler(flags: flags, mipmapped: false, anisotropic: false), tex: tex)
        cache[key] = gpu
        return gpu
    }

    /// `usershortcut` user-texture source (`Bindings_GetShortcutImage` 0x140174710). The value parses as
    /// `<type>:<6 chars>:<target>` (0x1401708c0: the second field must be exactly 6 characters); `file` targets are cut at
    /// `|` and `cmd` targets at a space (the rest are arguments). The engine asks the host for the target's icon (app vt+0x110,
    /// `web` targets fetch a favicon); when it is not ready it registers a pending request (binding manager +0x148,
    /// callback 0x14017a880) and the user texture fails for now (flag 0x40000000, the slot keeps its texture).
    /// macOS equivalent: the Finder icon of an existing `file`/`cmd` target, rendered at 256×256 (the Windows icon size is
    /// not in the exe); anything else fails like a pending request.
    public static func shortcutIcon(_ value: String) -> (pixels: Data, width: Int, height: Int)? {
        let parts = value.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[1].count == 6, parts[0] == "file" || parts[0] == "cmd" else { return nil }
        let target = String(parts[2].split(separator: parts[0] == "cmd" ? " " : "|", maxSplits: 1).first ?? "")
        guard !target.isEmpty, FileManager.default.fileExists(atPath: target) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: target)
        let n = 256
        var px = Data(count: n * n * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let cg = { () -> CGImage? in var r = NSRect(x: 0, y: 0, width: n, height: n); return icon.cgImage(forProposedRect: &r, context: nil, hints: nil) }() else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return nil }
        // Straight alpha like the decoded images.
        px.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: p.count, by: 4) where p[i + 3] != 0 && p[i + 3] != 255 {
                let a = Int(p[i + 3])
                for c in 0..<3 { p[i + c] = UInt8(min(255, (Int(p[i + c]) * 255 + a / 2) / a)) }
            }
        }
        return (px, n, n)
    }

    public static func isVideoFile(_ name: String) -> Bool {
        ["mp4", "webm", "mov", "m4v", "avi", "mkv"].contains((name as NSString).pathExtension.lowercased())
    }

    /// `sub_140099980`: flag 1 selects point filtering, flag 2 clamps, otherwise wrap.
    /// Non-point textures use trilinear filtering, or 8× anisotropic (inferred default for scene textures).
    func sampler(flags: TexFile.Flags, mipmapped: Bool, anisotropic: Bool = true) -> MTLSamplerState {
        let key = (flags.rawValue & 0x3) | (mipmapped ? 0x100 : 0) | (anisotropic ? 0 : 0x200)
        if let s = samplers[key] { return s }
        let d = MTLSamplerDescriptor()
        let point = flags.contains(.noInterpolation)
        d.minFilter = point ? .nearest : .linear
        d.magFilter = point ? .nearest : .linear
        d.mipFilter = mipmapped ? (point ? .nearest : .linear) : .notMipmapped
        if !point && anisotropic { d.maxAnisotropy = 8 }
        let mode: MTLSamplerAddressMode = flags.contains(.clampUVs) ? .clampToEdge : .repeat
        d.sAddressMode = mode; d.tAddressMode = mode; d.rAddressMode = mode
        let s = device.makeSamplerState(descriptor: d)!
        samplers[key] = s
        return s
    }

    /// TEX format enum to Metal pixel format, bytes per block, and block edge length (`sub_1400d2a20`).
    static func metalFormat(_ f: TexFile.Format) -> (MTLPixelFormat, Int, Int) {
        switch f {
        case .rgba8888: return (.rgba8Unorm, 4, 1)
        case .dxt5: return (.bc3_rgba, 16, 4)
        case .dxt3: return (.bc2_rgba, 16, 4)
        case .dxt1: return (.bc1_rgba, 8, 4)
        case .rg88: return (.rg8Unorm, 2, 1)
        case .r8: return (.r8Unorm, 1, 1)
        case .rg16f: return (.rg16Float, 4, 1)
        case .r16f: return (.r16Float, 2, 1)
        case .bc7: return (.bc7_rgbaUnorm, 16, 4)
        case .rgb10a2: return (.rgb10a2Unorm, 4, 1)
        case .rgba16f: return (.rgba16Float, 8, 1)
        case .r32f: return (.r32Float, 4, 1)
        case .rgba16: return (.rgba16Unorm, 8, 1)
        case .rgba16s: return (.rgba16Snorm, 8, 1)
        }
    }
}
