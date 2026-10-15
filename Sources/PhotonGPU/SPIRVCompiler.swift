import Foundation

/// HLSL → SPIR-V with glslang, the same front end and flags PhotonRender's ShaderCompiler uses on macOS
/// (`-D -V -S <stage> -e main --keep-uncalled`), plus the register shifts of `HLSLRegisterMap` when `shiftRegisters`
/// is set (Vulkan). Results are cached by a hash of the stage, flags and source.
public final class SPIRVCompiler {
    public enum Error: Swift.Error, CustomStringConvertible {
        case glslang(String)
        public var description: String { if case .glslang(let s) = self { return "glslang: \(s)" }; return "glslang" }
    }

    public let glslang: String
    public let cacheDirectory: URL
    public let shiftRegisters: Bool

    public static var defaultGlslang: String {
        if let p = ProcessInfo.processInfo.environment["PHOTON_GLSLANG"] { return p }
        for p in ["/opt/homebrew/bin/glslangValidator", "/usr/local/bin/glslangValidator", "/usr/bin/glslangValidator"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        #if os(Linux)
        // A package's own copy next to its private libraries (docs/linux-port.md §6.2).
        let exe = URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath().deletingLastPathComponent()
        let bundled = exe.appendingPathComponent("../lib/photon2/glslangValidator").standardized.path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        #endif
        return "glslangValidator"
    }

    public static var defaultCacheDirectory: URL {
        if let p = ProcessInfo.processInfo.environment["PHOTON_SPIRV_CACHE"] { return URL(fileURLWithPath: p) }
        let base = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        return base.appendingPathComponent("photon2/spirv")
    }

    public init(glslang: String = SPIRVCompiler.defaultGlslang, cacheDirectory: URL = SPIRVCompiler.defaultCacheDirectory,
                shiftRegisters: Bool = true) {
        self.glslang = glslang
        self.cacheDirectory = cacheDirectory
        self.shiftRegisters = shiftRegisters
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    public static func stageName(_ s: GPUShaderStage) -> String {
        switch s { case .vertex: return "vert"; case .fragment: return "frag"; case .geometry: return "geom" }
    }

    func arguments(stage: GPUShaderStage, input: String, output: String) -> [String] {
        var a = ["-D", "-V", "-S", Self.stageName(stage), "-e", "main", "--quiet", "--keep-uncalled"]
        if shiftRegisters {
            a += ["--shift-UBO-binding", "\(HLSLRegisterMap.uniformBase(stage))",
                  "--shift-texture-binding", "\(HLSLRegisterMap.textureBase)",
                  "--shift-sampler-binding", "\(HLSLRegisterMap.samplerBase)"]
        }
        return a + ["-o", output, input]
    }

    /// SPIR-V words for one stage.
    public func compile(hlsl: String, stage: GPUShaderStage) throws -> [UInt32] {
        let flags = arguments(stage: stage, input: "", output: "").joined(separator: " ")
        let key = Self.hash(flags + "\u{0}" + hlsl)
        let spv = cacheDirectory.appendingPathComponent(key + ".spv")
        if let d = try? Data(contentsOf: spv), d.count >= 20 { return SPIRVReflection.words([UInt8](d)) }
        let src = cacheDirectory.appendingPathComponent(key + ".hlsl"), tmp = cacheDirectory.appendingPathComponent(key + ".tmp.spv")
        try hlsl.write(to: src, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: tmp) }
        let (status, output) = try Self.run(glslang, arguments(stage: stage, input: src.path, output: tmp.path))
        guard status == 0, let d = try? Data(contentsOf: tmp) else { throw Error.glslang(output) }
        try? FileManager.default.removeItem(at: spv)
        try? FileManager.default.moveItem(at: tmp, to: spv)
        return SPIRVReflection.words([UInt8](d))
    }

    static func run(_ exe: String, _ args: [String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        defer { try? pipe.fileHandleForReading.close() }
        // Termination handler + semaphore, not waitUntilExit: on Linux waitUntilExit spins a run loop that never sees the
        // exit notification once other threads exist (lavapipe workers), and hangs.
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        try p.run()
        // Close our copy of the write end first: swift-corelibs-foundation keeps it open in the parent, and the read
        // below would never see EOF (the glslang child exits, the parent blocks forever).
        try? pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Two independent 64-bit FNV-1a lanes: a cache key, not a security hash (CryptoKit is Apple-only).
    public static func hash(_ s: String) -> String {
        var a: UInt64 = 0xcbf2_9ce4_8422_2325, b: UInt64 = 0x8422_2325_cbf2_9ce4
        for byte in s.utf8 {
            a = (a ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            b = (b ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            b = b &+ (b >> 29)
        }
        return String(format: "%016llx%016llx", a, b)
    }
}
