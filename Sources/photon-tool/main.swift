import Foundation
import CoreGraphics
import ImageIO
import Metal
import AppKit
import WebKit
import PhotonCore
import PhotonRender

let workshop = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Steam/steamapps/workshop/content/431960")
// PHOTON_WE_ASSETS: another assets folder (the CC0 stand-in in Tests/scenes/assets on CI runners).
let engineAssets = ProcessInfo.processInfo.environment["PHOTON_WE_ASSETS"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/common/wallpaper_engine/assets")

/// `tex-dump <file.tex> [props.json]`: TEXB variant selection and every mip's bytes as hex (synthetic TEXB tests).
/// props.json is `{name: {"value": v}}`, as in the engine's project properties.
func texDump(_ args: [String]) {
    guard let path = args.first, let data = FileManager.default.contents(atPath: path) else { print("usage: tex-dump file [props]"); return }
    if args.count > 1, let pd = FileManager.default.contents(atPath: args[1]),
       let props = (try? JSONSerialization.jsonObject(with: pd)) as? [String: Any] {
        var cur: [String: Any] = [:]
        for (k, v) in props { if let o = v as? [String: Any], let x = o["value"] { cur[k] = x } }
        UserProperties.current = cur
    }
    do {
        let tex = try TexFile(data: data)
        print("selected", tex.variantSelection.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        for (i, img) in tex.images.enumerated() {
            for (m, mip) in img.enumerated() {
                print("image \(i) mip \(m) \(mip.width)x\(mip.height) \(mip.data.map { String(format: "%02x", $0) }.joined())")
            }
        }
    } catch { print("error \(error)") }
}

/// Decodes every .tex in every workshop scene.pkg and in the engine assets; prints per-format counts.
func scanTextures() {
    var counts: [String: Int] = [:]
    var failures: [String] = []
    func record(_ name: String, _ data: Data) {
        do {
            let tex = try TexFile(data: data)
            let key = tex.flags.contains(.video) ? "video" : tex.imageFormat == 13 ? "png" : tex.imageFormat == 2 ? "jpeg"
                : tex.imageFormat != -1 ? "fif\(tex.imageFormat)" : "\(tex.format)"
            counts[key, default: 0] += 1
        } catch {
            failures.append("\(name): \(error)")
        }
    }
    let ids = (try? FileManager.default.contentsOfDirectory(atPath: workshop.path)) ?? []
    for id in ids {
        let pkgURL = workshop.appendingPathComponent(id).appendingPathComponent("scene.pkg")
        guard let pkg = try? PackageFile(url: pkgURL) else { continue }
        for name in pkg.entries.keys where name.hasSuffix(".tex") {
            if let data = pkg.read(name) { record("\(id)/\(name)", data) }
        }
    }
    let wsTotal = counts.values.reduce(0, +) + failures.count
    if let e = FileManager.default.enumerator(atPath: engineAssets.path) {
        for case let rel as String in e where rel.hasSuffix(".tex") {
            if let data = FileManager.default.contents(atPath: engineAssets.appendingPathComponent(rel).path) {
                record("assets/\(rel)", data)
            }
        }
    }
    print("workshop textures: \(wsTotal), total: \(counts.values.reduce(0, +) + failures.count)")
    for (k, v) in counts.sorted(by: { $0.value > $1.value }) { print("  \(k): \(v)") }
    print("failures: \(failures.count)")
    failures.prefix(20).forEach { print("  \($0)") }
}

/// Uploads every texture of every workshop wallpaper to Metal.
func uploadTextures() {
    let device = MTLCreateSystemDefaultDevice()!
    var ok = 0, failed: [String] = []
    for id in (try? FileManager.default.contentsOfDirectory(atPath: workshop.path)) ?? [] {
        let fs = AssetFileSystem(engineAssets: engineAssets)
        guard (try? fs.mountWallpaper(file: workshop.appendingPathComponent(id).appendingPathComponent("scene.pkg"))) != nil,
              let pkg = fs.package else { continue }
        let loader = TextureLoader(device: device, fs: fs)
        for name in pkg.entries.keys where name.hasPrefix("materials/") && name.hasSuffix(".tex") {
            let texName = String(name.dropFirst("materials/".count).dropLast(4))
            if loader.texture(named: texName) != nil { ok += 1 } else { failed.append("\(id)/\(texName)") }
        }
    }
    print("uploaded \(ok), failed \(failed.count)")
    failed.prefix(15).forEach { print("  \($0)") }
}

/// Builds and compiles every material pass of every workshop scene; reports failures by first error line.
func compileShaders(limit: Int?) {
    let compiler = ShaderCompiler()
    let device = MTLCreateSystemDefaultDevice()!
    var ok = 0, failures: [String: [String]] = [:]
    var seen = Set<String>()
    let ids = ((try? FileManager.default.contentsOfDirectory(atPath: workshop.path)) ?? []).sorted()
    for id in ids.prefix(limit ?? ids.count) {
        let fs = AssetFileSystem(engineAssets: engineAssets)
        guard (try? fs.mountWallpaper(file: workshop.appendingPathComponent(id).appendingPathComponent("scene.pkg"))) != nil,
              let pkg = fs.package else { continue }
        let builder = ShaderBuilder(sources: ShaderSourceLoader(fs: fs))
        let textures = TextureLoader(device: device, fs: fs)
        for name in pkg.entries.keys.sorted() where name.hasPrefix("materials/") && name.hasSuffix(".json") {
            guard let mat = fs.readJSON(name) as? [String: Any], let passes = mat["passes"] as? [[String: Any]] else { continue }
            for pass in passes {
                guard let shader = pass["shader"] as? String else { continue }
                var combos: [String: Int] = [:]
                for (k, v) in (pass["combos"] as? [String: Any]) ?? [:] { combos[k] = (v as? NSNumber)?.intValue ?? 0 }
                var bound: [Int: Int32] = [:]
                for (i, t) in ((pass["textures"] as? [Any]) ?? []).enumerated() {
                    guard let tname = t as? String else { continue }
                    bound[i] = textures.texture(named: tname)?.tex.rawFormat ?? 0
                }
                let request = ShaderBuilder.Request(shader: shader, combos: combos, boundTextures: bound)
                if !seen.insert("\(id)|\(request.hashValue)").inserted { continue }
                do {
                    let program = try builder.build(request)
                    let vs = try compiler.compile(hlsl: program.vertex.hlsl, stage: .vertex)
                    let fsStage = try compiler.compile(hlsl: program.fragment.hlsl, stage: .fragment)
                    _ = try device.makeLibrary(source: vs.msl, options: nil)
                    _ = try device.makeLibrary(source: fsStage.msl, options: nil)
                    ok += 1
                } catch {
                    let first = "\(error)".split(separator: "\n").first(where: { $0.contains("ERROR") || $0.contains("error") }).map(String.init) ?? "\(error)".prefix(160).description
                    failures[first, default: []].append("\(id) \(shader)")
                }
            }
        }
    }
    print("compiled \(ok) programs, \(failures.values.map(\.count).reduce(0, +)) failed")
    for (msg, list) in failures.sorted(by: { $0.value.count > $1.value.count }).prefix(25) {
        print("  [\(list.count)] \(msg.prefix(200))\n      e.g. \(list.first!)")
    }
}

/// Renders a wallpaper offline to PNG: photon-tool render <workshop id> <out.png> [seconds] [width] [height]
func renderWallpaper(_ args: [String]) {
    SceneRenderer.soundEnabled = false
    SceneRenderer.simulatedScriptClock = true
    let device = MTLCreateSystemDefaultDevice()!
    let id = args[0], out = URL(fileURLWithPath: args[1])
    let t = args.count > 2 ? Double(args[2])! : 1
    let w = args.count > 3 ? Int(args[3])! : 1920, h = args.count > 4 ? Int(args[4])! : 1080
    // Offline renders never start system-audio capture (no permission prompt) unless asked.
    SceneRenderer.audioCaptureEnabled = ProcessInfo.processInfo.environment["PHOTON_AUDIO"] != nil
    let start = Date()
    let dir = id.hasPrefix("/") ? URL(fileURLWithPath: id) : workshop.appendingPathComponent(id)
    let project = SceneRenderer.readProject(dir)
    if project["file"] != nil, ProjectKind.classify(file: (project["file"] as? String) ?? "") == .web {
        renderWeb(dir: dir, project: project, out: out, seconds: t, width: w, height: h)
        return
    }
    let scene: SceneRenderer
    SceneRenderer.resolutionScreenSize = SIMD2(w, h)   // the `resolution` "auto" test uses the render size
    do { scene = try SceneRenderer(device: device, wallpaperDirectory: id.hasPrefix("/") ? URL(fileURLWithPath: id) : workshop.appendingPathComponent(id), engineAssets: engineAssets) }
    catch { print("load failed: \(error)"); exit(1) }
    print("loaded in \(String(format: "%.2f", Date().timeIntervalSince(start)))s, ortho \(scene.orthoSize)")
    // PHOTON_GENERAL='{"alignment":3,"alignmentx":0,…}': the wallpaper's general (UI) properties (docs/re/09 §5).
    if let g = ProcessInfo.processInfo.environment["PHOTON_GENERAL"], let data = g.data(using: .utf8),
       let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        scene.applyGeneralProperties(dict)
    }
    // PHOTON_EDR=<headroom>: a display-HDR scene renders into an fp16 extended-linear target like the app's EDR view;
    // the PNG gets the clipped sRGB encoding and the peak linear value is printed.
    let edr = ProcessInfo.processInfo.environment["PHOTON_EDR"].flatMap(Float.init).map { _ in scene.wantsEDROutput } ?? false
    if edr { scene.edrHeadroom = ProcessInfo.processInfo.environment["PHOTON_EDR"].flatMap(Float.init) ?? 1 }
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: edr ? .rgba16Float : .bgra8Unorm, width: w, height: h, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]
    let tex = device.makeTexture(descriptor: d)!
    scene.simulate(to: max(0, t - 0.1))
    // Warm up a few frames so time-based state (parallax smoothing) settles.
    // PHOTON_WARMUP=<n> (default 3): warm-up frames at 30 fps before t; per-frame accumulators (sprite-sheet and GIF
    // clocks, stale uniforms) advance once per rendered frame like the engine's. Each warm-up frame is waited for, so
    // state read back on the CPU next frame (sprite objects' occlusion-query visibility buffer, Sprite.swift: D3D
    // GetData of the last completed query) holds that frame's result as it would at the engine's frame pacing.
    let warm = ProcessInfo.processInfo.environment["PHOTON_WARMUP"].flatMap(Int.init) ?? 3
    // PHOTON_POINTER=x,y (0…1, top-left origin; default 0.5,0.5): the cursor position the scene sees.
    let renderPointer: CGPoint = {
        let v = (ProcessInfo.processInfo.environment["PHOTON_POINTER"] ?? "").split(separator: ",").compactMap { Double($0) }
        return v.count == 2 ? CGPoint(x: v[0], y: v[1]) : CGPoint(x: 0.5, y: 0.5)
    }()
    for i in 0..<warm {
        guard let wcb = scene.render(into: tex, time: max(0, t - Double(warm - i) / 30), outputSize: CGSize(width: w, height: h),
                                     pointer: renderPointer) else { continue }
        wcb.commit(); wcb.waitUntilCompleted()
    }
    let cb = scene.render(into: tex, time: t, outputSize: CGSize(width: w, height: h), pointer: renderPointer)!
    cb.commit(); cb.waitUntilCompleted()
    if let err = cb.error { print("GPU error: \(err)") }
    print("draws: \(scene.lastDrawCount)")
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    if edr {
        var half = [Float16](repeating: 0, count: w * h * 4)
        tex.getBytes(&half, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        var peak: Float = 0
        func enc(_ x: Float) -> UInt8 {
            let c = min(max(x, 0), 1)
            return UInt8((c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055) * 255 + 0.5)
        }
        for i in 0..<(w * h) {
            let r = Float(half[4 * i]), g = Float(half[4 * i + 1]), b = Float(half[4 * i + 2])
            peak = max(peak, r, g, b)
            bytes[4 * i] = enc(b); bytes[4 * i + 1] = enc(g); bytes[4 * i + 2] = enc(r); bytes[4 * i + 3] = 255
        }
        print("EDR peak linear value: \(peak)")
    } else {
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    }
    if ProcessInfo.processInfo.environment["PHOTON_ALPHA"] != nil {
        for i in stride(from: 0, to: bytes.count, by: 4) { let a = bytes[i + 3]; bytes[i] = a; bytes[i + 1] = a; bytes[i + 2] = a }
    }
    let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(out.path)")
}

/// Prints translated HLSL: photon-tool hlsl <workshop id> <shader> [COMBO=1 ...]
func dumpHLSL(_ args: [String]) {
    let fs = AssetFileSystem(engineAssets: engineAssets)
    _ = try? fs.mountWallpaper(file: workshop.appendingPathComponent(args[0]).appendingPathComponent("scene.pkg"))
    var combos: [String: Int] = [:]
    for kv in args.dropFirst(2) { let p = kv.split(separator: "="); if p.count == 2 { combos[String(p[0])] = Int(p[1]) ?? 0 } }
    let builder = ShaderBuilder(sources: ShaderSourceLoader(fs: fs))
    do {
        // LIGHTCONFIG=<packed C+0x121c> stands in for the scene's general.lightconfig.
        let lightConfig = UInt32(combos.removeValue(forKey: "LIGHTCONFIG") ?? 0)
        let prog = try builder.build(.init(shader: args[1], combos: combos, boundTextures: [0: 0], lightConfig: lightConfig))
        print("// ===== VERTEX =====\n" + prog.vertex.hlsl + "\n// ===== FRAGMENT =====\n" + prog.fragment.hlsl)
        if let g = prog.geometry { print("// ===== GEOMETRY =====\n" + g.hlsl) }
        if let e = prog.emulation {
            print("// ===== EMULATED VERTEX+GEOMETRY (maxvertexcount \(e.maxVertexCount)) =====\n" + e.hlsl)
        } else if let err = prog.emulationError { print("// geometry emulation failed: \(err)") }
    } catch { print(error) }
}

/// Parses every .mdl in the workshop packages and engine assets.
func scanMdl() {
    var ok = 0, failed: [String] = []
    var anims = 0, bones = 0
    for id in (try? FileManager.default.contentsOfDirectory(atPath: workshop.path)) ?? [] {
        guard let pkg = try? PackageFile(url: workshop.appendingPathComponent(id).appendingPathComponent("scene.pkg")) else { continue }
        for name in pkg.entries.keys where name.hasSuffix(".mdl") {
            do {
                let m = try MdlFile(data: pkg.read(name)!)
                let validTracks = m.animations.allSatisfy { a in a.tracks.allSatisfy { $0.samples.count == (a.frames + 1) * 9 } }
                if m.meshes.isEmpty || !validTracks { failed.append("\(id)/\(name): meshes \(m.meshes.count) tracksOK \(validTracks)") } else { ok += 1 }
                anims += m.animations.count; bones += m.bones.count
            } catch { failed.append("\(id)/\(name): \(error)") }
        }
    }
    print("mdl ok \(ok), failed \(failed.count), animations \(anims), bones \(bones)")
    failed.prefix(10).forEach { print("  \($0)") }
}

/// Audio spectrum checks: photon-tool audio-test <seconds> | audio-test synth
/// `synth` feeds sines through the analyzer deterministically; <seconds> first runs synth, then live capture.
func audioTest(_ args: [String]) {
    func row(_ v: [Float]) -> String { v.map { String(format: "%.2f", $0) }.joined(separator: " ") }
    func synth(sampleRate: Double, left: Double, right: Double) {
        let an = AudioAnalyzer(sampleRate: sampleRate)
        let sm = AudioSpectrumSmoother()
        let period = 8, per = Int(sampleRate * Double(period) / 1000)
        var n = 0, spectrum = [Float](repeating: 0, count: 128)
        for _ in 0..<250 { // 2 s of 8 ms polls; frames at the same rate
            var s = [Float](repeating: 0, count: per * 2)
            for j in 0..<per {
                let t = Double(n + j) / sampleRate
                s[2 * j] = Float(0.5 * sin(2 * .pi * left * t)); s[2 * j + 1] = Float(0.5 * sin(2 * .pi * right * t))
            }
            n += per
            if let out = an.poll([AudioPacket(samples: s, channels: 2, silent: false)], periodMs: period) { spectrum = out }
            sm.update(input: spectrum, dt: Float(period) / 1000)
        }
        func expect(_ f: Double) -> Int {
            // Same mapping as the analyzer, including the +1-per-step cap.
            let k = Int((f * Double(an.N) / sampleRate).rounded())
            var prev = 0
            for i in 1...k { prev = min(Int(powf(Float(i - 1) / Float(an.M - 1), 0.25) * 64) % 64, prev + 1) }
            return prev
        }
        print("synth sr=\(Int(sampleRate)) N=\(an.N) M=\(an.M) fill=\(an.fill)  L=\(Int(left)) Hz (expect 64-bin \(expect(left)))  R=\(Int(right)) Hz (expect 64-bin \(expect(right)))")
        let raw = Array(spectrum[0..<64]), rawR = Array(spectrum[64..<128])
        print("  raw L peak bin \(raw.indices.max { raw[$0] < raw[$1] }!) = \(String(format: "%.3f", raw.max()!)), raw R peak bin \(rawR.indices.max { rawR[$0] < rawR[$1] }!) = \(String(format: "%.3f", rawR.max()!))")
        let a = sm.arrays
        print("  64L lit (>0.1): \(a.left64.indices.filter { a.left64[$0] > 0.1 })")
        print("  64R lit (>0.1): \(a.right64.indices.filter { a.right64[$0] > 0.1 })")
        print("  16L: \(row(a.left16))\n  16R: \(row(a.right16))")
    }
    synth(sampleRate: 44100, left: 440, right: 5000)
    synth(sampleRate: 48000, left: 1000, right: 100)
    guard let secs = args.first.flatMap(Double.init) else { return }
    let audio = AudioSystem.shared
    audio.start()
    let sm = AudioSpectrumSmoother()
    let start = Date()
    var last = start, lastPrint = start
    while Date().timeIntervalSince(start) < secs {
        usleep(16_000)
        let now = Date()
        sm.update(input: audio.latestSpectrum(), dt: Float(now.timeIntervalSince(last)))
        last = now
        if now.timeIntervalSince(lastPrint) >= 0.25 {
            lastPrint = now
            print(String(format: "t=%5.2f", now.timeIntervalSince(start)) + "  L16: \(row(sm.arrays.left16))\n        R16: \(row(sm.arrays.right16))")
        }
    }
    audio.stop()
}

switch CommandLine.arguments.dropFirst().first {
case "--version", "version": print("photon-tool \(PhotonVersion.string)")
case "audio-test": audioTest(Array(CommandLine.arguments.dropFirst(2)))
case "scan-mdl": scanMdl()
case "dump-mdl": dumpMdl(Array(CommandLine.arguments.dropFirst(2)))
case "rootmotion-replay": rootMotionReplay(Array(CommandLine.arguments.dropFirst(2)))
case "hlsl": dumpHLSL(Array(CommandLine.arguments.dropFirst(2)))
case "gs-check":
    // photon-tool gs-check <PHOTON_PDUMP file with gsin records> <out.jsonl>
    let a = Array(CommandLine.arguments.dropFirst(2))
    do {
        try GeometryCheck.run(dump: URL(fileURLWithPath: a[0]), out: URL(fileURLWithPath: a[1]),
                              fs: AssetFileSystem(engineAssets: engineAssets), device: MTLCreateSystemDefaultDevice()!)
    } catch { print("gs-check: \(error)") }
case "render": renderWallpaper(Array(CommandLine.arguments.dropFirst(2)))
case "transition": renderTransition(Array(CommandLine.arguments.dropFirst(2)))
case "shader-coverage": shaderCoverage(Array(CommandLine.arguments.dropFirst(2)))
case "compile-shaders": compileShaders(limit: CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) : nil)
case "upload-tex": uploadTextures()
case "scan-tex": scanTextures()
case "tex-dump": texDump(Array(CommandLine.arguments.dropFirst(2)))
case "fxc-check": fxcCheck(Array(CommandLine.arguments.dropFirst(2)))
case "hrtf-dump": hrtfDump(Array(CommandLine.arguments.dropFirst(2)))
case "sound-ref": soundRef(Array(CommandLine.arguments.dropFirst(2)))
case "text-shape": textShape(Array(CommandLine.arguments.dropFirst(2)))
default: print("usage: photon-tool scan-tex")
}


/// Web wallpapers (`ProjectKind.web`): load in an offscreen WKWebView, wait `seconds`, snapshot.
func renderWeb(dir: URL, project: [String: Any], out: URL, seconds: Double, width: Int, height: Int) {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let frame = CGRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(contentRect: frame.offsetBy(dx: -20000, dy: -20000), styleMask: [.borderless], backing: .buffered, defer: false)
    let props = WebWallpaper.typedProperties(project: project, overrides: [:])
    let installRoot = engineAssets.deletingLastPathComponent()
    let web: WebWallpaper
    do { web = try WebWallpaper(directory: dir, file: (project["file"] as? String) ?? "", properties: props,
                                 engineInstall: installRoot, frame: frame) }
    catch { print("load failed: \(error)"); exit(1) }
    window.contentView = web.webView
    window.orderFrontRegardless()
    web.load()
    // PHOTON_GENERAL: the wallpaper's general properties (wec_* colour filter, alignmentfliph), applied every tick
    // like the app does.
    let general = ProcessInfo.processInfo.environment["PHOTON_GENERAL"].flatMap { $0.data(using: .utf8) }
        .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
    let deadline = Date().addingTimeInterval(max(seconds, 0.5))
    while Date() < deadline { web.applyWallpaperGeneral(general); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    var done = false
    let cfg = WKSnapshotConfiguration()
    cfg.snapshotWidth = NSNumber(value: Double(width) / Double(window.backingScaleFactor))
    web.webView.takeSnapshot(with: cfg) { image, error in
        if let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: out)
            print("wrote \(out.path) (web)")
        } else {
            print("snapshot failed: \(error.map { "\($0)" } ?? "no image")")
        }
        done = true
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    window.orderOut(nil)
}
