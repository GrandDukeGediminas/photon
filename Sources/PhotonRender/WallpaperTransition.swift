import Foundation
import Metal
import PhotonCore
import simd

/// The engine's wallpaper-switch transition settings (`browsetransition` in the general config, a playlist's settings
/// object). Parsed by `Transition_ParseSettings` 0x140075790 (docs/re/frame-graph.md §T1).
public struct TransitionSettings: Equatable {
    /// -1 "none" (no overlay), -2 `false` / "none (no flicker)" (the old frame is held until the new wallpaper is
    /// ready, then cut), -3 "random", otherwise the `FADEEFFECT` number (0 fade … 26 boilover).
    public var mode: Int
    /// `transitiontime` in milliseconds (default 500 when the key is absent, 0x140075a2f).
    public var timeMs: Int
    /// `transitionpool` (strings, `atoi`'d) for "random"; empty = every effect.
    public var pool: [Int]

    public init(mode: Int, timeMs: Int, pool: [Int] = []) {
        self.mode = mode; self.timeMs = timeMs; self.pool = pool
    }

    /// The config default of `browsetransition` (0x140048253–0x140048347): `{"transition":"none","transitiontime":1500}`.
    public static let browseDefault = TransitionSettings(mode: -1, timeMs: 1500)

    /// `Transition_ParseSettings` 0x140075790. Only an object is read (tag 7). `transition`: a bool gives 0 (fade) for
    /// true and -2 for false (`lea eax, [rax*2-2]`, 0x140075813); a string "random" gives -3 and reads
    /// `transitionpool` (an array; only its string members count, each `atoi`'d), "none" keeps -1, any other string is
    /// `atoi`'d; other types keep -1. `transitiontime` (int, uint or double) → int, else 500.
    public static func parse(_ value: Any?) -> TransitionSettings {
        var s = TransitionSettings(mode: -1, timeMs: 0)
        guard let o = value as? [String: Any] else { return s }
        let t = o["transition"]
        if let n = t as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
            s.mode = n.boolValue ? 0 : -2
        } else if let str = t as? String {
            if str == "random" {
                s.mode = -3
                if let pool = o["transitionpool"] as? [Any] {
                    s.pool = pool.compactMap { ($0 as? String).map(atoi) }
                }
            } else if str != "none" {
                s.mode = atoi(str)
            }
        }
        s.timeMs = 500
        if let n = o["transitiontime"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { s.timeMs = Int(truncating: n) }
        return s
    }

    public var jsonObject: [String: Any] {
        var o: [String: Any] = ["transitiontime": timeMs]
        switch mode {
        case -1: o["transition"] = "none"
        case -2: o["transition"] = "-2"
        case -3: o["transition"] = "random"; if !pool.isEmpty { o["transitionpool"] = pool.map(String.init) }
        default: o["transition"] = String(mode)
        }
        return o
    }

    public static func atoi(_ s: String) -> Int {
        // CRT atoi: optional whitespace and sign, then leading digits; anything else gives 0.
        var it = s.drop { $0 == " " || $0 == "\t" || $0 == "\n" }
        var sign = 1
        if let c = it.first, c == "-" || c == "+" { sign = c == "-" ? -1 : 1; it = it.dropFirst() }
        var v = 0
        for c in it { guard let d = c.wholeNumberValue, c.isASCII else { break }; v = v &* 10 &+ d }
        return Int(Int32(truncatingIfNeeded: sign * v))
    }

    /// The effect for one switch (0x14006919e–0x140069261): "random" picks `int(rand/32767 · n)` from the pool (clamped to
    /// its range, the value itself unclamped) or, with an empty pool, `min(int(rand/32767 · 27), 26)`; a number is
    /// clamped to 0…26. nil for -1 (no overlay) and -2 (hold, no effect).
    public func pickEffect() -> Int? {
        switch mode {
        case -1, -2: return nil
        case -3:
            let r = Float(Int.random(in: 0...32767)) / 32767
            if pool.isEmpty { return max(0, min(Int(r * 27), 26)) }
            return pool[max(0, min(Int(r * Float(pool.count)), pool.count - 1))]
        default: return max(0, min(mode, 26))
        }
    }
}

/// The wallpaper-switch overlay (`Transition_Thread` 0x140058770, renderer object 0x168 bytes from 0x14005deb0). The engine
/// draws it in its own child window with a premultiplied composition swap chain (DXGI_ALPHA_MODE_PREMULTIPLIED, blending
/// disabled, cleared to 0), so DWM composites it over the live new wallpaper; here the overlay is rendered into a
/// transparent texture and composited over the wallpaper's output with (ONE, ONE_MINUS_SRC_ALPHA).
/// Timing (0x14005a34a–0x14005a3cd): `progress = clamp((elapsed − 0.1) / (transitiontime · 0.001), 0, 1)` where `elapsed`
/// counts from the moment the new wallpaper reported ready (`Transition_StartTick` 0x14006a030); the overlay is removed
/// after the first frame drawn at progress ≥ 1. Until the start it shows the progress-0 frame.
public final class WallpaperTransition {
    public let effect: Int
    public let duration: Double
    public private(set) var startTime: Double?
    /// `g_Hash`, `g_Hash2`: rand()/32767 once per transition (0x14005e0f9–0x14005e130).
    let hash: Float, hash2: Float
    let program: Program
    let snapshot: MTLTexture
    let aspect: Float
    public let width: Int, height: Int
    var overlay: MTLTexture?
    var depth: MTLTexture?
    let vertexBuffer: MTLBuffer?
    let vertexCount: Int
    let device: MTLDevice

    /// Seconds before the progress starts moving once the new wallpaper is ready (`subss xmm6, xmm9`, xmm9 = 0.1).
    public static let startDelay = 0.1

    /// The overlay's `rand()` (0…32767): g_Hash, g_Hash2, g_Random and the shatter sites. Uniformly random by default;
    /// the transition checks seed it (`seed(_:)`) so a frame can be compared between macOS and Linux.
    nonisolated(unsafe) static var rand: () -> Int = { Int.random(in: 0...32767) }

    /// MSVC's `rand()` from `srand(seed)` (the engine seeds it from QueryPerformanceCounter, 0x140058770).
    public static func seed(_ seed: UInt32) {
        var state = seed
        rand = {
            state = state &* 214013 &+ 2531011
            return Int((state >> 16) & 0x7fff)
        }
    }

    /// `snapshot` is the old wallpaper's last frame (the engine reads it back through the wallpaper's vt+0x60 and uploads
    /// it as B8G8R8A8_UNORM). Its size is the overlay size (the engine uses the window's client size for the viewport,
    /// `g_Width`/`g_Height` and the aspect).
    public init(device: MTLDevice, engineAssets: URL, effect: Int, timeMs: Int, snapshot: MTLTexture,
                commandQueue: MTLCommandQueue) throws {
        self.device = device
        self.effect = effect
        duration = Double(timeMs) * 0.001
        hash = Float(Self.rand()) / 32767
        hash2 = Float(Self.rand()) / 32767
        width = snapshot.width; height = snapshot.height
        aspect = height > 0 ? Float(width) / Float(height) : 1
        program = try Program.get(device: device, engineAssets: engineAssets, effect: effect)

        // Snapshot texture: one level, or (shader binds g_Texture0MipMapped, flag 1) a full chain whose levels are built
        // with dx11playlistgaussian from the level above (0x140059bb1–0x14005a14e).
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: snapshot.pixelFormat, width: width, height: height,
                                                         mipmapped: program.flags & 1 != 0)
        d.usage = [.shaderRead, .renderTarget]
        d.storageMode = .private
        let tex = device.makeTexture(descriptor: d)!
        tex.label = "transitionSnapshot"
        let cb = commandQueue.makeCommandBuffer()!
        let blit = cb.makeBlitCommandEncoder()!
        blit.copy(from: snapshot, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: tex, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        if program.flags & 1 != 0 { try Self.gaussianMips(tex, device: device, engineAssets: engineAssets, commandBuffer: cb) }
        cb.commit()
        self.snapshot = tex

        // Geometry: effect 23's VS takes TEXCOORD1 (flag 2): the glass-shatter mesh (0x14005cd80), no GS. Every other effect
        // draws one point through `dx11playlisttransition.geom` (16: the bricks, otherwise a fullscreen strip), run by the
        // shared geometry-shader emulation (GeometryEmulation); the GS ignores the point's attributes.
        var verts: [Float] = []
        if program.flags & 2 != 0 {
            verts = Self.shatterMesh(aspect: aspect)
        } else {
            verts = [Float](repeating: 0, count: program.stride)
        }
        vertexCount = verts.count / program.stride
        vertexBuffer = verts.isEmpty ? nil : device.makeBuffer(bytes: verts, length: verts.count * 4, options: .storageModeShared)
    }

    /// `Transition_StartTick` 0x14006a030 sets the start once the new wallpaper's vt+0x78 says it is ready (scene: W+0x1b8
    /// bit 0), or after 3 s (0.5 s for web and application wallpapers, types 2 and 3) without it.
    public func start(at time: Double) { if startTime == nil { startTime = time } }

    public func progress(at time: Double) -> Float {
        guard let s = startTime else { return 0 }
        let p = Float(time - s - Self.startDelay) / Float(duration)
        if p.isNaN || !(p < 1) { return p.isNaN ? 0 : 1 }
        return max(p, 0)
    }

    public func isFinished(at time: Double) -> Bool { progress(at: time) >= 1 }

    /// Draws the overlay at `time` over `output` (which holds the new wallpaper's frame, or black while it loads).
    public func encode(over output: MTLTexture, commandBuffer: MTLCommandBuffer, time: Double) {
        let p = progress(at: time)
        if overlay == nil {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            overlay = device.makeTexture(descriptor: d)
            overlay?.label = "transitionOverlay"
            if program.flags & 2 != 0 {
                let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
                dd.usage = .renderTarget
                dd.storageMode = .private
                depth = device.makeTexture(descriptor: dd)
            }
        }
        guard let overlay else { return }
        // Pass 1 (0x14005a4ef–0x14005a78a): viewport = client size, clear RTV to 0 and DSV to 1, blend disabled,
        // cull none, depth LESS with writes.
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = overlay
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        if let depth {
            rp.depthAttachment.texture = depth
            rp.depthAttachment.loadAction = .clear
            rp.depthAttachment.clearDepth = 1
            rp.depthAttachment.storeAction = .dontCare
        }
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.label = "transition \(effect)"
        enc.setRenderPipelineState(program.pipeline)
        if depth != nil { enc.setDepthStencilState(program.depthState) }
        enc.setCullMode(.none)
        var cbuf = constants(progress: p)
        enc.setVertexBytes(&cbuf, length: MemoryLayout<Constants>.size, index: 0)
        enc.setFragmentBytes(&cbuf, length: MemoryLayout<Constants>.size, index: 0)
        enc.setFragmentTexture(snapshot, index: 0)
        if let n = program.noise { enc.setFragmentTexture(n, index: 1) }
        if let c = program.clouds { enc.setFragmentTexture(c, index: 2) }
        enc.setFragmentSamplerState(program.clampSampler, index: 0)
        enc.setFragmentSamplerState(program.wrapSampler, index: 1)
        if let gs = program.geometry, let vb = vertexBuffer {
            enc.setVertexBuffer(vb, offset: 0, index: ShaderCompiler.vertexBufferIndex)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: gs.listVertexCount, instanceCount: 1)
        } else if let vb = vertexBuffer {
            enc.setVertexBuffer(vb, offset: 0, index: ShaderCompiler.vertexBufferIndex)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        }
        enc.endEncoding()

        // Pass 2: DWM's composition of the premultiplied swap chain over the wallpaper window.
        let cp = MTLRenderPassDescriptor()
        cp.colorAttachments[0].texture = output
        cp.colorAttachments[0].loadAction = .load
        cp.colorAttachments[0].storeAction = .store
        guard let c = commandBuffer.makeRenderCommandEncoder(descriptor: cp) else { return }
        c.label = "transition composite"
        c.setRenderPipelineState(Composite.shared(device).pipeline(output.pixelFormat))
        c.setFragmentTexture(overlay, index: 0)
        c.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        c.endEncoding()
    }

    /// The old wallpaper's frame as the engine reads it back for the overlay (vt+0x60 → `R_ReadBackbuffer`
    /// 0x14009b7b0): BGRA8, opaque; an fp16 EDR frame goes through passthroughlinear first (frame-graph §T5).
    public static func resolveSnapshot(_ source: MTLTexture, into destination: MTLTexture, hdrScale: Float = 1,
                                       commandBuffer: MTLCommandBuffer) {
        Composite.shared(source.device).resolveSnapshot(source, into: destination, hdrScale: hdrScale, commandBuffer: commandBuffer)
    }

    /// A held old frame (−2, or −1's frozen frame) drawn over `output` through the overlay composite (opaque, so a copy;
    /// decoded to linear over an fp16 EDR output).
    public static func drawHeld(_ snapshot: MTLTexture, over output: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let cp = MTLRenderPassDescriptor()
        cp.colorAttachments[0].texture = output
        cp.colorAttachments[0].loadAction = .load
        cp.colorAttachments[0].storeAction = .store
        guard let c = commandBuffer.makeRenderCommandEncoder(descriptor: cp) else { return }
        c.label = "held frame"
        c.setRenderPipelineState(Composite.shared(snapshot.device).pipeline(output.pixelFormat))
        c.setFragmentTexture(snapshot, index: 0)
        c.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        c.endEncoding()
    }

    /// `g_bufDynamic` (0xa0 bytes, filled at 0x14005a415–0x14005a4d4).
    struct Constants {
        var progress: Float, hash: Float, hash2: Float, random: Float
        var aspect: Float, width: Float, height: Float, pad: Float = 0
        var viewProjection: simd_float4x4
        var viewProjectionInv: simd_float4x4
    }

    func constants(progress p: Float) -> Constants {
        let vp = Self.viewProjection(aspect: aspect)
        // g_Random: rand()/32767 every frame (0x14005a430).
        return Constants(progress: p, hash: hash, hash2: hash2, random: Float(Self.rand()) / 32767,
                         aspect: height > 0 ? aspect : 1, width: Float(width), height: Float(height),
                         viewProjection: vp, viewProjectionInv: vp.inverse)
    }

    /// The glass-shatter camera (0x140058c3f–0x140058e5e): world = scale(2, 2, 1) · translate(0, 0, −1/(tan(π/4) · 0.5)),
    /// projection = XMMatrixPerspectiveFovRH(π/2, aspect, 0.1, 100) (0x14005b5b0), row-vector product W·P. The engine
    /// stores its transpose, so the HLSL (column_major) matrix equals W·P; a simd matrix built from those rows has the
    /// same memory layout.
    static func viewProjection(aspect: Float) -> simd_float4x4 {
        let dist = 1 / (tanf(Float.pi / 4) * 0.5)
        let w = simd_float4x4(rows: [SIMD4(2, 0, 0, 0), SIMD4(0, 2, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, -dist, 1)])
        let h: Float = 1 / tanf(Float.pi / 4), zn: Float = 0.1, zf: Float = 100
        let f = zf / (zn - zf)
        let p = simd_float4x4(rows: [SIMD4(h / aspect, 0, 0, 0), SIMD4(0, h, 0, 0), SIMD4(0, 0, f, -1), SIMD4(0, 0, f * zn, 0)])
        return w * p
    }

    // MARK: - Geometry

    /// Glass-shatter mesh (`Transition_BuildShatterMesh` 0x14005cd80): n = clamp(int(rand/32767 · 11 + 35), 35, 45) random
    /// sites in [−1, 1]² (y drawn first), Voronoi facets inside the rect (−1, −1, 1, 1) (`CreateVoronoiFacets` in
    /// cloneextensions64.dll, ported in VoronoiFacets.swift). Per facet, with
    /// c = its bounding-box centre: a front fan (z 0, normal +z), a back fan (z −0.006, normal −z) and a wall quad per
    /// edge (normal (dy, −dx, 0)/len of edge i → i+1). Vertex: POSITION (x·aspect, y, z), TEXCOORD0 (x/2 + ½, ½ − y/2),
    /// TEXCOORD1 centre (cx·aspect, cy, −0.003), NORMAL — 11 floats.
    static func shatterMesh(aspect: Float, sites given: [SIMD2<Float>]? = nil) -> [Float] {
        var sites = given ?? []
        if given == nil {
            func r() -> Float { Float(Self.rand()) / 32767 }
            let n = max(35, min(Int(r() * 11 + 35), 45))
            for _ in 0..<n { let y = r() * 2 - 1; let x = r() * 2 - 1; sites.append(SIMD2(x, y)) }
        }
        var out: [Float] = []
        let zBack: Float = -0.006, zCenter: Float = -0.003
        // Facets in the DLL's order (sites sorted by y then x), each counter-clockwise from its first graph edge
        // (VoronoiFacets, a port of cloneextensions64.dll CreateVoronoiFacets checked against the DLL under emulation).
        for facet in VoronoiFacets.generate(sites: sites) {
            let poly = facet.polygon
            let lo = poly.reduce(SIMD2<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)) { simd_min($0, $1) }
            let hi = poly.reduce(SIMD2<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)) { simd_max($0, $1) }
            let c = (hi - lo) * 0.5 + lo
            func v(_ p: SIMD2<Float>, _ z: Float, _ n: SIMD3<Float>) {
                out += [p.x * aspect, p.y, z, p.x * 0.5 + 0.5, 0.5 - p.y * 0.5, c.x * aspect, c.y, zCenter, n.x, n.y, n.z]
            }
            let k = poly.count
            for t in 1..<(k - 1) {
                v(poly[0], 0, SIMD3(0, 0, 1)); v(poly[t + 1], 0, SIMD3(0, 0, 1)); v(poly[t], 0, SIMD3(0, 0, 1))
                v(poly[0], zBack, SIMD3(0, 0, -1)); v(poly[t], zBack, SIMD3(0, 0, -1)); v(poly[t + 1], zBack, SIMD3(0, 0, -1))
            }
            for a in 0..<k {
                let b = (a + 1) % k
                let d = poly[a] - poly[b]
                let len = (d.x * d.x + d.y * d.y).squareRoot()
                let n = len > 0 ? SIMD3<Float>(d.y / len, -d.x / len, 0) : SIMD3<Float>(0, 0, 0)
                v(poly[a], 0, n); v(poly[b], zBack, n); v(poly[a], zBack, n)
                v(poly[a], 0, n); v(poly[b], 0, n); v(poly[b], zBack, n)
            }
        }
        return out
    }

    // MARK: - Mips

    /// Level i ≥ 1 = dx11playlistgaussian (3×3 weights 21/31/48 ÷ 256, taps 3.333 texels apart) of level i − 1, drawn
    /// with the engine's 6-vertex quad (0x140059cf1–0x140059d6e) and the clamp sampler.
    static func gaussianMips(_ tex: MTLTexture, device: MTLDevice, engineAssets: URL, commandBuffer: MTLCommandBuffer) throws {
        let g = try Gaussian.get(device: device, engineAssets: engineAssets)
        let quad: [Float] = [-1, 1, 0, 0, 0, 1, -1, 0, 1, 1, -1, -1, 0, 0, 1, 1, 1, 0, 1, 0, 1, -1, 0, 1, 1, -1, 1, 0, 0, 0]
        for level in 1..<tex.mipmapLevelCount {
            guard let src = tex.makeTextureView(pixelFormat: tex.pixelFormat, textureType: .type2D, levels: (level - 1)..<level, slices: 0..<1)
            else { continue }
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = tex
            rp.colorAttachments[0].level = level
            rp.colorAttachments[0].loadAction = .dontCare
            rp.colorAttachments[0].storeAction = .store
            guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { continue }
            enc.setRenderPipelineState(try g.pipeline(tex.pixelFormat))
            quad.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: ShaderCompiler.vertexBufferIndex) }
            enc.setFragmentTexture(src, index: 0)
            enc.setFragmentSamplerState(g.sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.endEncoding()
        }
    }

    // MARK: - Programs

    /// One compiled effect: `dx11playlisttransition` with `FADEEFFECT = n` (0x14005c390 compiles vs_4_0/gs_4_0/ps_4_0 and
    /// derives flags from reflection: 1 = the PS binds `g_Texture0MipMapped`, 2 = the VS input has TEXCOORD1 (no GS then),
    /// 4 = the PS binds `g_Texture1Noise` or `g_Texture2Clouds`; 0x14005c776–0x14005c883).
    final class Program {
        let pipeline: MTLRenderPipelineState
        let depthState: MTLDepthStencilState
        let clampSampler: MTLSamplerState
        let wrapSampler: MTLSamplerState
        let flags: Int
        let stride: Int
        /// The emulated geometry stage (all effects but the shatter, flag 2).
        let geometry: GeometryEmulation.Result?
        let noise: MTLTexture?
        let clouds: MTLTexture?

        private static var cache: [String: Program] = [:]
        private static let lock = NSLock()

        static func get(device: MTLDevice, engineAssets: URL, effect: Int) throws -> Program {
            let key = "\(device.registryID).\(effect)"
            if let p = lock.withLock({ cache[key] }) { return p }
            let p = try Program(device: device, engineAssets: engineAssets, effect: effect)
            lock.withLock { cache[key] = p }
            return p
        }

        init(device: MTLDevice, engineAssets: URL, effect: Int) throws {
            let dir = engineAssets.appendingPathComponent("shaders/HLSL")
            let vsSrc = try String(contentsOf: dir.appendingPathComponent("dx11playlisttransition.vert"), encoding: .utf8)
            let psSrc = try String(contentsOf: dir.appendingPathComponent("dx11playlisttransition.frag"), encoding: .utf8)
            let define = "#define FADEEFFECT \(effect)\n"
            let compiler = ShaderCompiler()
            // Reflection on the untouched source gives the engine's flags; the compiled PS aliases g_Texture0MipMapped
            // to g_Texture0 (both are t0 in the engine, one SRV with or without mips).
            let reflect = try compiler.compile(hlsl: define + psSrc, stage: .fragment).reflection
            let images = ((reflect["separate_images"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            let vs = try compiler.compile(hlsl: define + vsSrc, stage: .vertex)
            let inputs = (vs.reflection["inputs"] as? [[String: Any]]) ?? []
            var f = 0
            if images.contains("g_Texture0MipMapped") { f |= 1 }
            if inputs.count > 2 { f |= 2 }
            if images.contains("g_Texture1Noise") || images.contains("g_Texture2Clouds") { f |= 4 }
            flags = f
            let ps = try compiler.compile(hlsl: define + psSrc.replacingOccurrences(
                of: "Texture2D g_Texture0MipMapped:register(t0);", with: "#define g_Texture0MipMapped g_Texture0"), stage: .fragment)

            // The GS (0x14005c390 compiles gs_4_0 unless the VS takes TEXCOORD1) folded into the vertex function.
            var vsStage = vs
            var gsResult: GeometryEmulation.Result?
            if f & 2 == 0 {
                let gsSrc = try String(contentsOf: dir.appendingPathComponent("dx11playlisttransition.geom"), encoding: .utf8)
                let e = try GeometryEmulation.buildRaw(vertexHLSL: vsSrc, geometryHLSL: gsSrc, defines: define)
                vsStage = try compiler.compile(hlsl: e.hlsl, stage: .vertex)
                gsResult = e
            }
            geometry = gsResult
            let vlib = try device.makeLibrary(source: vsStage.msl, options: nil)
            let flib = try device.makeLibrary(source: ps.msl, options: nil)
            let pd = MTLRenderPipelineDescriptor()
            pd.label = "dx11playlisttransition FADEEFFECT=\(effect)"
            pd.vertexFunction = vlib.makeFunction(name: vsStage.entryPoint)
            pd.fragmentFunction = flib.makeFunction(name: ps.entryPoint)
            pd.colorAttachments[0].pixelFormat = .bgra8Unorm
            pd.colorAttachments[0].isBlendingEnabled = false
            if f & 2 != 0 { pd.depthAttachmentPixelFormat = .depth32Float }
            // Input layout (0x14005cad0): POSITION float3, TEXCOORD0 float2 [, TEXCOORD1 float3, NORMAL float3].
            let vd = MTLVertexDescriptor()
            let formats: [MTLVertexFormat] = [.float3, .float2, .float3, .float3]
            let sizes = [3, 2, 3, 3]
            var offset = 0
            for (i, _) in inputs.enumerated() where i < 4 {
                vd.attributes[i].format = formats[i]
                vd.attributes[i].offset = offset * 4
                vd.attributes[i].bufferIndex = ShaderCompiler.vertexBufferIndex
                offset += sizes[i]
            }
            stride = offset
            vd.layouts[ShaderCompiler.vertexBufferIndex].stride = offset * 4
            if gsResult != nil { vd.layouts[ShaderCompiler.vertexBufferIndex].stepFunction = .perInstance }
            pd.vertexDescriptor = vd
            pipeline = try device.makeRenderPipelineState(descriptor: pd)

            // Depth-stencil +0xc0 (0x14005e676): DepthEnable, write ALL, LESS. Samplers +0x90/+0x98 (0x14005e4d9–0x14005e592):
            // MIN_MAG_MIP_LINEAR, CLAMP / WRAP, MaxLOD FLT_MAX.
            let ds = MTLDepthStencilDescriptor()
            ds.depthCompareFunction = .less
            ds.isDepthWriteEnabled = true
            depthState = device.makeDepthStencilState(descriptor: ds)!
            func sampler(_ mode: MTLSamplerAddressMode) -> MTLSamplerState {
                let s = MTLSamplerDescriptor()
                s.minFilter = .linear; s.magFilter = .linear; s.mipFilter = .linear
                s.sAddressMode = mode; s.tAddressMode = mode; s.rAddressMode = mode
                return device.makeSamplerState(descriptor: s)!
            }
            clampSampler = sampler(.clampToEdge)
            wrapSampler = sampler(.repeat)
            // Flag 4: assets/materials/util/noise.png and clouds_256.png as 256×256 B8G8R8A8 (0x14005990d–0x140059b71).
            func png(_ name: String) -> MTLTexture? {
                guard f & 4 != 0, let data = try? Data(contentsOf: engineAssets.appendingPathComponent("materials/util/" + name)),
                      let img = TexFile.decodeStraightRGBA(data) else { return nil }
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: img.width, height: img.height, mipmapped: false)
                d.usage = .shaderRead
                let t = device.makeTexture(descriptor: d)
                img.pixels.withUnsafeBytes {
                    t?.replace(region: MTLRegionMake2D(0, 0, img.width, img.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: img.width * 4)
                }
                t?.label = name
                return t
            }
            noise = png("noise.png")
            clouds = png("clouds_256.png")
        }
    }

    final class Gaussian {
        let vs: ShaderCompiler.CompiledStage, ps: ShaderCompiler.CompiledStage
        let device: MTLDevice
        let sampler: MTLSamplerState
        private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
        private static var cache: [UInt64: Gaussian] = [:]
        private static let lock = NSLock()

        static func get(device: MTLDevice, engineAssets: URL) throws -> Gaussian {
            if let g = lock.withLock({ cache[device.registryID] }) { return g }
            let g = try Gaussian(device: device, engineAssets: engineAssets)
            lock.withLock { cache[device.registryID] = g }
            return g
        }

        init(device: MTLDevice, engineAssets: URL) throws {
            self.device = device
            let dir = engineAssets.appendingPathComponent("shaders/HLSL")
            let compiler = ShaderCompiler()
            vs = try compiler.compile(hlsl: String(contentsOf: dir.appendingPathComponent("dx11playlistgaussian.vert"), encoding: .utf8), stage: .vertex)
            ps = try compiler.compile(hlsl: String(contentsOf: dir.appendingPathComponent("dx11playlistgaussian.frag"), encoding: .utf8), stage: .fragment)
            let s = MTLSamplerDescriptor()
            s.minFilter = .linear; s.magFilter = .linear; s.mipFilter = .linear
            s.sAddressMode = .clampToEdge; s.tAddressMode = .clampToEdge
            sampler = device.makeSamplerState(descriptor: s)!
        }

        func pipeline(_ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            if let p = pipelines[format] { return p }
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = try device.makeLibrary(source: vs.msl, options: nil).makeFunction(name: vs.entryPoint)
            pd.fragmentFunction = try device.makeLibrary(source: ps.msl, options: nil).makeFunction(name: ps.entryPoint)
            pd.colorAttachments[0].pixelFormat = format
            let vd = MTLVertexDescriptor()
            vd.attributes[0].format = .float3; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = ShaderCompiler.vertexBufferIndex
            vd.attributes[1].format = .float2; vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = ShaderCompiler.vertexBufferIndex
            vd.layouts[ShaderCompiler.vertexBufferIndex].stride = 20
            pd.vertexDescriptor = vd
            let p = try device.makeRenderPipelineState(descriptor: pd)
            pipelines[format] = p
            return p
        }
    }

    /// Premultiplied "over" of the overlay onto the wallpaper output (DWM composition of an
    /// DXGI_ALPHA_MODE_PREMULTIPLIED swap chain), pixel for pixel.
    final class Composite {
        private static var instances: [UInt64: Composite] = [:]
        private static let lock = NSLock()
        static func shared(_ device: MTLDevice) -> Composite {
            lock.withLock {
                if let c = instances[device.registryID] { return c }
                let c = Composite(device: device)
                instances[device.registryID] = c
                return c
            }
        }
        let device: MTLDevice
        let library: MTLLibrary
        private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
        init(device: MTLDevice) {
            self.device = device
            library = try! device.makeLibrary(source: """
            #include <metal_stdlib>
            using namespace metal;
            struct V { float4 p [[position]]; };
            vertex V compV(uint i [[vertex_id]]) {
                float2 uv = float2((i << 1) & 2, i & 2);
                V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); return o;
            }
            fragment float4 compF(V in [[stage_in]], texture2d<float> t [[texture(0)]]) {
                uint2 c = min(uint2(in.p.xy), uint2(t.get_width() - 1, t.get_height() - 1));
                return t.read(c);
            }
            // Over an extended-linear (EDR) output: the 8-bit overlay is sRGB content, which the compositor decodes
            // before blending (DWM composing the B8G8R8A8 swap chain over an scRGB desktop). Colour is un-premultiplied,
            // decoded with the sRGB curve and premultiplied again.
            fragment float4 compLinearF(V in [[stage_in]], texture2d<float> t [[texture(0)]]) {
                uint2 c = min(uint2(in.p.xy), uint2(t.get_width() - 1, t.get_height() - 1));
                float4 o = t.read(c);
                if (o.a <= 0) return float4(0);
                float3 e = saturate(o.rgb / o.a);
                float3 l = select(pow((e + 0.055) / 1.055, 2.4), e / 12.92, e <= 0.04045);
                return float4(l * o.a, o.a);
            }
            // The snapshot readback (`R_ReadBackbuffer` 0x14009b7b0): an R16G16B16A16_FLOAT back buffer is first drawn
            // with materials/util/backbufferpassthrough.json (shader passthroughlinear: rgb = max(1.055·(rgb /
            // g_HDRParams.x)^(1/2.4) − 0.055, 0)) into an R8G8B8A8_UNORM target; every readback then swaps R and B
            // and forces alpha to 0xff (0x14009bc70–0x14009bca1).
            fragment float4 snapF(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant float2 &hdr [[buffer(0)]]) {
                uint2 c = min(uint2(in.p.xy), uint2(t.get_width() - 1, t.get_height() - 1));
                float3 v = t.read(c).rgb;
                if (hdr.y > 0) v = max(1.055 * pow(v / hdr.x, 0.416666667) - 0.055, 0.0);
                return float4(v, 1);
            }
            """, options: nil)
        }
        private var snapPipeline: MTLRenderPipelineState?
        /// Copies `source` (the old wallpaper's frame, 8-bit or fp16 EDR) into `destination` (BGRA8) as the engine's
        /// readback does: the fp16 path through passthroughlinear with `hdrScale` = g_HDRParams.x (white / 80 nits; 1
        /// for photon2's EDR, where 1.0 is SDR white), alpha forced to 1.
        func resolveSnapshot(_ source: MTLTexture, into destination: MTLTexture, hdrScale: Float, commandBuffer: MTLCommandBuffer) {
            if snapPipeline == nil {
                let pd = MTLRenderPipelineDescriptor()
                pd.vertexFunction = library.makeFunction(name: "compV")
                pd.fragmentFunction = library.makeFunction(name: "snapF")
                pd.colorAttachments[0].pixelFormat = destination.pixelFormat
                snapPipeline = try? device.makeRenderPipelineState(descriptor: pd)
            }
            guard let p = snapPipeline else { return }
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = destination
            rp.colorAttachments[0].loadAction = .dontCare
            rp.colorAttachments[0].storeAction = .store
            guard let e = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { return }
            e.label = "transition snapshot"
            e.setRenderPipelineState(p)
            var hdr = SIMD2<Float>(hdrScale, source.pixelFormat == .rgba16Float ? 1 : 0)
            e.setFragmentBytes(&hdr, length: 8, index: 0)
            e.setFragmentTexture(source, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        func pipeline(_ format: MTLPixelFormat) -> MTLRenderPipelineState {
            if let p = pipelines[format] { return p }
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = library.makeFunction(name: "compV")
            pd.fragmentFunction = library.makeFunction(name: format == .rgba16Float ? "compLinearF" : "compF")
            pd.colorAttachments[0].pixelFormat = format
            pd.colorAttachments[0].isBlendingEnabled = true
            pd.colorAttachments[0].sourceRGBBlendFactor = .one
            pd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            pd.colorAttachments[0].sourceAlphaBlendFactor = .one
            pd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            let p = try! device.makeRenderPipelineState(descriptor: pd)
            pipelines[format] = p
            return p
        }
    }
}
