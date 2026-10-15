import Foundation
import Metal
import PhotonCore
import PhotonRender

/// `shader-coverage [engine|workshop|all] [randomVariants] [outDir]`: translates and compiles every engine shader
/// (`assets/shaders/**.frag` with a `.vert`) and, with `workshop`/`all`, every shader shipped inside the corpus packages,
/// over the combo permutations the engine can select. For each shader the variants are: the declared defaults; every
/// preprocessor identifier at each value it can take (0, 1, any constant it is compared against in an `#if`, its
/// `[COMBO]` default and options, and the engine-chosen ranges for engine combos: `BLENDMODE` 0–30, `TEXnFORMAT` .tex
/// formats, light counts); all switches on; seeded random mixes; each with no texture bound, slot 0 bound and every
/// declared slot bound (with every component bit set). Variants that translate to the same HLSL are compiled once.
/// Failures are grouped by the first compiler error line; the HLSL of each failure is written to `outDir`.
func shaderCoverage(_ args: [String]) {
    let mode = args.first ?? "engine"
    let randomCount = args.count > 1 ? Int(args[1]) ?? 24 : 24
    let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : NSTemporaryDirectory() + "photon-shader-coverage")
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let device = MTLCreateSystemDefaultDevice()!

    struct Job { let wallpaper: String?; let shader: String }
    var jobs: [Job] = []
    if mode == "engine" || mode == "all" {
        let root = engineAssets.appendingPathComponent("shaders")
        let e = FileManager.default.enumerator(atPath: root.path)
        while let rel = e?.nextObject() as? String {
            guard rel.hasSuffix(".frag"), !rel.hasPrefix("HLSL/") else { continue }
            let name = String(rel.dropLast(5))
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(name + ".vert").path) { jobs.append(Job(wallpaper: nil, shader: name)) }
        }
    }
    if mode == "engine" || mode == "all" {
        // Stock effects (`assets/effects/<x>/`) are templates the editor copies into each project; their shaders resolve
        // from the effect folder the way a project's copy resolves from the wallpaper folder.
        let effects = engineAssets.appendingPathComponent("effects")
        for fx in ((try? FileManager.default.contentsOfDirectory(atPath: effects.path)) ?? []).sorted() {
            let root = effects.appendingPathComponent(fx).appendingPathComponent("shaders")
            let e = FileManager.default.enumerator(atPath: root.path)
            while let rel = e?.nextObject() as? String {
                guard rel.hasSuffix(".frag") else { continue }
                let name = String(rel.dropLast(5))
                if FileManager.default.fileExists(atPath: root.appendingPathComponent(name + ".vert").path) {
                    jobs.append(Job(wallpaper: "@" + fx, shader: name))
                }
            }
        }
    }
    if mode == "workshop" || mode == "all" {
        for id in ((try? FileManager.default.contentsOfDirectory(atPath: workshop.path)) ?? []).sorted() {
            let fs = AssetFileSystem(engineAssets: engineAssets)
            let dir = workshop.appendingPathComponent(id)
            var names = Set<String>()
            if (try? fs.mountWallpaper(file: dir.appendingPathComponent("scene.pkg"))) != nil, let pkg = fs.package {
                for n in pkg.entries.keys where n.hasPrefix("shaders/") && n.hasSuffix(".frag") { names.insert(String(n.dropFirst(8).dropLast(5))) }
            }
            if let e = FileManager.default.enumerator(atPath: dir.appendingPathComponent("shaders").path) {
                while let rel = e.nextObject() as? String { if rel.hasSuffix(".frag") { names.insert(String(rel.dropLast(5))) } }
            }
            for n in names.sorted() { jobs.append(Job(wallpaper: id, shader: n)) }
        }
    }
    jobs.sort { ($0.wallpaper ?? "", $0.shader) < ($1.wallpaper ?? "", $1.shader) }

    let lock = NSLock()
    var programs = 0, variantsTried = 0, failed = 0
    var failures: [String: [String]] = [:]
    var failedShaders = Set<String>()
    var perShader: [String] = []
    var allRows: [String] = []

    // Foundation's Process/Pipe is not safe to launch from many threads at once ("Bad file descriptor"); the engine
    // and photon compile serially, so only translation runs in parallel here.
    let compileLock = NSLock()
    // Serial by default; COVERAGE_PARALLEL=1 translates shaders concurrently (compiles stay serialised by compileLock).
    let serial = ProcessInfo.processInfo.environment["COVERAGE_PARALLEL"] != "1"
    func each(_ n: Int, _ body: (Int) -> Void) { if serial { for i in 0..<n { body(i) } } else { DispatchQueue.concurrentPerform(iterations: n, execute: body) } }
    each(jobs.count) { j in
        let job = jobs[j]
        let fs = AssetFileSystem(engineAssets: engineAssets)
        if let w = job.wallpaper, w.hasPrefix("@") {
            fs.addSearchDirectory(engineAssets.appendingPathComponent("effects").appendingPathComponent(String(w.dropFirst())))
        } else if let w = job.wallpaper {
            let dir = workshop.appendingPathComponent(w)
            if (try? fs.mountWallpaper(file: dir.appendingPathComponent("scene.pkg"))) == nil {
                _ = try? fs.mountWallpaper(file: dir.appendingPathComponent("scene.json"))
            }
        }
        let sources = ShaderSourceLoader(fs: fs)
        let builder = ShaderBuilder(sources: sources)
        let compiler = ShaderCompiler()
        let label = (job.wallpaper.map { $0 + ":" } ?? "") + job.shader
        guard let vert = sources.load(stage: "shaders/\(job.shader).vert"), let frag = sources.load(stage: "shaders/\(job.shader).frag") else { return }
        let info = sources.info(shader: job.shader)
        let candidates = ShaderVariants.candidates(source: vert + "\n" + frag, info: info)
        let requests = ShaderVariants.requests(shader: job.shader, info: info, candidates: candidates, random: randomCount, seed: UInt64(j + 1))
        var seen = Set<String>()
        var okCount = 0, tried = 0, bad = 0
        var localFailures: [(String, String)] = []
        var rows: [String] = []
        let hlslDir = outDir.appendingPathComponent("hlsl")
        try? FileManager.default.createDirectory(at: hlslDir, withIntermediateDirectories: true)
        for r in requests {
            tried += 1
            guard let prog = try? builder.build(r) else { continue }
            let key = prog.vertex.hlsl + "\u{1}" + prog.fragment.hlsl
            if !seen.insert(key).inserted { continue }
            let combos = r.combos.filter { $0.value != 0 }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            let desc = "\(label) [\(combos)] lc=\(String(r.lightConfig, radix: 16)) slots=\(r.boundTextures.keys.sorted())"
            // Every unique program's HLSL, for the FXC cross-check (scratchpad r7/shaders/fxc).
            let base = label.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_") + "_\(seen.count)"
            try? prog.vertex.hlsl.write(to: hlslDir.appendingPathComponent(base + ".vs.hlsl"), atomically: true, encoding: .utf8)
            try? prog.fragment.hlsl.write(to: hlslDir.appendingPathComponent(base + ".ps.hlsl"), atomically: true, encoding: .utf8)
            do {
                compileLock.lock()
                defer { compileLock.unlock() }
                let vs = try compiler.compile(hlsl: prog.vertex.hlsl, stage: .vertex)
                let ps = try compiler.compile(hlsl: prog.fragment.hlsl, stage: .fragment)
                _ = try device.makeLibrary(source: vs.msl, options: nil)
                _ = try device.makeLibrary(source: ps.msl, options: nil)
                okCount += 1
                rows.append("\(base)\tOK\t\t\(desc)")
            } catch {
                bad += 1
                let text = "\(error)"
                var first = text.split(separator: "\n").first(where: { $0.contains("ERROR") || $0.contains("error") }).map(String.init) ?? String(text.prefix(160))
                first = first.replacingOccurrences(of: #"/\S+\.hlsl:\d+:"#, with: "", options: .regularExpression)
                localFailures.append((first, desc))
                rows.append("\(base)\tFAIL\t\(first)\t\(desc)")
            }
        }
        lock.lock()
        programs += okCount; variantsTried += tried; failed += bad
        if bad > 0 { failedShaders.insert(label) }
        for (k, v) in localFailures { failures[k, default: []].append(v) }
        allRows += rows
        perShader.append("\(label)\t\(seen.count) unique\t\(okCount) ok\t\(bad) failed\t\(candidates.count) idents")
        lock.unlock()
    }
    try? allRows.sorted().joined(separator: "\n").write(to: outDir.appendingPathComponent("results.tsv"), atomically: true, encoding: .utf8)
    try? perShader.sorted().joined(separator: "\n").write(to: outDir.appendingPathComponent("per-shader.tsv"), atomically: true, encoding: .utf8)
    print("shaders \(jobs.count), variants \(variantsTried), unique programs \(programs + failed), compiled \(programs), failed \(failed) in \(failedShaders.count) shaders")
    for (msg, list) in failures.sorted(by: { $0.value.count > $1.value.count }).prefix(40) {
        print("  [\(list.count)] \(msg.prefix(220))\n      e.g. \(list.first!.prefix(400))")
    }
    for s in failedShaders.sorted() { print("FAILED \(s)") }
}

enum ShaderVariants {
    /// Values each preprocessor identifier can take.
    static func candidates(source: String, info: ShaderSourceLoader.Info) -> [String: [Int]] {
        var values: [String: Set<Int>] = [:]
        let skip: Set<String> = ["defined", "HLSL", "HLSL_SM40", "HLSL_SM30", "GLSL", "SHADERVERSION", "GS_ENABLED", "PLATFORM_ANDROID"]
        let ident = try! NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]*"#)
        let cmp = try! NSRegularExpression(pattern: #"([A-Za-z_][A-Za-z0-9_]*)\s*(==|!=|>=|<=|>|<)\s*(\d+)"#)
        var defined = Set<String>()
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#define") {
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if parts.count > 1 { defined.insert(String(parts[1].prefix(while: { $0 != "(" }))) }
                continue
            }
            guard line.hasPrefix("#if") || line.hasPrefix("#elif") else { continue }
            let body = line.drop(while: { $0 != " " && $0 != "\t" })
            let ns = String(body) as NSString
            for m in ident.matches(in: String(body), range: NSRange(location: 0, length: ns.length)) {
                let n = ns.substring(with: m.range)
                if skip.contains(n) || n.hasPrefix("g_") { continue }
                values[n, default: [0, 1]].formUnion([0, 1])
            }
            for m in cmp.matches(in: String(body), range: NSRange(location: 0, length: ns.length)) {
                let n = ns.substring(with: m.range(at: 1))
                guard let v = Int(ns.substring(with: m.range(at: 3))) else { continue }
                values[n, default: [0, 1]].formUnion([v, v + 1, max(v - 1, 0)])
            }
        }
        for c in info.combos { values[c.name, default: [0, 1]].insert(c.defaultValue) }
        for (k, _) in values where defined.contains(k) && info.combos.first(where: { $0.name == k }) == nil { values[k] = nil }
        // Macros the shaders define themselves (`#define GRADIENT_SAMPLER g_Texture4`, FORMAT_* constants) and texture
        // combos (a sampler's `combo` / `components`, defined only from a bound texture) are not free combos.
        for k in Array(values.keys) where k.hasSuffix("_SAMPLER") || k.hasPrefix("FORMAT_") { values[k] = nil }
        for (_, smp) in info.samplers {
            if let c = smp.combo { values[c] = nil }
            for c in smp.componentCombos { values[c] = nil }
        }
        // Engine-chosen ranges.
        for k in values.keys {
            if k == "BLENDMODE" { values[k]!.formUnion(0...30) }
            if k.hasPrefix("TEX"), k.hasSuffix("FORMAT") { values[k]!.formUnion([0, 4, 6, 7, 8, 9]) }
            if k == "BONECOUNT" { values[k]!.formUnion([1, 32, 64]) }
            if k == "INSTANCECOUNT" { values[k]!.formUnion([5, 9, 13, 21]) }
        }
        // Light counts come from the scene light config, not from combos.
        for k in Array(values.keys) where k.hasPrefix("LIGHTS_") { values[k] = nil }
        return values.mapValues { $0.sorted() }
    }

    /// Packed `general.lightconfig` values (point, spot, tube, directional nibbles; 2-bit spot-shadow at 16, spot-cookie
    /// 18, spot-shadow-cookie 20, directional-shadow 22, point-shadow 24), each with shadow counts within the type counts.
    static let lightConfigs: [UInt32] = [
        0, 0x1, 0x1111, 0x4444, 0x0004, 0x0040, 0x0400, 0x4000,
        (1 << 16) | (1 << 18) | (1 << 20) | (1 << 22) | (1 << 24) | 0x1434,
        (1 << 22) | 0x1000, (3 << 16) | 0x0030, (2 << 24) | 0x0002, (1 << 18) | 0x0010, (1 << 20) | 0x0010,
    ]

    static func requests(shader: String, info: ShaderSourceLoader.Info, candidates: [String: [Int]], random: Int, seed: UInt64) -> [ShaderBuilder.Request] {
        let slots = info.samplers.keys.sorted()
        var compBits: [Int: Int32] = [:]
        for (s, i) in info.samplers { compBits[s] = Int32(truncatingIfNeeded: ((1 << i.componentCombos.count) - 1) << 20) }
        let bindings: [[Int: Int32]] = [[:], slots.contains(0) ? [0: 0] : [:], Dictionary(uniqueKeysWithValues: slots.map { ($0, Int32(0)) })]
        // Material_Load fills empty slots with the sampler default, and TEXnFORMAT sees it (0x1401a6902).
        var defaults: [Int: Int32] = [:]
        for (s, i) in info.samplers where !(i.defaultTexture ?? "").isEmpty { defaults[s] = 0 }
        var base: [String: Int] = [:]
        for c in info.combos { base[c.name] = c.defaultValue }
        var out: [ShaderBuilder.Request] = []
        func add(_ combos: [String: Int], _ binding: [Int: Int32], lc: UInt32 = 0, flags: Bool = false, fog: Int = 0, ortho: Bool = false) {
            var scene: [String: Int] = ["REVERSEDEPTH": 1]
            if ortho { scene["SCENE_ORTHO"] = 1 }
            out.append(ShaderBuilder.Request(shader: shader, combos: combos, boundTextures: binding,
                                             textureFlags: flags ? compBits : [:], formatTextures: binding.merging(defaults) { a, _ in a },
                                             sceneCombos: scene, lightConfig: lc, fogFlags: fog, shadowQuality: 1))
        }
        for b in bindings { add(base, b); add(base, b, flags: true, ortho: true) }
        for (k, vs) in candidates.sorted(by: { $0.key < $1.key }) {
            for v in vs {
                var c = base; c[k] = v
                add(c, bindings[2], flags: true)
                add(c, bindings[0])
            }
        }
        var allOn = base
        for (k, vs) in candidates { allOn[k] = max(allOn[k] ?? 0, vs.contains(1) ? 1 : vs.last ?? 0) }
        for b in bindings { add(allOn, b, flags: true) }
        if candidates["LIGHTING"] != nil || info.combos.contains(where: { $0.name == "LIGHTING" }) {
            for lc in lightConfigs {
                var c = base; c["LIGHTING"] = 1
                add(c, bindings[2], lc: lc, flags: true, fog: 3)
                var d = allOn; d["LIGHTING"] = 1
                add(d, bindings[2], lc: lc, flags: true, fog: 3)
            }
        }
        var rng = SplitMix(state: seed)
        let keys = candidates.keys.sorted()
        for _ in 0..<random {
            var c = base
            for k in keys where rng.next() % 2 == 0 {
                let vs = candidates[k]!
                c[k] = vs[Int(rng.next() % UInt64(vs.count))]
            }
            let lc = lightConfigs[Int(rng.next() % UInt64(lightConfigs.count))]
            add(c, bindings[Int(rng.next() % 3)], lc: lc, flags: rng.next() % 2 == 0, fog: Int(rng.next() % 4), ortho: rng.next() % 2 == 0)
        }
        return out
    }

    struct SplitMix {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}
