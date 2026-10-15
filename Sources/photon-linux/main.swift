import Foundation
import PhotonCore
import PhotonGPU
import PhotonProto
#if os(Linux)
import PhotonRender
#endif
import PhotonVulkan

// photon-linux: the Linux port's developer CLI (docs/linux-port.md §6).
//   photon-linux --version                                   the version (PhotonVersion: stamped by packaging)
//   photon-linux info                                        Vulkan device and capabilities
//   photon-linux render <id|dir> <out.png> [sec] [w] [h]     headless render with the full renderer (Linux) to PNG
//   photon-linux render-proto <id|dir> <out.png> [sec] [w] [h]  the PhotonGPU-only prototype (clear + plain image layers)
//   photon-linux reflect <file.spv>                          SPIR-V reflection as JSON (cross-check with spirv-cross)
//   photon-linux bench <id|dir> [frames] [w] [h] [--sync] [--readback]   frames per second (Bench.swift)
//   photon-linux desktop <id|dir> [options]                  X11 / Wayland / web desktop hosts (Host/)
//   photon-linux app [--background] [--self-test DIR]        the app: status icon, browser, playlists, settings (App/)
//   photon-linux video-frame <file> <sec> <out.png> | gif-frames <file.gif> [prefix] | text-shape <font> <size> <text>
//                                                            media and text checks against macOS (MediaCheck.swift)
//   photon-linux sound-check [mac-ref-dir] | spectrum-check <s> <L Hz> <R Hz> | media-check <s> | system-check <s>
//                                                            audio and system integration checks (AudioCheck.swift)
// Environment: PHOTON_WE_ASSETS (engine assets dir), PHOTON_WORKSHOP (workshop content/431960 dir), PHOTON_ONLY (ids).

let env = ProcessInfo.processInfo.environment
let args = Array(CommandLine.arguments.dropFirst())

func fail(_ s: String) -> Never {
    FileHandle.standardError.write(Data((s + "\n").utf8))
    exit(1)
}

var engineAssets: URL {
    if let p = env["PHOTON_WE_ASSETS"] { return URL(fileURLWithPath: p) }
    #if os(Linux)
    return URL(fileURLWithPath: "/we/assets")
    #else
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/common/wallpaper_engine/assets")
    #endif
}

var workshop: URL {
    if let p = env["PHOTON_WORKSHOP"] { return URL(fileURLWithPath: p) }
    #if os(Linux)
    return URL(fileURLWithPath: "/workshop")
    #else
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam/steamapps/workshop/content/431960")
    #endif
}

switch args.first {
case "--version", "version":
    print("photon-linux \(PhotonVersion.string)")

case "info":
    do {
        let d = try VulkanDevice()
        let c = d.capabilities
        print("device: \(c.deviceName)")
        print("geometry shaders: \(c.geometryShaders), BC textures: \(c.bcTextureCompression), max anisotropy: \(c.maxAnisotropy), "
              + "max MSAA: \(c.maxSampleCount), multi-viewport: \(c.multiViewport)")
        print("driver: \(d.driverDescription)\(d.writesAllSamplers ? " (every sampler descriptor written: lavapipe before Mesa 23.2)" : "")")
    } catch { fail("\(error)") }

case "render":
    // The full renderer (PhotonRender through the Metal facade on Vulkan); on macOS builds photon-tool is the renderer.
    #if os(Linux)
    SceneRender.main(Array(args.dropFirst()), workshop: workshop, engineAssets: engineAssets)
    #else
    fail("photon-linux render runs on Linux; on macOS use photon-tool render (or render-proto)")
    #endif

case "render-proto":
    guard args.count >= 3 else { fail("usage: photon-linux render-proto <id|dir> <out.png> [seconds] [width] [height]") }
    let id = args[1], out = URL(fileURLWithPath: args[2])
    var options = ProtoScene.Options()
    if args.count > 3, let t = Float(args[3]) { options.time = t }
    if args.count > 4, let w = Int(args[4]) { options.width = w }
    if args.count > 5, let h = Int(args[5]) { options.height = h }
    if let only = env["PHOTON_ONLY"] { options.only = Set(only.split(separator: ",").compactMap { Int($0) }) }
    let dir = id.hasPrefix("/") || id.hasPrefix(".") ? URL(fileURLWithPath: id) : workshop.appendingPathComponent(id)
    do {
        let start = Date()
        let device = try VulkanDevice()
        let scene = try ProtoScene(device: device, wallpaper: dir, engineAssets: engineAssets, options: options)
        for line in scene.log { print("note: \(line)") }
        print("device \(device.capabilities.deviceName), \(scene.layerCount) layer(s), loaded in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        let rgba = try scene.render()
        let png = PNGWriter.encode(rgba: rgba, width: options.width, height: options.height, keepAlpha: env["PHOTON_KEEPALPHA"] == "1")
        try png.write(to: out)
        print("wrote \(out.path)")
    } catch { fail("render failed: \(error)") }

case "reflect":
    guard args.count >= 2, let data = FileManager.default.contents(atPath: args[1]) else { fail("usage: photon-linux reflect <file.spv>") }
    do {
        let r = try SPIRVReflection(words: SPIRVReflection.words([UInt8](data)))
        var ubos: [[String: Any]] = []
        for b in r.uniformBlocks {
            ubos.append(["name": b.name, "set": b.set, "binding": b.binding, "block_size": b.size,
                         "members": b.members.map { ["name": $0.name, "offset": $0.offset, "type": $0.type, "array": $0.arrayCount,
                                                     "array_stride": $0.arrayStride] }])
        }
        let json: [String: Any] = [
            "entry": r.entryPoint, "ubos": ubos,
            "images": r.images.map { ["name": $0.name, "binding": $0.binding] },
            "samplers": r.samplers.map { ["name": $0.name, "binding": $0.binding] },
            "inputs": r.inputs.map { ["name": $0.name, "location": $0.location, "type": $0.type] },
        ]
        let d = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: d, as: UTF8.self))
    } catch { fail("\(error)") }

#if os(Linux)
case "bench": // frames per second of the full renderer (Bench.swift)
    Bench.main(Array(args.dropFirst()), workshop: workshop, engineAssets: engineAssets)

case "desktop": // X11 desktop host (Host/X11Desktop.swift)
    exit(DesktopCommand.main(args, workshop: workshop, engineAssets: engineAssets))

case "app": // the app: status icon, browser, properties, playlists, settings (App/LinuxApp.swift)
    exit(LinuxApp.main(args))

case "video-frame": exit(MediaCheck.videoFrame(Array(args.dropFirst()))) // MediaCheck.swift
case "gif-frames": exit(MediaCheck.gifFrames(Array(args.dropFirst())))
case "text-shape": exit(MediaCheck.textShape(Array(args.dropFirst())))
case "sound-check": exit(AudioCheck.soundCheck(Array(args.dropFirst()))) // AudioCheck.swift
case "spectrum-check": exit(AudioCheck.spectrumCheck(Array(args.dropFirst())))
case "media-check": _ = ScriptMediaCheck.run(seconds: args.count > 1 ? Double(args[1]) ?? 5 : 5)
case "system-check": exit(AudioCheck.systemCheck(Array(args.dropFirst())))
case "hrtf-ir": exit(AudioCheck.hrtfIR(Array(args.dropFirst())))
case "transition": exit(TransitionCheck.main(Array(args.dropFirst()), workshop: workshop, engineAssets: engineAssets)) // TransitionCheck.swift
#endif

default:
    fail("usage: photon-linux --version | app [--background] | desktop <id|dir> [options] | info | render <id|dir> <out.png> [seconds] [width] [height] | reflect <file.spv>")
}
