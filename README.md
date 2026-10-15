# photon2

A native macOS rebuild of Wallpaper Engine's scene renderer, written in Swift and Metal.

The behaviour comes from reverse engineering the real engine (`wallpaper64.exe` and `scenescript64.dll`). This repository publishes only the clean-room implementation: no engine binaries, no decompiled code, and not the reverse-engineering notes (`docs/re/…` references in comments point to those private notes). Wallpapers render from your own Steam workshop downloads, and the engine's base assets (shaders, materials, effects, script prelude) are read from your Wallpaper Engine install at runtime. Nothing from the engine is copied into this repo.

## Requirements

- macOS 14 or later, Apple silicon or a Metal-capable GPU.
- Wallpaper Engine owned on Steam. photon checks this at launch with steamcmd (`+login <account> +licenses_for_app 431960`). The launch window sets everything up in the app: it can download Valve's steamcmd into photon's folder, and signs steamcmd in (password and Steam Guard code are passed straight to steamcmd and never stored; steamcmd keeps its own login) and re-checks weekly; a successful check covers 30 days offline. The Windows build has to be installed somewhere readable, for example a CrossOver bottle. The default path is `~/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/common/wallpaper_engine/assets`. Override it with `PHOTON_WE_ASSETS`.
- Workshop items downloaded by Steam for macOS to `~/Library/Application Support/Steam/steamapps/workshop/content/431960`.
- `glslangValidator` and `spirv-cross` from Homebrew, at `/opt/homebrew/bin`. Shaders go WE dialect → HLSL (the engine's own translation) → SPIR-V → Metal, and the results are cached in `~/Library/Caches/photon2/shaders`.

## Linux

The Linux port (`photon-linux`: X11 and Wayland desktop hosts, web wallpapers, a GTK status-icon app) is described in [`docs/linux-port.md`](docs/linux-port.md). It also reads your own Wallpaper Engine install and Steam Workshop folder. Packages are built with `scripts/linux/package.sh` (x86_64 and arm64), the Flatpak with `scripts/linux/flatpak.sh` and the AppImage with `scripts/linux/appimage.sh`. CI publishes all of them as workflow artifacts:

```sh
sudo apt install ./photon2_0.6.0-1~ubuntu24.04_amd64.deb   # Ubuntu 24.04 or newer
sudo apt install ./photon2_0.6.0-1~deb12_amd64.deb         # Debian 12
sudo dnf install ./photon2-0.6.0-1.x86_64.rpm              # Fedora 40 or newer
flatpak install ./photon2-x86_64.flatpak                   # any distribution; pulls the GNOME 51 runtime from Flathub
./photon2-0.6.0-x86_64.AppImage app                        # glibc 2.36 or newer; host Vulkan driver
systemctl --user enable --now photon2.service              # start with the session (packages), or Settings → Start at login
```

Every package carries OpenAL Soft 1.21.1 privately in `/usr/lib/photon2`. That is the engine's version, so sound objects mix the same samples as Wallpaper Engine does. Distribution OpenAL (1.23 and newer) gives different output for the same calls. What each package needs from the system, and why, is in §6.2 of the port document.

## Running

```sh
swift build -c release
.build/release/photon 1139304621        # a workshop id, or a path to a wallpaper folder
```

`photon` puts a borderless Metal window on every display at desktop level: behind the Finder icons, click-through, on every Space. It runs from a menu-bar icon: **Browse Wallpapers…** opens the library (workshop items plus the engine's default projects). Scene, video, web (`.html`, run in a WKWebView host that injects the engine's own web runtime) and GIF wallpapers play; application (`.exe`) wallpapers are reported as unsupported. Pick a wallpaper and choose **Apply** for all displays or one display (double-click applies to all), edit its properties (sliders, colours, toggles, combos and text, shown or hidden by each property's condition), and pause, mute or set the volume. Choices are saved in the `photon2` defaults domain. Changing a property reloads the scene. The "Wallpaper" section holds the engine's general properties (volume, playback rate, mouse parallax, alignment and flip), applied without a reload. **Settings…** (menu bar or browser) holds the engine's automatic playback rules (another app focused, maximized or fullscreen, another app playing audio, display asleep, on battery, application rules), the frame-rate limit and post-processing; the screen lock pauses playback until unlock (docs/re/09-host.md). Only the first display showing a wallpaper plays its sound. **Playlists** (bottom of the browser): pick a display (or all), add wallpapers, and Configure them like the engine's playlist dialog: change on a timer, at login (each start of photon), by time of day (each wallpaper's end time), by day of week, or never; random or sorted order; a transition (or none) and its time; change when a video ends, keep changing while paused, start with the first wallpaper, play it only at startup. Save and Load keep named playlists. The menu bar has Next Wallpaper, Previous Wallpaper and Saved Playlists while a playlist runs. Applying a single wallpaper to a display removes its playlist (docs/re/09-host.md §9).

Developer tool:

```sh
.build/release/photon-tool render <id> out.png [seconds] [width] [height]   # offline render
.build/release/photon-tool scan-tex | upload-tex | scan-mdl | compile-shaders
.build/release/photon-tool tex-dump file.tex [props.json]                     # TEXB variant selection and mip bytes
.build/release/photon-tool hlsl <id> <shader> [COMBO=1 …]                     # print translated HLSL
.build/release/photon-tool shader-coverage [engine|workshop|all] [random] [dir]  # compile every shader × combo variant
.build/release/photon-tool fxc-check [--rerun] <id|dir|hlsl dir> …            # run WE's own FXC (d3dcompiler_47 under CrossOver) on every stage photon2 compiles; verdicts feed PHOTON_FXC_STRICT
.build/release/photon-tool gs-check <pdump> <out.jsonl>                     # replay PHOTON_PDUMP gsin draws through the emulated geometry stage, capture every vertex
.build/release/photon-tool audio-test synth | <seconds>
.build/release/photon-tool transition <old> <new> <effect> <progress> out.png [w h]   # one frame of the wallpaper-switch overlay (old/new: id, folder, PNG or color:r,g,b)
```

Debug environment variables:

| Variable | Effect |
|---|---|
| `PHOTON_ONLY` / `PHOTON_SKIP` | Comma-separated object ids to draw or skip |
| `PHOTON_SHOW=<render target>` | Show a named render target instead of the final frame |
| `PHOTON_ALPHA=1` | Dump the alpha channel when rendering offline |
| `PHOTON_PROP_<name>=<json>` | Override a user property |
| `PHOTON_NOANIM=1` | Puppets stay in their bind pose |
| `PHOTON_MODELS=0` | Skip 3D model objects |
| `PHOTON_AUDIO=1` | Enable audio capture in offline renders |
| `PHOTON_TEXTDEBUG=1` | Log text layout |
| `PHOTON_SPRITEDEBUG=<v>` | Log sprite-object occlusion samples; a number forces the visibility v |
| `PHOTON_POSTPROCESSING=disabled\|enabled\|ultra\|displayhdr` | The engine's post-processing quality setting (default `enabled`). `ultra` turns on the HDR bloom path for scenes with `hdr` and `bloom` set; `displayhdr` also outputs those scenes as EDR (fp16, extended linear sRGB) |
| `PHOTON_EDR=<headroom>` | Offline renders of display-HDR scenes go through an fp16 target with that EDR headroom; prints the peak value |
| `PHOTON_RESOLUTION=full\|half\|auto` | The engine's `resolution` setting (texture reduction: half drops the top mip and halves layer composites); the app's Settings › Performance › Texture resolution sets it too |
| `PHOTON_SEED=<n>` | Fix the particle RNG seed (reproducible offline renders) |
| `PHOTON_FPS=<n>` | The engine's `fps` setting (default 15, the medium preset). Particles read it: 1–20 runs their operators in two half-steps, and it caps the rope-trail UV estimate |
| `PHOTON_NOMORPH=1` | Disable morph targets (blend shapes) |
| `PHOTON_NODEPTH=1` | Render without the back-buffer depth buffer |
| `PHOTON_NOCULL=1` | Disable back-face culling |
| `PHOTON_NOCLIP=1` | Draw puppets without their clip groups |
| `PHOTON_NOPHYSICS=1` | Disable puppet bone physics (secondary motion) |
| `PHOTON_SHADOWS` / `PHOTON_VOLUMETRICS` | The engine's `shadows` / `volumetrics` quality settings: `disabled`, `low`, `medium` (default), `high`, `ultra` |
| `PHOTON_SCRIPTLOG=1` | Log SceneScript output and errors |
| `PHOTON_MEDIA=off\|<events.json>` | SceneScript media integration: `off` disables it, a JSON file replays scripted media events on the scene clock (tests); default polls macOS Now Playing (MediaRemote) |
| `PHOTON_REFLECTION=0` | The engine's `reflection` setting off: `_rt_Reflection` is only cleared (planar reflections disabled) |
| `PHOTON_NOFRUSTUM=1` | Disable frustum culling of models, images and text |
| `PHOTON_TEXDEBUG=1` | Log draws and slots that fall back to the error texture |
| `PHOTON_DUMP_HLSL=<dir>` | Write every program's translated vertex/fragment HLSL into `<dir>` (FXC cross-checks) |
| `PHOTON_FXC_STRICT=1` | Draw `dx11fallback` (solid dark red) for the stages WE's FXC rejects, as the engine does, using the verdicts `photon-tool fxc-check` recorded. Off by default |
| `PHOTON_FXC_CACHE=<file>` | Verdict table for `fxc-check` / `PHOTON_FXC_STRICT` (default `~/Library/Caches/photon2/fxc-verdicts.tsv`) |
| `PHOTON_WINE`, `PHOTON_WINE_BOTTLE`, `PHOTON_FXC_DLL`, `PHOTON_FXC_EXE` | `fxc-check` harness: CrossOver's `wine` (default `~/Applications/CrossOver.app/…/bin/wine`), bottle (`Steam`), the engine's `d3dcompiler_47.dll` (default `distribution/bin` next to the assets) and a prebuilt `docs/re/tools/fxc.c` (otherwise built with `x86_64-w64-mingw32-gcc`) |
| `PHOTON_WARMUP=<n>` | `photon-tool render`: warm-up frames at 30 fps before the rendered time (default 3). Sprite-sheet and GIF clocks step once per rendered frame, like the engine's |
| `PHOTON_WEBDEBUG=1` | Log web wallpaper console output and errors |
| `PHOTON_GENERAL='{"alignment":3,…}'` | `photon-tool render`: the wallpaper's general properties (alignment, alignmentx/y/z, alignmentposition, alignmentfliph, schemecolor, cameraparallax, colour options `wec_e`/`wec_brs`/`wec_con`/`wec_sa`/`wec_hue`, LUT filter `wcc_v`/`wcc_amt`; web wallpapers: the `wec_*` CSS filter and flip) |
| `PHOTON_NOGS=1` | Build programs without geometry shaders (no `GS_ENABLED`, no `.geom`): particles take the engine's non-GS quad path (A/B only; the engine always uses the GS) |
| `PHOTON_MSAA=none\|x2\|x4\|x8` | The engine's `msaa` setting (default `x2`); only scenes with 3D model objects are multisampled |
| `PHOTON_WEBPLUGINS=0` | Web wallpapers without the LED plugin objects (`window.cue`, `wpPlugins.led`) |
| `PHOTON_TRANSITION_MS=<ms>` | `photon-tool transition`: the transition time (default 1000) |
| `PHOTON_TRANSITION_EDR=1` | `photon-tool transition` with `color:` frames as fp16 EDR (r,g,b / 255, linear): runs the engine's HDR snapshot readback and the EDR overlay composite, prints the centre pixel |

## Layout

| Target | Contents |
|---|---|
| `PhotonCore` | File formats and logic with no GPU dependency: `.pkg`, the VFS lookup order, `.tex`, `.mdl`, the shader preprocessor and GLSL-dialect → HLSL translator, JSON merge and user-property bindings, keyframe animation |
| `PhotonRender` | Metal renderer: shader compilation, materials, render targets, the image layer and effect loop, bloom/combine, particles, text, puppets, video, audio spectrum, sound, SceneScript |
| `PhotonHost` | Desktop-level windows, one per display, driven by per-screen display links |
| `photon` | The wallpaper app |
| `photon-tool` | Corpus scans, offline rendering, shader dumps |

## Where photon2 deliberately differs from the engine

These are platform differences. Each one is marked in the code.

- **No geometry shaders on Metal.** `GS_ENABLED` is never defined, so stock shaders take their non-geometry-shader paths. The engine supports that path too.
- **Packed-array casts.** The engine's HLSL uses FXC-only array casts such as `(float[16])x`. We emit equivalent element-wise code instead.
- **Varyings linked by name.** D3D11 drivers tolerate vertex and pixel shaders whose varyings don't line up. Metal doesn't, so fragment inputs are linked to vertex outputs by name, and missing ones become zero.
- **New render targets are cleared to transparent black.** D3D11 zero-fills them; Metal doesn't.
- **SceneScript runs on JavaScriptCore**, not V8. See `docs/re/08-scenescript.md` and the notes in `Script*.swift`.
- **Text is shaped and rasterised by CoreText**, not FreeType.

## Status

Checked by rendering all 176 items of the test library (157 workshop items and 19 default projects) offline with `photon-tool render`
and comparing them against their previews:

- 174 load and render. That includes the two Corsair default projects, which are web wallpapers.
- 3643568696 is a preset whose dependency isn't downloaded; the engine can't load it either.
- `def:sheep` is a Windows application (`.exe`) wallpaper, which can't run on macOS.
- 5 wallpapers hit shader-authoring bugs that fail to compile in the real engine too. Both engines fall back to `dx11fallback`.

Session 6 resolved every open item in the reverse-engineering notes, including the ones no corpus wallpaper uses. These were traced in the binary and tested with synthetic scenes:
- planar reflections;
- the error texture;
- frustum culling;
- lit puppets;
- puppet IK;
- particle remap, noise and collisions;
- `layerimage`;
- TEXB texture variants;
- IModelData;
- GIF wallpapers;
- the host frame pacing.

A few traced features are not ported; each is listed in the summary at the top of `unknowns.md`.
