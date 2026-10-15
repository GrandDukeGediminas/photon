# Synthetic test scenes

Redistributable Wallpaper Engine projects for CI (docs/linux-port.md §7). The Steam Workshop corpus and the engine's
own assets cannot be shipped, so these scenes are written from scratch and are CC0 (LICENSE; the one font is OFL).

| Scene | Exercises |
|---|---|
| `images` | five image layers: translucent blending, per-object alpha, scale, rotation |
| `effects` | custom effect passes on image layers (time-driven sine displacement, luminance tint), two chained effects on one layer, `constantshadervalues` |
| `particles` | two particle systems: box and sphere emitters, lifetime / size / velocity / colour / rotation initializers, movement with gravity and drag, alpha fade, size change; seeded (`PHOTON_SEED=1`) |
| `text` | text layers in `fonts/NotoMono-Regular.ttf` loaded through the wallpaper's own files: centre and left alignment, multi-line, kerning pairs, colour, opaque background with padding, rotation |
| `perspective` | perspective camera (fov, near/far), two static MDL meshes (cube, torus) with a lit shader, depth test and write, back-face culling, MSAA (scenes with models are multisampled) |
| `web` | web wallpaper: CSS gradient and shapes, canvas bars driven by user properties (`color`, `slider`, `textinput`) through `wallpaperPropertyListener`; the page log is checked against `web.log` |

`assets/` stands in for the engine's `assets` folder (`PHOTON_WE_ASSETS`): the shaders the scenes name (`cc0_*`) and
the materials the renderer loads by fixed path for these features (`materials/util/effectpassthrough.json` for effect
layers, `materials/fonts/basefont*.json` and `fontbackground.json` for text). The shaders are minimal programs in the
engine's shader dialect; they are not the engine's shaders and do not render real wallpapers the way the engine does.

`tools/make_tex.py` and `tools/make_mdl.py` generate every `.tex` (RGBA8888 with box-filtered mips) and `.mdl` (MDLV0017,
one static mesh) from code; running them reproduces the committed files byte for byte.

## References and checks

- `refs/<arch>/<id>.png` (`aarch64`, `x86_64`): Linux renders (`photon-linux render <dir> out.png 2 640 360`, lavapipe
  in the `photon2-linux:dev` image, `PHOTON_SEED=1`); `web` is a 640x360 Xvfb capture of the desktop host.
  `refs/<arch>/driver.txt` records the Mesa package and lavapipe device; with the same driver the renders must be
  byte-identical, otherwise the limits apply.
- `refs-mac/<id>.png`: macOS renders (`photon-tool render`, Metal on an Apple GPU) of the five scene projects.
- `thresholds.tsv` / `thresholds-mac.tsv`: per-scene limits for `scripts/linux/pixeldiff.py`.

```sh
scripts/linux/scenes-check.sh                      # Linux renders vs refs (needs the image and a photon-linux build)
scripts/linux/scenes-check.sh --mac $PHOTON_TOOL   # also macOS renders vs refs-mac, and a Metal-vs-lavapipe table
scripts/linux/scenes-check.sh --update             # rewrite refs/<arch>/ and web.log from the current Linux renders
PHOTON_LX_PLATFORM=linux/amd64 PHOTON_LX_IMAGE=photon2-linux:dev-amd64 scripts/linux/scenes-check.sh   # x86_64 on an arm64 host
```

`photon-tool render` must read `PHOTON_WE_ASSETS` for the macOS side (photon-linux already does).

Metal against lavapipe on 2026-10-14 (640x360): mean absolute difference 0.024 to 0.120, at most 197 pixels over 32
(`perspective`: edges, 2x MSAA on Metal against 1 sample on lavapipe, which has no 2x mode).
