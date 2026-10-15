#!/bin/sh
# Linux checks that need no Steam corpus and no Wallpaper Engine install (docs/linux-port.md §7): what the hosted CI
# runner (.github/workflows/ci.yml) runs, and runnable locally. Builds photon-linux in the container, then:
#   1. photon-linux info, desktop --self-test (pause rules)
#   2. text shaping against CoreText for the cases with system fonts (ArialMT, Menlo-Regular from text-cases.txt; the
#      other cases need the engine's font files) and for Tests/scenes/text-cases.txt (the committed OFL font)
#   3. the synthetic CC0 scenes against their references (scenes-check.sh)
#   4. the GTK app check (in-container/app-check.sh), when it exists
#   5. the desktop environments with the CC0 scene: KWin (kde-check.sh) and GNOME Shell with the extension
#      (gnome-check.sh), see ci.sh --kde --gnome
#   scripts/linux/ci-hosted.sh [release|debug] [--no-build]
# PHOTON_WS / PHOTON_WE may name empty directories (they are created when missing). Exit status 0 when all passed.
. "$(dirname "$0")/env.sh"
config=release; build=1
for a in "$@"; do case $a in --no-build) build=0 ;; release|debug) config=$a ;; *) echo "unknown option $a"; exit 2 ;; esac; done
mkdir -p "$PHOTON_WS" "$PHOTON_WE" 2>/dev/null
fail=0
step() { printf '\n== %s\n' "$*"; }

step "image $PHOTON_LX_IMAGE"
docker image inspect "$PHOTON_LX_IMAGE" >/dev/null 2>&1 || docker build -t "$PHOTON_LX_IMAGE" "$repo/docker/linux" || exit 1

if [ $build = 1 ]; then
  step "build photon-linux ($config)"
  "$here/build.sh" $config || exit 1
fi

step "checks without the corpus"
lx "/build/$config/photon-linux info && /build/$config/photon-linux desktop --self-test" || fail=1

step "text shaping against CoreText (system fonts and the committed test font)"
t=$PHOTON_LX_OUT/text-hosted; mkdir -p "$t"
# System-font cases of text-cases.txt and their CoreText blocks from text-coretext.txt.
grep -v '^#' "$here/text-cases.txt" | awk -F'|' 'NF >= 3 && $1 !~ /\.(ttf|otf|TTF|OTF)$/' > "$t/system-cases.txt"
awk -F'|' '/^== / { split(substr($0, 4), f, "|"); keep = f[1] !~ /\.(ttf|otf|TTF|OTF)$/ } /^#/ { next } keep' \
  "$here/text-coretext.txt" > "$t/system-coretext.txt"
grep -v '^#' "$repo/Tests/scenes/text-coretext.txt" > "$t/scenes-coretext.txt"
PHOTON_LX_DOCKER_ARGS="-v $t:/t" lx "/scripts/in-container/text-cases.sh /build/$config/photon-linux /nonexistent /t/system-cases.txt > /t/system-linux.txt;
    /scripts/in-container/text-cases.sh /build/$config/photon-linux /src/Tests/scenes/text/fonts /src/Tests/scenes/text-cases.txt > /t/scenes-linux.txt"
for k in system scenes; do
  n=$(grep -c '^== ' "$t/$k-coretext.txt")
  if [ "$n" -gt 0 ] && diff "$t/$k-coretext.txt" "$t/$k-linux.txt" > "$t/$k-diff.txt"; then
    echo "text shaping ($k): $n cases identical to CoreText"
  else
    echo "text shaping ($k): FAILED ($t/$k-diff.txt)"; head -20 "$t/$k-diff.txt"; fail=1
  fi
done

step "synthetic CC0 scenes"
"$here/scenes-check.sh" $config || fail=1

if [ -x "$here/in-container/app-check.sh" ]; then
  step "GTK app (Xvfb and headless sway)"
  mkdir -p "$PHOTON_LX_OUT/app"
  lx "/scripts/in-container/app-check.sh /build/$config/photon-linux /out/app" || fail=1
fi

step "KWin (Plasma window management)"
lx "dbus-run-session -- timeout 600 sh /scripts/in-container/kde-check.sh /build/$config/photon-linux" | grep -v '^dbus-daemon' \
  | tee "$PHOTON_LX_OUT/kde-check.txt"
grep -q 'kde checks passed' "$PHOTON_LX_OUT/kde-check.txt" || fail=1

step "GNOME Shell with the photon2 extension"
"$here/gnome-extension.sh" > /dev/null || fail=1
lx "dbus-run-session -- timeout 900 sh /scripts/in-container/gnome-check.sh /build/$config/photon-linux /out/pkg/photon2@photon2.github.io.shell-extension.zip" \
  | grep -v '^dbus-daemon\|calendar-server' | tee "$PHOTON_LX_OUT/gnome-check.txt"
grep -q 'gnome checks passed' "$PHOTON_LX_OUT/gnome-check.txt" || fail=1

[ $fail = 0 ] && printf "\nhosted checks passed\n" || printf "\nhosted checks FAILED\n"
exit $fail
