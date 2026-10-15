import CryptoKit
import Foundation

/// The engine compiles every translated stage with `D3DCompile` (d3dcompiler_47, flags 0x8800) and replaces a stage that
/// fails with `shaders/HLSL/dx11fallback.vert` / `.frag` (`ShaderProgram_Compile` 0x1400d5070: VS at 0x1400d561d,
/// GS/PS through `ShaderProgram_CompileStage` 0x1400d44e0; VS fallback 0x1400d569f–0x1400d57ba, PS fallback
/// 0x1400d57bd–0x1400d58a8, each stage on its own; the GS gets no fallback and is dropped once any stage fell back).
/// photon2 compiles with glslang, which accepts a few programs FXC rejects (X3011 non-literal global `const`
/// initialisers, X4000 possibly-uninitialised outputs). `photon-tool fxc-check` runs WE's real compiler on photon2's
/// translated stages and records the verdicts here; `PHOTON_FXC_STRICT=1` then applies the engine's fallback to exactly
/// the stages FXC rejected (docs/re/shader-keys.md §9, unknowns SH15). Off by default.
public enum FXCVerdicts {
    /// One recorded stage: TSV `hash  stage  ok|fail  shader  combos  error  wallpapers`.
    public struct Record {
        public let hash: String
        public let stage: String
        public let ok: Bool
        public let shader: String
        public let combos: String
        public let error: String
        /// Wallpapers (workshop ids / paths) whose programs use the stage, as far as `fxc-check` has seen.
        public var sources: [String]

        public init(hash: String, stage: String, ok: Bool, shader: String, combos: String, error: String, sources: [String] = []) {
            self.hash = hash; self.stage = stage; self.ok = ok; self.shader = shader; self.combos = combos; self.error = error
            self.sources = sources
        }

        var line: String {
            func clean(_ s: String) -> String { s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
            return [hash, stage, ok ? "ok" : "fail", clean(shader), clean(combos), clean(error), sources.joined(separator: " ")].joined(separator: "\t")
        }
    }

    public static let strict = ProcessInfo.processInfo.environment["PHOTON_FXC_STRICT"] == "1"

    /// `PHOTON_FXC_CACHE`, default `~/Library/Caches/photon2/fxc-verdicts.tsv`.
    public static var cacheURL: URL {
        if let p = ProcessInfo.processInfo.environment["PHOTON_FXC_CACHE"] { return URL(fileURLWithPath: p) }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("photon2/fxc-verdicts.tsv")
    }

    /// The key of one translated stage: SHA-256 of `<vs|ps>\0<hlsl>` (the HLSL photon2 compiles, before the harness
    /// strips the `[[vk::location]]` attributes FXC does not know).
    public static func key(hlsl: String, stage: String) -> String {
        SHA256.hash(data: Data((stage + "\u{0}" + hlsl).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func load(_ url: URL = cacheURL) -> [String: Record] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: Record] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3 else { continue }
            out[f[0]] = Record(hash: f[0], stage: f[1], ok: f[2] == "ok", shader: f.count > 3 ? f[3] : "",
                               combos: f.count > 4 ? f[4] : "", error: f.count > 5 ? f[5] : "",
                               sources: f.count > 6 ? f[6].split(separator: " ").map(String.init) : [])
        }
        return out
    }

    public static func save(_ records: [String: Record], to url: URL = cacheURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let header = "# photon2 FXC verdicts (photon-tool fxc-check): sha256(stage\\0hlsl)\tstage\tok|fail\tshader\tcombos\terror\twallpapers\n"
        let body = records.values.sorted { ($0.shader, $0.hash) < ($1.shader, $1.hash) }.map(\.line).joined(separator: "\n")
        try (header + body + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Failing stage keys, loaded once when strict mode is on.
    nonisolated(unsafe) static var failing: [String: Record] = {
        guard strict else { return [:] }
        let all = load()
        let f = all.filter { !$0.value.ok }
        NSLog("photon: PHOTON_FXC_STRICT: %d FXC-rejected stages of %d in %@", f.count, all.count, cacheURL.path)
        return f
    }()

    /// Every stage `ShaderLibrary` compiles is reported here when set (`photon-tool fxc-check` collects them).
    nonisolated(unsafe) public static var observer: ((_ hash: String, _ stage: String, _ hlsl: String, _ shader: String, _ combos: String) -> Void)?
}
