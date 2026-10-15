import CVulkan
import Foundation
import PhotonGPU

/// Keeps C structs and strings alive for the duration of a Vulkan call chain (pNext chains, arrays of create infos).
final class Arena {
    private var frees: [() -> Void] = []

    func ptr<T>(_ value: T) -> UnsafeMutablePointer<T> {
        let p = UnsafeMutablePointer<T>.allocate(capacity: 1)
        p.initialize(to: value)
        frees.append { p.deinitialize(count: 1); p.deallocate() }
        return p
    }

    func array<T>(_ values: [T]) -> UnsafeMutablePointer<T>? {
        guard !values.isEmpty else { return nil }
        let p = UnsafeMutablePointer<T>.allocate(capacity: values.count)
        p.initialize(from: values, count: values.count)
        frees.append { p.deinitialize(count: values.count); p.deallocate() }
        return p
    }

    func cstr(_ s: String) -> UnsafePointer<CChar> {
        let p = strdup(s)!
        frees.append { free(p) }
        return UnsafePointer(p)
    }

    func cstrs(_ list: [String]) -> UnsafePointer<UnsafePointer<CChar>?>? {
        guard let a = array(list.map { Optional(cstr($0)) }) else { return nil }
        return UnsafePointer(a)
    }

    deinit { for f in frees.reversed() { f() } }
}

func vkCheck(_ r: VkResult, _ what: @autoclosure () -> String) throws {
    guard r == VK_SUCCESS else { throw GPUError.failed("\(what()) failed: VkResult \(r.rawValue)") }
}

func vkVersion(_ major: UInt32, _ minor: UInt32, _ patch: UInt32 = 0) -> UInt32 { (major << 22) | (minor << 12) | patch }

/// A fixed-size C char array (deviceName, extensionName) as a String.
func cString<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
}

extension GPUPixelFormat {
    var vk: VkFormat {
        switch self {
        case .rgba8Unorm: return VK_FORMAT_R8G8B8A8_UNORM
        case .bgra8Unorm: return VK_FORMAT_B8G8R8A8_UNORM
        case .rgba8UnormSRGB: return VK_FORMAT_R8G8B8A8_SRGB
        case .bgra8UnormSRGB: return VK_FORMAT_B8G8R8A8_SRGB
        case .rg8Unorm: return VK_FORMAT_R8G8_UNORM
        case .r8Unorm: return VK_FORMAT_R8_UNORM
        case .rgba16Float: return VK_FORMAT_R16G16B16A16_SFLOAT
        case .rg16Float: return VK_FORMAT_R16G16_SFLOAT
        case .r16Float: return VK_FORMAT_R16_SFLOAT
        case .rgba32Float: return VK_FORMAT_R32G32B32A32_SFLOAT
        case .r32Float: return VK_FORMAT_R32_SFLOAT
        case .rgba16Unorm: return VK_FORMAT_R16G16B16A16_UNORM
        case .rgba16Snorm: return VK_FORMAT_R16G16B16A16_SNORM
        // DXGI R10G10B10A2 has red in the low bits: Vulkan's A2B10G10R10 pack.
        case .rgb10a2Unorm: return VK_FORMAT_A2B10G10R10_UNORM_PACK32
        case .bc1: return VK_FORMAT_BC1_RGBA_UNORM_BLOCK
        case .bc2: return VK_FORMAT_BC2_UNORM_BLOCK
        case .bc3: return VK_FORMAT_BC3_UNORM_BLOCK
        case .bc7: return VK_FORMAT_BC7_UNORM_BLOCK
        case .depth32Float: return VK_FORMAT_D32_SFLOAT
        case .depth24Stencil8: return VK_FORMAT_D24_UNORM_S8_UINT
        }
    }

    var aspect: VkImageAspectFlags {
        switch self {
        case .depth32Float: return VK_IMAGE_ASPECT_DEPTH_BIT.rawValue
        case .depth24Stencil8: return VK_IMAGE_ASPECT_DEPTH_BIT.rawValue | VK_IMAGE_ASPECT_STENCIL_BIT.rawValue
        default: return VK_IMAGE_ASPECT_COLOR_BIT.rawValue
        }
    }
}

extension GPUVertexFormat {
    var vk: VkFormat {
        switch self {
        case .float: return VK_FORMAT_R32_SFLOAT
        case .float2: return VK_FORMAT_R32G32_SFLOAT
        case .float3: return VK_FORMAT_R32G32B32_SFLOAT
        case .float4: return VK_FORMAT_R32G32B32A32_SFLOAT
        case .uchar4Normalized: return VK_FORMAT_R8G8B8A8_UNORM
        case .uchar4: return VK_FORMAT_R8G8B8A8_UINT
        case .ushort2: return VK_FORMAT_R16G16_UINT
        case .ushort4: return VK_FORMAT_R16G16B16A16_UINT
        case .short2Normalized: return VK_FORMAT_R16G16_SNORM
        case .short4Normalized: return VK_FORMAT_R16G16B16A16_SNORM
        case .uint: return VK_FORMAT_R32_UINT
        case .uint4: return VK_FORMAT_R32G32B32A32_UINT
        }
    }
}

extension GPUBlendFactor {
    var vk: VkBlendFactor {
        switch self {
        case .zero: return VK_BLEND_FACTOR_ZERO
        case .one: return VK_BLEND_FACTOR_ONE
        case .sourceColor: return VK_BLEND_FACTOR_SRC_COLOR
        case .oneMinusSourceColor: return VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR
        case .sourceAlpha: return VK_BLEND_FACTOR_SRC_ALPHA
        case .oneMinusSourceAlpha: return VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
        case .destinationColor: return VK_BLEND_FACTOR_DST_COLOR
        case .oneMinusDestinationColor: return VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR
        case .destinationAlpha: return VK_BLEND_FACTOR_DST_ALPHA
        case .oneMinusDestinationAlpha: return VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA
        }
    }
}

extension GPUBlendOperation {
    var vk: VkBlendOp {
        switch self {
        case .add: return VK_BLEND_OP_ADD
        case .subtract: return VK_BLEND_OP_SUBTRACT
        case .reverseSubtract: return VK_BLEND_OP_REVERSE_SUBTRACT
        case .min: return VK_BLEND_OP_MIN
        case .max: return VK_BLEND_OP_MAX
        }
    }
}

extension GPUCompareFunction {
    var vk: VkCompareOp {
        switch self {
        case .never: return VK_COMPARE_OP_NEVER
        case .less: return VK_COMPARE_OP_LESS
        case .equal: return VK_COMPARE_OP_EQUAL
        case .lessEqual: return VK_COMPARE_OP_LESS_OR_EQUAL
        case .greater: return VK_COMPARE_OP_GREATER
        case .notEqual: return VK_COMPARE_OP_NOT_EQUAL
        case .greaterEqual: return VK_COMPARE_OP_GREATER_OR_EQUAL
        case .always: return VK_COMPARE_OP_ALWAYS
        }
    }
}

extension GPUAddressMode {
    var vk: VkSamplerAddressMode {
        switch self {
        case .repeat: return VK_SAMPLER_ADDRESS_MODE_REPEAT
        case .clampToEdge: return VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
        case .mirrorRepeat: return VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT
        case .clampToBorder: return VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER
        }
    }
}

extension GPUColorWriteMask {
    var vk: VkColorComponentFlags {
        var m: UInt32 = 0
        if contains(.red) { m |= VK_COLOR_COMPONENT_R_BIT.rawValue }
        if contains(.green) { m |= VK_COLOR_COMPONENT_G_BIT.rawValue }
        if contains(.blue) { m |= VK_COLOR_COMPONENT_B_BIT.rawValue }
        if contains(.alpha) { m |= VK_COLOR_COMPONENT_A_BIT.rawValue }
        return m
    }
}

extension GPUVertexLayout {
    /// Engine attribute ids sharing a D3D semantic (docs/re/02 §6), as `VertexLayout.semanticGroup` (ShaderProgram.swift).
    static func semanticGroup(_ id: Int) -> Int {
        switch id {
        case 0, 1: return 0
        case 7...24: return 100 + (id - 7) / 3
        default: return 1000 + id
        }
    }

    /// D3D11 binds vertex inputs by semantic and fills missing components with (0, 0, 0, 1): a shader input the mesh
    /// lacks (a_PositionVec4 on the float3 quad) reads the mesh attribute with the same semantic. Vulkan, like Metal,
    /// needs an explicit attribute per consumed location, so the aliases are added here; Vulkan expands the missing
    /// components with (0, 0, 0, 1) like D3D11.
    func attributes(forInputs locations: [Int]) -> [GPUVertexAttribute] {
        var out = attributes.filter { a in locations.contains(a.location) }
        for loc in locations where !out.contains(where: { $0.location == loc }) {
            if let src = attributes.first(where: { Self.semanticGroup($0.location) == Self.semanticGroup(loc) }) {
                out.append(GPUVertexAttribute(location: loc, format: src.format, offset: src.offset))
            }
        }
        return out
    }
}
