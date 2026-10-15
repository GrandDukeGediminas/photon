#!/bin/sh
# Linux CI for photon2 (docs/linux-port.md §7): builds the image and photon-linux in Docker, runs the checks that need no
# corpus, compares text shaping with CoreText (text-check.sh), renders the test set (scenes, video wallpapers and video
# textures, GIF wallpapers, text-heavy scenes; wallpapers.txt) on lavapipe and compares it with reference renders against
# the committed per-wallpaper limits in scripts/linux/thresholds.tsv.
#
#   scripts/linux/ci.sh [--mac | --refs DIR] [--linux-refs DIR] [--native-gs] [--x11] [--audio] [--wayland] [--web]
#                       [--kde] [--gnome] [--debug]
#     --mac            render the macOS references now with photon-tool (pairs, so clock wallpapers agree on the minute)
#                      and regenerate the CoreText text-shaping reference
#     --refs DIR       use existing macOS references DIR/<id>.png (default: $PHOTON_LX_OUT/mac if present)
#     --linux-refs DIR also require every render to equal DIR/lx_<id>.png exactly (lavapipe is deterministic on one Mesa)
#     --native-gs      native geometry shaders: must render exactly like the emulation drawn through a pass-through
#                      geometry stage (in-container/native-gs-check.sh)
#     --x11            X11 host smoke test under Xvfb: swapchain and readback presentation, screenshot vs headless render;
#                      then the host features (in-container/host-features.sh): the 27 transition effects against
#                      `photon-tool transition` (references regenerated with --mac), switches inside a host, stretch and
#                      clone, the cursor, application rules, the audio-playing rule, pausevram, video loops
#     --audio          audio and system integration (in-container/audio-check.sh): OpenAL Soft 1.21.1 sound objects against
#                      photon2's voice model (and the macOS output from `photon-tool sound-ref`, regenerated with --mac),
#                      spectrum capture through PipeWire and PulseAudio, sound objects in the X11 host with pause rules,
#                      MPRIS media events and the UPower / logind / screensaver signals from fake D-Bus services
#     --wayland        Wayland host under headless sway / labwc (in-container/wayland-smoke.sh): layer-shell surfaces
#                      through the Vulkan swapchain and wl_shm equal to the headless render, fractional scale 1.5,
#                      output hotplug, fullscreen / maximized clients through wlr-foreign-toplevel, the GNOME
#                      static-background fallback
#     --web            web wallpapers on WebKitGTK (in-container/web-check.sh): the API test page on X11 and on Wayland
#                      (properties, directories, audio frames from a PipeWire tone, MPRIS media, plugins, colour
#                      filter, pause), compared with the macOS host's output (regenerated with --mac), and the install's
#                      def_corsair_collection / def_corsair_o_tron
#     --kde            the Wayland host under KWin 5.27 (kwin_wayland --virtual, in-container/kde-check.sh): layer-shell
#                      frames equal to the headless render (KWin's ScreenShot2), the rules from
#                      org_kde_plasma_window_management (granted through packaging/linux/photon2-kwin.desktop): fullscreen
#                      on one of two outputs, maximized, virtual desktops, an app_id rule
#     --gnome          the GNOME host under GNOME Shell 46 (gnome-shell --headless, in-container/gnome-check.sh) with the
#                      packed extension (gnome-extension.sh): screenshots equal to the headless render, animation,
#                      fullscreen / maximized pauses, an app_id rule, desktop clicks, the overview, extension disable
# Exit status: 0 when every check passed. The workshop corpus and engine assets are not redistributable, so they come
# from the local Steam folders (PHOTON_WS, PHOTON_WE in env.sh).
set -e
. "$(dirname "$0")/env.sh"
config=release; refs=""; mac=0; linux_refs=""; native=0; x11=0; audio=0; wayland=0; web=0; kde=0; gnome=0
while [ $# -gt 0 ]; do
  case $1 in
    --mac) mac=1 ;;
    --refs) refs=$2; shift ;;
    --linux-refs) linux_refs=$2; shift ;;
    --native-gs) native=1 ;;
    --x11) x11=1 ;;
    --audio) audio=1 ;;
    --wayland) wayland=1 ;;
    --web) web=1 ;;
    --kde) kde=1 ;;
    --gnome) gnome=1 ;;
    --debug) config=debug ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
  shift
done
out=$PHOTON_LX_OUT
fail=0
step() { printf '\n== %s\n' "$*"; }
# pxdiff <refs-dir> <renders-dir> <report> [pixeldiff options]: pixeldiff.py in the container (numpy + PIL are in the image).
pxdiff() {
  r=$1; o=$2; rep=$3; shift 3
  PHOTON_LX_DOCKER_ARGS="-v $r:/refs:ro -v $o:/renders:ro" lx "python3 /scripts/pixeldiff.py /refs /renders --ids /scripts/wallpapers.txt $*" \
    | tee "$rep"
  ! grep -q '^FAILED' "$rep"
}

step "image $PHOTON_LX_IMAGE"
docker image inspect "$PHOTON_LX_IMAGE" >/dev/null 2>&1 || docker build -t "$PHOTON_LX_IMAGE" "$repo/docker/linux"

step "build photon-linux ($config)"
"$here/build.sh" $config

step "checks without the corpus"
lx "/build/$config/photon-linux info && /build/$config/photon-linux desktop --self-test" || fail=1

step "text shaping against CoreText"
if [ $mac = 1 ]; then
  : "${PHOTON_TOOL:=/tmp/photon2-mac/release/photon-tool}"
  if [ ! -x "$PHOTON_TOOL" ] || [ "${PHOTON_TOOL_REBUILD:-1}" = 1 ]; then
    (cd "$repo" && swift build -c release --product photon-tool --scratch-path "$(dirname "$(dirname "$PHOTON_TOOL")")" | tail -1)
    PHOTON_TOOL_REBUILD=0
  fi
  PHOTON_TOOL=$PHOTON_TOOL "$here/text-check.sh" $config --mac || fail=1
else
  "$here/text-check.sh" $config || fail=1
fi

step "render the test set"
if [ $mac = 1 ]; then
  : "${PHOTON_TOOL:=/tmp/photon2-mac/release/photon-tool}"
  if [ ! -x "$PHOTON_TOOL" ] || [ "${PHOTON_TOOL_REBUILD:-1}" = 1 ]; then
    (cd "$repo" && swift build -c release --product photon-tool --scratch-path "$(dirname "$(dirname "$PHOTON_TOOL")")" | tail -1)
  fi
  refs=$out/mac
  PHOTON_TOOL=$PHOTON_TOOL "$here/render-set.sh" $config --mac "$refs" --tag renders
else
  "$here/render-set.sh" $config --tag renders
fi
[ -z "$refs" ] && [ -d "$out/mac" ] && refs=$out/mac

if [ -n "$refs" ]; then
  step "pixel diff against macOS references ($refs)"
  pxdiff "$refs" "$out/renders" "$out/diff-mac.md" --thresholds /scripts/thresholds.tsv || fail=1
else
  echo "no macOS references (--mac or --refs DIR): skipping the macOS comparison"
fi
if [ -n "$linux_refs" ]; then
  step "exact comparison with earlier lavapipe renders ($linux_refs)"
  pxdiff "$linux_refs" "$out/renders" "$out/diff-linux.md" --ref-prefix lx_ --exact || fail=1
fi

if [ $native = 1 ]; then
  step "native geometry shaders against the emulation"
  ids=$(test_ids)
  lx "/scripts/in-container/native-gs-check.sh /build/$config/photon-linux /out/native-gs $ids" | tee "$out/native-gs.txt"
  grep -q FAIL "$out/native-gs.txt" && fail=1
fi

if [ $x11 = 1 ]; then
  step "X11 host under Xvfb"
  lx "/scripts/in-container/x11-smoke.sh /build/$config/photon-linux" || fail=1
  step "host features under Xvfb (transitions, layouts, cursor, rules)"
  trref=""
  if [ $mac = 1 ]; then
    mkdir -p "$out/tr-mac"
    for e in $(seq 0 26); do
      PHOTON_TRANSITION_SEED=7 "$PHOTON_TOOL" transition color:220,60,40 color:30,60,200 $e 0.5 "$out/tr-mac/mac_${e}_0.5.png" 320 180 > /dev/null || fail=1
    done
    trref=/out/tr-mac
  elif [ -f "$out/tr-mac/mac_0_0.5.png" ]; then
    trref=/out/tr-mac
  fi
  lx "timeout 900 sh /scripts/in-container/host-features.sh /build/$config/photon-linux $trref" | tee "$out/host-features.txt"
  grep -q 'host feature checks passed' "$out/host-features.txt" || fail=1
fi

if [ $audio = 1 ]; then
  step "audio and system integration"
  soundref=""
  if [ $mac = 1 ]; then
    dll="$(dirname "$PHOTON_WE")/distribution/bin/mediaextensions64.dll"
    "$PHOTON_TOOL" sound-ref "$dll" "$out/soundref-mac" && soundref=/out/soundref-mac
  elif [ -f "$out/soundref-mac/hrtf.f32" ]; then
    soundref=/out/soundref-mac
  fi
  lx "/scripts/in-container/audio-check.sh /build/$config/photon-linux $soundref" | tee "$out/audio-check.txt"
  grep -q 'audio and system checks passed' "$out/audio-check.txt" || fail=1
fi

if [ $wayland = 1 ]; then
  step "Wayland host under headless sway / labwc"
  lx "timeout 600 /scripts/in-container/wayland-smoke.sh /build/$config/photon-linux" | tee "$out/wayland-smoke.txt"
  grep -q 'wayland smoke test passed' "$out/wayland-smoke.txt" || fail=1
fi

if [ $web = 1 ]; then
  step "web wallpapers on WebKitGTK"
  webref=""
  if [ $mac = 1 ]; then
    # The macOS host's output for the API page (photon-tool render with PHOTON_WEBDEBUG=1), with the directory
    # properties pointing at a host copy of the test images.
    "$here/web-mac-ref.sh" "$PHOTON_TOOL" "$out/web-mac" && webref=/out/web-mac
  elif [ -f "$out/web-mac/webapi.log" ]; then
    webref=/out/web-mac
  fi
  lx "timeout 900 /scripts/in-container/web-check.sh /build/$config/photon-linux $webref" | grep -v '^libEGL' | tee "$out/web-check.txt"
  grep -q 'web checks passed' "$out/web-check.txt" || fail=1
fi

if [ $kde = 1 ]; then
  step "Wayland host under KWin (Plasma window management)"
  lx "dbus-run-session -- timeout 600 sh /scripts/in-container/kde-check.sh /build/$config/photon-linux" | grep -v '^dbus-daemon' \
    | tee "$out/kde-check.txt"
  grep -q 'kde checks passed' "$out/kde-check.txt" || fail=1
fi

if [ $gnome = 1 ]; then
  step "GNOME host under GNOME Shell with the photon2 extension"
  "$here/gnome-extension.sh" > /dev/null || fail=1
  lx "dbus-run-session -- timeout 900 sh /scripts/in-container/gnome-check.sh /build/$config/photon-linux /out/pkg/photon2@photon2.github.io.shell-extension.zip" \
    | grep -v '^dbus-daemon\|calendar-server' | tee "$out/gnome-check.txt"
  grep -q 'gnome checks passed' "$out/gnome-check.txt" || fail=1
fi

if [ $fail = 0 ]; then step "CI passed"; else step "CI FAILED"; fi
exit $fail
