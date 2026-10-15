import CryptoKit
import Foundation
import PhotonCore
#if os(Linux)
import Metal
import PhotonGPU
#endif

/// Compiles translated HLSL to Metal Shading Language: glslang (HLSL front end) → SPIR-V → SPIRV-Cross.
///
/// Register mapping: `tN`/`sN` keep their slot as the Metal texture/sampler index. Constant buffer `bN`
/// becomes Metal buffer `N`; vertex data uses `vertexBufferIndex`.
public final class ShaderCompiler {
    public static let vertexBufferIndex = 16

    public struct CompiledStage {
        public let msl: String
        public let entryPoint: String
        /// SPIRV-Cross reflection JSON (uniform buffer member offsets etc.).
        public let reflection: [String: Any]
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case tool(String, String)
        public var description: String {
            switch self { case .tool(let t, let msg): return "\(t): \(msg)" }
        }
    }

    let glslang: String
    let spirvCross: String
    let cacheDir: URL

    public init(glslang: String = ShaderCompiler.defaultTool("glslangValidator", env: "PHOTON_GLSLANG"),
                spirvCross: String = ShaderCompiler.defaultTool("spirv-cross", env: "PHOTON_SPIRV_CROSS"),
                cacheDir: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("photon2/shaders")) {
        self.glslang = glslang
        self.spirvCross = spirvCross
        self.cacheDir = cacheDir
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    public func compile(hlsl: String, stage: HLSLTranslator.Stage) throws -> CompiledStage {
        #if os(Linux)
        return try compileSPIRV(hlsl: hlsl, stage: stage)
        #else
        return try compileMSL(hlsl: hlsl, stage: stage)
        #endif
    }

    #if os(Linux)
    /// Linux (Vulkan through the Metal facade): the same glslang front end and flags, plus the register shifts of
    /// `HLSLRegisterMap` (one descriptor set for every stage); the SPIR-V travels to `makeLibrary(source:)` wrapped by
    /// `MetalSPIRV.source`. The reflection is SPIRV-Cross's, with uniform-block bindings shifted back to the cbuffer
    /// register so `ShaderProgram.layouts` reads the same JSON as on macOS.
    func compileSPIRV(hlsl: String, stage: HLSLTranslator.Stage) throws -> CompiledStage {
        let gpuStage: GPUShaderStage = stage == .vertex ? .vertex : stage == .fragment ? .fragment : .geometry
        let stageName = SPIRVCompiler.stageName(gpuStage)
        let key = SHA256.hash(data: Data(("vk\u{0}" + stageName + "\u{0}" + hlsl).utf8)).map { String(format: "%02x", $0) }.joined()
        let base = cacheDir.appendingPathComponent(key)
        let spvURL = base.appendingPathExtension("spv"), reflURL = base.appendingPathExtension("json")
        if let spv = try? Data(contentsOf: spvURL), spv.count >= 20, let refl = try? Data(contentsOf: reflURL) {
            return CompiledStage(msl: MetalSPIRV.source(stage: gpuStage, words: SPIRVReflection.words([UInt8](spv))), entryPoint: "main0",
                                 reflection: (try? JSONSerialization.jsonObject(with: refl)) as? [String: Any] ?? [:])
        }
        let hlslURL = base.appendingPathExtension("hlsl"), tmpURL = base.appendingPathExtension("tmp.spv")
        try hlsl.write(to: hlslURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: hlslURL); try? FileManager.default.removeItem(at: tmpURL) }
        try run(glslang, ["-D", "-V", "-S", stageName, "-e", "main", "--quiet", "--keep-uncalled",
                          "--shift-UBO-binding", "\(HLSLRegisterMap.uniformBase(gpuStage))",
                          "--shift-texture-binding", "\(HLSLRegisterMap.textureBase)",
                          "--shift-sampler-binding", "\(HLSLRegisterMap.samplerBase)",
                          "-o", tmpURL.path, hlslURL.path], tool: "glslang")
        let reflText = try run(spirvCross, [tmpURL.path, "--reflect"], tool: "spirv-cross")
        var refl = (try? JSONSerialization.jsonObject(with: Data(reflText.utf8))) as? [String: Any] ?? [:]
        if let ubos = refl["ubos"] as? [[String: Any]] {
            refl["ubos"] = ubos.map { u -> [String: Any] in
                var u = u
                if let b = u["binding"] as? Int { u["binding"] = b - HLSLRegisterMap.uniformBase(gpuStage) }
                return u
            }
        }
        let spv = try Data(contentsOf: tmpURL)
        try? FileManager.default.removeItem(at: spvURL)
        try spv.write(to: spvURL)
        try JSONSerialization.data(withJSONObject: refl).write(to: reflURL)
        return CompiledStage(msl: MetalSPIRV.source(stage: gpuStage, words: SPIRVReflection.words([UInt8](spv))), entryPoint: "main0", reflection: refl)
    }
    #endif

    func compileMSL(hlsl: String, stage: HLSLTranslator.Stage) throws -> CompiledStage {
        let stageName = stage == .vertex ? "vert" : stage == .fragment ? "frag" : "geom"
        let key = SHA256.hash(data: Data((stageName + "\u{0}" + hlsl).utf8)).map { String(format: "%02x", $0) }.joined()
        let base = cacheDir.appendingPathComponent(key)
        let mslURL = base.appendingPathExtension("metal"), reflURL = base.appendingPathExtension("json")
        if let msl = try? String(contentsOf: mslURL, encoding: .utf8), let refl = try? Data(contentsOf: reflURL) {
            return CompiledStage(msl: msl, entryPoint: "main0", reflection: (try? JSONSerialization.jsonObject(with: refl)) as? [String: Any] ?? [:])
        }

        let hlslURL = base.appendingPathExtension("hlsl"), spvURL = base.appendingPathExtension("spv")
        try hlsl.write(to: hlslURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: spvURL) }

        try run(glslang, ["-D", "-V", "-S", stageName, "-e", "main", "--quiet", "--keep-uncalled",
                          "-o", spvURL.path, hlslURL.path], tool: "glslang")
        let msl = try run(spirvCross, [spvURL.path, "--msl", "--msl-version", "30000", "--msl-decoration-binding"], tool: "spirv-cross")
        let reflText = try run(spirvCross, [spvURL.path, "--reflect"], tool: "spirv-cross")
        try msl.write(to: mslURL, atomically: true, encoding: .utf8)
        try reflText.write(to: reflURL, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: hlslURL)
        let refl = (try? JSONSerialization.jsonObject(with: Data(reflText.utf8))) as? [String: Any] ?? [:]
        return CompiledStage(msl: msl, entryPoint: "main0", reflection: refl)
    }

    /// Homebrew's path on macOS (as before); on Linux the env override, the distro path, /usr/local, or the copy a
    /// package carries next to its private libraries (`<exe>/../lib/photon2/`, docs/linux-port.md §6.2: Fedora has no
    /// spirv-cross package).
    public static func defaultTool(_ name: String, env: String) -> String {
        #if os(Linux)
        if let p = ProcessInfo.processInfo.environment[env] { return p }
        let exe = URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath().deletingLastPathComponent()
        for p in ["/usr/bin/" + name, "/usr/local/bin/" + name, exe.appendingPathComponent("../lib/photon2/" + name).standardized.path]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return "/usr/bin/" + name
        #else
        return "/opt/homebrew/bin/" + name
        #endif
    }

    @discardableResult
    private func run(_ exe: String, _ args: [String], tool: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        // Close our pipe ends explicitly: the handles are not released with the Pipe objects, so every compile leaked
        // four descriptors and a long session (or `photon-tool shader-coverage`) ended with Process.run failing with
        // EBADF, i.e. every later shader falling back to dx11fallback.
        defer {
            for h in [out.fileHandleForReading, out.fileHandleForWriting, err.fileHandleForReading, err.fileHandleForWriting] { try? h.close() }
        }
        // Wait on a semaphore, not waitUntilExit: that spins the current run loop, which re-enters display-link
        // callbacks when a scene loads on the main thread.
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        try p.run()
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        exited.wait()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw Error.tool(tool, (text + String(decoding: errData, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text
    }
}
