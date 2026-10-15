import Foundation
import Metal
import PhotonCore
import PhotonRender

/// `photon-tool fxc-check [--rerun] <workshop id | wallpaper dir | hlsl dir> ...`
///
/// Runs Wallpaper Engine's own `d3dcompiler_47.dll` (D3DCompile, `main`, vs_5_0/ps_5_0, flags 0x8800, as
/// `ShaderProgram_Compile` 0x1400d5070 does) on every stage photon2 translates, and records the verdicts in
/// `FXCVerdicts.cacheURL` (`PHOTON_FXC_CACHE`). `PHOTON_FXC_STRICT=1` then gives the stages FXC rejects the engine's
/// `dx11fallback`. Arguments: a workshop id or wallpaper directory is loaded and rendered for one frame, collecting
/// every program `ShaderLibrary` compiles; a directory of `*.vs.hlsl` / `*.ps.hlsl` files (`PHOTON_DUMP_HLSL`,
/// `shader-coverage` output) is checked file by file (no shader/combo names then).
///
/// Harness: `docs/re/tools/fxc.c`, built once with mingw-w64 into the cache directory (or `PHOTON_FXC_EXE`), run under
/// CrossOver's wine (`PHOTON_WINE`, bottle `PHOTON_WINE_BOTTLE`, default `Steam`). The DLL is WE's
/// `distribution/bin/d3dcompiler_47.dll` next to the assets (`PHOTON_FXC_DLL` overrides).
func fxcCheck(_ argv: [String]) {
    var args = argv
    let rerun = args.contains("--rerun")
    args.removeAll { $0 == "--rerun" }
    guard !args.isEmpty else {
        print("usage: photon-tool fxc-check [--rerun] <workshop id | wallpaper dir | hlsl dir> ...")
        return
    }
    struct Stage { let hash: String; let stage: String; let hlsl: String; let shader: String; let combos: String }
    var stages: [String: Stage] = [:]
    var sources: [String: [String]] = [:]
    var current = ""
    FXCVerdicts.observer = { hash, stage, hlsl, shader, combos in
        if stages[hash] == nil { stages[hash] = Stage(hash: hash, stage: stage, hlsl: hlsl, shader: shader, combos: combos) }
        if sources[hash]?.contains(current) != true { sources[hash, default: []].append(current) }
    }
    SceneRenderer.soundEnabled = false
    SceneRenderer.simulatedScriptClock = true
    SceneRenderer.audioCaptureEnabled = false
    let device = MTLCreateSystemDefaultDevice()!
    let fm = FileManager.default
    for a in args {
        var isDir: ObjCBool = false
        let path = a.hasPrefix("/") ? a : workshop.appendingPathComponent(a).path
        let hlslDir = fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            && ((try? fm.contentsOfDirectory(atPath: path)) ?? []).contains { $0.hasSuffix(".hlsl") }
        if hlslDir {
            for f in ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted() where f.hasSuffix(".vs.hlsl") || f.hasSuffix(".ps.hlsl") || f.hasSuffix(".gs.hlsl") {
                guard let text = try? String(contentsOfFile: path + "/" + f, encoding: .utf8) else { continue }
                let st = f.hasSuffix(".vs.hlsl") ? "vs" : f.hasSuffix(".gs.hlsl") ? "gs" : "ps"
                let h = FXCVerdicts.key(hlsl: text, stage: st)
                if stages[h] == nil { stages[h] = Stage(hash: h, stage: st, hlsl: text, shader: f, combos: "") }
            }
            print("\(a): \(stages.count) stages so far")
            continue
        }
        let before = stages.count
        current = a
        do {
            let scene = try SceneRenderer(device: device, wallpaperDirectory: URL(fileURLWithPath: path), engineAssets: engineAssets)
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 640, height: 360, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            let tex = device.makeTexture(descriptor: d)!
            scene.simulate(to: 0.9)
            if let cb = scene.render(into: tex, time: 1, outputSize: CGSize(width: 640, height: 360), pointer: CGPoint(x: 0.5, y: 0.5)) {
                cb.commit(); cb.waitUntilCompleted()
            }
        } catch {
            print("\(a): load failed: \(error)")
        }
        print("\(a): \(stages.count - before) new stages")
    }
    FXCVerdicts.observer = nil

    var verdicts = FXCVerdicts.load()
    for (h, list) in sources where verdicts[h] != nil {
        for s in list where verdicts[h]?.sources.contains(s) == false { verdicts[h]?.sources.append(s) }
    }
    let todo = stages.values.filter { rerun || verdicts[$0.hash] == nil }.sorted { $0.hash < $1.hash }
    print("\(stages.count) stages collected, \(todo.count) to compile with FXC")
    if !todo.isEmpty {
        guard let results = runFXC(todo.map { ($0.hash, $0.stage, $0.hlsl) }) else { return }
        for s in todo {
            guard let (ok, err) = results[s.hash] else { print("  no FXC result for \(s.hash) (\(s.shader))"); continue }
            let first = err.split(separator: "\n").first { $0.contains("error") }.map(String.init) ?? ""
            // Drop the harness path prefix "Z:\…\<hash>.hlsl" from the message.
            let msg = first.replacingOccurrences(of: #"^.*\.hlsl"#, with: "", options: .regularExpression)
            verdicts[s.hash] = FXCVerdicts.Record(hash: s.hash, stage: s.stage, ok: ok, shader: s.shader, combos: s.combos, error: msg,
                                                  sources: sources[s.hash] ?? [])
        }
    }
    do { try FXCVerdicts.save(verdicts) } catch { print("cannot write \(FXCVerdicts.cacheURL.path): \(error)") }
    let failing = stages.keys.compactMap { verdicts[$0] }.filter { !$0.ok }.sorted { ($0.shader, $0.stage) < ($1.shader, $1.stage) }
    print("FXC rejects \(failing.count) of \(stages.count) collected stages (cache: \(verdicts.values.filter { !$0.ok }.count) rejected of \(verdicts.count), \(FXCVerdicts.cacheURL.path))")
    for r in failing {
        print("  \(r.hash.prefix(12)) \(r.stage) \(r.shader) [\(r.combos)] \(r.error.prefix(140)) — in \(r.sources.joined(separator: " "))")
    }
}

/// Compiles `(hash, stage, hlsl)` with the real FXC under wine; returns hash → (ok, compiler output).
func runFXC(_ items: [(String, String, String)]) -> [String: (Bool, String)]? {
    let env = ProcessInfo.processInfo.environment
    let fm = FileManager.default
    let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("photon2")
    let work = cache.appendingPathComponent("fxc-work")
    try? fm.removeItem(at: work)
    try? fm.createDirectory(at: work, withIntermediateDirectories: true)
    let wine = env["PHOTON_WINE"] ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine").path
    let bottle = env["PHOTON_WINE_BOTTLE"] ?? "Steam"
    let dll = env["PHOTON_FXC_DLL"] ?? engineAssets.deletingLastPathComponent().appendingPathComponent("distribution/bin/d3dcompiler_47.dll").path
    var exe = env["PHOTON_FXC_EXE"] ?? cache.appendingPathComponent("fxc.exe").path
    if env["PHOTON_FXC_EXE"] == nil, !fm.fileExists(atPath: exe) {
        // docs/re/tools/fxc.c, located from this source file (the repo checkout).
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../docs/re/tools/fxc.c").standardized.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["x86_64-w64-mingw32-gcc", "-O2", "-o", exe, src]
        do { try p.run(); p.waitUntilExit() } catch { print("cannot run mingw: \(error)"); return nil }
        guard p.terminationStatus == 0, fm.fileExists(atPath: exe) else { print("building \(src) with x86_64-w64-mingw32-gcc failed"); return nil }
        exe = cache.appendingPathComponent("fxc.exe").path
    }
    for (path, what) in [(wine, "wine (PHOTON_WINE)"), (dll, "d3dcompiler_47.dll (PHOTON_FXC_DLL)"), (exe, "fxc.exe")] where !fm.fileExists(atPath: path) {
        print("missing \(what): \(path)")
        return nil
    }
    func z(_ p: String) -> String { "Z:" + p.replacingOccurrences(of: "/", with: "\\") }
    var list = ""
    for (hash, stage, hlsl) in items {
        // photon2 pins varying locations with `[[vk::location(n)]]` for glslang; FXC rejects the attribute, the engine's
        // translator never emits it, and nothing else differs.
        let text = hlsl.replacingOccurrences(of: #"\[\[vk::location\(\d+\)\]\] "#, with: "", options: .regularExpression)
        let file = work.appendingPathComponent(hash + ".hlsl").path
        try? text.write(toFile: file, atomically: true, encoding: .utf8)
        list += "\(stage == "vs" ? "vs_5_0" : stage == "gs" ? "gs_5_0" : "ps_5_0") \(z(file))\n"
    }
    let listFile = work.appendingPathComponent("list.txt").path
    try? list.write(toFile: listFile, atomically: true, encoding: .utf8)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: wine)
    p.arguments = ["--bottle", bottle, "--no-gui", z(exe), z(listFile), z(dll)]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    print("running FXC on \(items.count) stages (\(dll))")
    do { try p.run() } catch { print("cannot run wine: \(error)"); return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    var results: [String: (Bool, String)] = [:]
    var current: (Bool, String)?
    var buf: [String] = []
    for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") {
        let l = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        if l.hasPrefix("OK ") || l.hasPrefix("FAIL ") {
            let ok = l.hasPrefix("OK ")
            let path = String(l.dropFirst(ok ? 3 : 5))
            let name = path.split(separator: "\\").last.map(String.init) ?? path
            current = (ok, String(name.dropLast(5))) // "<hash>.hlsl"
            buf = []
        } else if l == "--END--", let c = current {
            results[c.1] = (c.0, buf.joined(separator: "\n"))
            current = nil
        } else if current != nil {
            buf.append(l)
        }
    }
    try? fm.removeItem(at: work)
    return results
}
