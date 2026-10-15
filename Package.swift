// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "photon2",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "photon", targets: ["photon"]),
        .executable(name: "photon-tool", targets: ["photon-tool"]),
    ],
    targets: [
        // Desktop-level window hosting: one borderless Metal window per display, behind the icons.
        .target(name: "PhotonHost"),
        // The version string (photon_version.h; packaging stamps it, docs/linux-port.md §6.2).
        .target(name: "CPhotonVersion"),
        // Wallpaper Engine file formats and asset resolution, rebuilt from docs/re.
        .target(name: "PhotonCore", dependencies: ["CPhotonVersion"]),
        // Metal renderer for scenes.
        .target(name: "PhotonRender", dependencies: ["PhotonCore"]),
        // Developer CLI: corpus scans and format checks.
        .executableTarget(name: "photon-tool", dependencies: ["PhotonCore", "PhotonRender"]),
        // The app model shared by the macOS app and the Linux app (`photon-linux app`): AppState and its persistence, the
        // library scan, playlists and their scheduler, the playback evaluator, property presets, layout geometry and the
        // settings catalog. Foundation + Combine (a LinuxCompat stand-in on Linux) + PhotonRender's settings statics.
        .target(name: "PhotonApp", dependencies: ["PhotonRender", "PhotonCore"]),
        .executableTarget(name: "photon", dependencies: ["PhotonApp", "PhotonHost", "PhotonRender", "PhotonCore"]),
        // `swift test`: the app's logic (playlists, playback rules, settings, layouts, transitions) and a headless
        // renderer harness (offscreen views, no desktop windows; PHOTON_TEST_INTEGRATION=1 for the GPU/corpus part).
        .testTarget(name: "photonTests", dependencies: ["photon", "PhotonApp", "PhotonHost", "PhotonRender", "PhotonCore"]),
    ]
)

// Single-threaded render loop; Swift 6 strict concurrency adds nothing here.
for target in package.targets {
    target.swiftSettings = [.swiftLanguageMode(.v5)]
}

// MARK: - Linux port (docs/linux-port.md)
// Additive block: the macOS targets above are unchanged. PhotonGPU (the backend-neutral GPU interface) builds everywhere.
// The Vulkan backend and the headless prototype build on Linux, and on macOS with PHOTON_VULKAN=1 (Homebrew
// vulkan-loader + molten-vk) for local iteration. On Linux the app targets are dropped and PhotonRender builds against the
// LinuxCompat stand-ins below.
#if os(Linux)
let photonLinux = true
#else
let photonLinux = false
#endif
let photonVulkan = photonLinux || Context.environment["PHOTON_VULKAN"] == "1"

package.targets.append(.target(name: "PhotonGPU", swiftSettings: [.swiftLanguageMode(.v5)]))
if photonVulkan {
    package.targets.append(contentsOf: [
        .systemLibrary(name: "CVulkan", pkgConfig: "vulkan",
                       providers: [.apt(["libvulkan-dev"]), .brew(["vulkan-loader", "vulkan-headers"])]),
        .target(name: "PhotonVulkan", dependencies: ["PhotonGPU", "CVulkan"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // Headless scene prototype written against PhotonGPU only (clear + plain image layers → PNG).
        .target(name: "PhotonProto", dependencies: ["PhotonCore", "PhotonGPU"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "photon-linux", dependencies: ["PhotonCore", "PhotonGPU", "PhotonVulkan", "PhotonProto"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
    package.products.append(.executable(name: "photon-linux", targets: ["photon-linux"]))
}
if photonLinux {
    // Image decode (libpng, libjpeg-turbo) and LZ4 for PhotonCore in place of ImageIO / Compression.
    // stb_image decodes GIFs: the loader the engine's resourceutil64.dll uses (OpenGIF/AdvanceGIF).
    package.targets.append(.systemLibrary(name: "CPhotonLinux", providers: [.apt(["libpng-dev", "libturbojpeg0-dev", "liblz4-dev", "libstb-dev"])]))

    // Apple-framework stand-ins (docs/linux-port.md §4): modules with the Apple names, implementing the subset of each API
    // PhotonRender calls, so the renderer's sources build unchanged on Linux. `Metal` is a facade over PhotonGPU (Vulkan);
    // the rest wrap FreeType, JavaScriptCore (WebKitGTK) or are plain Swift.
    let compat = "Sources/LinuxCompat/"
    let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]
    package.targets.append(contentsOf: [
        .target(name: "simd", path: compat + "simd", swiftSettings: v5),
        .target(name: "CryptoKit", path: compat + "CryptoKit", swiftSettings: v5),
        .target(name: "Accelerate", path: compat + "Accelerate", swiftSettings: v5),
        .target(name: "Metal", dependencies: ["PhotonGPU", "PhotonVulkan"], path: compat + "Metal", swiftSettings: v5),
        .systemLibrary(name: "CFreeType", path: compat + "CFreeType", pkgConfig: "freetype2",
                       providers: [.apt(["libfreetype-dev", "libfontconfig-dev"])]),
        .target(name: "CoreGraphics", dependencies: ["CFreeType"], path: compat + "CoreGraphics", swiftSettings: v5),
        // HarfBuzz shapes CTLine runs (the engine shapes with HarfBuzz too, docs/linux-port.md §3.3).
        .systemLibrary(name: "CHarfBuzz", path: compat + "CHarfBuzz", pkgConfig: "harfbuzz", providers: [.apt(["libharfbuzz-dev"])]),
        .target(name: "CoreText", dependencies: ["CoreGraphics", "CFreeType", "CHarfBuzz"], path: compat + "CoreText", swiftSettings: v5),
        .systemLibrary(name: "CJavaScriptCore", path: compat + "CJavaScriptCore", pkgConfig: "javascriptcoregtk-4.1",
                       providers: [.apt(["libjavascriptcoregtk-4.1-dev"])]),
        .target(name: "JavaScriptCore", dependencies: ["CJavaScriptCore"], path: compat + "JavaScriptCore", swiftSettings: v5),
        .target(name: "AppKit", dependencies: ["CoreGraphics"], path: compat + "AppKit", swiftSettings: v5),
        // GStreamer for video textures, video wallpapers and their audio (docs/linux-port.md §3.5), behind a small C
        // interface (CPhotonMedia) so Swift never sees GLib's variadic API.
        .systemLibrary(name: "CGStreamer", path: compat + "CGStreamer", pkgConfig: "gstreamer-app-1.0",
                       providers: [.apt(["libgstreamer1.0-dev", "libgstreamer-plugins-base1.0-dev"])]),
        .target(name: "CPhotonMedia", dependencies: ["CGStreamer"], path: "Sources/CPhotonMedia",
                linkerSettings: [.linkedLibrary("gstvideo-1.0"), .linkedLibrary("gstapp-1.0")]),
        // Xlib + XRandR for the X11 desktop host in photon-linux; DPMS and MIT-SCREEN-SAVER for its sleep/screensaver rules;
        // XInput 2 for desktop clicks and XTEST for the pointer test client.
        .systemLibrary(name: "CX11", path: compat + "CX11", pkgConfig: "x11", providers: [.apt(["libx11-dev", "libxrandr-dev", "libxss-dev", "libxi-dev", "libxtst-dev"])]),
        // Phase 4 (docs/linux-port.md §3.6, §5.1): OpenAL Soft 1.21.1 for sound objects (the engine's own library), and
        // CPhotonSystem (C) for spectrum capture (PipeWire, PulseAudio) and D-Bus (MPRIS, UPower, logind, screensaver).
        .systemLibrary(name: "COpenAL", path: compat + "COpenAL", pkgConfig: "openal", providers: [.apt(["libopenal-dev"])]),
        .systemLibrary(name: "CPipeWire", path: compat + "CPipeWire", pkgConfig: "libpipewire-0.3", providers: [.apt(["libpipewire-0.3-dev"])]),
        .systemLibrary(name: "CPulseSimple", path: compat + "CPulseSimple", pkgConfig: "libpulse-simple", providers: [.apt(["libpulse-dev"])]),
        .systemLibrary(name: "CGio", path: compat + "CGio", pkgConfig: "gio-2.0", providers: [.apt(["libglib2.0-dev"])]),
        .target(name: "CPhotonSystem", dependencies: ["CPipeWire", "CPulseSimple", "CGio"], path: "Sources/CPhotonSystem"),
        // Phase 5 (docs/linux-port.md §5.2, §5.3): the Wayland host's client side (layer-shell, xdg-output, viewporter,
        // fractional-scale, foreign-toplevel; generated protocol code in Sources/CPhotonWayland/protocols), and web
        // wallpapers on WebKitGTK 4.1 (GTK 3, the javascriptcoregtk-4.1 SceneScript links) with gtk-layer-shell.
        .systemLibrary(name: "CWaylandClient", path: compat + "CWaylandClient", pkgConfig: "wayland-client",
                       providers: [.apt(["libwayland-dev"])]),
        .target(name: "CPhotonWayland", dependencies: ["CWaylandClient"], path: "Sources/CPhotonWayland"),
        .systemLibrary(name: "CWebKitGTK", path: compat + "CWebKitGTK", pkgConfig: "webkit2gtk-4.1",
                       providers: [.apt(["libwebkit2gtk-4.1-dev"])]),
        .systemLibrary(name: "CGtkLayerShell", path: compat + "CGtkLayerShell", pkgConfig: "gtk-layer-shell-0",
                       providers: [.apt(["libgtk-layer-shell-dev"])]),
        .target(name: "CPhotonWeb", dependencies: ["CWebKitGTK", "CGtkLayerShell"], path: "Sources/CPhotonWeb"),
        // Phase 6 (docs/linux-port.md §6.1): the app. Combine's ObservableObject / @Published for the shared model
        // (PhotonApp), GTK 3 for its windows, and CPhotonApp (C) for the StatusNotifierItem + dbusmenu status icon.
        .target(name: "Combine", path: compat + "Combine", swiftSettings: v5),
        .systemLibrary(name: "CGtk3", path: compat + "CGtk3", pkgConfig: "gtk+-3.0", providers: [.apt(["libgtk-3-dev"])]),
        .target(name: "CPhotonApp", dependencies: ["CGtk3"], path: "Sources/CPhotonApp"),
    ])
    if let app = package.targets.first(where: { $0.name == "PhotonApp" }) {
        app.dependencies += ["Combine", "JavaScriptCore"]
    }
    if let core = package.targets.first(where: { $0.name == "PhotonCore" }) {
        core.dependencies += ["CPhotonLinux", "simd", "CoreGraphics"]
    }
    // PhotonRender builds from the same sources; files whose job is a macOS service are replaced by
    // Sources/PhotonRender/Linux/*.swift: VideoTexture on GStreamer, AudioCapture's backends on PipeWire/PulseAudio, the
    // MediaRemote poller on MPRIS, sound voices on OpenAL Soft (Sound*.swift build with `#if os(Linux)` branches). Web
    // wallpapers (WKWebView) come with phase 5.
    if let render = package.targets.first(where: { $0.name == "PhotonRender" }) {
        render.dependencies += ["PhotonGPU", "simd", "CryptoKit", "Accelerate", "Metal", "CoreGraphics", "CoreText", "JavaScriptCore", "AppKit",
                                "CPhotonMedia", "COpenAL", "CPhotonSystem"]
        render.exclude += ["AudioCapture.swift", "WebWallpaper.swift", "WebMedia.swift", "VideoTexture.swift", "GeometryCheck.swift"]
    }
    if let tool = package.targets.first(where: { $0.name == "photon-linux" }) {
        tool.dependencies += ["PhotonRender", "Metal", "CoreGraphics", "CoreText", "CX11", "CPhotonMedia", "COpenAL", "CPhotonSystem",
                              "CPhotonWayland", "CPhotonWeb", "PhotonApp", "Combine", "CGtk3", "CPhotonApp"]
        // The playback-rule evaluator and the app model come from PhotonApp, shared with the macOS app.
    }
    let appleOnly: Set<String> = ["PhotonHost", "photon", "photon-tool", "photonTests"]
    package.targets.removeAll { appleOnly.contains($0.name) }
    package.products.removeAll { appleOnly.contains($0.name) }
}
