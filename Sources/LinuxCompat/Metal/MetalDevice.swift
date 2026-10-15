import Foundation
import PhotonGPU
import PhotonVulkan

// The Metal facade (docs/linux-port.md §3.2): Metal's object model implemented on PhotonGPU, so PhotonRender's
// Metal-shaped code runs unchanged on the Vulkan backend. It is a migration aid, not a general Metal: it implements what
// photon2 calls, with photon2's binding conventions —
//   * buffer index N (N ≠ 16) = HLSL constant buffer register bN of that stage, by value;
//   * buffer index 16 (ShaderCompiler.vertexBufferIndex) = the one interleaved vertex stream;
//   * texture/sampler index N = HLSL tN/sN, shared by the vertex and fragment stage (Draw.swift binds both alike);
//   * shader "MSL" is either SPIR-V wrapped by `MetalSPIRV.source` (PhotonRender's ShaderCompiler on Linux) or one of
//     the hand-written MSL utility shaders, which are swapped for HLSL ports (BuiltinShaders.swift) by function name.
// Command buffers are asynchronous as on Metal: commit submits and returns; waitUntilCompleted, completed handlers and
// visibility results follow the GPU's fence. Texture uploads and readbacks are ordered on the one queue (PhotonVulkan).

public enum MetalFacade {
    public static let vertexBufferIndex = 16
    nonisolated(unsafe) static var shared: MetalDevice?
    static let lock = NSLock()
}

public func MTLCreateSystemDefaultDevice() -> MTLDevice? {
    MetalFacade.lock.lock()
    defer { MetalFacade.lock.unlock() }
    if let d = MetalFacade.shared { return d }
    do {
        let d = MetalDevice(gpu: try VulkanDevice())
        MetalFacade.shared = d
        return d
    } catch {
        NSLog("photon: no Vulkan device: %@", "\(error)")
        return nil
    }
}

public func MTLCopyAllDevices() -> [MTLDevice] { MTLCreateSystemDefaultDevice().map { [$0] } ?? [] }

// MARK: - Protocols

public protocol MTLResource: AnyObject {
    var label: String? { get set }
    var device: MTLDevice { get }
}

public protocol MTLDevice: AnyObject {
    var name: String { get }
    var registryID: UInt64 { get }
    var hasUnifiedMemory: Bool { get }
    var recommendedMaxWorkingSetSize: UInt64 { get }
    func makeCommandQueue() -> MTLCommandQueue?
    func makeCommandQueue(maxCommandBufferCount: Int) -> MTLCommandQueue?
    func makeTexture(descriptor: MTLTextureDescriptor) -> MTLTexture?
    func makeBuffer(length: Int, options: MTLResourceOptions) -> MTLBuffer?
    func makeBuffer(bytes: UnsafeRawPointer, length: Int, options: MTLResourceOptions) -> MTLBuffer?
    func makeSamplerState(descriptor: MTLSamplerDescriptor) -> MTLSamplerState?
    func makeDepthStencilState(descriptor: MTLDepthStencilDescriptor) -> MTLDepthStencilState?
    func makeLibrary(source: String, options: MTLCompileOptions?) throws -> MTLLibrary
    func makeRenderPipelineState(descriptor: MTLRenderPipelineDescriptor) throws -> MTLRenderPipelineState
    func supportsTextureSampleCount(_ sampleCount: Int) -> Bool
    /// The PhotonGPU device underneath (Linux-only escape hatch for hosts: presentation, readback).
    var gpuDevice: GPUDevice { get }
}

public extension MTLDevice {
    func makeBuffer(length: Int) -> MTLBuffer? { makeBuffer(length: length, options: []) }
}

public protocol MTLTexture: MTLResource {
    var textureType: MTLTextureType { get }
    var pixelFormat: MTLPixelFormat { get }
    var width: Int { get }
    var height: Int { get }
    var depth: Int { get }
    var mipmapLevelCount: Int { get }
    var sampleCount: Int { get }
    var arrayLength: Int { get }
    var usage: MTLTextureUsage { get }
    var storageMode: MTLStorageMode { get }
    var parent: MTLTexture? { get }
    var isFramebufferOnly: Bool { get }
    func replace(region: MTLRegion, mipmapLevel: Int, withBytes: UnsafeRawPointer, bytesPerRow: Int)
    func replace(region: MTLRegion, mipmapLevel: Int, slice: Int, withBytes: UnsafeRawPointer, bytesPerRow: Int, bytesPerImage: Int)
    func getBytes(_ pixelBytes: UnsafeMutableRawPointer, bytesPerRow: Int, from region: MTLRegion, mipmapLevel: Int)
    func getBytes(_ pixelBytes: UnsafeMutableRawPointer, bytesPerRow: Int, bytesPerImage: Int, from region: MTLRegion, mipmapLevel: Int, slice: Int)
    func makeTextureView(pixelFormat: MTLPixelFormat) -> MTLTexture?
    func makeTextureView(pixelFormat: MTLPixelFormat, textureType: MTLTextureType, levels: Range<Int>, slices: Range<Int>) -> MTLTexture?
    /// The PhotonGPU texture underneath (Linux-only).
    var gpuTexture: GPUTextureResource { get }
}

public protocol MTLBuffer: MTLResource {
    var length: Int { get }
    func contents() -> UnsafeMutableRawPointer
    func didModifyRange(_ range: Range<Int>)
}

public protocol MTLSamplerState: AnyObject {
    var label: String? { get }
    var device: MTLDevice { get }
}

public protocol MTLDepthStencilState: AnyObject {
    var label: String? { get }
    var device: MTLDevice { get }
}

public protocol MTLRenderPipelineState: AnyObject {
    var label: String? { get }
    var device: MTLDevice { get }
}

public protocol MTLFunction: AnyObject {
    var name: String { get }
    var functionType: MTLFunctionType { get }
    var vertexAttributes: [MTLVertexAttribute]? { get }
    var device: MTLDevice { get }
    var label: String? { get set }
}

public protocol MTLLibrary: AnyObject {
    var functionNames: [String] { get }
    func makeFunction(name: String) -> MTLFunction?
    var label: String? { get set }
    var device: MTLDevice { get }
}

// MARK: - Device

public final class MetalDevice: MTLDevice {
    public let gpu: GPUDevice
    public let registryID: UInt64
    public var name: String { gpu.capabilities.deviceName }
    public var hasUnifiedMemory: Bool { true }
    public var recommendedMaxWorkingSetSize: UInt64 { 8 << 30 }
    public var gpuDevice: GPUDevice { gpu }
    let compiler = SPIRVCompiler()
    private var builtinModules: [String: GPUShaderModule] = [:]
    private let builtinLock = NSLock()

    init(gpu: GPUDevice) {
        self.gpu = gpu
        registryID = UInt64(UInt(bitPattern: ObjectIdentifier(gpu).hashValue))
    }

    public func makeCommandQueue() -> MTLCommandQueue? { MetalCommandQueue(device: self) }
    public func makeCommandQueue(maxCommandBufferCount: Int) -> MTLCommandQueue? { MetalCommandQueue(device: self) }

    public func makeTexture(descriptor d: MTLTextureDescriptor) -> MTLTexture? {
        guard let format = d.pixelFormat.gpu else {
            NSLog("photon: Metal facade: unsupported pixel format %@", "\(d.pixelFormat)")
            return nil
        }
        var g = GPUTextureDescriptor(format: format, width: d.width, height: d.height, mipLevels: max(d.mipmapLevelCount, 1),
                                     sampleCount: max(d.sampleCount, 1))
        g.type = d.textureType == .type3D ? .type3D : .type2D
        g.depth = d.textureType == .type3D ? max(d.depth, 1) : 1
        // Every facade texture can be copied from (blits, readback); render targets also as attachments.
        var usage: GPUTextureUsage = [.shaderRead, .copySource]
        if d.usage.contains(.renderTarget) { usage.insert(.renderTarget) }
        if d.usage.contains(.pixelFormatView) { usage.insert(.pixelFormatView) }
        g.usage = usage
        do {
            let t = try gpu.makeTexture(g)
            return MetalTexture(device: self, gpu: t, pixelFormat: d.pixelFormat, textureType: d.textureType, usage: d.usage,
                                storageMode: d.storageMode, arrayLength: d.arrayLength, parent: nil)
        } catch {
            NSLog("photon: Metal facade: makeTexture %dx%d %@ failed: %@", d.width, d.height, "\(d.pixelFormat)", "\(error)")
            return nil
        }
    }

    public func makeBuffer(length: Int, options: MTLResourceOptions) -> MTLBuffer? {
        guard let b = try? gpu.makeBuffer(length: max(length, 4)) else { return nil }
        memset(b.contents, 0, max(length, 4))
        return MetalBuffer(device: self, gpu: b, length: length)
    }

    public func makeBuffer(bytes: UnsafeRawPointer, length: Int, options: MTLResourceOptions) -> MTLBuffer? {
        guard let b = makeBuffer(length: length, options: options) else { return nil }
        memcpy(b.contents(), bytes, length)
        return b
    }

    public func makeSamplerState(descriptor: MTLSamplerDescriptor) -> MTLSamplerState? {
        guard let s = try? gpu.makeSampler(descriptor.gpu) else { return nil }
        return MetalSampler(device: self, gpu: s, label: descriptor.label)
    }

    public func makeDepthStencilState(descriptor: MTLDepthStencilDescriptor) -> MTLDepthStencilState? {
        MetalDepthStencil(device: self, state: GPUDepthStencilDescriptor(compare: descriptor.depthCompareFunction.gpu,
                                                                         write: descriptor.isDepthWriteEnabled), label: descriptor.label)
    }

    public func makeLibrary(source: String, options: MTLCompileOptions?) throws -> MTLLibrary {
        if let stage = MetalSPIRV.decode(source) {
            let module = try gpu.makeShaderModule(stage: stage.stage, spirv: stage.words, entryPoint: "main", label: "spirv")
            return MetalLibrary(device: self, functions: ["main0": MetalFunction(device: self, name: "main0", module: module)])
        }
        // Hand-written MSL utility shaders: the declared function names select their HLSL ports.
        var functions: [String: MetalFunction] = [:]
        for name in BuiltinShaders.functionNames(inMSL: source) {
            guard let b = BuiltinShaders.all[name] else { continue }
            functions[name] = MetalFunction(device: self, name: name, lazy: { [unowned self] in try self.builtinModule(name, b) })
        }
        if functions.isEmpty { throw MTLLibraryError("Metal facade: no SPIR-V and no known MSL functions in library source") }
        return MetalLibrary(device: self, functions: functions)
    }

    func builtinModule(_ name: String, _ b: BuiltinShaders.Shader) throws -> GPUShaderModule {
        builtinLock.lock()
        defer { builtinLock.unlock() }
        if let m = builtinModules[name] { return m }
        let words = try compiler.compile(hlsl: b.hlsl, stage: b.stage)
        let m = try gpu.makeShaderModule(stage: b.stage, spirv: words, entryPoint: "main", label: name)
        builtinModules[name] = m
        return m
    }

    public func makeRenderPipelineState(descriptor d: MTLRenderPipelineDescriptor) throws -> MTLRenderPipelineState {
        guard let vf = d.vertexFunction as? MetalFunction, let ff = d.fragmentFunction as? MetalFunction else {
            throw MTLLibraryError("Metal facade: pipeline needs a vertex and a fragment function")
        }
        let ca = d.colorAttachments[0]!
        guard let color = ca.pixelFormat.gpu else { throw MTLLibraryError("Metal facade: colour format \(ca.pixelFormat)") }
        var g = GPURenderPipelineDescriptor(vertex: try vf.module(), fragment: try ff.module(),
                                            vertexLayout: d.vertexDescriptor?.gpu ?? GPUVertexLayout(stride: 0, attributes: []),
                                            colorFormat: color, depthFormat: d.depthAttachmentPixelFormat.gpu,
                                            sampleCount: max(d.rasterSampleCount, 1))
        g.blend = ca.gpu
        g.alphaToCoverage = d.isAlphaToCoverageEnabled
        g.label = d.label ?? "\(vf.name)/\(ff.name)"
        var pointsDraw = false
        if let gf = d.geometryFunction as? MetalFunction {
            g.geometry = try gf.module()
            if d.geometryInput == .point {
                // Native geometry stage: the particle point list steps per vertex and is drawn as points.
                g.vertexLayout.perInstance = false
                g.primitive = .point
                pointsDraw = true
            }
        }
        let p = try gpu.makeRenderPipeline(g)
        return MetalPipeline(device: self, gpu: p, label: d.label, nativeGeometry: pointsDraw)
    }

    public func supportsTextureSampleCount(_ sampleCount: Int) -> Bool { gpu.capabilities.sampleCounts.contains(sampleCount) }
}

// MARK: - Resources

final class MetalTexture: MTLTexture {
    let owner: MetalDevice
    let gpu: GPUTextureResource
    let pixelFormat: MTLPixelFormat
    let textureType: MTLTextureType
    let usage: MTLTextureUsage
    let storageMode: MTLStorageMode
    let arrayLength: Int
    let parent: MTLTexture?
    var label: String?
    /// Single-mip views used as render-pass attachments (Vulkan attachments name exactly one level).
    private var levelViews: [Int: GPUTextureResource] = [:]
    private let lock = NSLock()

    init(device: MetalDevice, gpu: GPUTextureResource, pixelFormat: MTLPixelFormat, textureType: MTLTextureType, usage: MTLTextureUsage,
         storageMode: MTLStorageMode, arrayLength: Int, parent: MTLTexture?) {
        owner = device
        self.gpu = gpu
        self.pixelFormat = pixelFormat
        self.textureType = textureType
        self.usage = usage
        self.storageMode = storageMode
        self.arrayLength = arrayLength
        self.parent = parent
    }

    var device: MTLDevice { owner }
    var gpuTexture: GPUTextureResource { gpu }
    var width: Int { gpu.descriptor.width }
    var height: Int { gpu.descriptor.height }
    var depth: Int { gpu.descriptor.depth }
    var mipmapLevelCount: Int { gpu.descriptor.mipLevels }
    var sampleCount: Int { gpu.descriptor.sampleCount }
    var isFramebufferOnly: Bool { false }

    /// The texture as a render-pass attachment at mip `level`.
    func attachment(level: Int) throws -> GPUTextureResource {
        if level == 0 && mipmapLevelCount == 1 { return gpu }
        lock.lock()
        defer { lock.unlock() }
        if let v = levelViews[level] { return v }
        let v = try gpu.makeView(format: gpu.descriptor.format, baseLevel: level, levelCount: 1)
        levelViews[level] = v
        return v
    }

    private func bytesPerImage(_ region: MTLRegion, bytesPerRow: Int) -> Int {
        let f = gpu.descriptor.format
        return bytesPerRow * ((max(region.size.height, 1) + f.block.size - 1) / f.block.size)
    }

    func replace(region: MTLRegion, mipmapLevel: Int, withBytes bytes: UnsafeRawPointer, bytesPerRow: Int) {
        let bpi = bytesPerImage(region, bytesPerRow: bytesPerRow)
        replace(region: region, mipmapLevel: mipmapLevel, slice: 0, withBytes: bytes, bytesPerRow: bytesPerRow, bytesPerImage: bpi)
    }

    func replace(region: MTLRegion, mipmapLevel: Int, slice: Int, withBytes bytes: UnsafeRawPointer, bytesPerRow: Int, bytesPerImage: Int) {
        let d = max(region.size.depth, 1)
        let bpi = bytesPerImage > 0 ? bytesPerImage : self.bytesPerImage(region, bytesPerRow: bytesPerRow)
        do {
            try gpu.replace(level: mipmapLevel, x: region.origin.x, y: region.origin.y, width: region.size.width, height: region.size.height,
                            depth: d, bytes: UnsafeRawBufferPointer(start: bytes, count: bpi * d), bytesPerRow: bytesPerRow, bytesPerImage: bpi)
        } catch {
            NSLog("photon: Metal facade: replace failed: %@", "\(error)")
        }
    }

    func getBytes(_ pixelBytes: UnsafeMutableRawPointer, bytesPerRow: Int, from region: MTLRegion, mipmapLevel: Int) {
        getBytes(pixelBytes, bytesPerRow: bytesPerRow, bytesPerImage: bytesPerImage(region, bytesPerRow: bytesPerRow), from: region,
                 mipmapLevel: mipmapLevel, slice: 0)
    }

    func getBytes(_ pixelBytes: UnsafeMutableRawPointer, bytesPerRow: Int, bytesPerImage: Int, from region: MTLRegion, mipmapLevel: Int, slice: Int) {
        let d = max(region.size.depth, 1)
        do {
            try gpu.read(level: mipmapLevel, x: region.origin.x, y: region.origin.y, width: region.size.width, height: region.size.height,
                         depth: d, into: UnsafeMutableRawBufferPointer(start: pixelBytes, count: bytesPerImage * d),
                         bytesPerRow: bytesPerRow, bytesPerImage: bytesPerImage)
        } catch {
            NSLog("photon: Metal facade: getBytes failed: %@", "\(error)")
        }
    }

    func makeTextureView(pixelFormat: MTLPixelFormat) -> MTLTexture? {
        makeTextureView(pixelFormat: pixelFormat, textureType: textureType, levels: 0..<mipmapLevelCount, slices: 0..<1)
    }

    func makeTextureView(pixelFormat: MTLPixelFormat, textureType: MTLTextureType, levels: Range<Int>, slices: Range<Int>) -> MTLTexture? {
        guard let f = pixelFormat.gpu, let v = try? gpu.makeView(format: f, baseLevel: levels.lowerBound, levelCount: levels.count) else { return nil }
        return MetalTexture(device: owner, gpu: v, pixelFormat: pixelFormat, textureType: textureType, usage: usage, storageMode: storageMode,
                            arrayLength: 1, parent: self)
    }
}

final class MetalBuffer: MTLBuffer {
    let owner: MetalDevice
    let gpu: GPUBuffer
    let length: Int
    var label: String?
    init(device: MetalDevice, gpu: GPUBuffer, length: Int) {
        owner = device
        self.gpu = gpu
        self.length = length
    }
    var device: MTLDevice { owner }
    func contents() -> UnsafeMutableRawPointer { gpu.contents }
    func didModifyRange(_ range: Range<Int>) {}
}

final class MetalSampler: MTLSamplerState {
    let owner: MetalDevice
    let gpu: GPUSampler
    let label: String?
    init(device: MetalDevice, gpu: GPUSampler, label: String?) {
        owner = device
        self.gpu = gpu
        self.label = label
    }
    var device: MTLDevice { owner }
}

final class MetalDepthStencil: MTLDepthStencilState {
    let owner: MetalDevice
    let state: GPUDepthStencilDescriptor
    let label: String?
    init(device: MetalDevice, state: GPUDepthStencilDescriptor, label: String?) {
        owner = device
        self.state = state
        self.label = label
    }
    var device: MTLDevice { owner }
}

final class MetalPipeline: MTLRenderPipelineState {
    let owner: MetalDevice
    let gpu: GPURenderPipeline
    let label: String?
    /// Has a native geometry stage (`MTLRenderPipelineDescriptor.geometryFunction`).
    let nativeGeometry: Bool
    init(device: MetalDevice, gpu: GPURenderPipeline, label: String?, nativeGeometry: Bool = false) {
        owner = device
        self.gpu = gpu
        self.label = label
        self.nativeGeometry = nativeGeometry
    }
    var device: MTLDevice { owner }
}

final class MetalFunction: MTLFunction {
    let owner: MetalDevice
    let name: String
    var label: String?
    private var cached: GPUShaderModule?
    private let make: (() throws -> GPUShaderModule)?

    init(device: MetalDevice, name: String, module: GPUShaderModule) {
        owner = device
        self.name = name
        cached = module
        make = nil
    }

    init(device: MetalDevice, name: String, lazy: @escaping () throws -> GPUShaderModule) {
        owner = device
        self.name = name
        make = lazy
    }

    var device: MTLDevice { owner }

    func module() throws -> GPUShaderModule {
        if let m = cached { return m }
        let m = try make!()
        cached = m
        return m
    }

    var functionType: MTLFunctionType {
        guard let m = try? module() else { return .vertex }
        return m.stage == .fragment ? .fragment : .vertex
    }

    /// SPIR-V input locations of a vertex function = the engine attribute ids (Metal attribute indices).
    var vertexAttributes: [MTLVertexAttribute]? {
        guard let m = try? module(), m.stage == .vertex else { return nil }
        return m.reflection.inputs.map { MTLVertexAttribute(name: $0.name, attributeIndex: $0.location, isActive: true) }
    }
}

final class MetalLibrary: MTLLibrary {
    let owner: MetalDevice
    let functions: [String: MetalFunction]
    var label: String?
    init(device: MetalDevice, functions: [String: MetalFunction]) {
        owner = device
        self.functions = functions
    }
    var device: MTLDevice { owner }
    var functionNames: [String] { Array(functions.keys) }
    func makeFunction(name: String) -> MTLFunction? {
        if let f = functions[name] { return f }
        NSLog("photon: Metal facade: no function %@ in library", name)
        return nil
    }
}

// MARK: - SPIR-V in place of MSL

/// How PhotonRender's ShaderCompiler hands SPIR-V to `makeLibrary(source:)` on Linux: the `msl` string carries the
/// stage and the SPIR-V words in base64 behind a marker line.
public enum MetalSPIRV {
    static let marker = "// photon2-spirv "

    public static func source(stage: GPUShaderStage, words: [UInt32]) -> String {
        let data = words.withUnsafeBytes { Data($0) }
        return marker + SPIRVCompiler.stageName(stage) + "\n" + data.base64EncodedString() + "\n"
    }

    static func decode(_ source: String) -> (stage: GPUShaderStage, words: [UInt32])? {
        guard source.hasPrefix(marker) else { return nil }
        let lines = source.split(separator: "\n", maxSplits: 1)
        guard lines.count == 2 else { return nil }
        let stageName = lines[0].dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        let stage: GPUShaderStage = stageName == "vert" ? .vertex : stageName == "geom" ? .geometry : .fragment
        guard let data = Data(base64Encoded: lines[1].trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return (stage, SPIRVReflection.words([UInt8](data)))
    }
}
