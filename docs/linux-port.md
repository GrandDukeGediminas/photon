# photon2 on Linux

State as of 2026-10-14 (phase 6). The renderer (PhotonRender, about 24,000 lines) builds unchanged on Linux and renders
scene, video and GIF wallpapers through Vulkan. All 22 test wallpapers in §7 render on Mesa lavapipe in a Docker
container within their committed limits against the macOS Metal render. Video textures and video wallpapers decode
through GStreamer (§3.5), GIFs through stb_image (the engine's decoder; both test GIF wallpapers are pixel-identical to
macOS), and text is shaped by HarfBuzz: 14 shaping cases give CoreText's exact glyphs, advances and positions (§3.3). The
X11 desktop host draws wallpapers behind the desktop, presents through a Vulkan swapchain (readback + XShmPutImage remains
as the fallback) and plays a video wallpaper's sound. Phase 4 added audio and system integration: sound objects play
through OpenAL Soft 1.21.1, the engine's own audio library (§3.6), the audio spectrum is captured from PipeWire or
PulseAudio, SceneScript media events come from MPRIS, and the host's playback rules run the macOS app's evaluator on
UPower, logind, screensaver and DPMS inputs (§5, §5.1). Phase 5 added the Wayland host: layer-shell background
surfaces per output with Vulkan or `wl_shm` presentation, hotplug, fractional scale and pause rules from
wlr-foreign-toplevel (§5.2), and web wallpapers on WebKitGTK 4.1 with the macOS host's page API (§5.3).
Phase 6 added the app: the macOS app's model moved into the `PhotonApp` library, which both apps use, and
`photon-linux app` is a GTK 3 app with a StatusNotifierItem status icon, the wallpaper browser, properties, presets,
playlists and settings, driving the desktop hosts as child processes (§6.1). It ships as a `.deb`, an `.rpm`, a tarball,
a Flatpak manifest and a systemd user unit (§6.2). `scripts/linux/ci.sh` builds and checks everything in Docker against
the local corpus; `.github/workflows/ci.yml` runs on hosted runners with six CC0 test scenes instead (§7). Phase 6b
closed the remaining feature gaps with the macOS app (§5.4): wallpaper-switch transitions (all 27 effects, the −1 / −2
rules, scene, video and web, in one host or handed over between host processes without a black frame), playlist
advance at a video's end, the application, audio-playing and VRAM rules, single instance, stretch and clone on Wayland,
and the cursor (position and desktop clicks) on both hosts. Phase 6c covered the two desktop environments the Wayland
host did not: on KDE Plasma the rules read KWin's `org_kde_plasma_window_management`, and on GNOME a Shell extension
(`packaging/gnome-shell`) shows the host's frames as the desktop background and reports Mutter's window states over
D-Bus (§5.2). What is left is in §9.

## 1. Layout

| Target | Platform | What it is |
|---|---|---|
| `PhotonCore` | all | file formats, asset resolution, HLSL translation. `Linux/LinuxPlatform.swift` replaces ImageIO (libpng, libjpeg-turbo), Compression (liblz4) and a few CoreFoundation calls |
| `PhotonGPU` | all | backend-neutral GPU interface: value types and protocols, SPIR-V compiler driver (glslang), SPIR-V reflection |
| `PhotonVulkan` | Linux; macOS with `PHOTON_VULKAN=1` | `PhotonGPU` on Vulkan 1.3 (dynamic rendering, extended dynamic state) |
| `PhotonRender` | all | the renderer. On macOS it uses Metal and Apple frameworks directly; on Linux the same sources build against `Sources/LinuxCompat` |
| `Sources/LinuxCompat/*` | Linux | modules named after the Apple frameworks PhotonRender imports (`Metal`, `simd`, `CoreGraphics`, `CoreText`, `JavaScriptCore`, `AppKit`, `CryptoKit`, `Accelerate`) plus C module maps (`CVulkan`, `CFreeType`, `CHarfBuzz`, `CGStreamer`, `CJavaScriptCore`, `CX11`, `COpenAL`, `CPipeWire`, `CPulseSimple`, `CGio`, `CWaylandClient`, `CWebKitGTK`, `CGtkLayerShell`) |
| `PhotonRender/Linux/*.swift` | Linux | the Linux side of the PhotonRender files that wrap a macOS service: `VideoTextureLinux` (GStreamer, §3.5), `SoundOpenAL` (sound voices on OpenAL Soft), `AudioCaptureLinux` (spectrum capture backends), `LinuxMedia` (MPRIS poller) (§3.6, §5.1), `WebMediaLinux` (MPRIS
media events for web pages, §5.3). Excluded on Linux: `AudioCapture.swift` (Core Audio tap, ScreenCaptureKit), `VideoTexture.swift`, `WebWallpaper.swift`, `WebMedia.swift`, `GeometryCheck.swift` |
| `CPhotonMedia` (+ `LinuxCompat/CGStreamer`) | Linux | C wrapper over GStreamer: video decoder pulled on the scene clock, Y'CbCr → BGRA, audio-only player (§3.5), whole-file PCM decode for OpenAL buffers (§3.6) |
| `CPhotonWayland` (+ `CWaylandClient`) | Linux | Wayland client for the desktop host: outputs, layer surfaces, GNOME background toplevels, fractional scale, `wl_shm` buffers, foreign-toplevel states, KWin's Plasma window and virtual-desktop states, a test client; generated protocol code in `protocols/` (§5.2) |
| `CPhotonWeb` (+ `CWebKitGTK`, `CGtkLayerShell`) | Linux | WebKitGTK 4.1 web views in background windows (layer-shell or DESKTOP type), the `photon-web` scheme, script messages (§5.3) |
| `CPhotonSystem` (+ `CPipeWire`, `CPulseSimple`, `CGio`) | Linux | C wrapper for system services: spectrum capture from the default sink's monitor (PipeWire `pw_stream`, PulseAudio `pa_simple` fallback), MPRIS polling, the UPower / logind / screensaver signal watcher (§3.6, §5.1), the GNOME Shell extension's state and pointer signals (`photon_gnome.c`, §5.2) |
| `PhotonProto` | Linux; macOS with `PHOTON_VULKAN=1` | the first prototype: clear + plain image layers written directly against `PhotonGPU` |
| `PhotonApp` | all | the app model both apps use (§6.1): `AppState` and its persistence, the library scan, property specs and conditions, playlists and their scheduler (`PlaylistController`), the playback evaluator, property presets, layout geometry, the settings catalog; `XDGDefaults` (Linux) keeps the settings in `~/.config/photon2/photon2.plist` |
| `photon-linux` | Linux; macOS with `PHOTON_VULKAN=1` | CLI: `app` (the GTK app, `App/`), `info`, `render`, `render-proto`, `reflect`, `bench`, `desktop` (X11, Wayland and web hosts; `--control`, `--output`, `--list-outputs` for the app), the media/text checks `video-frame`, `gif-frames`, `text-shape`, the audio/system checks `sound-check`, `spectrum-check`, `media-check`, `system-check`, `hrtf-ir`, and `transition` (one switch-overlay frame, §5.4) |
| `CPhotonApp` (+ `LinuxCompat/CGtk3`, `LinuxCompat/Combine`) | Linux | the status icon (StatusNotifierItem + com.canonical.dbusmenu over GDBus), the Background portal, GTK helpers; GTK 3 for the app's windows; `Combine` is a stand-in with `ObservableObject`, `@Published` and the publisher operators PhotonApp uses |
| `packaging/` | Linux | `.desktop` entries (including `photon2-kwin.desktop`, KWin's permission entry), icon, systemd user unit, AppStream metadata (`linux/`), Flatpak manifest (`flatpak/`), the GNOME Shell extension (`gnome-shell/photon2@photon2.github.io`) |
| `Tests/scenes/` | all | six CC0 test scenes, a CC0 stand-in for the engine's assets folder, references and limits for hosted CI (§7) |
| `scripts/linux/` | host (macOS or Linux) + Docker | build, render, benchmark, pixel-diff and CI scripts (§7, §8) |
| `photon`, `photon-tool`, `PhotonHost`, tests | macOS | unchanged, except the model files moved into `PhotonApp` (§6.1, phase 6), `photon-tool` reading `PHOTON_WE_ASSETS`, and `photon-tool text-shape` (the CoreText side of §3.3's check), `photon-tool sound-ref` (the macOS side of §3.6's check), the evaluator moved into its own file (§3.4) and the web page scripts moved into `WebPageScripts.swift` (§3.4) |

Everything Linux-specific is gated in `Package.swift` (the block under `// MARK: - Linux port`) or by `#if os(Linux)`.
The macOS target graph is the same as before the port except for the behaviour-preserving source edits listed in §3.4 (macOS renders of 8 corpus wallpapers are byte-identical before and after each phase).

## 2. GPU architecture

### 2.1 PhotonGPU

`PhotonGPU` describes the GPU the way the engine uses D3D11, because the translated HLSL is written against that model:

- **Bindings by register.** Constant buffers by `(stage, bN)`, textures by `tN`, samplers by `sN`; textures and samplers
  are shared by all stages. Uniform data is passed by value per draw (`setUniformBytes`), like Metal's `setVertexBytes`
  and the engine's per-draw `Map(WRITE_DISCARD)`.
- **One interleaved vertex stream** (`GPUVertexLayout`), attribute locations = engine attribute ids (docs/re/02 §6).
  Inputs the mesh lacks alias the attribute with the same D3D semantic, as D3D11's input assembler does.
- **Engine conventions in one place** (`EngineConventions.swift`): reverse-Z (clear 0, compare GREATER), counter-clockwise
  front faces, the blend table for modes 0 to 3 with the colour-write, dest-colour and alpha-MAX modifiers.
- **Shaders are SPIR-V** from glslang's HLSL front end (`-D -V -e main --keep-uncalled`, the same flags the macOS path
  has always used). `HLSLRegisterMap` shifts registers into one descriptor set: vertex `b0..b11` at bindings 0..11,
  pixel `b0..b11` at 16..27, `t0..t15` at 32..47, `s0..s15` at 48..63, geometry `bN` at 64+.

Protocols: `GPUDevice`, `GPUBuffer`, `GPUTextureResource` (upload, synchronous readback, views), `GPUSampler`,
`GPUShaderModule` (with reflection), `GPURenderPipeline`, `GPUOcclusionQuerySet`, `GPUCommandBuffer` (render passes with
optional MSAA resolve, texture and region copies, mip generation, texture-to-buffer copies) and `GPURenderEncoder`.

### 2.2 Vulkan backend

`PhotonVulkan` keeps every image in `VK_IMAGE_LAYOUT_GENERAL`, so an image can be an attachment, sampled and copied
without layout bookkeeping (swapchain images are the one exception, §2.2.1). Each draw writes one descriptor set;
registers the pipeline's SPIR-V declares but nothing bound get D3D11's NULL-binding values (a zero constant buffer, a
1×1 transparent black texture, a default sampler). New textures are cleared to zero, as D3D11 does.

All pipelines share one descriptor set layout (every HLSL register at a fixed binding), and Vulkan lets a set leave
the bindings the bound pipeline does not use unwritten. Lavapipe before Mesa 23.2 does not: at `vkCmdBindDescriptorSets`
time `handle_set_stage` walks every binding of the layout and `fill_sampler_stage` copies `*descriptor->sampler`, a
NULL pointer for a sampler binding nothing wrote, so the queue thread segfaults on the first draw (Debian 12's Mesa
22.3.6: SIGSEGV at `lvp_execute.c:1116`, binding 41, `VK_DESCRIPTOR_TYPE_SAMPLER`, vertex stage; unwritten sampled
images and uniform buffers are NULL-safe there). Mesa 23.2 moved lavapipe to descriptor buffers and the path is gone.
`VulkanDevice.writesAllSamplers` is set for `VK_DRIVER_ID_MESA_LLVMPIPE` when the Mesa version in `driverInfo`
("Mesa 22.3.6 (LLVM 15.0.6)") is below 23.2 (`driverVersion` is no use: lavapipe reported 1 there until Mesa 25.x;
a `driverInfo` without a Mesa version counts as old); each draw then also writes the default sampler into the sampler bindings its pipeline
does not declare. Nothing samples them, so the output is unchanged: on Debian 12's stock lavapipe the five CC0 scenes
are byte-identical to Fedora 40's Mesa 24.1 renders, and on `photon2-linux:dev` (Mesa 25.2.8) `compare-builds.sh` gives
identical PNGs for the 22-wallpaper set against a build without the change, with the workaround off and forced on
(apart from the two clock-seconds scenes, §7). Other drivers skip the extra writes; `PHOTON_VK_WRITE_ALL_SAMPLERS=1|0`
forces it either way (`=0` on Mesa 22.3 reproduces the crash with `photon-linux render Tests/scenes/images`), and
`photon-linux info` prints the driver and whether the workaround is on.

How each D3D11/Metal behaviour maps, and how it was checked:

| Behaviour | Vulkan mapping | Check |
|---|---|---|
| y axis | negative-height viewport (core 1.1): NDC +y is the top row, as on D3D11 and Metal. `SV_Position` stays framebuffer-relative, so `uint2(p.xy)` reads in the utility shaders are unchanged | orientation and text placement match in all 13 renders |
| depth | reverse-Z unchanged (clear 0, `GREATER`); viewport depth range [0, 1] as D3D11; D32_SFLOAT | model scene 3509243656: 99.8% of pixels identical |
| front face | `VK_FRONT_FACE_COUNTER_CLOCKWISE` under the flipped viewport, matching Metal `.counterClockwise` | same model scene, back-face culling on |
| sRGB | all targets UNORM/float like the engine; the only sRGB use is the HDR encode view (`bgra8Unorm_srgb`), done with `VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT` + `B8G8R8A8_SRGB` views | HDR scenes 1425503532 and 2927802976: mean difference 0.44 and 0.63 |
| blend | `GPUBlendDescriptor` 1:1 to `VkPipelineColorBlendAttachmentState`, incl. alpha MAX and dest-colour | every corpus render |
| half-pixel | no offset needed: D3D10+ and Vulkan both sample texel centres at .5 and rasterise at pixel centres | no shifted edges in the diffs |
| MSAA | render-pass resolve (`VK_RESOLVE_MODE_AVERAGE_BIT`) for `storeAndMultisampleResolve`; `vkCmdResolveImage` for `ResolveSubresource` | lavapipe supports 1 and 4 samples only, so the engine's default x2 falls back to 1 there, exactly as `CheckMultisampleQualityLevels` failing does on Windows (Multisample.swift). On GPUs with 2× it is used |
| fp16 | `R16G16B16A16_SFLOAT` render targets for HDR scenes | HDR renders above |
| geometry shaders | default: the Metal path's `GeometryEmulation` (GS folded into an instanced vertex shader). `PHOTON_NATIVE_GS=1`: the device's geometry stage (§2.2.2) | native output equals the emulation drawn through a pass-through geometry stage, byte for byte, on all 7 GS wallpapers |
| viewport arrays | `VIEWPORT_WITH_COUNT` dynamic state + `shaderOutputViewportIndex` for the shadow caster pass | lavapipe exposes both |
| occlusion queries | `VkQueryPool` (precise when supported); the Metal facade copies results into the visibility buffer after the command buffer completes | sprite objects |

#### 2.2.1 Submission, barriers, frames in flight

- **Asynchronous command buffers.** `commit()` ends and submits the buffer and returns. Each submission owns a
  `CommandContext` (command buffer, fence, upload ring, descriptor pools) taken from a free list and returned once its
  fence has signalled, so a steady frame allocates nothing; before, every command buffer created a 4 MB upload buffer
  and fresh descriptor pools and waited at commit. `waitUntilCompleted()`, `addCompletedHandler`, `isCompleted` follow
  the fence. Completed handlers run on the thread that next commits, waits or calls `VulkanDevice.poll()` (there is no
  callback thread). More than 64 unfinished buffers (Metal's default `maxCommandBufferCount`) makes the next one wait.
- **Uploads and readbacks** are their own submissions on the one queue: `replace` stages through the submission's ring
  and returns without waiting (the copy runs after every earlier submission and before every later one, which is
  `MTLTexture.replace` ordering, and safer than Metal for textures an in-flight frame still reads); `read` (`getBytes`)
  waits for its own fence instead of `vkQueueWaitIdle`.
- **Barriers.** `HazardTracker` records which images the operations since the last barrier wrote and read. An
  operation gets a barrier only when it reads or writes an image written since then, or writes one read since then;
  the barrier waits for exactly the stages of those operations (graphics or transfer) and makes everything visible to
  every later graphics and transfer access. The first operation of a submission gets a full barrier, since earlier
  submissions are not tracked. A render pass's sampled textures are known only once it is encoded, and Vulkan allows no
  barriers for them inside the pass, so the encoder records its commands into a list and replays them at `end()` behind
  the barrier the pass needs. Before: two `ALL_COMMANDS` barriers around every pass and copy. Readback submissions end
  with a device → host barrier.
- **Presentation.** `VulkanSwapchain` (VK_KHR_xlib_surface + VK_KHR_swapchain) is CAMetalLayer's role:
  `nextDrawable()` acquires an image, `GPUCommandBuffer.present(_:to:)` ends the frame's command buffer with a copy of
  the rendered texture into it (a blit when format or size differ), with the UNDEFINED → TRANSFER_DST → PRESENT_SRC
  transitions; the submission waits for the acquire semaphore at the transfer stage only, so the frame renders while
  the image is still being acquired, and `vkQueuePresentKHR` follows. Two frames in flight: acquiring waits for the
  frame that used the same slot. FIFO by default, IMMEDIATE/MAILBOX with `--no-vsync`. The surface create-info is
  declared in `CVulkan/shim.h`, so PhotonVulkan needs no X11 headers.

Linux renders before and after these changes are byte-identical on all 13 test wallpapers
(`scripts/linux/compare-builds.sh`).

#### 2.2.2 Native geometry shaders

`PHOTON_NATIVE_GS=1` on a device with `geometryShader` (lavapipe has it) runs the engine's particle geometry shaders on
the geometry stage. `GeometryEmulation.buildNative` makes the pair from the same composition as the emulation: the
vertex stage passes the point's `VS_INPUT` and `SV_VertexID` through; the geometry stage runs the program's vertex
`main` and geometry `main` once per point (the emulation runs them once per output vertex), keeps the emitted vertices
and their strip positions, and appends every triangle as an independent triangle in D3D11's order: (i, i+1, i+2) for
even and (i+1, i, i+2) for odd strip triangles. Vulkan's own strip order for odd triangles is (i, i+2, i+1), which has a
different first (provoking) vertex. Constant buffers are the emulation's merged blocks, so one layout serves both stages
and the backend binds the vertex stage's bytes to the geometry stage's registers. The draw Draw.swift encodes for the
emulation (`listVertexCount` vertices × one instance per point) becomes a point-list draw of the points in the facade.

Verification (`scripts/linux/ci.sh --native-gs`): `PHOTON_NATIVE_GS=passthrough` draws the *emulated* vertex function
through a geometry stage that passes each triangle through unchanged. The native render equals that render byte for
byte on all 7 test wallpapers with GS programs (1 to 12 programs each), so both paths emit the same triangles in the same
order with the same attribute bits. Against the emulation without any geometry stage, 26 to 5,510 pixels differ (max
channel difference 1 to 54, at most 12 pixels over 8): the same differences appear with the pass-through stage, so they
come from lavapipe's vertex processing once a geometry stage is bound, not from the shaders (llvmpipe clips and maps to
the viewport in a separate code path then; which operation rounds differently was not traced). On lavapipe the native
path is no faster (within ±4%); the emulation stays the default because it is the path macOS runs. The wallpaper-switch
transition (`dx11playlisttransition.geom`, raw HLSL through `GeometryEmulation.buildRaw`) still uses the emulation.

### 2.3 The Metal facade (how PhotonRender runs on Vulkan today)

PhotonRender calls Metal directly in about 30 files. Rewriting them before anything ran on Linux would have meant a long
stretch with no way to compare output. Instead `Sources/LinuxCompat/Metal` is a module named `Metal` that implements the
part of Metal photon2 uses, on top of `PhotonGPU`:

- `MTLDevice`, `MTLTexture`, `MTLBuffer`, `MTLSamplerState`, `MTLDepthStencilState`, `MTLRenderPipelineState`,
  `MTLLibrary`/`MTLFunction`, `MTLCommandQueue`/`MTLCommandBuffer`, render and blit encoders, and their descriptors.
- photon2's binding convention is the contract: buffer index `N` is HLSL `bN` of that stage; index 16
  (`ShaderCompiler.vertexBufferIndex`) is the vertex stream; texture/sampler index `N` is `tN`/`sN`.
- Shaders: on Linux `ShaderCompiler` compiles with the register shifts and returns the SPIR-V, base64-wrapped behind a
  marker line, in the field that holds MSL on macOS; `makeLibrary(source:)` unwraps it. The reflection JSON comes from
  `spirv-cross --reflect` as before, with uniform bindings shifted back to the register number, so
  `ShaderProgram.layouts` is unchanged. The 10 hand-written MSL utility functions (blit, depth copy, quarter downsample,
  transition composite and snapshot) are matched by name to HLSL ports in `BuiltinShaders.swift`.
- Render-pass attachments that name a mip level use single-level views (Vulkan attachments address one level).
- Command buffers are asynchronous as on Metal (§2.2.1): `commit()` returns at once; occlusion results are copied into
  the visibility buffers and completed handlers run when the fence signals. `getBytes` after `waitUntilCompleted`
  (ParticleLayerImage) and texture uploads between frames keep their Metal ordering through the single queue.
- Linux-only additions hosts use: `MTLDevice.gpuDevice`, `MTLTexture.gpuTexture`, `MTLCommandBuffer.gpuCommandBuffer`
  (to present), and `MTLRenderPipelineDescriptor.geometryFunction` / `geometryInput` (native geometry stage).

### 2.4 Moving PhotonRender onto PhotonGPU with bit-identical macOS output

The facade is a bridge, not the end state. The end state is PhotonRender calling `PhotonGPU` directly, with a
`PhotonMetal` backend on macOS and `PhotonVulkan` on Linux. The migration is file by file and each step is checked by
rendering the corpus with `photon-tool render` before and after and requiring byte-identical PNGs:

1. Add `PhotonMetal`: `GPUDevice` and friends over Metal. Metal needs MSL, so its `makeShaderModule` runs SPIRV-Cross
   on the SPIR-V exactly as `ShaderCompiler` does today (`--msl --msl-version 30000 --msl-decoration-binding`, compiled
   from unshifted SPIR-V so the MSL is byte-identical to today's cache entries).
2. Give `PhotonGPU` the Metal behaviour the facade still emulates: per-stage texture binding (Metal allows different
   textures at the same index per stage; photon2 never does, so this is an assertion, not a feature). Asynchronous
   completion handlers are in `GPUCommandBuffer` already (§2.2.1).
3. Port in dependency order: `RenderTarget` and `RenderContext` (the texture stack and pass management), then `Draw`,
   `ShaderProgram`, `TextureLoader`, then the leaf users (Shadows, Volumetrics, Multisample, ColorCorrection,
   WallpaperTransition, ParticleLayerImage, Sprite, FontAtlas, Morph). `MTLTexture` becomes `GPUTextureResource`,
   `MTLRenderCommandEncoder` becomes `GPURenderEncoder`, and so on; the facade's code is the reference for each mapping.
4. The utility MSL becomes HLSL compiled through the normal path (the ports in `BuiltinShaders.swift` already exist).
   That step changes the macOS shader source, so it is the one place where "byte-identical" is checked on pixels
   rather than on MSL: same PNGs required.
5. Drop the `Metal` facade once nothing on Linux imports Metal.

Why the output stays identical: the Metal objects created, their descriptors, the MSL and the encoder call sequence are
the same before and after each step; only the Swift layer in between changes. A step that changes any of those is
caught by the corpus render diff.

## 3. Shaders, numerics, and what was changed for Linux

### 3.1 Shader path

HLSL from `PhotonCore`'s translator → glslang → SPIR-V. On Linux SPIR-V goes to Vulkan as is; on macOS SPIRV-Cross makes
MSL. The SPIR-V cache on Linux is `~/.cache/photon2/shaders` (key: SHA-256 of `vk` + stage + source).

### 3.2 simd, CryptoKit, Accelerate

`LinuxCompat/simd` reproduces Apple's arm64 code paths: the same fused multiply-adds, software emulation of the
`FRECPE`/`FRSQRTE` estimate instructions, and `__invert_f3`/`__invert_f4` transcribed from `libsystem_m`'s disassembly.
Over 18,100 test cases every vector and matrix function and every quaternion function photon2 calls is bit-identical to
macOS. Two functions are not (quaternion `angle`, 1 ULP in 36 of 300 cases; `simd_slerp`, up to 17 ULP), and photon2
calls neither. `CryptoKit.SHA256` matches `sha256sum`. `Accelerate` implements the vDSP DFT/FFT entry points
`AudioSpectrum` uses with Apple's length rules and scaling, in double precision (worst relative error against macOS
8e-8 for the float DFT).

### 3.3 Text

`LinuxCompat/CoreGraphics` and `CoreText` are FreeType, fontconfig and HarfBuzz. Glyph ids, advances (unhinted, in
points), bounding boxes and outline paths come from FreeType; glyph rasters differ from CoreText's by 1.2 to 2.8 grey
levels on average over ink pixels (FreeType vs CoreText anti-aliasing). `CFHash` of a `CTFont` is by value (name, face,
size), as on macOS; an identity hash made FontAtlas re-rasterise glyphs on every text rebuild until its pages filled.
Font files are read once per process and every FreeType face and HarfBuzz face of a file reads the same bytes
(`CGFont.FontStorage`); before that, 3509243656 (49 text layers) peaked at 7.3 GB and was killed by the OOM killer.

**Lines (`CTLineCreateWithAttributedString`)** are built the way CoreText builds them, each rule measured against
macOS 26 with `text-shape`:

1. Each character gets a font: the run's font if its cmap has it, else a fallback; marks, variation selectors, emoji
   modifiers and ZWJ/ZWNJ stay with the font before them. The fallback cascade starts with Arimo (CoreText's starts with
   Helvetica: a font without a space or an en dash gets them from Helvetica, a bold font from Helvetica-Bold), then
   fontconfig's best font covering the character, a colour font first for emoji with emoji presentation.
2. Within each same-font stretch, Common and Inherited characters take the script before them. CoreText splits
   "Привет мир Ελληνικά" in one font into two runs, "Привет мир " and "Ελληνικά", and puts the space between a Hangul
   fallback run and Latin text into the Latin run; one CTRun per font and script.
3. Each run is shaped by HarfBuzz (default features: `liga`, `kern`, `calt`, `mark`, ...) with the whole paragraph as
   context, cluster level "monotone characters" so a combining mark reports its own string index as CoreText does.
4. Runs go into visual order by a run-level bidi reorder (paragraph direction from the first strong run, neutral runs
   between two runs of one direction take it). A right-to-left run's glyphs come from HarfBuzz in visual order, as in a
   CoreText CTRun.
5. A glyph's advance is the distance from its position to the next glyph's, so an offset mark has a negative advance and
   its base carries the rest (CoreText reports "ŝ́" that way; HarfBuzz's own advances give the mark 0).

Line metrics are `hhea` ascender, descender and line gap. The old rule (OS/2 typo metrics when fsSelection bit 7,
USE_TYPO_METRICS, is set) was wrong for 9 of the 82 fonts in the workshop corpus' scene packages, e.g. NikkyouSans
(ascent 31.72 on macOS, 27.16 before at 32 pt). A CFF font's units-per-em ratio goes through its FontMatrix: without a
FontMatrix operator CoreText's value carries a factor of 1 + 17·2⁻²³, with one the factor is FontMatrix[0] × unitsPerEm
(LEMONMILK stores 0.000488281 for 1/2048).

**Font substitution.** `CTFontCreateWithName` with a PostScript name that is not installed but has a metric-compatible
substitute loads the substitute and reports the requested name, so FontAtlas's `systemfont_*` chains (which test the
name to decide whether a font exists) behave as on a system that has the font: ArialMT → Arimo or Liberation Sans,
TimesNewRomanPSMT → Tinos/Liberation Serif, CourierNewPSMT → Cousine/Liberation Mono, Calibri → Carlito, Cambria →
Caladea, Menlo-Regular → DejaVu Sans Mono (Menlo is Apple's revision of it). ArialMT and Arimo agree in glyph ids,
advances, kerning and line metrics on every case tested; Menlo and DejaVu Sans Mono in advances and line metrics.
Helvetica is left out (Arimo has its advance widths but ascent 25.35 against Helvetica's 21.56 at 28 pt), as are fonts
without a metric clone (Verdana, Georgia, Comic Sans MS, Helvetica Neue, Segoe UI, Consolas), which keep fontconfig's
best match. On this Mac, `systemfont_calibri` falls back to Helvetica Neue (Calibri is not installed) while Linux uses
Carlito, which is what Windows shows.

**Checks.** `scripts/linux/text-check.sh` lays out 14 cases (11 engine fonts, ArialMT, Menlo; Latin with kerning,
combining marks, Cyrillic + Greek) and requires output identical to CoreText's, to 4 decimals: all 14 are. Over the 82
fonts extracted from the corpus' scene packages, laying out "office ffi fl AVATAR Wa To. 12:45 – “Hi” 東京 こんにちは",
the runs in each font's own face are identical to CoreText's for 75 fonts; the other 7 differ in their fallback runs
(Helvetica vs Arimo: Helvetica has an `ffi` ligature and slightly different kerning) or are fonts macOS resolves to a
different installed face. Fallback runs differ in font everywhere (PingFang/Hiragino/Apple SD Gothic vs Noto CJK, Geeza
Pro vs Noto Sans Arabic, Apple Color Emoji vs Noto Color Emoji); run structure, string indices and order match.

### 3.4 SceneScript

`LinuxCompat/JavaScriptCore` implements `JSContext`/`JSValue` on WebKitGTK's JavaScriptCore C API, which is the same
engine Apple ships. A test of every native-function signature, exception path and conversion SceneScript uses prints
87 lines that are byte-identical on macOS and Linux. Swift on Linux has no `@convention(block)` for Swift types, so
`SceneScript.installNatives` now registers its 12 native functions through `scriptNative(_:)`
(`PhotonRender/ScriptNativeFunction.swift`): on macOS it converts to the identical block type as before, on Linux it
wraps the closure in a JSC C-API function object.

The other edits to shared sources: `ShaderCompiler` gained the Linux SPIR-V branch (the macOS branch is the old function
under a new name), `SceneRenderer`'s daytime sum is split into named terms so swift-corelibs' type checker finishes (same
operations in the same order), and `ScriptMedia`'s MediaRemote poller is `#if !os(Linux)`.

Phase 4 edits to shared sources, all behaviour-preserving on macOS (the same 8 corpus renders byte-identical, `swift test`
77 tests passing, the macOS voice output checked against itself through `photon-tool sound-ref`):
- `Sound.swift`, `SoundSpatial.swift`, `SoundHRTF.swift` build on Linux: the AVFoundation/CoreAudio parts (`PCMVoice`,
  the `AVAudioPlayer` voice, `SoundOutput`'s headphone probe) are `#if !os(Linux)`, and `SoundObject.play` /
  `updateSpatial` have a Linux branch that hands the source to OpenAL (§3.6). `SoundObject`'s rules (track pick, loop /
  random / single, countdown in wall-clock time, startsilent, script play/pause/stop) are now the same code on both.
- `AudioCapture.swift` is split: the packet queue and `AudioSystem` (the engine's `Audio_Thread` loop) moved unchanged
  into `AudioSystem.swift`; the backend choice is `startPlatformBackend()` per platform.
- `Sources/photon/PlaybackRules.swift` is split: the settings, snapshot and `PlaybackEvaluator` (Foundation only) moved
  into `PlaybackEvaluator.swift`, which photon-linux compiles too; `AppIdentity(pid:)` (NSRunningApplication) stays.
- `ScriptMedia.thumbnail` decodes through `TexFile.decodeStraightRGBA` on Linux (LinuxCompat's `NSImage(data:)` does not
  decode), with `MediaColors.premultipliedWords` giving the colour pass what `MediaColors.rgba` draws on macOS.
- New: `SoundReference.swift` (the cross-platform sound test scene, unused by the renderer), `photon-tool sound-ref`.

Phase 5 edits to shared sources: `WebWallpaper.swift`'s injected scripts, property and directory handling and the
JavaScript it sends moved into `WebPageScripts.swift` (Foundation only, built on both platforms); `WebWallpaper` calls
it and keeps its public `typedProperties` / `properties`. The strings are the same except the LED plugin, whose objects
are now installed right before `onPluginLoaded` (§5.3), which changes web pages only. The 7 corpus scene and video
renders are byte-identical before and after (§7).

Phase 6 edits to shared sources: the app model moved from `Sources/photon` into `Sources/PhotonApp` with `package`
access (§6.1); `photon-tool` takes `PHOTON_WE_ASSETS`; the desktop hosts gained `--control`, `--output`,
`--list-outputs`, `--properties` / `--property` and `--general` for scenes, `--msaa`, `--resolution`, `--postprocessing`,
`--window-update-rate` and `--audio`. PhotonRender is unchanged. The X11 smoke test (swapchain, readback and the
prototype equal to the headless render, 0 differing pixels), the Wayland smoke test, the web checks and the 33
pause-rule checks pass with the phase-6 build.

### 3.5 Video and GIF

**Video textures and video wallpapers** (`PhotonRender/Linux/VideoTextureLinux.swift`, `Sources/CPhotonMedia`) keep
VideoTexture.swift's interface and frame choice: the decoder is pulled on the render thread, driven by the scene (or
SceneScript video) clock, and `update(time:)` shows the last frame whose presentation time is ≤ time mod duration,
restarting on a backwards jump or one of more than 2 s (a flushing accurate seek to t − 0.001 when t > 0.05, as the macOS
reader's `timeRange`). Looping, `rate`, seeking (ScriptVideo.swift) and the crop of video user textures
(`TextureLoader.videoUserTexture`, docs/re/shader-keys.md) are shared code above this interface.

- Pipeline: `filesrc ! decodebin ! videoconvert ! video/x-raw,format=I420 ! appsink sync=false max-buffers=2`. Only the
  first video pad is linked. Timestamps are converted to stream time with the sample's segment, so MP4 edit lists give
  a first frame at 0 as in AVFoundation. Embedded MP4s (flag-0x20 `.tex`) are cached in `$XDG_CACHE_HOME/photon2/video`.
- Y'CbCr → BGRA is done in C, not by videoconvert: videoconvert's fixed-point I420 → BGRA was 2 to 4 levels darker than
  VideoToolbox (fitted: G = 1.18 Y' − 0.19 Cb − 0.50 Cr + 63.5 against the BT.709 1.164 / 0.213 / 0.533 that VideoToolbox
  matches). photon_media.c uses the standard matrix of the caps colorimetry (BT.601 up to 576 lines and BT.709 above for
  untagged streams, which is also VideoToolbox's choice: forcing the other matrix raises the mean difference from 0.61 to
  2.14 and from 0.93 to 2.39 on the two untagged test videos), limited range, bilinear chroma with H.264's default
  siting. Only frames that are shown are converted.
- Duration is the video track's `tkhd` duration (`MP4Probe`), which is what `AVAssetTrack.timeRange` reports; the
  container duration can be the audio track's (9d1e0cdb: 20.009 s container, 19.983 s video).

Checked with `photon-linux video-frame` against AVAssetReader (BGRA) on the 11 corpus videos (9 embedded in scene `.tex`
files, 2 video wallpapers; 336×336 to 4090×2300, 11 to 60 fps), frame at t = 2: durations equal to the microsecond, the
same frame chosen in all 11, mean absolute difference 0.29 to 1.00 per channel (signed: R −0.2 to −0.6, G +0.1 to +0.2,
B −0.1 to −0.8). The remainder is VideoToolbox's own rounding: no rounding offset or coefficient set reproduces it.
Decoding is libavcodec (`avdec_h264`), so the decoded Y'CbCr is that of every conformant H.264 decoder. Hardware decoders
that decodebin may pick on a real desktop (VA-API, NVDEC) output GPU memory that this caps filter does not accept; that
path is untested.

**Video wallpaper sound** (`photon-linux/Host/VideoAudio.swift`): the same `sync(clock:rate:volume:paused:)` as
Sources/photon/VideoAudio.swift, on GStreamer `playbin` with only the audio flag; it seeks when it drifts more than
0.15 s from the wallpaper clock and pauses with the outputs. Under Xvfb with `--rate 150` (fakesink with sync) the
position stayed within 3 ms of the clock over 8 s and across the loop point of 3611879823 (50.618 s).

**GIFs** decode with stb_image's `stbi_load_gif_from_memory` (libstb), the loader behind the engine's
`OpenGIF`/`AdvanceGIF`: `TexFile.gifFrames` (GIF user textures, `AnimatedGIF` timing) and `spriteSheet(gif:)` (GIF
wallpapers, the 0.011 s → 0.1 s delay rule) are the macOS functions' layouts on stb's frames, with fully transparent
pixels zeroed as the macOS premultiplied context leaves them. Against ImageIO on 10 corpus preview GIFs (611 frames,
disposal modes 0, 1, 2, 10 to 300 ms delays): sizes, frame counts and delays all equal, every frame pixel-identical except
one frame of 2938612768, where ImageIO leaves column 0 transparent after a restore-to-background frame and stb draws it
(stb is the engine's decoder). The two GIF wallpapers of the test set render pixel-identical to macOS.

### 3.6 Sound objects and the audio spectrum

**Sound objects** play through OpenAL Soft 1.21.1, the library `mediaextensions64.dll` links (docs/re/06 §4.1,
loader-keys §6.9), instead of the emulation macOS uses (`SoundSpatial.stereoGains`, `HrtfVoiceFilter`). The image builds
1.21.1 from the release tag (Ubuntu ships 1.23.1); its embedded `Default HRTF.mhr` (80,353 bytes) is byte-identical to
the MinPHR03 blob at file offset 0x2b7d90 of the dll. `PhotonRender/Linux/SoundOpenAL.swift` makes the engine's calls:
one device and context from `alcOpenDevice(NULL)` / `alcCreateContext(dev, NULL)`, so OpenAL Soft itself decides HRTF
(on for a headphone sink: the PulseAudio backend reads the active port and `device.form_factor`), the default distance
model (inverse distance clamped), default sources (AL_AUTO spatialisation, so only mono buffers are panned), and per
track `AL_ROLLOFF_FACTOR` = attenuation and `AL_REFERENCE_DISTANCE` = mindistance on play, `AL_POSITION` (the engine's
view-space position, `SoundSpatial.sourcePosition`) and `AL_GAIN` = (volume² × master · 100) · 0.01 per frame (the dll's
SFML volume round trip). Playback modes, the countdown, the script methods and the volume rule (a renderer volume of 0
pauses the tracks, above 0 resumes them; docs/re/06 §4.0) are Sound.swift's own code (§3.4), shared with macOS. Tracks decode with GStreamer to float32 at their own
rate; OpenAL resamples. Decoded buffers are shared per file (FNV-1a of the bytes) and freed with their last voice.
`PHOTON_HRTF=1/0` adds `ALC_HRTF_SOFT` to the context attributes.

One patch to 1.21.1: `fastf2i` rounds to nearest on every CPU. 1.21.1 converts with `cvtss2si` (round to nearest) on
x86 and truncates elsewhere, so on arm64 `GetHrtfCoeffs` made every HRTF delay with a fraction of .5 or more one sample
shorter than the engine's x86 build: an impulse from a source straight ahead came out at sample 279 instead of 280
(256 + a 24-sample delay). x86_64 builds compute the same values with or without the patch.

**Check** (`photon-linux sound-check`, `SoundReference.swift`): seven scenes of mono noise tracks on a 48 kHz device,
driven per update (480 frames, 1024 in one scene) as the engine drives a source: AL_ROLLOFF_FACTOR, AL_REFERENCE_DISTANCE,
AL_POSITION and AL_GAIN, then `alSourcePlay` / `alSourcePause` / `alSourceStop` (restart = stop + play in one update,
as `Sound_Play` does).

- `main` (200 updates, 48 kHz track): the source at the listener, on a circle of radius 2, sweeping elevation, at 0.25
  to 8 units with rolloff 2, through gain steps from 0 to 1.6, paused for 10 updates and resumed at the listener while
  moving out through OpenAL's at-the-listener radius (0.0004 per update; AL_REFERENCE_DISTANCE/1024 = 0.00098).
- `stop` (106 updates, 48 kHz, 13,577 frames): stop while playing, play again, pause then stop while paused, restart,
  stop then play, the one-shot track running out at sample 137 of an update, a fresh play and a stop at the listener.
- `r22050`, `r44100`, `r96000` (113–119 updates): the same kind of script with a 22.05 / 44.1 / 96 kHz track (OpenAL
  increments 1882, 3763, 8192), ending in a one-shot end; `r96000-1024` uses 1024-frame updates, which OpenAL mixes in
  two passes of 512 because one pass holds at most 1024 + 48 source samples.
- `loop22050` (62 updates): a 700-sample looping track at 22.05 kHz, wrapping every 1.5 updates, paused, resumed,
  stopped.

OpenAL renders each scene on an `ALC_SOFT_loopback` device (float stereo, HRTF off and on; it reports default resampler
1 = linear, the engine's); photon2's voice (`VoiceMixer`, which `PCMVoice` renders through) renders it on Linux and,
through `photon-tool sound-ref` (files `<scene>.speaker.f32` / `<scene>.hrtf.f32`), on macOS. Every update is compared
with no offset; the event rows are the updates where the voice starts, pauses, resumes, stops or runs out, and the
update after.

| Scene | OpenAL vs macOS, speakers (max / RMS) | OpenAL vs macOS, HRTF (max / RMS) | event updates, speakers / HRTF (max) |
|---|---|---|---|
| main | 3.0e-8 / 1.8e-9 | 4.2e-7 / 1.4e-8 | 0 / 3.0e-8 |
| stop | 6.0e-8 / 3.2e-9 | 8.9e-8 / 4.0e-9 | 4.5e-8 / 3.0e-8 |
| r22050 | 4.5e-8 / 2.9e-9 | 1.0e-7 / 4.5e-9 | 3.0e-8 / 3.7e-8 |
| r44100 | 6.0e-8 / 3.0e-9 | 1.5e-7 / 4.4e-9 | 3.0e-8 / 4.5e-8 |
| r96000 | 6.0e-8 / 3.6e-9 | 1.7e-7 / 5.7e-9 | 3.0e-8 / 3.0e-8 |
| r96000-1024 | 6.0e-8 / 3.6e-9 | 1.9e-7 / 5.7e-9 | 3.0e-8 / 4.5e-8 |
| loop22050 | 4.5e-8 / 2.9e-9 | 9.7e-8 / 4.6e-9 | 4.5e-8 / 3.0e-8 |

OpenAL against photon2's voice built for Linux gives the same numbers except `main` HRTF (6.0e-8); the Linux and macOS
builds of the voice agree to 3.7e-8 on every scene except `main` HRTF (4.1e-7). That rest comes from the platform, not
the voice: most likely Darwin's and glibc's `asin` / `atan2` / `sin` / `cos` differing in the last bit for some
directions, which moves an HRTF blend weight (not traced further). The other rests (≤ 1.9e-7) are float summation order
(OpenAL adds every voice into one dry buffer / accumulator in voice-list order) and arm64 OpenAL fusing the NEON
`vmlaq_f32` multiply-adds, which the engine's x86 build does not. `sound-check` gates every all-update row at 1e-6.

Before the macOS fixes below the comparison had to drop the 256-sample HRTF offset and the four pause/resume mixes, and
still left 1.74e-3 on speakers. What macOS's voice did differently from OpenAL Soft 1.21.1, all fixed (docs/re/06
§4.1–4.2):

- **256-sample HRTF latency.** 1.21.1 writes the per-source HRTF mix at `HrtfAccumData + HrtfDirectDelay` (256 samples,
  `alc/voice.cpp`, to line it up with the ambisonic HRTF decode; the dll's `DoHrtfMix` uses device +0x4a30 = the
  accumulator + 0x800). `HrtfVoiceFilter` now writes 256 samples in and carries HrirLength + 256 samples between mixes.
  Without it macOS played HRTF sound 5.3 ms early (max difference 0.86 on this scene).
- **Pause and resume.** OpenAL's pause mix reads the track's next samples and fades them to 0 without advancing the
  position; the resumed voice keeps its fading flag, history and position, so its first mix ramps from 0 to the target
  and replays the faded samples. `PCMVoice` stopped at once on speakers, faded silence on HRTF, and on resume ramped from
  the pre-pause gains (speakers) or restarted the filter at constant gain (HRTF).
- **Panning near ±90°.** OpenAL pans into a first-order ambisonic dry buffer (W, Y, X) and decodes it afterwards; nothing
  clamps the decoded gains, which go slightly negative just behind the side. `stereoGains` clamped each speaker gain at
  0. `VoiceMixer` now ramps the three dry gains with `Mix_` (target reached one step after the mix, step = Δ·(1/n),
  constant below FLT_EPSILON, 1e-5 silence skip) and decodes per sample, which also removes the old ramp difference
  (`PCMVoice` reached the new gain on the last sample of a mix).
- **At the listener.** OpenAL treats a source closer than max(FLT_EPSILON, `AL_REFERENCE_DISTANCE`/1024) as at the
  listener (`ToSource.normalize`, dll 0x1801952f0); `SoundSpatial` used FLT_EPSILON. With FLT_EPSILON this scene differs
  by 0.18 (speaker) / 0.48 (HRTF) at x = 0.0004 and 0.0008.

- **Stop, end of a one-shot track and resampling** (docs/re/06 §4.2). The engine stops a track through the dll's SFML
  `sf::SoundStream`, whose streaming thread calls `alSourceStop`; a one-shot track ends when the SFML queue runs out.
  OpenAL then mixes the voice once more from its held samples (up to the quietest, then held), fading to 0 over 64
  samples; the update that reaches the end of a track plays its last sample for the rest of the update. Every source
  resamples with OpenAL's linear resampler (12-bit fractional stepping). macOS went silent at once on stop (speakers),
  faded silence (HRTF), and resampled with AVAudioConverter or the AVAudioEngine mixer. `VoiceMixer` now ports the voice
  (`stop`, `r*` and `loop22050` scenes above).

In the X11 host the first output's scene owns the sound (the first display on macOS), at `--volume` / 100 times the mute
fade (6 per second toward 0 while a mute rule holds, docs/re/09 §2), paused with that output. Under Xvfb with OpenAL's
wave writer, a looping 440 Hz tone at x = 1800 of a 1920-wide scene comes out with left/right level 0.36, and a
fullscreen test client silences it for 2.9 s (the pause rule) before it resumes.

**Audio spectrum.** `AudioSystem` (the engine's `Audio_Thread`) and `AudioAnalyzer` are shared; only the capture is new
(`Linux/AudioCaptureLinux.swift`, `CPhotonSystem/photon_capture.c`). PipeWire: a `pw_stream` with
`stream.capture.sink = true`, so the session manager links it to the default sink's monitor, float32 stereo at the graph
rate; each buffer is one packet, as one WASAPI `GetBuffer` is (docs/re/06 §5.1). If no PipeWire daemon answers within
3 s, PulseAudio's `@DEFAULT_MONITOR@` at float32 stereo 48 kHz. A packet of exact zeros is marked silent, as on macOS.
`PHOTON_AUDIO_BACKEND=pipewire|pulse` picks one. In the container a 440 Hz left / 2 kHz right tone played into a PipeWire
null sink lands in 64-bin bands 18 and 38 through both backends, the bands the analyzer's mapping predicts at 48 kHz
(N 2089, fill 1392); the scene's own sound objects, played through OpenAL into the same sink, show up in band 18 too.

## 4. macOS-only dependencies and their Linux replacements

| macOS dependency | Used for | Linux replacement | Status |
|---|---|---|---|
| Metal, MetalKit | rendering, presentation | `PhotonGPU` + `PhotonVulkan` (facade today) | done: Vulkan swapchain on X11 (`VK_KHR_xlib_surface`) and Wayland (`VK_KHR_wayland_surface`), `XShmPutImage` / `wl_shm` fallbacks |
| simd | all math | `LinuxCompat/simd` | done, bit-identical (§3.2) |
| ImageIO, CoreGraphics bitmaps | PNG/JPEG decode, GIF frames | libpng, libjpeg-turbo (`CPhotonLinux`); GIF via stb_image (the engine's own decoder) | done (§3.5) |
| Compression | LZ4 in .tex | liblz4 (the library the engine links) | done |
| CoreText, CoreGraphics text | text layers, MSDF glyphs | FreeType + fontconfig + HarfBuzz (`LinuxCompat/CoreText`) | done (§3.3) |
| JavaScriptCore | SceneScript | WebKitGTK JavaScriptCore C API (`LinuxCompat/JavaScriptCore`) | done |
| CryptoKit | cache keys | `LinuxCompat/CryptoKit` (SHA-256) | done |
| Accelerate (vDSP) | audio spectrum FFT | `LinuxCompat/Accelerate` | done |
| AVFoundation (AVAssetReader), CoreVideo | video textures, video wallpapers | GStreamer (`decodebin`, `appsink`), frames converted and uploaded per scene clock (`CPhotonMedia`) | done (§3.5) |
| AVFoundation (AVPlayer) | a video wallpaper's sound | GStreamer `playbin`, audio only | done in the X11 host (§3.5) |
| AVFoundation (AVAudioPlayer/AVAudioEngine), CoreAudio | sound objects, HRTF | OpenAL Soft 1.21.1, the engine's own library (docs/re/06 §4), including its HRTF | done (§3.6) |
| CoreAudio process taps, ScreenCaptureKit | audio spectrum capture | PipeWire monitor stream (`pw_stream` on the default sink's monitor), PulseAudio `@DEFAULT_MONITOR@` as fallback | done (§3.6) |
| WebKit (WKWebView) | web wallpapers | WebKitGTK 4.1 `WebKitWebView` in a layer-shell or DESKTOP-type GTK window, the same page scripts (`WebPageScripts`) | done (§5.3) |
| MediaRemote (private) | SceneScript and web media integration | MPRIS over D-Bus (`org.mpris.MediaPlayer2.*`: Metadata, PlaybackStatus, Position, artUrl) | done (§5.1, §5.3) |
| AppKit (NSWindow, NSScreen, NSWorkspace) | desktop windows, screens | X11 (§5) / Wayland layer-shell (§5.2); `LinuxCompat/AppKit` covers the renderer's few calls (`NSScreen` from `PHOTON_SCREENS`, `NSWorkspace.open` → `xdg-open`) | done; GNOME Wayland gets a still background only (§5.2) |
| IOKit.ps | battery rule | UPower over D-Bus (`OnBattery`), `/sys/class/power_supply` when UPower is absent | done (§5) |
| NSWorkspace sleep/lock/screensaver notifications | sleep, lock and screensaver rules | logind `PrepareForSleep`, the session's `Lock`/`Unlock`/`LockedHint`, `org.freedesktop.ScreenSaver` / `org.gnome.ScreenSaver` `ActiveChanged`, X11 DPMS and MIT-SCREEN-SAVER | done (§5) |
| SwiftUI, Combine | the `photon` app UI (library, playlists, settings) | GTK 3 windows (`photon-linux app`), the shared `PhotonApp` model, `LinuxCompat/Combine` for `ObservableObject` / `@Published` | done (§6.1) |
| NSStatusItem | the menu-bar icon | StatusNotifierItem + dbusmenu on the session bus (`CPhotonApp`) | done (§6.1) |
| UserDefaults (`photon2` domain) | settings | `XDGDefaults`: the same keys and value types in `~/.config/photon2/photon2.plist` | done (§6.1) |

## 5. Linux desktop host

`photon-linux desktop` (`Sources/photon-linux/Host/`) is the X11 host (the Wayland host is §5.2, web wallpapers §5.3).
Design:

- **Windows.** One window per monitor, at the monitor's geometry from XRandR (`XRRGetMonitors`, falling back to the
  root window), with `_NET_WM_WINDOW_TYPE_DESKTOP`, `_NET_WM_STATE_BELOW|STICKY|SKIP_TASKBAR|SKIP_PAGER`,
  `_NET_WM_DESKTOP = 0xFFFFFFFF` and `WM_CLASS photon2`. EWMH window managers (GNOME/Mutter on X11, KWin, Xfwm,
  Openbox) then keep it under every other window and out of the task list. `--root` draws onto the root window for
  window managers without desktop-type support.
- **Frames.** The default source is the full renderer (`SceneRender.Source`, one per monitor size); `--proto` uses
  PhotonProto. Each output window gets a `VulkanSwapchain` and frames are presented without leaving the GPU (§2.2.1).
  The fallback, used in root mode (the root window belongs to the desktop), with `--present readback`, when the driver
  has no WSI or the swapchain cannot be created, and for `--proto`: the frame is read back as BGRA8 rows and put with
  `XShmPutImage` (MIT-SHM) or `XPutImage`. Expose on a paused output re-presents the last frame. `--no-vsync` picks an
  IMMEDIATE/MAILBOX swapchain, `--still` shows one scene time prepared like `photon-linux render` (tests), and the host
  prints the steady-state frame rate after the first frame (which loads the scene) on exit.
- **Pause rules.** The evaluator is the macOS app's `PlaybackEvaluator` (0x14006cea0, docs/re/09 §1.3), compiled from
  the same file. Its window masks come from polling `_NET_ACTIVE_WINDOW`, `_NET_CLIENT_LIST_STACKING` and each client's
  `_NET_WM_STATE` (`FULLSCREEN`, `MAXIMIZED_VERT`+`HORZ`, `HIDDEN`) and geometry, mapped to monitors. Its host flags come
  from the system inputs, read every `windowupdaterate` tick as wallpaper64's window procedure handles them (§1.4):
  - battery (flag 0x10): UPower `OnBattery` (property and `PropertiesChanged`), `/sys/class/power_supply` without UPower;
  - sleep (`Sleep` 0x14006ed90, flag 0x20; sleep rule run / pause / stop): logind `PrepareForSleep(true)` until
    `(false)`, or DPMS reporting standby, suspend or off (the engine's `GUID_MONITOR_POWER_ON` "off");
  - lock (`WM_WTSSESSION_CHANGE`): the session's `Lock`/`Unlock` signals and `LockedHint` pause through the tray-pause
    path unless already paused, and unlock resumes only a pause the lock made;
  - screensaver (flag 0x400000, pause all): `ActiveChanged` from `org.freedesktop.ScreenSaver` or `org.gnome.ScreenSaver`,
    or the X server's MIT-SCREEN-SAVER state.

  `DesktopRuleState` (`DesktopPauseRules.swift`) holds that event state and applies the decision (a monitor pauses with
  the tray-pause or asleep flags or its mask bit; mute fades the sound to 0; stop keeps the last pause state), so all of
  it is tested without an X server or a bus. `--sleep`, `--battery`, `--fullscreen`, `--maximized`, `--focus` set the
  rules (engine strings). The application rules, the "another process plays audio" rule and `pausevram` are §5.4.
- **Tested** under Xvfb in the container: with `--proto` the host's screenshot equals the headless render exactly
  (single monitor, two monitors via `--monitors`, `XShmPutImage` and `XPutImage`, root mode); with the full renderer
  and `--still`, the swapchain screenshot and the readback screenshot both equal the headless render exactly
  (`scripts/linux/in-container/x11-smoke.sh`); two outputs via `--monitors` each present through their own swapchain;
  root mode and `--no-shm` take the readback path. Frame rates are in §7.
  A test client marked fullscreen pauses its monitor and a maximized one pauses the other; `--self-test` runs 60 rule
  checks (window masks on X11 and Wayland, the shared evaluator, lock, sleep, screensaver, battery, application rules,
  audio, layouts, VRAM). Not yet exercised: a real window manager's `_NET_CLIENT_LIST` (without one, the host lists the root's
  children), multiple XRandR monitors (Xvfb ignores `xrandr --setmonitor`).
- **Clock, rate, sound.** The scene loop of docs/re/09 §2, as `WallpaperRenderer` runs it on macOS: dt clamped to
  [0.0001, 0.25], the time scale fading toward 0 while every output is paused and the volume toward 0 while muted (6 per
  second), scene time advancing by clamp(rate · speed · dt, 0.0001, 0.25) and stopping when fully paused; `--rate P` is
  the wallpaper's `rate` property (P/100, at least 0.1 for scenes, as is for video wallpapers, docs/re/09 §2 and §7).
  Sound objects (§3.6) and a video wallpaper's sound (`VideoAudio`, §3.5) play at `--volume P` / 100 (default 50, the
  engine's UI default; `--mute`; `--no-sound` keeps OpenAL closed) times the mute fade.
  `PHOTON_AUDIO_SINK=fakesink` replaces the audio sink (tests), `PHOTON_VIDEO_AUDIO_LOG=1` prints clock and position.
- **Not wired:** Aero-Peek-like overrides (`unpauseaero`; no Linux counterpart), the remote-session cases.

### 5.1 Media integration and the D-Bus inputs

`PhotonRender/Linux/LinuxMedia.swift` is the Linux `NowPlayingPoller` behind `ScriptMedia`, so SceneScript media hooks and
`$mediaThumbnail` textures get the same events as on macOS. Once a second it polls the session bus
(`photon_mpris_poll`): the player shown is the first `org.mpris.MediaPlayer2.*` name that is Playing, else Paused, else
any. Mapping to the WinRT session winrtutil64 reads: status = a player exists; playback = `PlaybackStatus` (Playing 1,
Paused 2, Stopped 0); properties `xesam:title`, `xesam:artist`, `xesam:album` → albumTitle, `xesam:albumArtist`,
`xesam:genre` (lists joined with ", "); thumbnail = the image at `mpris:artUrl` (file, data or http(s) URL), with the
Spotify crop rule keyed on the player's desktop entry; timeline = `Position` / `mpris:length`. MPRIS players do not
signal position changes, so a timeline event goes out when the length or state changes or the position is more than 1 s
from where the last report and `Rate` put it (a seek), which is when SMTC players report one. Web pages get the same
source in their own payloads (§5.3).

The signal watcher (`photon_system_watch_start`) runs a GLib main loop on its own thread, subscribes before reading the
initial values, and keeps a state struct the host reads each tick. The buses are the standard ones
(`DBUS_SYSTEM_BUS_ADDRESS` / `DBUS_SESSION_BUS_ADDRESS` override them, which the tests use).

Checks in the container (`in-container/audio-check.sh`, fake services in `fake_dbus.py`): a fake player's title,
artist list, album, album artist, genres, a 300×300 PNG cover (primary colour 0x2727C8 from `MediaColors.dominant`),
play → pause, a second song and a seek to 100 s all arrive as the expected `ScriptMedia` events; UPower, logind and
screensaver changes on a private system bus and the session bus show up in `system-check` within 0.1 s, and the host,
run with `--battery pause --sleep pause`, logs pause on battery, lock, PrepareForSleep, screensaver, and resumes once each
ends.

### 5.2 Wayland host

`photon-linux desktop` picks Wayland when `WAYLAND_DISPLAY` is set (`--backend x11|wayland` forces one). The client
side is C (`Sources/CPhotonWayland`, protocol code generated by `scripts/linux/gen-wayland-protocols.sh` from
wayland-protocols and the wlr protocol XML vendored in `vendor/wayland-protocols`); the host is
`Host/WaylandDesktop.swift`, with the X11 host's scene loop (clock, pause and mute fades, sound, video wallpaper audio).

- **Surfaces.** Compositors do not let clients put windows below others, so each `wl_output` gets a
  `zwlr_layer_surface_v1` on the `background` layer, anchored to all four edges, exclusive zone -1, keyboard
  interactivity none, opaque region set. Outputs are tracked across hotplug (registry `global` / `global_remove`; a
  layer surface the compositor closes is dropped) and indexed for the rules in advertisement order (Wayland has no
  primary output). Logical geometry and connector names come from `zxdg_output_v1`.
- **Scale.** The buffer is `round(logical × scale)`: the scale is `wp_fractional_scale_v1`'s preferred scale (in
  120ths) when the compositor has it, else the output's integer `wl_output.scale`; `wp_viewporter` maps the buffer
  onto the logical size (`wl_surface.set_buffer_scale` without a viewporter). A 1920×1080 output at scale 1.5 gets a
  1280×720 logical surface with a 1920×1080 buffer, so frames are rendered at device pixels, not upscaled.
- **Presentation.** `VulkanSwapchain` on the `wl_surface` (`VK_KHR_wayland_surface`; `supportsWaylandPresentation`),
  resized on configure or scale change (`resize`). Mesa's FIFO on Wayland waits for frame callbacks, which a compositor
  can stop sending to a covered background surface, so the host uses MAILBOX or IMMEDIATE and paces itself with `--fps`
  (`--wayland-fifo` opts back in). The fallback (`--present readback`, no WSI, swapchain failure) copies the BGRA frame
  into a double-buffered `wl_shm` XRGB8888 buffer. `--hold S` keeps the last frame up after the run (screenshots).
- **Pause rules.** `zwlr_foreign_toplevel_manager_v1` gives each toplevel's activated, maximized, minimized and
  fullscreen states and the outputs it entered, but no geometry. `DesktopPauseRules.masks(toplevels:outputs:)`: focus =
  the activated toplevel's output; maximized = every non-minimized maximized toplevel's output (any window, as the
  engine's probe); fullscreen = the activated toplevel when fullscreen, or every fullscreen toplevel when none is
  activated. A toplevel on two outputs counts on the first it entered (MonitorFromWindow picks one; which one is
  Inferred). Layer surfaces are not toplevels, so photon's own surfaces never count. The system inputs (UPower,
  logind, lock, screensaver) are the D-Bus ones of §5; Wayland has no DPMS query for clients.
- **KDE Plasma (KWin).** KWin has layer-shell but not wlr-foreign-toplevel. Its window list is
  `org_kde_plasma_window_management` (plasma-wayland-protocols 1.10.0, version 16, vendored with
  `plasma-virtual-desktop`): per window the state flags (active, minimized, maximized, fullscreen, skip-taskbar,
  on-all-desktops), the geometry in global logical coordinates, the pid and the app_id; windows are announced by uuid
  (`window_with_uuid`, `get_window_by_uuid`; `window` / `get_window` below version 13), and `unmapped` drops them.
  `org_kde_plasma_virtual_desktop_management` says which desktops are current, and `show_desktop_changed` whether
  "show desktop" hides everything. Because there is geometry, `DesktopPauseRules.plasmaSnapshot` builds the X11 probe's
  snapshot and the X11 rules apply unchanged: a window's monitor holds its centre, the active window is fullscreen when
  it has the state or covers its monitor, maximized counts for any visible window; windows on another virtual desktop
  are unmapped, minimized or "show desktop" windows hidden, and skip-taskbar windows (Plasma's desktop and panels) take
  the place of EWMH desktop/dock windows (Inferred: the protocol has no window type). The application is the pid's
  executable from /proc with the app_id (`LinuxProcesses.identity(pid:appID:)`: name = the app_id's last dotted part,
  bundle id = the app_id). KWin advertises the protocol only to a client whose executable is the `Exec` path of a
  `.desktop` entry listing it in `X-KDE-Wayland-Interfaces`, compared with `/proc/<pid>/exe` literally (a relative
  `Exec`, a symlink or another directory does not match; checked in the container). The packages install the hidden
  entry `photon2-kwin.desktop` with `Exec=/usr/bin/photon-linux desktop`; without it the host runs with the frames and
  the system rules only and prints what is missing.
- **GNOME (Mutter)** has neither layer-shell nor a foreign-toplevel protocol. `--backend gnome` (chosen automatically
  under GNOME when layer-shell is missing) gives each output a plain `xdg_toplevel` sized to its logical size, app_id
  `io.github.photon2.Photon.Background`, title `photon2 background <connector>`, with the same swapchain or `wl_shm`
  presentation as the layer surfaces. The extension `photon2@photon2.github.io` (GNOME 45+, ESM;
  `packaging/gnome-shell`) finds these windows, moves each to the monitor its connector names
  (`get_monitor_for_connector`), sticks and minimizes it, so the window itself is not drawn, takes no input and never
  has focus, and adds a `Clutter.Clone` of its window actor to every background actor (`BackgroundManager.
  _createBackgroundActor` is patched: the desktop, the overview's workspace previews, the lock screen). Mutter
  composites the client's buffer straight from the clone, so the animation costs no copy beyond what any window costs.
  The windows are filtered out of the overview, the workspace thumbnails, the window switcher (`get_tab_list`) and the
  dash (`Shell.App.get_windows`, `AppSystem.get_running`). This is approach (a) of the plan, the one Hanabi uses for
  videos; importing frames through shared memory into a Clutter texture (b) would add a CPU copy per frame. The
  extension also owns `io.github.photon2.Shell` on the session bus (`/io/github/photon2/Shell`,
  `io.github.photon2.Shell1`): `GetState` and `StateChanged` carry Mutter's windows as JSON (focus, minimized,
  maximized, fullscreen, monitor index, on the active workspace, DESKTOP/DOCK type, pid, app id; monitors with their
  geometry and the connectors the renderer titles named), sent when a window or workspace signal fires and at most
  once a second otherwise; `PointerChanged(x, y, desktop, pressed)` carries the cursor at 30 Hz while it moves and the
  left button pressed on the desktop (the stage, the background group or a DESKTOP-type window, outside the overview).
  `CPhotonSystem/photon_gnome.c` follows these on its own GLib thread; `DesktopPauseRules.gnomeSnapshot` maps Mutter's
  monitor index to the host's outputs by connector, else by geometry, and the X11 probe decides as above. The host
  refuses to start without the extension (its windows would be ordinary windows) and stops when the extension leaves
  the bus for more than 2 s. The extension runs in the `unlock-dialog` session mode as well, so locking the screen
  does not end the host. `--static-background WxH` remains: one frame (prepared like `render`) written to
  `$XDG_CACHE_HOME/photon2/background.png` and set as `org.gnome.desktop.background picture-uri` / `picture-uri-dark`
  with `picture-options` zoom, a still for systems without the extension.
- **Compositor support.** wlroots compositors (sway, labwc, Hyprland, river, Wayfire): layer-shell and
  foreign-toplevel. KDE Plasma: layer-shell and Plasma window management. GNOME: the extension.
- **Tested** (`scripts/linux/in-container/wayland-smoke.sh`, `ci.sh --wayland`) under sway 1.9 and labwc 0.7.1 with the
  headless backend and the pixman renderer, screenshots by grim (wlr-screencopy): the full renderer through the
  swapchain and through `wl_shm` (`--still`) equals the headless render byte for byte at 1280×720; at scale 1.5 the
  buffer is 1920×1080 and equals the 1920×1080 headless render byte for byte; a second output (1024×576) created with
  `swaymsg create_output` while the host runs gets a surface equal to the 1024×576 headless render, and `output
  HEADLESS-2 unplug` removes it; a fullscreen `xdg_toplevel` (`desktop --wl-test-client fullscreen`) pauses the output
  under sway and a maximized one under labwc (sway has no maximized state), and both resume when the client closes;
  `--static-background` sets the gsettings keys (keyfile backend) and writes a PNG equal to the headless render.
  `desktop --self-test` has 9 Wayland mask cases, 8 KWin and 4 GNOME snapshot cases (60 checks in all). Not exercised:
  a real GPU's WSI (radv/anv/NVIDIA through dmabuf instead of lavapipe's `wl_shm`), Hyprland, a compositor that
  withholds frame callbacks.
- **Tested on KWin** (`in-container/kde-check.sh`, `ci.sh --kde`): KWin 5.27.11 from Ubuntu 24.04 as
  `kwin_wayland --virtual` with two 1280×720 outputs (the image removes `kwin_wayland`'s file capability, which a
  container refuses at exec). KWin's own screenshot of each output (`org.kde.KWin.ScreenShot2.CaptureScreen`,
  `kwin_screenshot.py`) equals the headless render of the same frame byte for byte, both through the Vulkan swapchain.
  Without `photon2-kwin.desktop` the protocol is withheld and the host says so; with it, a fullscreen client on
  Virtual-1 (`--wl-test-client fullscreen --output Virtual-1`) pauses Virtual-1 while Virtual-0 keeps running, and
  both run after it closes; a maximized client pauses the output KWin places it on (Virtual-0) and nothing else; a
  maximized window stops pausing when KWin switches to a second virtual desktop (`VirtualDesktopManager` over D-Bus) and
  pauses again on the way back; a fullscreen client with app_id `org.example.mygame` and a mute rule for "mygame"
  mutes instead of pausing. Without panels an active maximized window covers its output, so the log calls that pause
  "fullscreen", as the X11 geometry rule does. Not run: Plasma 6 (KWin 6 sends only `window_with_uuid`, which the
  code handles), plasmashell's own desktop and panel windows, a session with Activities.
- **Tested on GNOME** (`in-container/gnome-check.sh`, `ci.sh --gnome`): GNOME Shell 46.0 (Mutter 46.2, Ubuntu 24.04)
  as `gnome-shell --headless --wayland --no-x11` with two 1280×720 virtual monitors (Meta-0, Meta-1), the extension
  installed from the zip that `gnome-extension.sh` packs, and a test-only helper extension that sets unsafe mode for
  `org.gnome.Shell.Eval` and the screenshot API. The shell needs a system bus, and the container hides
  `/run/systemd/seats` so it uses its dummy login manager. Results: the two background windows are minimized,
  unfocused, on all workspaces and absent from the tab list; the screenshot of each monitor with `--still` equals the
  headless render byte for byte (top bar made transparent); without `--still`, two screenshots 1 s apart differ by a
  mean of 37.8 levels on both monitors and the host holds its 15 fps; a fullscreen client on Meta-1 pauses Meta-1
  while Meta-0 keeps animating (36 levels between two shots), both resume, and a maximized client (Mutter puts it on
  Meta-0) pauses Meta-0 alone; the app_id rule mutes; a Clutter virtual pointer at 320,180 reaches the scene as UV
  0.25,0.25, a click on the background is a desktop press and a click on a window is not; the overview shows the
  wallpaper in both workspace previews and previews only the test window; disabling the extension stops the host and
  leaves no window behind. Not run: GNOME 45, 47, 48 and 49 (the extension guards the calls that changed:
  `get_maximized` → `is_maximized` in 49), fractional scaling, the desktop-icons extension's DESKTOP window (its
  clicks count as desktop clicks in the code), and the lock screen.

### 5.4 Switches, layouts, cursor and the remaining rules (phase 6b)

The scene hosts' shared part is `Host/SceneHost.swift`: the scene loop, the control commands, the rule evaluation, the
layouts, the cursor and the switches. `X11Desktop.swift` and `WaylandDesktop.swift` only provide the outputs (the
`HostSurface` protocol: name, pixel size, logical geometry, swapchain or readback) and the window-system inputs.

**Wallpaper switches** (docs/re/frame-graph.md §T, the macOS `WallpaperRenderer` switch logic):

- In one host (`load {json}` on stdin): a scene or video wallpaper replaces the running one on the same outputs. Per
  output (or per shared frame) the old frame is read back as the engine does (`SceneFrameSource.capture`: rendered at
  the output size, resolved to opaque BGRA8), then: an effect (0–26, or random from the pool) → `WallpaperTransition`
  (the engine's `dx11playlisttransition` with the GS emulation, as on macOS) at progress 0 over black; −2 → the old frame
  held; "none" between two wallpapers of one type → the old frame frozen; "none" between types (scene ↔ video) → black.
  That frame is presented before the new scene loads (the load is synchronous, as on the engine's render thread), the
  effect starts with the new scene's first frame (0.1 s delay, `transitiontime`) and is composited over every frame
  until progress ≥ 1; hold, frozen and cut end with the first frame. A transition runs the loop at ≥ 60 fps. A
  transition that cannot be built (no `dx11playlisttransition` in the assets: the CC0 stand-in) switches with a cut,
  as the macOS app does.
- Between hosts (scene ↔ web, web → web, a changed display grouping or settings): `snapshot DIR` makes the old host
  write each output's frame (`<output>.bgra`, `shared.bgra`; a web host through `webkit_web_view_get_snapshot`, waited
  for up to 3 s) and stop drawing; the new host starts with `--switch-snapshot DIR --transition JSON` and shows the
  overlay / held frame before its wallpaper has loaded; the app ends the old host when the new one prints `host:
  ready`. A web host draws the overlay with a pass-through `GtkDrawingArea` in a `GtkOverlay` above the `WebKitWebView`
  (cairo OVER of the premultiplied overlay rendered offscreen with Vulkan and read back, the composite DWM does for the
  engine); the effect starts 0.5 s after the switch (a page never reports ready), a −2 hold lasts until the page has
  loaded (3 s at most). Restarts without a wallpaper change overlap the same way (the old frame stays until the new host
  has drawn); "none" between types ends the old host at once.
- Checked (`in-container/host-features.sh`): `photon-linux transition` renders every effect; with
  `PHOTON_TRANSITION_SEED=7` (MSVC `rand` from `srand(7)` for g_Hash, g_Hash2, g_Random and the shatter sites, in both
  `photon-tool` and `photon-linux`) 22 of the 27 effects equal `photon-tool transition` on macOS (mean difference
  < 0.05 at 320×180, progress 0.5; most exactly 0); effects 1, 2, 12, 23 and 26 take their pattern from the shader's
  `nrand` = `frac(sin(x) · 43758.5453)`, which differs per pixel between GPUs (sin precision), and match in mean
  colour. In the X11 host, root-window samples every 0.1 s through a switch red → blue: a fade passes through the mix,
  −2 and "none" go straight from red to blue, none of them shows a black frame; random picks from its pool; "none"
  scene → video cuts; an effect into a video wallpaper starts. The same fade under sway (grim samples). In the app
  (`app-check.sh`): a browse switch with a fade loads in the running host; scene → web hands over with the scene's
  frame, web → scene with a −2 hold and the page's frame, and the old host ends after the new one is ready.

**Playlists and video ends.** A video wallpaper's host prints `video: ended N` each time the scene clock passes a
multiple of the container duration (the macOS loop count); the app calls `PlaylistController.videoEnded` for the
host's displays (the source display in stretch / clone), which selects the next item with the playlist's transition.

**Layouts on both backends** (`--layout stretch|clone`, `--clone-source NAME`, `--clone-flip NAME,…`; docs/re/09 §8.2,
§8.3): the scene renders once
into a shared frame and each output shows its part through a scaled blit (`GPUCommandBuffer.blit` / `present(_:region:
to:)`, vkCmdBlitImage, nearest when the sizes match): stretch = the bounding box of the outputs' logical rectangles at
the smallest scale (16384 at most), each output its rectangle; clone = the source output's frame (`--clone-source`,
default the first), cover-fitted onto the
others and mirrored on flipped outputs (`LayoutGeometry`, shared with macOS). The pause rule then needs every output
covered (`layout` 1/2 in the evaluator); the switch overlay covers the shared frame; the cursor maps into the box (stretch)
or the first output (clone). Web wallpapers stay per display. The app passes `--layout` instead of the bounding-box
`--monitors` it used before. Checked: under sway with two 1280×720 outputs, each grim capture equals its half of the
2560×720 headless render byte for byte (the X11 host the same with `--monitors`, swapchain and readback); clone onto a
1024×576 flipped output matches the mirrored, scaled source (mean 0.6).

**Split regions** (`--region NAME=X,Y,W,H`, repeatable; docs/re/09 §8.3): the profile's `splits` cut a display into
regions (`<display>/L`, `/R`, nested), each a wallpaper instance of its own (wallpaper, playlist, preset and properties
keyed by the region). The app runs a host per region; the host's surface on that output covers only the rectangle
(logical units from the output's top-left), so its scene is sized to the region and everything else in the host
(units, switches, pointer UV) works unchanged. X11: the desktop-type window is the region's rectangle (root mode puts
the frame there); wlroots and KWin: a layer surface anchored top-left with the region's size and the offset as margins
(`photon_wl_surface_create_region`); GNOME: an xdg_toplevel of the region's size titled `photon2 background <connector>
X,Y,W,H`, which the extension (`parseTitle`) shows as a clone at the region's part of every background actor of the
monitor, beside the monitor's other regions; web pages: the WebKitGTK window (layer surface or desktop window) over the
region (`photon_web_view_create_region`). The rules probe the whole output, so a region pauses with its display (the
engine's split records keep the monitor index). A region that is a member of a stretch or clone group is one of the
group host's outputs, cut to its rectangle. Sound: the first host of a wallpaper (display order, then regions) plays
its sound objects and a video's audio; the app gives later hosts of the same wallpaper `--no-sound`. Checked
(`host-features.sh` 3c, `wayland-smoke.sh` 7c): a nested split (640×720 left, 640×360 top and bottom right) with three
hosts running at once; each region of the root window / grim capture equals its wallpaper's headless render at the
region's size byte for byte (Vulkan swapchain); in the app, `app-check.sh`'s layout passes (below).

**Cursor** (macOS `pointer(in:)` and `DesktopPointer`): the position in global logical coordinates becomes each scene's
pointer UV (y down; parallax, cursor scripts, particle control points, `g_PointerState`), the left button pressed on the
desktop becomes `pointerDown` until it is released anywhere. X11: `XQueryPointer` per frame for the position, XInput 2
raw button events on the root (delivered over any window), and a press counts when the top-level window under the
pointer is photon's, the root or a `_NET_WM_WINDOW_TYPE_DESKTOP` window (or a WM frame holding one). Wayland: `wl_seat` /
`wl_pointer` events on the layer surfaces, which only get them when nothing is above them, i.e. on the desktop; over
windows the last position stays (clients see no global position). Web pages get pointer events from WebKit itself.
Checked with XTEST (`desktop --pointer-test`) and wlr-virtual-pointer (`desktop --wl-pointer-test`, protocol XML vendored):
positions map to the output UV, a click on the background is a press, a click on a window is not.
`PHOTON_POINTER_LOG=1` prints them.

**Application rules** (`--app-rules`, the app's `apprules`; docs/re/09 §1.5): X11 windows' processes come from
`_NET_WM_PID` → /proc (`comm`, the `exe` file name) with the `WM_CLASS` class; Wayland toplevels from their app_id
(`org.mozilla.firefox` matches "firefox" too); condition-0 rules from the user's processes in /proc. As on macOS, a window
whose application has a rule for its state leaves the global focus / maximized / fullscreen mask and its rule acts
instead. **Another application plays audio**: the sink inputs of PulseAudio or pipewire-pulse
(`photon_audio_streams`, `CPhotonSystem/photon_streams.c`), a stream that is not corked counting as playing; streams of
photon's own processes (this one, the app, other hosts, their WebKit processes: anything whose executable or an
ancestor's is photon-linux) are excluded; also the input of "playingaudio" rules. **`pausevram`**: `VK_EXT_memory_budget`
(device-local heaps' usage and budget, `VulkanDevice.memoryBudget()`) through the hysteresis the macOS app uses, now
shared (`VRAMRule`, PhotonApp: stop at 80 %, release under 75 % after 15 s or under 35 %); a stop frees the scenes
(they reload when it ends), as the engine destroys its wallpapers. Checked: a running `sleep` with a pause rule pauses
and resumes; a fullscreen window of class `mygame` (X11) / app_id `org.example.mygame` (sway) with a mute rule mutes
instead of the global fullscreen pause; a tone played by `paplay` into a PipeWire null sink pauses a host with
`--audio pause` while the host's own OpenAL stream is recognised as photon's; `PHOTON_VRAM_TEST` (a file with "used
budget" in MB) at 90 % stops and at 30 % resumes; on lavapipe the real reading is printed (e.g. 1586 of 8217 MB).

**Single instance** (`photon-linux app`): the first instance owns `io.github.photon2.Photon` on the session bus (the
Flatpak's app id) and exports `Activate(as arguments, s activation_token)` at `/io/github/photon2/Photon`; a second
launch calls it with its arguments and `XDG_ACTIVATION_TOKEN` / `DESKTOP_STARTUP_ID` and exits 0. The first applies a
wallpaper id given to the second and raises the browser (`gtk_window_set_startup_id` + present), except for a
`--background` launch. No session bus: no guard. `--self-test` and `PHOTON_SINGLE_INSTANCE=0` skip it. Checked in
`app-check.sh` on X11 and Wayland.

**Display layouts in the app** (`app-check.sh`, layout passes; `app --self-test` with `PHOTON_SELFTEST_LAYOUT=1`): two
800×1000 outputs (X11: `PHOTON_X11_MONITORS=LEFT=800x1000+0+0,RIGHT=800x1000+800+0` on one Xvfb screen, which the app's
`--list-outputs` and every host it starts read instead of XRandR; Wayland: two headless sway outputs). Through Settings
→ Displays: a clone group of both outputs (name `group_<hashCode>`, the only wallpaper target, one host with
`--layout clone` over both), a locked source and a flip (the host restarts with `--clone-source`, `--clone-flip`),
removal; a vertical split of the first output at 400 px (targets `/L`, `/R` and the second output; the browser applies
a second wallpaper to `/R`; a host per region with `--region LEFT=0,0,400,1000` and `LEFT=400,0,400,1000`; the
wallpaper shown on `/L` and the second output plays its sound in one host only), a nested horizontal split of `/R`
(the new `/R/L` takes `/R`'s wallpaper, three region hosts), moving the first divider to 200 px (the hosts follow),
removal (back to a host per display). The capture of the split must show different pictures in the two regions.

### 5.3 Web wallpapers

A project whose `file` classifies as web (`.html` or an http(s) URL) runs in WebKitGTK 4.1 instead of the scene
renderer; `photon-linux desktop <dir>` hands it to `Host/WebDesktop.swift`. WebKitGTK 4.1 (GTK 3) rather than 6.0
(GTK 4) because SceneScript already links `javascriptcoregtk-4.1`, and 6.0 would load a second JavaScriptCore with the
same C symbols into the process. The GTK and WebKit calls are C (`Sources/CPhotonWeb`).

- **Windows.** One web view per monitor (the engine runs a CEF wallpaper per monitor), in a GTK window that is a
  gtk-layer-shell surface on the `background` layer on Wayland (anchors, exclusive zone -1, keyboard mode none,
  namespace `photon2`) and an undecorated DESKTOP-type window kept below, sticky and out of the taskbar and pager on X11.
  WebKit composites the page into the window itself (GPU when the driver has GL, software otherwise), so no frame goes
  through photon's renderer. Monitor hotplug (`monitor-added` / `monitor-removed`) rebuilds the pages. GTK 3 scales by
  integers; on a fractional output the compositor scales the next integer scale down.
- **Page API.** The page side moved from `WebWallpaper.swift` into `PhotonRender/WebPageScripts.swift`, which both hosts
  use, so macOS and Linux inject the same scripts and send the same JavaScript: the engine's runtime read from the
  install's `webwallpaper64.exe` (docs/re/09 §6), the bindings (`wallpaperRegisterAudioListener` with its one-callback
  rule, the five media listeners, `wallpaperRequestRandomFileForProperty`, `wallpaperGetUtilities`, video-ended and
  screenshot no-ops), the LED plugin stubs, and on load `applyGeneralProperties`, `applyUserProperties` with typed
  property objects in jsoncpp key order, `userDirectoryFilesAddedOrChanged` for `fetchall` directories, then `setPaused`
  with `___wpxPause` / `___wpxUnpause`, the `wec_*` CSS filter and the `alignmentfliph` flip. Messages come back through
  `window.webkit.messageHandlers.photon` on both (WebKitGTK's script message handler). Pages load from the secure,
  CORS-enabled scheme `photon-web://wallpaper/<file>`, and directory properties from `photon-web://local/<path>`
  restricted to their folders, served from disk as the macOS `WKURLSchemeHandler` does. `--general JSON` (or
  `PHOTON_GENERAL`) and `--property name=value` set the wallpaper's general and user properties.
- **Audio** comes from the §3.6 capture: once a page registered a listener and the project has
  `supportsaudioprocessing` (and `audioprocessing` is not off), the analyzer's raw 128 floats go to it every 33 ms, as the
  CEF wallpaper's audio thread sends them (docs/re/09 §6).
- **Media** comes from MPRIS (`PhotonRender/Linux/WebMediaLinux.swift`): status `{enabled}` true while the session bus
  answers, playback from `PlaybackStatus`, properties from `xesam:*` (`albumArtist` filled, `subTitle` and `contentType`
  empty), the thumbnail re-encoded as a PNG data URL with the five `MediaColors` colours, the timeline on length or state
  changes and seeks (§5.1). The first registration starts the poller; later ones replay the current state from
  wallpaper64's empty baseline.
- **Rules.** The probe runs on a second connection: EWMH on X11 (`X11Probe`, shared with the X11 host), foreign-toplevel
  on Wayland; its monitors are matched to GDK's by logical geometry. Pause runs the page's pause script, mute is
  `webkit_web_view_set_is_muted`, stop destroys the views and recreates them when the rule ends (as on macOS).
- **LED plugin fix (both hosts).** The `cue` / `wpPlugins.led` objects were defined at document start.
  def_corsair_o_tron's main script declares `var cue = null;`, which replaced the object with null, and its
  `onPluginLoaded('cue')` then threw on `window.cue.getDeviceCount` (on macOS as well). They are now installed in the
  same `___wpxShared.onLoad` callback that calls `onPluginLoaded`, the order in which the page expects them.

**Tested** (`in-container/web-check.sh`, `ci.sh --web`) with the API test page `scripts/linux/web-test/api`, which logs
what the host delivers: on Xvfb with a 440 Hz / 2 kHz tone in a PipeWire null sink, a fake MPRIS player and a fullscreen
X11 test client, every check passes: utilities, the injected runtime, the plugin calls, typed user properties and
general settings, both directory modes with images served from `photon-web://local`, one audio listener receiving 231
frames in about 8 s with peak bands 18 and 38, all five media events (title, playing then paused, a PNG thumbnail with
primary colour `#C82727`, a 200 s timeline), pause and resume. The 10 page lines that do not depend on the host's inputs
equal the macOS host's (`scripts/linux/web-mac-ref.sh`, `photon-tool render` with `PHOTON_WEBDEBUG=1`). With
`wec_e`, hue 75, saturation 20 and flip, the computed style is `contrast(1) brightness(1) saturate(0.4)
hue-rotate(90deg)` / `scaleX(-1)` on both, and the sampled colours are within 2 levels of the macOS render (66, 100, 48
against 65, 98, 47); unfiltered they are equal. Under sway the page sits in a layer-shell surface whose grim capture
has the X11 colours, and a fullscreen `xdg_toplevel` pauses and resumes it. def_corsair_collection and
def_corsair_o_tron load without script errors and draw the same layout as on macOS; corsair_o_tron's spectrum bars move
with the test tone.

## 6. The app and shipping

### 6.1 The app (`photon-linux app`)

**Shared model.** `Sources/PhotonApp` holds what the macOS app's UI sits on: `AppState` (assignments, property
overrides, general properties, playback settings and rules, fps, MSAA, resolution, post-processing, layout, clone flip,
the switch transition, master volume, mute, pause) with its persistence, `Library` (scan, `PropertySpec`, general
properties, `LocalizedStrings`, `ConditionEvaluator`), `EnginePlaylist` / `PlaylistRunner` / `PlaylistController`,
`PlaybackEvaluator`, the property presets, `LayoutGeometry` (span and cover geometry), and `SettingsCatalog` /
`PlaylistEditing` (option lists, transition labels, the playlist panel's item rules). These are the macOS files, moved;
the edits are access control (`package`, plus explicit `package` initializers where a memberwise one was used across
modules) and three `#if` branches:

- `DisplayInfo`: on macOS the CoreGraphics display UUID and `NSScreen`, as before; on Linux the output's connector name
  (XRandR monitor or `xdg_output` name) from `photon-linux desktop --list-outputs`, which is also what `--output` takes.
- `PlaylistController.tick`: `CACurrentMediaTime()` on macOS, `ProcessInfo.systemUptime` on Linux.
- `EnginePlaylist.number` / `bool`: `CFGetTypeID == CFBooleanGetTypeID` on Darwin; on Linux a Swift `Bool` or an
  `NSNumber` with objCType `c` (what JSONSerialization makes of `true`/`false`).

The macOS app keeps its SwiftUI views, `PlaybackMonitor`, `WallpaperRenderer`, `LayoutCompositor` (whose `spanRegions` /
`coverUV` now call `LayoutGeometry`), `ThumbnailCache` and the preset name prompt, and re-exports PhotonApp
(`Sources/photon/Exports.swift`); the tests add `@testable import PhotonApp`. Persistence keys and defaults are
unchanged. Checked: `swift build`, `swift build -c release` and `swift test` pass (81 tests, 16 skipped), and
`PHOTON_TEST_INTEGRATION=1 swift test` runs all 81 including the headless renderer tests with no failure.

**Combine on Linux.** `LinuxCompat/Combine` implements `ObservableObject` (one `ObservableObjectPublisher` per object),
`@Published` through the `_enclosingInstance` subscript (the object's `objectWillChange` fires, then the projected
publisher sends the new value, then it is stored, which is Combine's order), and the operators PhotonApp calls (`map`,
`removeDuplicates`, `dropFirst`, `filter`, `sink`, `store(in:)`); a subscription gets the current value first, as
`Published.Publisher` does.

**Settings file.** `XDGDefaults` (a `UserDefaults` subclass) keeps the `photon2` domain in
`$XDG_CONFIG_HOME/photon2/photon2.plist` (`~/.config/photon2/photon2.plist`), an XML property list with the macOS keys
and value types (`assignments`, `overrides` as JSON data, `mastervolume`, `muted`, `playback*`, `windowupdaterate`,
`pausevram`, `apprules`, `fps`, `postprocessing`, `layout`, `cloneflip`, `msaa`, `resolution`, `browsetransition`,
`wpresets`, `playlists`, `selectedplaylists`, `playliststate`), written on every change. Two keys are Linux only:
`workshopdir` and `weinstalldir`.

**Why GTK 3.** photon-linux already links WebKitGTK 4.1 (GTK 3) for web wallpapers and `javascriptcoregtk-4.1` for
SceneScript; GTK 4 cannot be loaded into the same process. The windows are written in Swift against GTK's C API
(`App/GtkSupport.swift`: casts in place of the `GTK_*()` macros, closures for signals); the status icon and a few helpers
are C (`CPhotonApp`).

**Windows** (`Sources/photon-linux/App/`), each mirroring its SwiftUI counterpart:

- Browser (`BrowserWindow.swift`, macOS `BrowserView`): a flow-box grid of the library with preview thumbnails decoded
  off the main thread (GdkPixbuf, cropped to fill), a search field over title, tags and id, "Show unsupported"; a
  double-click applies to every display. The details pane shows the preview, title, type and id, the unsupported
  reason or a display picker with Apply, where the wallpaper is showing, load errors, the general properties
  ("Wallpaper": volume, rate, parallax, alignment and its position, zoom and flip, LUT filter, colour options) and the
  project's properties with Presets (load, save current, delete) and Reset. Playback bar: pause, mute, master volume,
  post-processing, reload library, settings.
- Properties (`PropertiesPanel.swift`): bool, slider (quantized to the step from the minimum, as on macOS), color
  (`r g b` in 0 to 1, or 0 to 255 read), combo, textinput, file / directory, group and text rows; a row is shown when its
  `condition` evaluates true in JavaScriptCore with the current values (`ConditionEvaluator`).
- Playlist panel and its settings dialog (`PlaylistPanel.swift`, macOS `PlaylistPanel` / `PlaylistSettingsSheet`): the
  playlist of "All displays" or one display, edited in place; Add wallpaper, Load (and delete) saved playlists, Save,
  Configure, Clear, Next; per-item remove, move, preset (right-click), half-hour end times for time of day and day ranges
  for day of week; the dialog has the mode, hours and minutes, order, transition with its pool and time, and the
  timer-only options.
- Settings (`SettingsWindow.swift`, macOS `SettingsView`): the six playback rules with the options the engine's UI
  offers for one or several displays, "stop when video memory runs out", the check interval, application rules,
  frame rate, post-processing, MSAA, texture resolution, the switch transition and its duration, the layout with clone
  flips, master volume and mute, the library folders, and "Start photon when I log in".

**Status icon** (`Tray.swift`, `CPhotonApp/photon_tray.c`). A StatusNotifierItem on the session bus
(`org.kde.StatusNotifierItem-<pid>-<n>`, object `/StatusNotifierItem`, `IconName photon2` plus `IconPixmap` from the
installed PNG), registered with `org.kde.StatusNotifierWatcher` whenever a watcher appears; KDE Plasma, waybar,
swaybar, xfce4-panel's SN plugin and GNOME's AppIndicator extension host such items. The menu is exported over
`com.canonical.dbusmenu` (version 3) at `/MenuBar`: the wallpapers showing, Next Wallpaper / Previous Wallpaper / Saved
Playlists while a playlist runs, Browse Wallpapers…, Settings…, Pause or Resume, Mute (checkmark), what the playback
rules last did, Quit photon (the macOS menu). A left click opens the browser, a middle click toggles pause, and a host
that calls `ContextMenu` gets the same menu as a GtkMenu. Inside Flatpak the item registers under its unique bus name
(the sandbox cannot own `org.kde.StatusNotifierItem-*`). With no watcher on the bus after 3 s (GNOME without the
extension), the app opens the browser.

**Driving the hosts** (`HostSupervisor.swift`). The app does not draw; it runs `photon-linux desktop <folder> --control
--output <names>` processes, one per group of displays that show the same wallpaper with the same property values.

- On the command line (a change restarts the host): the outputs, the user property values with the display's running
  preset applied (`--properties JSON`, now honoured by scene hosts through `SceneRenderer(propertyOverrides:)`), the
  general properties (`--general`), the six rules, `--window-update-rate`, `--fps`, `--msaa`, `--resolution`,
  `--postprocessing`.
- On stdin (`HostControl.swift`, live): `pause`, `mute`, `volume` (wallpaper volume × master volume), `rate`, `general
  {json}` (alignment, colour options and flip change without a reload, as in the engine), `quit`. End of input ends a
  host, so hosts never outlive the app.
- Layouts: stretch and clone run one host over every output with `--layout stretch|clone` (and `--clone-source`,
  `--clone-flip`), which renders a shared frame (§5.4); a stretch or clone group of the profile (docs/re/09 §8.3,
  `LayoutPlan.hostGroups`) runs one such host over its own outputs; web wallpapers stay per display.
- Switches (§5.4): hosts are keyed by their outputs. A scene or video wallpaper replacing another on the same outputs
  with the same settings is sent as `load` with the transition (`AppState.takeTransition`: the playlist's settings or
  `browsetransition`); anything else starts a new host that takes over from the old one (`snapshot`,
  `--switch-snapshot`, `--transition`, `host: ready`). `video: ended` lines drive `PlaylistController.videoEnded`. The
  application rules and `pausevram` go to every host (`--app-rules`, `--pause-vram`). Hosts write their stdout line by
  line.
- Hosts are posix_spawn children watched with `g_child_watch_add` / `g_unix_fd_add`; Foundation's `Process` was not
  used because its exit notification never arrived inside the GTK main loop. A host that exits within 10 s or with an
  error marks the wallpaper failed (shown in the grid and details) and is not restarted until something changes.
- `playback:` lines from the hosts become the tray's and the settings window's status.

AppState's debounced reloads and the playlist timer are Foundation timers and main-queue blocks, so the Foundation run
loop is serviced from the GLib loop every 15 ms. Each pass first queues an empty main-queue block: with only a past limit date, swift-corelibs'
`RunLoop.run(mode:before:)` sometimes blocked in an unbounded `ppoll` on its own descriptors, which froze the GTK loop
(found in phase 6b, when the self-test ran long enough to hit it); the readable main-queue eventfd makes every pass
return at once.

**Library folders** (`LibraryPaths.swift`): the Workshop folder is `PHOTON_WORKSHOP`, the `workshopdir` setting, or the
first `steamapps/workshop/content/431960` found in the library folders (`libraryfolders.vdf`) of `~/.local/share/Steam`,
`~/.steam/steam`, `~/.steam/root` or Steam's Flatpak; the engine assets are `PHOTON_WE_ASSETS`, `<weinstalldir>/assets`,
`steamapps/common/wallpaper_engine/assets`, or photon's own copy in `~/.local/share/photon2/wallpaper_engine/assets`,
which the setup window downloads with steamcmd when none of the others has the files (`EngineFiles.swift`). The library is the Workshop folder plus the install's
`projects/defaultprojects` and `projects/myprojects` (as on macOS) plus `PHOTON_LIBRARY` (colon-separated).

**Checked** (`scripts/linux/in-container/app-check.sh`): under Xvfb (1600×1000) and under headless sway, each with a
private session bus and a stand-in tray (`fake_sni_watcher.py`), `photon-linux app --self-test OUTDIR` drives the app
through its widgets: select and double-click a tile (a host starts and draws the wallpaper behind the window), Apply to
one display, the volume slider and flip of the general properties, the test scene's bool / conditional slider / combo /
textinput properties, Save preset, a two-item playlist with the settings dialog (timer 1 min, sorted), Save playlist,
Next, the settings window's fps / MSAA / focus rule (the hosts restart with `--msaa x4`), the tray's Pause and Mute
(the host logs `control: pause true`), and reads the settings file back. The watcher reads the item's properties and
the dbusmenu layout over D-Bus and clicks Pause: Status goes to Passive and the item becomes Resume, a second click
resumes. Phase 6b added the switches (in place with a fade, by handover to the `web` scene and back with a −2 hold;
with `--corpus` also a timer playlist with videosequence whose generated 2 s video's end moves it on with its effect),
the rules reaching the hosts, and the single-instance check. On 2026-10-14 all 61 self-test checks, the 6 tray checks
and the single-instance check pass on both backends with the CC0 scenes (whose stand-in assets have no transition
shaders: the switches cut there), and with `--corpus` all 59 self-test checks
(2541606883 ↔ 1442092399 with the fade drawn in the host, → corsair_collection with the overlay over the page and back
with a −2 hold, the generated clip's end moving the playlist on with effect 1) and the single-instance check. The
display-layout passes (§5.4: clone groups and splits through Settings → Displays on two outputs) were added in session
10; re-run on 2026-10-14 with them, CC0 and `--corpus`: X11 and Wayland 61 / 59 self-test checks, the 6 tray checks, the
single-instance check and 41 layout checks per backend pass, and the split captures show different pictures per region
(mean pixel difference 9.5 CC0, 62 corpus). Window snapshots and screen captures land in the output folder (§8).

Not done: content-switching application rules (`loadwallpaper` / `loadplaylist` / `loadprofile`, not ported on macOS
either); NVIDIA Surround's `auto_split`; the cursor over windows on Wayland (no global position for clients); the overlay over a web page
is read back from the GPU each frame (fine at 1080p on lavapipe, a dmabuf path would avoid it); a real compositor's
xdg-activation for the raised window was not tried.

### 6.2 Packages and installation

- **Binary:** `swift build -c release --static-swift-stdlib --product photon-linux -Xlinker -rpath -Xlinker
  '$ORIGIN/../lib/photon2'`. The Swift runtime and Foundation are linked in. The rest comes from the system: libvulkan1
  and a Vulkan 1.3 driver (Mesa radv/anv/lavapipe, NVIDIA 535+), libpng16, libturbojpeg, liblz4, FreeType, fontconfig,
  HarfBuzz, javascriptcoregtk-4.1, X11 (Xrandr, Xext, Xss, Xi, Xtst), wayland-client, GTK 3 (the app), webkit2gtk-4.1
  and gtk-layer-shell (web wallpapers), libpipewire-0.3 and libpulse (spectrum capture), GLib/GIO (D-Bus), libcurl
  (FoundationNetworking), GStreamer 1.x with plugins-base, -good and -libav (MP4/WebM demuxers, H.264/HEVC/VP9), and
  the shader tools glslangValidator and spirv-cross (only for shader compiles; the SPIR-V cache makes later runs
  offline). Recommended fonts: fonts-croscore, fonts-crosextra-carlito/-caladea (metric-compatible substitutes, §3.3),
  fonts-noto-core, -cjk and -color-emoji.
- **Private libraries** (`/usr/lib/photon2`, found through the RUNPATH above, so the tree is relocatable):
  - `libopenal.so.1`: OpenAL Soft 1.21.1 with the `fastf2i` rounding patch, built in the image (§3.6). This is the
    engine's version. Distributions ship 1.23 or newer, and those mix the same calls differently: with Ubuntu's
    1.23.1 put in front through `LD_LIBRARY_PATH`, `sound-check` reports default resampler 2 instead of 1 and
    differences of 0.08 to 0.47 (speaker) and 0.53 to 0.86 (HRTF) per sample against photon2's voice model, where the
    bundled 1.21.1 stays under 1e-6. So the library is bundled instead of depended on; replacing it is one
    `LD_LIBRARY_PATH` away, and `usr/share/doc/photon2/copyright` names the source tarball, its SHA-256 and the patch
    (LGPL-2.0-or-later; the licence text is installed next to it).
  - `libstb.so.0`: stb_image as Debian builds it (GIF decoding, §3.5). Fedora has no shared libstb.
  - `.rpm` and tarball only: `glslangValidator` and `spirv-cross` from the build image. Fedora packages glslang but
    not spirv-cross. `ShaderCompiler.defaultTool` and `SPIRVCompiler.defaultGlslang` look in `/usr/bin`,
    `/usr/local/bin`, then `<exe>/../lib/photon2/`.
- **Version:** `Sources/CPhotonVersion/include/photon_version.h` holds `PHOTON_VERSION_BASE` (0.9.3), the one place the
  version is written. `PhotonVersion.string` (PhotonCore) returns the version stamped at build time with
  `swift build -Xcc '-DPHOTON_VERSION="<v>"'`, or the base with `-dev` appended for an unstamped build.
  `photon-linux --version`, `photon-tool --version` and `photon --version` print it; the macOS menu shows it above
  "Quit photon". `package.sh` and `appimage.sh` default to `env.sh photon_version`: `git describe --tags --match
  'v[0-9]*'` (`v0.7.0-3-gabc1234` becomes `0.7.0+3.gabc1234`, valid for dpkg and rpm) in a tagged checkout, else the
  base. `package-build.sh` stamps the binary with the package version and checks `--version` before packaging,
  `appimage-build.sh` refuses a Debian 12 binary stamped with another version, and the Flatpak manifest stamps the base.
  The install tests compare `--version` with the installed package's upstream version (`dpkg-query`, `rpm -q`), the
  AppImage's file name, and the source tree's base (Flatpak).
- **Assets:** like macOS, photon2 reads the user's own Wallpaper Engine install (or the copy it downloads with the
  user's account) and Steam Workshop folder; nothing from Wallpaper Engine is packaged. The app finds Steam's folders itself (§6.1); the CLI subcommands still default to the
  container mount points `/we/assets` and `/workshop` (`PHOTON_WE_ASSETS`, `PHOTON_WORKSHOP` override).
- **Files** (`packaging/linux/`): `photon2.desktop` (`Exec=photon-linux app`), `photon2-autostart.desktop`
  (`--background`), `photon2.svg` (rendered to 32 to 256 px PNGs), `photon2.service` (systemd user unit: `PartOf=` /
  `After=` / `WantedBy=graphical-session.target`, `ExecStart=/usr/bin/photon-linux app --background`,
  `Restart=on-failure`; the hosts are in its control group), AppStream metadata (the packages point its `launchable`
  at `photon2.desktop`, the Flatpak at `io.github.photon2.Photon.desktop`). `photon2-kwin.desktop` (`NoDisplay`,
  `Exec=/usr/bin/photon-linux desktop`, `X-KDE-Wayland-Interfaces=org_kde_plasma_window_management`) lets KWin give
  the host its window list (§5.2). The `.deb` and `.rpm` install the GNOME Shell extension system-wide in
  `/usr/share/gnome-shell/extensions/photon2@photon2.github.io` (users enable it once:
  `gnome-extensions enable photon2@photon2.github.io`, then log out and in on Wayland); `scripts/linux/gnome-extension.sh`
  packs the same files as `photon2@photon2.github.io.shell-extension.zip` for the tarball, AppImage and Flatpak users
  (`gnome-extensions install --force <zip>`) and for extensions.gnome.org.
- **Packages:** `scripts/linux/package.sh [version] [--distro ubuntu24.04|debian12|all] [--no-test|--test-only]`
  builds in a container (`in-container/package-build.sh`) and writes to `$PHOTON_LX_OUT/pkg`:

  | Build image | Output | Installs on |
  |---|---|---|
  | `photon2-linux:dev` (Ubuntu 24.04) | `photon2_<v>-1~ubuntu24.04_<arch>.deb` | Ubuntu 24.04 and later (`libc6 (>= 2.38)`, t64 package names) |
  | same | `photon2-<v>-1.<arch>.rpm` | Fedora 40 and later (`libc.so.6(GLIBC_2.38)`) |
  | same | `photon2-<v>-<arch>.tar.gz` | the staged `/usr` tree, relocatable |
  | `photon2-linux:bookworm` (`docker/linux/Dockerfile.bookworm`) | `photon2_<v>-1~deb12_<arch>.deb` | Debian 12 (glibc 2.36, pre-t64 names) |

  One Ubuntu-built `.deb` cannot serve Debian 12: the binary needs glibc 2.38 (`strlcpy`, `strlcat`, `fmod`, `fmodf`
  and the C23 `__isoc23_strtol` family come from the 2.38 headers) and depends on the t64 package names. The bookworm
  image carries the same Swift 6.2 toolchain, the `-dev` packages and the same OpenAL Soft 1.21.1 build.
  `Depends:` are the packages that own every library the binary and the private libraries name (DT_NEEDED through the
  loader cache and `dpkg -S`), `libc6` at least the newest GLIBC symbol version used, plus `mesa-vulkan-drivers |
  vulkan-icd`, the shader tools and the GStreamer plugins. The `.rpm` takes its requirements from rpm's ELF scanner,
  excludes the private libraries from Provides and Requires, and its binary drops the `CURL_OPENSSL_4` symbol-version
  requirement (`in-container/elf-drop-verneed.py`): Fedora's libcurl has no version nodes, and with the requirement
  glibc prints "no version information available" at every start. `desktop-file-validate` checks both entries (Debian
  12's validator does not know the Desktop Entry 1.5 key `SingleMainWindow`; the script says so and checks the rest).
- **Install test** (`in-container/package-install-test.sh`, run by `package.sh` unless `--no-test`): a fresh
  `ubuntu:24.04` and `fedora:40` container (`debian:12` for the Debian package) installs the package with apt or dnf,
  then installs the same file again with plain `dpkg -i` / `rpm -i --replacepkgs` (no `--force`), runs `apt-get check`
  / `rpm -V`, `ldd` (nothing missing; OpenAL and stb resolve to `/usr/lib/photon2`), `photon-linux info`, `desktop
  --self-test`, `sound-check` (OpenAL Soft 1.21.1 against the voice model), `--version`, the five CC0 scenes, `app --help` and
  `desktop --list-outputs` under Xvfb. The renders are compared with `Tests/scenes/refs/<arch>`: gated on Ubuntu 24.04
  (the image's Mesa), reported on Fedora 40 (Mesa 24.1, LLVM 18) and Debian 12, whose lavapipe differs (Fedora:
  mean 0.07 to 0.70 per scene; `effects` has 9,445 pixels over 8). Debian 12 runs everything on its stock Mesa 22.3.6
  lavapipe (LLVM 15) with the sampler-descriptor workaround (§2.2), and the test fails if `info` does not report it;
  its renders are byte-identical to Fedora 40's. `package.sh --backports` adds a second Debian 12 run
  (`debian12-backports`, `PHOTON_MESA_BACKPORTS=1`) on bookworm-backports' Mesa 25.0.

  Results on 2026-10-14 (arm64 on the Mac's Docker; x86_64 under Rosetta, `PHOTON_LX_PLATFORM=linux/amd64`):

  | Package | arm64 | x86_64 |
  |---|---|---|
  | `.deb` in ubuntu:24.04 | all checks; renders byte-identical to `refs/aarch64` | all checks; renders byte-identical to `refs/x86_64` |
  | `.rpm` in fedora:40 | all checks | all checks (render differences equal to arm64's) |
  | Debian 12 `.deb` in debian:12 | all checks on the stock Mesa 22.3.6; renders byte-identical to Fedora 40's; `--backports` run: all checks | all checks with renders on backports Mesa (before the workaround; not re-run on the stock Mesa) |

- **Install:**

  ```sh
  sudo apt install ./photon2_0.9.3-1~ubuntu24.04_amd64.deb   # Ubuntu 24.04+
  sudo apt install ./photon2_0.9.3-1~deb12_amd64.deb         # Debian 12
  sudo dnf install ./photon2-0.9.3-1.x86_64.rpm              # Fedora 40+
  systemctl --user enable --now photon2.service              # start with the graphical session (or Settings → Start at login)
  photon-linux app                                           # open the browser; the status icon stays after the window closes
  ```

  Without the systemd unit, "Start photon when I log in" writes `~/.config/autostart/photon2.desktop`. Compositors
  that do not start `graphical-session.target` (plain sway, Hyprland) need `exec systemctl --user import-environment
  DISPLAY WAYLAND_DISPLAY` and a start of the target in their config, or the autostart entry.
- **Flatpak** (`packaging/flatpak/io.github.photon2.Photon.yml`, `scripts/linux/flatpak.sh`): GNOME 51 runtime
  (freedesktop 26.08; GNOME 47 is no longer on Flathub). The runtime still ships GTK 3, webkit2gtk-4.1 and
  javascriptcoregtk-4.1 next to WebKitGTK 6.0. Modules: OpenAL Soft 1.21.1 with the rounding patch (shadows the
  runtime's 1.25.2 through `/app/lib`), glslang 14.3.0, SPIRV-Cross, stb_image as `libstb`, gtk-layer-shell 0.9.0
  (sources pinned by commit or SHA-256), and photon built with the Swift 6 SDK extension (Swift 6.4.0 on 26.08).
  Changes needed to build it for real: CMake 4 needs `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` for OpenAL 1.21.1, GCC 15
  needs `-Wno-template-body` for OpenAL and `-include cstdint` for glslang 14.3.0, the photon module passes
  `-Xcc -I/app/include -Xlinker -L/app/lib` (SwiftPM does not forward `CPATH` / `LIBRARY_PATH`) and builds with
  `--build-system native` (Swift 6.4's default swiftbuild engine leaves Synchronization and _FoundationCollections out of
  a `--static-swift-stdlib` link), and two portability fixes in LinuxCompat: `FcFreeTypeQuery` moved to
  `fontconfig/fcfreetype.h` in fontconfig 2.16, and FreeType 2.13.3 made `FT_Outline.tags` unsigned. H.264/HEVC: the
  `org.freedesktop.Platform.ffmpeg-full` extension no longer exists on 25.08 and later; its replacement,
  `org.freedesktop.Platform.codecs-extra`, is an extension of the runtime itself, installed with it and on
  `GST_PLUGIN_SYSTEM_PATH`, so the manifest needs nothing for it. Vulkan and GL drivers come from the runtime's
  `org.freedesktop.Platform.GL` extension point (GL.default is Mesa: on aarch64 radv, nvk, lavapipe, freedreno,
  panfrost, asahi and v3dv ICDs; NVIDIA users get the extension matching their driver), Vulkan layers from `org.freedesktop.Platform.VulkanLayer`.
  `PHOTON_GLSLANG` / `PHOTON_SPIRV_CROSS` point at `/app/bin` (finish-args). Permissions: Wayland and fallback X11,
  `--device=dri`, PulseAudio and the PipeWire socket, network (web pages by URL), read-only Steam folders (native,
  `~/.steam`, Steam's Flatpak), the StatusNotifierWatcher, the screensaver and MPRIS names, UPower and logind on the
  system bus, dconf for the GNOME still background, `io.github.photon2.Shell` for the GNOME extension (which a Flatpak
  cannot install; the user installs the zip). KWin's window list is not available to the Flatpak or the AppImage: KWin
  grants it by comparing the client's `/proc/<pid>/exe` with a `.desktop` entry's absolute `Exec`, and neither
  `/app/bin/photon-linux` in the sandbox nor a path inside the AppImage's mount can be named in one, so there the KDE
  rules have no window input. "Start at login" goes through the Background portal there.
  `in-container/flatpak-check.sh` runs the installed app under bubblewrap in a privileged container. On 2026-10-14,
  arm64 only (built first in a privileged fedora:40 container, then with `flatpak.sh` in the CI job's
  `flatpak-github-actions:gnome-51` image; the bundle is 48 MB): OpenAL and stb from `/app/lib`, `info` on the
  GL extension's lavapipe (Mesa with LLVM 22.1.8), the pause-rule self-test, `sound-check` passed (OpenAL Soft 1.21.1;
  its HRTF status names "Default HRTF", the data file the runtime installs, instead of the built-in copy, with the same
  coefficients), `gst-inspect-1.0 avdec_h264` finds libav's H.264 decoder, `video-frame` decoded the H.264 video
  wallpaper 3611879823 (1920×1080, 50.6 s), and the five CC0 scenes rendered. The x86_64 Flatpak has not been
  built locally (Swift and WebKit-sized dependencies under Rosetta); the CI job builds it on an x86_64 runner.
- **AppImage** (`scripts/linux/appimage.sh`, `in-container/appimage-build.sh`): built in the bookworm image from the
  Debian 12 binary, so it starts on glibc 2.36 and later. linuxdeploy with its GTK and GStreamer plugins bundles GTK 3,
  GDK-Pixbuf loaders, GStreamer and its plugins (base, good, libav), WebKitGTK and everything they link (about 320
  libraries; 165 MB on arm64, 174 MB on x86_64). By linuxdeploy's excludelist the host provides glibc, libstdc++, X11 and xcb, EGL / GL /
  GLES / gbm / drm, Wayland client, ALSA, PipeWire, FreeType, fontconfig, HarfBuzz, FriBidi and the Vulkan loader with
  its drivers. WebKitGTK starts `WebKitWebProcess` and `WebKitNetworkProcess` from the directory compiled into
  libwebkit2gtk, and outside developer builds there is no run-time override. The bundled library gets the same-length
  substitution `/usr` → `././` (as Tauri's AppImage bundler does), the helpers get RUNPATH `$ORIGIN/../..`, and an
  AppRun hook changes to `$APPDIR/usr` before photon starts. Relative path arguments to the CLI therefore resolve against
  `$APPDIR/usr`; the caller's directory is in `OWD`. The JACK GStreamer plugin is dropped (it only warned at every plugin
  scan). `in-container/appimage-test.sh` runs it in fresh ubuntu:24.04 and fedora:40 containers with only the host
  libraries above, a Vulkan driver, Xvfb and D-Bus installed. On 2026-10-14, arm64 and x86_64 (Rosetta), both distributions: `info`, the self-test, the
  five CC0 scenes and the `web` scene in the desktop host through the bundled WebKitGTK (page log equal to
  `Tests/scenes/web.log`); `video-frame` decoded 3611879823's H.264 through the bundled gst-libav. In a container with no
  `/dev/dri`, Fedora's PowerVR ICD fails `vkEnumeratePhysicalDevices` once the AppImage's libraries let it load and the
  loader then reports no device at all, so the test sets `VK_DRIVER_FILES` to lavapipe. Under an emulator (Rosetta,
  qemu-user) binfmt refuses AppImages because of the type-2 magic in bytes 8 to 10 of the ELF header; the build zeroes it
  in its copies of linuxdeploy and the test in its copy of photon's AppImage.

## 7. Testing and CI

The image `docker/linux/Dockerfile` (`photon2-linux:dev`) has the Swift 6.2 toolchain, Mesa lavapipe forced as the only
Vulkan driver (with `GALLIVM_PERF=no_aos_sampling`, below), glslang, SPIRV-Cross, the C libraries above (GStreamer with
plugins-base/good/libav, HarfBuzz, libstb), OpenAL Soft 1.21.1 built from source (§3.6), PipeWire with WirePlumber and
pipewire-pulse, the PulseAudio client library, GIO, python3-gi for the fake D-Bus services, the fonts listed in §6, Xvfb
and ImageMagick, and for phase 5 libwayland, wayland-protocols, sway, labwc and grim (headless Wayland compositors and
screenshots), WebKitGTK 4.1, gtk-layer-shell and gsettings, and for phase 6c KWin 5.27 (`kwin-wayland`, with its file
capability removed), plasma-wayland-protocols, GNOME Shell 46, wayland-info and zip.

Current results (the `ci.sh --mac --native-gs --x11 --audio` run of 2026-10-14, phase 4), 1280×720 at t = 2 s,
`PHOTON_SEED=1`, macOS `photon-tool render` on an Apple GPU against `photon-linux render` on lavapipe (mac and Linux
frames rendered back to back so clock text shows the same minute). The image now runs lavapipe with
`GALLIVM_PERF=no_aos_sampling` (below); the phase-3 column is the run before that change.

| Wallpaper | Features | Identical px | Mean abs diff | Phase 3 mean | Max | Px > 8 | Px > 32 |
|---|---|---|---|---|---|---|---|
| 2541606883 | image + puppet | 41.0% | 0.386 | 0.386 | 23 | 449 | 0 |
| 1355236618 | image + effects | 75.7% | 0.165 | 0.645 | 46 | 405 | 3 |
| 1442092399 | image + bloom | 99.1% | 0.003 | 0.151 | 1 | 0 | 0 |
| 1275921440 | effects + particles | 93.8% | 0.026 | 0.801 | 15 | 5 | 0 |
| 1975950854 | particles + script + clock text | 50.9% | 0.226 | 0.226 | 12 | 13 | 0 |
| 2122598327 | effects + script + text | 35.2% | 0.338 | 0.979 | 9 | 1 | 0 |
| 1425503532 | HDR + bloom + particles | 71.3% | 0.234 | 0.438 | 33 | 757 | 1 |
| 3463520581 | puppet + particles + effects | 25.5% | 0.425 | 0.772 | 27 | 164 | 0 |
| 3509243656 | 3D model, perspective, HDR, 49 text layers | 99.8% | 0.023 | 0.024 | 157 | 525 | 222 |
| 3047405322 | lights + particles + script + text | 69.0% | 0.143 | 1.112 | 79 | 441 | 49 |
| 2067939514 | 45 objects, scripts, text | 38.3% | 1.608 | 1.608 | 61 | 46,660 | 421 |
| 2927802976 | HDR + bloom + effects | 78.3% | 0.165 | 0.628 | 15 | 215 | 0 |
| 1315534440 | effects + particles + script + text | 91.3% | 0.056 | 0.791 | 45 | 455 | 6 |
| 3642408184 | video wallpaper, 3840×2160 60 fps H.264 | 23.6% | 0.709 | 0.709 | 23 | 11,042 | 0 |
| 3611879823 | video wallpaper, 1920×1080 29.97 fps + AAC | 41.5% | 0.410 | 0.413 | 32 | 3,967 | 0 |
| 2903412088 | video texture 3840×2160 25 fps + 2 text layers | 18.3% | 0.552 | 1.373 | 48 | 2,279 | 37 |
| 3147346398 | video texture 3840×2160 30 fps | 52.3% | 0.326 | 0.327 | 31 | 4,260 | 0 |
| 3288381550 | video texture 4090×2300 60 fps | 15.1% | 0.605 | 0.605 | 43 | 985 | 9 |
| 3351163962 | 34 text layers: CJK, kaomoji (Thai, Armenian), seconds | 84.9% | 0.225 | 0.385 | 95 | 4,648 | 918 |
| 2902406982 | 97 text layers: CJK, seconds, frames per second | 32.8% | 0.462 | 2.618 | 255 | 1,030 | 492 |
| gif-1444077782 | GIF wallpaper, 65 frames, 10 ms delays | 100% | 0 | 0 | 0 | 0 | 0 |
| gif-2504353624 | GIF wallpaper, 28 frames, restore-to-background | 100% | 0 | 0 | 0 | 0 | 0 |

Where the differences come from:

- **llvmpipe's 8-bit sampler (fixed).** 2902406982 rendered 2.4 to 3.0 levels darker everywhere on Linux. Isolating its
  objects: the background image alone was within 0.3 levels; adding the compose layer 530 (`effects/blur`: 4-tap
  downsample, two 13-tap Gaussians, combine) took the mean down by 1.9 levels on Linux and by 0.04 on macOS. A uniform
  colour through the same blur came out identical on both, and with the Gaussian scale set to 0 (all taps on one
  coordinate) the image still lost 1.1 levels: the loss came from bilinear filtering of textured content, not from the
  shaders or from the render-target writes. llvmpipe samples 8-bit textures through its AoS fixed-point path, whose lerp
  rounds down; each filtered pass of a textured image loses about half a level. `GALLIVM_PERF=no_aos_sampling` (the
  float SoA sampler) removes it: 2902406982's blur layer then matches macOS within 0.03 levels, and the whole scene goes
  from mean 2.618 to 0.462. Every effect-heavy scene had the same bias (1275921440 0.801 → 0.026, 3047405322 1.112 →
  0.143, 1315534440 0.791 → 0.056). It is a property of the test driver, not of the port, so the fix is the image's
  `ENV`; frame rates change by less than 2% (1275921440 11.07 against 11.28 fps, 2902406982 3.58 against 3.64). Users on
  lavapipe get the same by setting the variable. 2902406982's remaining 492 pixels over 32 are its clock and FPS text.
- **Texture filtering in lavapipe.** llvmpipe's anisotropic filtering and LOD computation are not Apple's. The plain
  image wallpaper 2541606883 shows it alone: no effects, mean 0.39, with a channel bias (R +0.13, G −0.10, B +0.17)
  that the sampler setting does not change, so it comes from BC1 decoding. 2067939514's 46,660 pixels over 8 sit on a
  3840-wide photo minified to 1280; at 1920×1080 (no minification) the same scene has mean 0.30 and 1,619 pixels over 8.
  The earlier prototype rendered 2541606883 through MoltenVK (Vulkan on the Apple GPU) with zero differing pixels, which
  points at the sampler hardware, not at the Vulkan backend's state mapping.
- **Fonts.** 3509243656's remaining 222 pixels over 32 are its `systemfont_arial` text: Arial on macOS, Arimo in the
  container (same glyph ids, advances and metrics, §3.3; different outlines), plus FreeType-vs-CoreText anti-aliasing.
- **Video.** Y'CbCr conversion differs by 0.3 to 1.0 levels on average from VideoToolbox (§3.5); on top of that the
  4K videos are minified to 1280×720 through lavapipe's filtering, which makes 3642408184's 11,042 pixels over 8.
- **Time-dependent text.** 3351163962 and 2902406982 show seconds, a measured frame rate and (3351163962) a kaomoji
  picked at random; two macOS renders of either differ by 709 to 1,210 pixels over 32, so their limits include that.
- **MSAA.** 3509243656 renders with 1 sample on lavapipe (no 2× support) against 2 on macOS; rendering macOS with
  `PHOTON_MSAA=none` gives 207 pixels over 32 instead of 221.

Frame rates on lavapipe, 1280×720, release build, Docker Desktop VM with 10 CPUs (the Mac was in use, so ±5% is
noise). Host: `photon-linux desktop <id> --fps 1000 --seconds 30` under Xvfb, frames per second after the first frame
(which loads the scene). Before: readback + `XShmPutImage`, command buffers waited at commit. After: Vulkan swapchain
(FIFO), asynchronous command buffers with at most two frames in flight, hazard-tracked barriers; "readback" is the
fallback path of the new build. Headless: `photon-linux bench <id> 60`, before every frame waited, after up to two in
flight.

| Wallpaper | Host before | Host after (swapchain) | Ratio | Host after (readback) | Headless before (sync) | Headless after (async) | Ratio |
|---|---|---|---|---|---|---|---|
| 2541606883 | 128.1 | 133.8 | 1.04× | 130.1 | 151.8 | 156.5 | 1.03× |
| 1355236618 | 45.3 | 45.7 | 1.01× | 45.7 | 50.2 | 47.7 | 0.95× |
| 1442092399 | 180.4 | 188.3 | 1.04× | 186.3 | 225.9 | 238.7 | 1.06× |
| 1275921440 | 11.5 | 11.4 | 0.99× | 11.4 | 11.8 | 11.5 | 0.97× |
| 1975950854 | 101.7 | 105.1 | 1.03× | 104.9 | 118.2 | 124.5 | 1.05× |
| 2122598327 | 14.0 | 14.1 | 1.01× | 14.1 | 14.6 | 13.9 | 0.96× |
| 1425503532 | 80.3 | 82.8 | 1.03× | 81.4 | 92.0 | 98.0 | 1.07× |
| 3463520581 | 3.1 | 3.2 | 1.01× | 3.2 | 3.1 | 3.2 | 1.03× |
| 3509243656 | killed (OOM) | 9.4 | | 9.2 | crash | 13.7 | |
| 3047405322 | 19.0 | 19.2 | 1.01× | 19.4 | 22.2 | 24.2 | 1.09× |
| 2067939514 | 7.5 | 7.9 | 1.05× | 7.9 | 7.6 | 7.8 | 1.03× |
| 2927802976 | 11.1 | 11.7 | 1.05× | 11.5 | 11.1 | 11.8 | 1.06× |
| 1315534440 | 2.0 | 2.0 | 1.02× | 2.0 | 2.0 | 2.1 | 1.01× |

What this shows: lavapipe is the bottleneck, so the new submission path changes little on it (−5% to +9%, mostly
noise). `bench` splits a frame into encoding (scene update, scripts, particles and command recording: 0.4 to 9 ms on
these scenes), commit (0 ms) and waiting for the GPU (40 to 490 ms): llvmpipe rasterising and sampling. Capping
anisotropy at 1 (`PHOTON_VK_MAX_ANISOTROPY=1`, which changes the image) takes 1275921440 from 11.7 to 24.7 fps and
3463520581 from 3.2 to 4.8, so trilinear + 8× anisotropic sampling in llvmpipe is most of that time. On lavapipe
`MESA_VK_ENABLE_SUBMIT_THREAD=1` changes nothing (commit already returns at once). The asynchronous path and the
swapchain matter on a real GPU, where the CPU encoding the next frame and the readback copy were serialised with the
GPU before; that is measurable only outside this VM. 3509243656 could not run in the old host at all (font copies,
§3.3).

### CI

`scripts/linux/ci.sh` (§8) is the gate; it needs Docker and the local Steam folders, because the workshop corpus and
the engine assets cannot be redistributed.

1. `docker build docker/linux` when the image is missing; `swift build -c release --product photon-linux` in it.
2. Checks without the corpus: `photon-linux info`, `desktop --self-test` (60 rule checks: 9 Wayland, 12 KWin and GNOME).
3. Text shaping against CoreText (`text-check.sh`, §3.3): 14 cases must give CoreText's output exactly; `--mac`
   regenerates the reference with `photon-tool text-shape`, otherwise the committed `text-coretext.txt` is used.
4. The 22-wallpaper set (`scripts/linux/wallpapers.txt`: 13 scenes, 2 video wallpapers, 3 scenes with video textures,
   2 text-heavy scenes, 2 GIF wallpapers made from corpus preview.gif files) rendered at 1280×720, t = 2 s,
   `PHOTON_SEED=1`; with `--mac` each macOS reference is rendered with `photon-tool` right before its Linux frame.
5. `pixeldiff.py` against the references with the committed per-wallpaper limits in `scripts/linux/thresholds.tsv`
   (measured mean × 1.25 + 0.05, pixels over 32 × 1.5 + 20). `--linux-refs DIR` adds exact equality with earlier
   lavapipe renders (lavapipe is deterministic on one Mesa version).
6. `--native-gs`: native geometry shaders must equal the pass-through check byte for byte (§2.2.2). A scene whose two
   pass-through renders already differ (3351163962, 2902406982: clock seconds) is reported, not gated.
7. `--x11`: under Xvfb, PhotonProto through the host equals its headless render; the full renderer through the Vulkan
   swapchain and through readback (`--still`) both equal the headless render of the same frame. Then
   `in-container/host-features.sh` (§5.4): the 27 transition effects against `photon-tool transition` (references in
   `$PHOTON_LX_OUT/tr-mac`, regenerated by `--mac`), switches inside a host, stretch and clone, a clone group, a nested
   split with a host per region, the cursor, application rules, the audio-playing rule, `pausevram`, video loops.

8. `--audio` (`in-container/audio-check.sh`, §3.6, §5.1): `sound-check` (OpenAL Soft against photon2's voice model and,
   when `$PHOTON_LX_OUT/soundref-mac` exists or `--mac` regenerates it with `photon-tool sound-ref`, against macOS;
   limit 1e-5 on every mix, speaker and HRTF, pause and resume included); spectrum capture of a test tone through
   PipeWire and through the PulseAudio API (peak bands must equal the analyzer's mapping ±1); sound objects in the host
   through OpenAL's wave writer (level, pitch, side, silenced by a fullscreen client and resumed) and through PipeWire
   into the spectrum capture; MPRIS events from a fake player; UPower / logind / screensaver signals from fake services,
   in `system-check` and in the host's rule log. PipeWire, WirePlumber, pipewire-pulse and two dbus-daemons run inside
   the container for it.
9. `--wayland` (`in-container/wayland-smoke.sh`, §5.2): sway and labwc headless; swapchain and `wl_shm` frames, scale
   1.5 and a hotplugged output must equal the headless render byte for byte (grim); fullscreen (sway) and maximized
   (labwc) test clients must pause and resume the output; `--static-background` must set the gsettings keys; stretch
   across two outputs byte for byte, clone with a flipped output, a clone group, a nested split (three region hosts, each
   region byte for byte), the cursor through wlr-virtual-pointer, a fade inside the host, an application rule by app_id
   (§5.4).
10. `--web` (`in-container/web-check.sh`, §5.3): the API test page on Xvfb and under sway (layer-shell), with a PipeWire
   tone, a fake MPRIS player and fullscreen clients; 18 checks of what the page receives, its host-independent lines
   against the macOS host's (`$PHOTON_LX_OUT/web-mac`, regenerated by `--mac` through `web-mac-ref.sh`), filter colours
   within 3 levels of macOS, and the install's two web wallpapers (mounted from the CrossOver install's
   `projects/defaultprojects`, with `distribution/bin/webwallpaper64.exe` for the injected runtime).
11. `--kde` (`in-container/kde-check.sh`, §5.2): KWin 5.27 with two virtual outputs; frames equal to the headless
   render through ScreenShot2, a split output (two region hosts, each half byte for byte), the protocol withheld
   without `photon2-kwin.desktop`, fullscreen, maximized, virtual desktops and an app_id rule from
   `org_kde_plasma_window_management`. CC0 scene, no corpus.
12. `--gnome` (`gnome-extension.sh`, `in-container/gnome-check.sh`, §5.2): GNOME Shell 46 headless with the packed
   extension; screenshots equal to the headless render, a split monitor (two region windows placed by the extension,
   each half byte for byte), animation, fullscreen and maximized pauses per monitor, an app_id rule, desktop clicks, the
   overview, the host stopping when the extension is disabled. CC0 scene, no corpus.
   `ci-hosted.sh` runs both as well.

Session 10 run (2026-10-14, after the split regions and the clone-group / split GTK controls, arm64):
`ci.sh --mac --native-gs --x11 --audio --wayland --web --kde --gnome` passed every step, with the new split checks
(host-features 3c, wayland-smoke 7c, kde-check 2b, gnome-check 2b: every region equal to its headless render, max diff
0). `package.sh --distro all`: the Ubuntu 24.04 `.deb` passes everything including the gated render comparison; the
Fedora 40 `.rpm` and Debian 12 `.deb` pass every check, their renders reported only (own Mesa; the two byte-identical,
as before). `appimage.sh`: runs in ubuntu:24.04 and fedora:40. `app-check.sh` CC0 and `--corpus` (§6.1) pass.
macOS: `swift build`, `swift build -c release`, `swift test` (96 tests, 18 skipped without `PHOTON_TEST_INTEGRATION`).

Phase 5 run (2026-10-14, `ci.sh --x11 --audio --wayland --web` against the phase-4 macOS references): self-tests,
text shaping, X11, Wayland (`wayland smoke test passed`) and web (`web checks passed`) passed. Two steps failed for
reasons outside this phase: the pixel diff of 1975950854, 3047405322, 2903412088 and 3147346398 against references
rendered an hour earlier (clock minutes; the first macOS run of a video-texture scene after a build), which pass with
paired references from the phase-5 photon-tool (means 0.226, 0.143, 0.552, 0.326, the phase-4 values); and
`sound-check`, which now reads `main.*.f32` while `$PHOTON_LX_OUT/soundref-mac` holds the phase-4 `speaker.f32` /
`hrtf.f32` (the sound reference is being changed by the macOS audio work; `--mac` regenerates it).
macOS stayed byte-identical: `photon-tool render` of 7 wallpapers (2541606883, 1355236618, 1442092399, 1275921440,
1425503532, 3642408184, 2903412088) gives the same PNGs with builds from before and after phase 5 (2903412088 compared
on repeated renders, as above); `swift build` and `swift test` pass (81 XCTest tests, 16 skipped without `PHOTON_TEST_INTEGRATION`). The synthetic web page renders the
same PNG; its log differs in one line, `wpPlugins` being empty at script time now that the plugin objects arrive with
`onPluginLoaded` (§5.3).

Phase 4 run (2026-10-14, `ci.sh --mac --native-gs --x11 --audio`): every step passed; the diff table at the top of this
section is that run's `diff-mac.md`, and `thresholds.tsv` was reset from it with the same rule. macOS stayed
byte-identical: `photon-tool render` of 8 wallpapers (2541606883, 1355236618, 1442092399, 1275921440, 1425503532,
3642408184, 2903412088, 3147346398) gives the same PNGs with the phase-3 and the phase-4 builds (the two video-texture
scenes render differently on the very first run after a build, with either build, and identically on every later
run); `swift build` and `swift test` pass (77 XCTest tests, 16 skipped without `PHOTON_TEST_INTEGRATION`).

### Hosted CI and the CC0 test scenes

`.github/workflows/ci.yml` needs no Steam corpus, no Wallpaper Engine install and no secret (the only token is the
default read-only `GITHUB_TOKEN`, `permissions: contents: read`; the buildx `gha` cache uses the runner's own cache
token). Every Linux job runs on `ubuntu-24.04` (x86_64) and `ubuntu-24.04-arm` (aarch64):

- `macos` (macos-15): Homebrew glslang and spirv-cross, `swift build`, `swift build -c release`, `swift test`, then
  `photon-tool render` of the five scene projects against `Tests/scenes/refs-mac` (reported, not gating: hosted Macs
  have a paravirtual GPU).
- `linux`: the image with the buildx layer cache (scope per architecture), the SPIR-V cache, then `package.sh
  --no-test` (static binary, `.deb`, `.rpm`, tarball), `ci-hosted.sh --no-build` against that same static binary
  (`PHOTON_LX_BUILD=…/lx-build/static`, so Swift compiles once per job): `photon-linux info`, `desktop --self-test`,
  text shaping against the committed CoreText output (the system-font cases of `text-cases.txt` and four NotoMono cases
  of `Tests/scenes/text-cases.txt`), `scenes-check.sh` and the app check (§6.1); then `package.sh --test-only` (fresh
  ubuntu:24.04 and fedora:40). Renders, app screenshots, install-test output and the packages are artifacts named
  per architecture.
- `debian12`: `docker/linux/Dockerfile.bookworm` with its own cache scope, `package.sh --distro debian12` (build and
  debian:12 install test on Debian's own Mesa 22.3), then `appimage.sh` (build and the ubuntu:24.04 / fedora:40 runs).
  The packaging steps take their version from `photon_version` (the checkout has no tags, so `PHOTON_VERSION_BASE`).
- `flatpak`: `flatpak/flatpak-github-actions/flatpak-builder@v6` in `ghcr.io/flathub-infra/flatpak-github-actions:gnome-51`
  (privileged), then `flatpak-check.sh` on the installed bundle. Gating.

The workflow passes actionlint 1.7.12 (with its shellcheck pass over the `run:` blocks); the new shell scripts pass
shellcheck apart from informational notes. It has not run on GitHub yet: locally the steps ran as scripts, arm64
natively and x86_64 under Rosetta (Docker Desktop's amd64 emulation), with the results in §6.2.

`scenes-check.sh` compares against `Tests/scenes/refs/<arch>/` (`uname -m` in the container). Each directory holds
`driver.txt`, the `mesa-vulkan-drivers` version and lavapipe device line the references were rendered with. When the
container's driver line is the same, the five rendered scenes must be byte-identical (`pixeldiff.py --exact`); when
Ubuntu has moved Mesa on, the script says which build the references came from and checks the limits only.
`--update` writes the renders and `driver.txt` for the container's architecture and recompresses the PNGs (photon-linux
writes them with little compression; the pixels are unchanged). The x86_64 and aarch64 references (Mesa
25.2.8-0ubuntu0.24.04.4, LLVM 20.1.2; lavapipe uses 256-bit vectors on x86_64, 128-bit on aarch64) are pixel-identical
for `images`, `particles`, `text`, `perspective` and `web`; in `effects` 0.7% of the pixels differ by 1. Both
architectures reproduce their own references byte for byte (2026-10-14).

`Tests/scenes/` (CC0; the one font is OFL; on a case-insensitive file system `tests/` and `Tests/` are one directory,
so the scenes live next to `Tests/photonTests`, which SwiftPM ignores):

| Scene | Exercises |
|---|---|
| `images` | five image layers: translucent blending, per-object alpha, scale, rotation; unbound user properties of every type for the app check |
| `effects` | custom effect passes (time-driven sine displacement, luminance tint), two chained on one layer, `constantshadervalues` |
| `particles` | box and sphere emitters, random initializers, gravity, drag, fades, size change, `PHOTON_SEED=1` |
| `text` | multi-line text in NotoMono (committed), alignment, kerning, colour, opaque background with padding, rotation |
| `perspective` | perspective camera, two generated MDL meshes (cube, torus), lit shader, depth test, back-face culling, MSAA |
| `web` | web wallpaper: gradient and canvas bars driven by color / slider / textinput properties; page log checked |

`Tests/scenes/assets/` stands in for the engine's assets folder: shaders written from scratch in the engine's dialect
(`cc0_image`, `cc0_particle`, `cc0_font`, `cc0_solid`, `cc0_model`) and the materials the renderer loads by fixed path
(`materials/util/effectpassthrough.json`, `materials/fonts/basefont*.json`, `fontbackground.json`). `tools/make_tex.py`
and `tools/make_mdl.py` regenerate every `.tex` and `.mdl` byte for byte. References are 640×360 at t = 2: Linux renders
on lavapipe (`refs/aarch64`, `refs/x86_64`, byte-identical between runs) and macOS `photon-tool` renders (`refs-mac/`). Metal against lavapipe
on 2026-10-14:

| Scene | Identical px | Mean abs diff | Max | Px > 8 | Px > 32 |
|---|---|---|---|---|---|
| images | 95.0% | 0.045 | 14 | 265 | 0 |
| effects | 93.8% | 0.024 | 2 | 0 | 0 |
| particles | 85.2% | 0.059 | 3 | 0 | 0 |
| text | 84.1% | 0.118 | 34 | 564 | 1 |
| perspective | 97.2% | 0.120 | 91 | 944 | 197 |

`perspective`'s outliers are edges: 2× MSAA on Metal, 1 sample on lavapipe. The limits are mean × 1.25 + 0.05 and pixels
over 32 × 1.5 + 20, as in `thresholds.tsv`. Two shaping differences were found and kept out of
the test cases: in NotoMono CoreText keeps "Привет Ελληνικά" as one run where the Linux build splits it by script, and
the mark in "ŝ́" sits at y 4.2396 on CoreText against 3.7852 on Linux.

## 8. Commands

Everything runs through `scripts/linux/` from the repository root on the host (macOS with Docker Desktop, or Linux).
`scripts/linux/env.sh` holds the paths; override them in the environment: `PHOTON_WS` (workshop `content/431960`),
`PHOTON_WE` (Wallpaper Engine `assets`), `PHOTON_LX_BUILD` (SwiftPM scratch, default `/tmp/photon2-lx`),
`PHOTON_LX_OUT` (outputs, default `/tmp/photon2-lx-out`), `PHOTON_LX_CACHE` (SPIR-V cache), `PHOTON_LX_IMAGE`,
`PHOTON_LX_PLATFORM` (`docker --platform`, e.g. `linux/amd64`), `PHOTON_LX_SRC` (the tree mounted at `/src`; a copy keeps
a long build stable while the working tree changes), `PHOTON_LX_BOOKWORM_IMAGE` (Debian 12 build image).

```sh
# image (once; about 6 GB)
docker build -t photon2-linux:dev docker/linux

# build photon-linux in the container (release by default; binary in $PHOTON_LX_BUILD/release)
scripts/linux/build.sh [debug|release]

# CI: image, build, self-tests, text shaping against CoreText, the 22-wallpaper set rendered on lavapipe and compared with macOS references
# against scripts/linux/thresholds.tsv; --mac renders the references with photon-tool (pairs, same minute),
# --native-gs checks native geometry shaders, --x11 runs the desktop-host smoke test under Xvfb, --audio the audio and
# system checks (§3.6, §5.1)
scripts/linux/ci.sh --mac --native-gs --x11 --audio --wayland --web

# render the set (→ $PHOTON_LX_OUT/renders/lx_<id>.png); with macOS references rendered alongside
scripts/linux/render-set.sh release
PHOTON_TOOL=/path/to/photon-tool scripts/linux/render-set.sh release --mac /tmp/photon2-lx-out/mac

# diff table against references (runs in the container: numpy + PIL)
. scripts/linux/env.sh; PHOTON_LX_DOCKER_ARGS="-v /tmp/photon2-lx-out/mac:/refs:ro" \
  lx "python3 /scripts/pixeldiff.py /refs /out/renders --thresholds /scripts/thresholds.tsv"

# text shaping against CoreText (text-cases.txt vs the committed text-coretext.txt; --mac regenerates it with photon-tool)
scripts/linux/text-check.sh [release] [--mac]

# media and text checks in the container (compare with AVAssetReader / ImageIO / photon-tool text-shape on macOS)
lx "/build/release/photon-linux video-frame /out/clip.mp4 2 /out/frame.png"   # frame shown at t = 2, size, duration
lx "/build/release/photon-linux gif-frames /out/anim.gif /out/frame"           # size, delays; /out/frame_<n>.png
lx "/build/release/photon-linux text-shape ArialMT 28 'AVATAR fi'"              # CTLine runs, glyphs, advances
swift run -c release photon-tool text-shape ArialMT 28 'AVATAR fi'             # the same line through CoreText

# a video wallpaper in the X11 host with its sound (fakesink in the container), at 150 % rate
lx "Xvfb :99 -screen 0 1280x720x24 & sleep 1; DISPLAY=:99 PHOTON_AUDIO_SINK=fakesink PHOTON_VIDEO_AUDIO_LOG=1 \
    /build/release/photon-linux desktop 3611879823 --seconds 8 --rate 150"

# audio and system integration (§3.6, §5.1)
PHOTON_TOOL=/tmp/photon2-mac/release/photon-tool; DLL="$(dirname "$PHOTON_WE")/distribution/bin/mediaextensions64.dll"
$PHOTON_TOOL sound-ref "$DLL" /tmp/photon2-lx-out/soundref-mac                # macOS voice output for the test scene (nothing plays)
lx "/build/release/photon-linux sound-check /out/soundref-mac --out /out/sound"  # OpenAL Soft loopback vs photon2 / macOS
lx "/build/release/photon-linux hrtf-ir 2 0 0"                                 # OpenAL's HRTF impulse response next to photon2's filter
lx "/scripts/in-container/audio-check.sh /build/release/photon-linux /out/soundref-mac"   # everything below, with services
#   photon-linux spectrum-check <seconds> <left Hz> <right Hz>   (needs PipeWire or PulseAudio; PHOTON_AUDIO_BACKEND=pipewire|pulse)
#   photon-linux media-check <seconds>                          (ScriptMedia events from MPRIS, JSON lines)
#   photon-linux system-check <seconds>                         (UPower / logind / screensaver state as it changes)
#   ALSOFT_CONF=wave.conf photon-linux desktop <dir> --volume 100   (OpenAL's wave writer: [general] drivers = wave, [wave] file = …)

# Wayland host under a headless compositor (§5.2): sway with the headless backend, the host, a grim screenshot
lx 'export XDG_RUNTIME_DIR=/tmp/xdg WLR_BACKENDS=headless WLR_RENDERER=pixman; mkdir -m 700 $XDG_RUNTIME_DIR
    printf "output HEADLESS-1 resolution 1920x1080 scale 1.5\n" > /tmp/sway.conf; sway -c /tmp/sway.conf & sleep 2
    export WAYLAND_DISPLAY=wayland-1; /build/release/photon-linux desktop 2541606883 --seconds 5 --hold 3 & sleep 6
    grim /out/wayland.png'
lx "/scripts/in-container/wayland-smoke.sh /build/release/photon-linux"          # all Wayland checks
# KDE Plasma and GNOME (§5.2): KWin 5.27 and GNOME Shell 46 headless; the CC0 scene by default (or a wallpaper id)
lx "dbus-run-session -- sh /scripts/in-container/kde-check.sh /build/release/photon-linux"
scripts/linux/gnome-extension.sh                                                # → $PHOTON_LX_OUT/pkg/photon2@photon2.github.io.shell-extension.zip
lx "dbus-run-session -- sh /scripts/in-container/gnome-check.sh /build/release/photon-linux /out/pkg/photon2@photon2.github.io.shell-extension.zip"
#   photon-linux desktop <id> --backend gnome (needs the extension) | --wl-test-client fullscreen --output NAME
#   gnome-extensions install --force photon2@photon2.github.io.shell-extension.zip; gnome-extensions enable photon2@photon2.github.io
#   photon-linux desktop <id> --backend wayland|x11 | --static-background 1920x1080 (GNOME still) | --wl-test-client fullscreen

# web wallpapers (§5.3): WebKitGTK in desktop-type windows under Xvfb (layer-shell under Wayland), page console on stdout
lx "Xvfb :99 -screen 0 1280x720x24 & sleep 1; DISPLAY=:99 WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 PHOTON_WEBDEBUG=1 \
    /build/release/photon-linux desktop /we/projects/defaultprojects/corsair_o_tron --seconds 8 --dump-text"
#   options: --general '{"wec_e":true,"wec_hue":75}' --property name=value --eval 'js' --fullscreen pause …
scripts/linux/web-mac-ref.sh $PHOTON_TOOL /tmp/photon2-lx-out/web-mac          # the macOS host's output for the API page
lx "/scripts/in-container/web-check.sh /build/release/photon-linux /out/web-mac"   # all web checks
scripts/linux/gen-wayland-protocols.sh                                          # regenerate Sources/CPhotonWayland/protocols

# phase 6b (§5.4): host features under Xvfb; one transition frame; switches by hand through --control
lx "/scripts/in-container/host-features.sh /build/release/photon-linux /out/tr-mac"
PHOTON_TRANSITION_SEED=7 $PHOTON_TOOL transition color:220,60,40 color:30,60,200 23 0.5 mac.png 320 180   # macOS
lx "PHOTON_TRANSITION_SEED=7 /build/release/photon-linux transition color:220,60,40 color:30,60,200 23 0.5 /out/lx.png 320 180"
#   desktop <dir> --control, then on stdin: load {"dir": "/path/to/other", "transition": {"transition": "0", "transitiontime": 1500}}
#                                           snapshot /tmp/frames        (then: desktop <dir> --switch-snapshot /tmp/frames --transition '{…}')
#   desktop <dir> --layout stretch|clone [--clone-source NAME] [--clone-flip NAME,…] | --app-rules '[{"id":"…","application":"sleep","condition":0,"action":2}]'
#   desktop <dir> --region NAME=X,Y,W,H [--no-sound]      (a split region of output NAME, logical units from its corner)
#           | --pause-vram | --audio pause
#   desktop --pointer-test move 320 180 click 640 360 | --wl-pointer-test 1280 720 click 640 360 | --test-client … --class NAME
#   | --wl-test-client fullscreen --app-id ID

# the app (§6.1): under Xvfb and headless sway, self-test + tray over D-Bus; screenshots in $PHOTON_LX_OUT/app/{x11,wayland}
lx "/scripts/in-container/app-check.sh /build/release/photon-linux /out/app"              # CC0 test scenes
lx "/scripts/in-container/app-check.sh /build/release/photon-linux /out/app-corpus --corpus"   # workshop corpus
#   only the display-layout passes (clone group, splits on two outputs): PHOTON_LX_DOCKER_ARGS="-e PHOTON_APPCHECK_STEPS=layout"
#   (sh/bash: the variable reaches lx; or export it) — "basic" runs the rest; screenshots in /out/app/{x11,wayland}-layout
#   PHOTON_X11_MONITORS=NAME=WxH+X+Y,… replaces XRandR's monitors for the app and its hosts (Xvfb has one)
#   photon-linux app [--background] [--no-hosts] [--self-test DIR]; PHOTON_LIBRARY=dir:dir adds library folders
#   photon-linux desktop --list-outputs | desktop <dir> --control --output NAME,… --properties JSON --general JSON
# packages (§6.2): .deb / .rpm / tarball (Ubuntu 24.04 image), Debian 12 .deb (bookworm image), each installed and run in
# fresh ubuntu:24.04 / fedora:40 / debian:12 containers; --no-test builds only, --test-only re-runs the install tests
# version: default env.sh photon_version (git describe, else PHOTON_VERSION_BASE); --backports adds a Debian 12 run on
# bookworm-backports' Mesa (the default run uses Debian 12's own Mesa 22.3)
scripts/linux/package.sh [version] [--distro ubuntu24.04|debian12|all] [--no-test|--test-only] [--backports]
docker build -t photon2-linux:bookworm -f docker/linux/Dockerfile.bookworm docker/linux   # (package.sh does it when missing)
scripts/linux/appimage.sh [version] [--no-test]  # after package.sh --distro debian12 (same version); runs it in ubuntu:24.04 and fedora:40
scripts/linux/flatpak.sh [--no-check]            # flatpak-builder in a privileged container, bundle + headless checks
# x86_64 on an arm64 Mac (Rosetta): its own image tag and scratch directories
docker build --platform linux/amd64 -t photon2-linux:dev-amd64 docker/linux
PHOTON_LX_PLATFORM=linux/amd64 PHOTON_LX_IMAGE=photon2-linux:dev-amd64 PHOTON_LX_BOOKWORM_IMAGE=photon2-linux:bookworm-amd64 \
  PHOTON_LX_BUILD=/tmp/photon2-pkg-amd64 PHOTON_LX_OUT=/tmp/photon2-lx-out-amd64 scripts/linux/package.sh
photon-linux --version                           # photon-tool --version, photon --version on macOS
scripts/linux/scenes-check.sh [--mac $PHOTON_TOOL] [--update]  # CC0 scenes vs Tests/scenes/refs/<arch> (and refs-mac)
scripts/linux/ci-hosted.sh [release] [--no-build]              # what the hosted Linux job runs

# two builds must render byte-identical PNGs (e.g. before/after a backend change); PHOTON_COMPARE_ENV applies to the new one
scripts/linux/compare-builds.sh /path/to/other/scratch-dir release [id…]

# frames per second: headless async/sync/readback, desktop host with swapchain and with readback
scripts/linux/bench.sh release async sync readback host host-readback
python3 scripts/linux/benchtable.py before.txt after.txt

# one wallpaper by hand
. scripts/linux/env.sh
lx "/build/release/photon-linux render 2541606883 /out/linux.png 2 1280 720"
lx "Xvfb :99 -screen 0 1280x720x24 & sleep 1; DISPLAY=:99 /build/release/photon-linux desktop 2541606883 --seconds 5 --screenshot /out/desk.png"

# the same frame on macOS
PHOTON_SEED=1 swift run -c release photon-tool render 2541606883 out/mac.png 2 1280 720
```

Diagnostics: `PHOTON_POINTER_LOG=1` (cursor positions and desktop presses), `PHOTON_AUDIO_STREAMS_LOG=1` (the audio
streams the rule sees), `PHOTON_VRAM_TEST=file` (fake "used budget" MB for `pausevram`), `PHOTON_TRANSITION_SEED=n`,
`PHOTON_SINGLE_INSTANCE=0` (§5.4); `PHOTON_VK_STATS=1` prints each submission's barrier count; `PHOTON_NATIVE_GS=1|passthrough` (§2.2.2);
`PHOTON_VK_MAX_ANISOTROPY=n` caps sampler anisotropy (changes output; lavapipe's most expensive sampling path);
`PHOTON_VK_WSI=0` leaves the WSI extensions off; `PHOTON_VK_WRITE_ALL_SAMPLERS=1|0` forces the lavapipe < 23.2
sampler-descriptor workaround on or off (§2.2); `PHOTON_VIDEO_MATRIX=601|709` forces the Y'CbCr matrix of every video;
`PHOTON_AUDIO_SINK=<element>` and `PHOTON_VIDEO_AUDIO_LOG=1` (video wallpaper sound, §5); `PHOTON_HRTF=1|0` (OpenAL
context attribute), `PHOTON_AUDIO_BACKEND=pipewire|pulse` (spectrum capture), `ALSOFT_CONF`/`ALSOFT_DRIVERS` (OpenAL
Soft's own), `GALLIVM_PERF` (lavapipe sampler, §7), `PHOTON_WEBDEBUG=1` (page console and errors on stdout),
`PHOTON_WEBPLUGINS=0` (no LED plugin), `GDK_BACKEND` (the web host's GTK backend),
`WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1` (needed in the container, where bubblewrap cannot create namespaces). Test ids `gif-<id>` in
wallpapers.txt are GIF wallpapers built from item `<id>`'s preview.gif under `$PHOTON_LX_OUT/gifwp` (`env.sh`
`prepare_gifs`); every script maps them to that directory.

## 9. Plan

Effort is for one developer who knows the codebase.

| Phase | Work | Effort |
|---|---|---|
| 1 (done) | PhotonGPU, Vulkan backend, Metal facade, LinuxCompat modules, full renderer on lavapipe, X11 host, this document | done |
| 2 (done) | Vulkan swapchain presentation on X11 (`VK_KHR_xlib_surface`, readback fallback); asynchronous command buffers with recycled per-submission contexts and two frames in flight; hazard-tracked barriers; native geometry shaders as an option, verified against a pass-through check; font-memory fix; `bench`; `scripts/linux` with `ci.sh` and committed thresholds (§2.2.1, §2.2.2, §7). Left over: the Wayland surface comes with phase 5; timing on a real GPU (radv/anv/NVIDIA) to confirm the overlap the VM cannot show | done |
| 3 (done) | GStreamer decoder behind `VideoTexture` (video textures, video wallpapers) with Y'CbCr conversion matched to VideoToolbox, video wallpaper sound in the X11 host with `--rate`/`--volume`, GIF via stb_image, HarfBuzz shaping with CoreText's run, bidi and advance rules, hhea and CFF line metrics, metric-compatible font substitution, `text-check.sh`, 9 more test wallpapers (§3.3, §3.5, §7). Left over: hardware video decoders (VA-API/NVDEC caps), full bidi weak types, a WebM wallpaper (the corpus has none) | done |
| 4 (done) | OpenAL Soft 1.21.1 sound objects with the engine's source setup, checked against the macOS voice model (equal to 4.2e-7 on every mix after the §3.6 macOS fixes); spectrum capture through PipeWire and PulseAudio; MPRIS media events for SceneScript; the macOS playback evaluator in the X11 host with UPower, logind, screensaver and DPMS inputs, pause and mute fades; lavapipe's AoS sampler bias found and removed from the test image (2902406982 mean 2.62 → 0.46); `ci.sh --audio` with fake D-Bus services (§3.6, §5, §5.1, §7). Left over: the audio-playing and app rules (PipeWire stream and process lists), media for web pages (phase 5), a run on real hardware (headphone HRTF detection through a real PulseAudio/PipeWire sink, a real logind session) | done |
| 5 (done) | Wayland host: layer-shell surfaces per output, Vulkan `VK_KHR_wayland_surface` and `wl_shm` presentation, hotplug, fractional scale through viewporter, pause rules from wlr-foreign-toplevel, the GNOME still-background fallback; web wallpapers on WebKitGTK 4.1 in layer-shell or DESKTOP-type windows with the macOS page API (shared `WebPageScripts`), PipeWire audio frames, MPRIS media, plugin stubs, CSS filter and flip; the LED plugin timing fix for both hosts; `ci.sh --wayland --web` (§5.2, §5.3). Left over: KDE's window-management protocol for the rules there, a GNOME Shell extension for animated wallpapers, input (mouse parallax and clicks) on both Linux hosts, a real-GPU Wayland run (dmabuf WSI), the audio-playing and app rules | done |
| 6 (done) | `PhotonApp` shared by both apps (macOS unchanged: 81 tests, integration included); `photon-linux app` in GTK 3 with the StatusNotifierItem + dbusmenu status icon, browser, properties with conditions and presets, playlists, settings, XDG settings file, hosts driven over `--control`; `.desktop`, icon, systemd user unit, autostart, `.deb` / `.rpm` / tarball with an install test, a Flatpak manifest; six CC0 test scenes with references, `ci-hosted.sh` and the GitHub Actions workflow; the app checked under Xvfb and headless sway (§6, §7). Left over: transitions and video-end playlist advance on Linux (the host has to report and draw them), application rules in the hosts, the playing-audio and VRAM rules, single instance; packaging finished in 6b | done |
| 6b (done) | Packaging and CI: OpenAL Soft 1.21.1, libstb (and for the `.rpm` / tarball the shader tools) private in `/usr/lib/photon2`; a Debian 12 build image and `.deb`; install tests in fresh ubuntu:24.04, debian:12 and fedora:40 containers with plain `dpkg -i` / `rpm -i`, `sound-check` and the CC0 scenes; the Flatpak built on GNOME 51 and run headlessly (H.264 through codecs-extra); an AppImage that runs a web wallpaper through its bundled WebKitGTK; x86_64 references and exact per-architecture comparison; the workflow on both architectures, linted (§6.2, §7). Left over: a first run of the workflow on GitHub; a real-GPU desktop run of each package; Debian 12's stock lavapipe crash (Mesa 22.3); signing and a Flathub submission | done |
| 6b (done) | Wallpaper-switch transitions on Linux (in-host `load` and cross-process handover with snapshots, all 27 effects, −1/−2, web overlay in a GtkOverlay), video-end playlist advance, application rules (/proc, `_NET_WM_PID`, app_id), the audio-playing rule (pulse sink inputs), `pausevram` (VK_EXT_memory_budget, `VRAMRule` shared with macOS), single instance over D-Bus, stretch / clone with a shared frame on X11 and Wayland, the cursor (XInput 2 / XTEST, wl_pointer / wlr-virtual-pointer); `host-features.sh`, the Wayland and app checks extended (§5.4). Left over: content-switching app rules, clone groups, a zero-copy web overlay | done |
| 6c (done) | KWin's `org_kde_plasma_window_management` and virtual desktops for the rules on KDE Plasma (permission through `photon2-kwin.desktop`); the GNOME host: `xdg_toplevel` background windows shown by the `photon2@photon2.github.io` Shell extension through clones in the background actors, Mutter's window states and the desktop pointer over D-Bus; the extension in the packages and as a zip; `ci.sh --kde --gnome` with KWin 5.27 and GNOME Shell 46 headless in the container (§5.2). Left over: the extension on GNOME 45 and 47 to 49, Plasma 6, the KWin rules inside Flatpak and AppImage (KWin matches `/usr/bin/photon-linux` only), publishing the extension on extensions.gnome.org | done |
| 6d (done) | The monitor profile (docs/re/09 §8.3): clone groups with their source and flips (one host per group), split regions as wallpaper instances of their own (a host per region with `--region`: X11 window, layer surface with margins, GNOME extension regions, WebKitGTK window), sound for the first host of a wallpaper, clone-group and split controls in the GTK settings; split checks in host-features, wayland-smoke, kde-check, gnome-check and the app's layout passes (§5.4, §6.1). Left over: `auto_split` (NVIDIA Surround), split offsets in physical pixels on scaled outputs | done |
| 7 | Migrate PhotonRender from the Metal facade onto PhotonGPU with a PhotonMetal backend (§2.4), checked byte-identical on macOS at every step; delete the facade | 3 weeks |
