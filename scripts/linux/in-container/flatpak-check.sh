#!/bin/sh
# Runs the installed Flatpak (io.github.photon2.Photon) headlessly, in a privileged container with flatpak
# (scripts/linux/flatpak.sh, the CI flatpak job; docs/linux-port.md §6.2):
#   flatpak-check.sh <source dir> <outdir> [--user]
# Checks: OpenAL Soft and libstb resolve to /app/lib, `--version` equals PHOTON_VERSION_BASE of the source tree (the
# manifest stamps it), `info` on the runtime's lavapipe (GL.default), `desktop
# --self-test`, `sound-check` (the app's OpenAL Soft 1.21.1 module against photon2's voice model, limit 1e-6; the HRTF
# set is fetched from the 1.21.1 tag), the H.264 decoder from the runtime's codecs-extra extension, and the five CC0
# scenes rendered into <outdir>/fp_<id>.png. With PHOTON_FLATPAK_VIDEO=<file.mp4>, also `video-frame` of that file.
set -e
src=$(cd "$1" && pwd); out=$2; inst=${3:---system}
mkdir -p "$out"; out=$(cd "$out" && pwd)
app=io.github.photon2.Photon
fr() {
  cmd=$1; shift
  flatpak run "$inst" --filesystem="$src":ro --filesystem="$out" --env=PHOTON_SEED=1 --env=GALLIVM_PERF=no_aos_sampling \
    --env=SWIFT_BACKTRACE=enable=no --env=PHOTON_WE_ASSETS="$src/Tests/scenes/assets" --command="$cmd" "$app" "$@"
}
echo "== $(flatpak info "$inst" "$app" | grep -E 'Ref:|Runtime:' | tr -s ' ' | paste -sd' ' -)"
fr sh -c 'ldd /app/bin/photon-linux' > "$out/ldd.txt"
if grep 'not found' "$out/ldd.txt"; then exit 1; fi
grep -E 'lib(openal|stb)\.so' "$out/ldd.txt"
[ "$(grep -cE 'lib(openal|stb)\.so.* => /app/lib/' "$out/ldd.txt")" = 2 ] || { echo "OpenAL / stb not from /app/lib"; exit 1; }
want=$(sed -n 's/^#define PHOTON_VERSION_BASE "\(.*\)"$/\1/p' "$src/Sources/CPhotonVersion/include/photon_version.h")
v=$(fr photon-linux --version)
[ "$v" = "photon-linux $want" ] || { echo "--version says '$v', the source is $want"; exit 1; }
echo "--version: $v"
fr photon-linux info
fr photon-linux desktop --self-test > "$out/self-test.txt" 2>&1 || { tail -20 "$out/self-test.txt"; exit 1; }
tail -1 "$out/self-test.txt"
[ -s "$out/default-hrtf.mhr" ] || curl -fsSL "https://raw.githubusercontent.com/kcat/openal-soft/1.21.1/hrtf/Default%20HRTF.mhr" -o "$out/default-hrtf.mhr"
fr photon-linux sound-check --mhr "$out/default-hrtf.mhr" > "$out/sound-check.txt" 2>&1 || { cat "$out/sound-check.txt"; exit 1; }
grep -E '^(speaker|hrtf):|sound-check:' "$out/sound-check.txt"
fr gst-inspect-1.0 avdec_h264 > "$out/avdec_h264.txt" 2>&1 || { cat "$out/avdec_h264.txt"; echo "no H.264 decoder (codecs-extra)"; exit 1; }
grep -E '^ +(Long-name|Filename)' "$out/avdec_h264.txt"
for id in images effects particles text perspective; do
  fr photon-linux render "$src/Tests/scenes/$id" "$out/fp_$id.png" 2 640 360 > "$out/$id.txt" 2>&1 || { tail -20 "$out/$id.txt"; exit 1; }
done
echo "$(ls "$out"/fp_*.png | wc -l) scenes rendered"
if [ -n "$PHOTON_FLATPAK_VIDEO" ]; then
  flatpak run "$inst" --filesystem="$(dirname "$PHOTON_FLATPAK_VIDEO")":ro --filesystem="$out" --command=photon-linux "$app" \
    video-frame "$PHOTON_FLATPAK_VIDEO" 2 "$out/video-frame.png"
fi
echo "flatpak checks passed"
