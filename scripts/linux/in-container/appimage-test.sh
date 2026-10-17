#!/bin/sh
# In a fresh ubuntu:24.04 / fedora:40 container: runs the AppImage with only a Vulkan driver, Xvfb, a D-Bus daemon and
# the libraries AppImages leave to the host by policy (linuxdeploy's excludelist: glibc, libstdc++, X11 / xcb, EGL /
# GL / gbm / drm, Wayland client, ALSA, PipeWire, FreeType, fontconfig, HarfBuzz, FriBidi, the Vulkan loader),
# installed from the distribution:
#   appimage-test.sh <file.AppImage> <outdir>
# Checks: --version equals the version in the file name (photon2-<version>-<arch>.AppImage), info (lavapipe), desktop --self-test, the five CC0 scenes, and the web test scene in the desktop host under
# Xvfb (WebKitGTK's helper processes from inside the AppImage; the page log must match Tests/scenes/web.log).
set -e
ai=$1; out=$2; rm -rf "$out"; mkdir -p "$out"
. /etc/os-release
. "$(dirname "$0")/ci-lib.sh"
CI_CONTEXT="AppImage on $PRETTY_NAME"; CI_STEP="package install"; ci_trap
echo "== $PRETTY_NAME: $(basename "$ai")"
case $ID in
  ubuntu) apt_prepare
    deps="$(apt_update) && apt-get install -y -qq --no-install-recommends $APT_NET \
      mesa-vulkan-drivers libvulkan1 xvfb dbus x11-utils imagemagick libx11-6 libxext6 libxrandr2 libxss1 libharfbuzz0b libfreetype6 fontconfig fonts-dejavu-core \
      libegl1 libgl1 libgbm1 libx11-xcb1 libwayland-client0 libasound2t64 libfribidi0 libpipewire-0.3-0t64 libgles2" ;;
  fedora) deps="dnf install -y -q mesa-vulkan-drivers vulkan-loader xorg-x11-server-Xvfb dbus-daemon ImageMagick libXScrnSaver harfbuzz freetype fontconfig dejavu-sans-fonts \
      mesa-libEGL mesa-libGL mesa-libgbm libwayland-client alsa-lib fribidi pipewire-libs libglvnd-gles" ;;
  *) ci_reported=1; ci_annotate error "$CI_CONTEXT: unsupported distribution $ID (ubuntu and fedora have package lists)"; exit 2 ;;
esac
retry_install "$out/install.log" "package install" "$deps" || die_log "$out/install.log" "package install" $?
# lavapipe only: without /dev/dri, Fedora's PowerVR ICD fails vkEnumeratePhysicalDevices once the AppImage's libraries
# let it load, and the loader then reports no device at all.
CI_STEP="Vulkan driver"
VK_DRIVER_FILES=$(ls /usr/share/vulkan/icd.d/lvp_icd*.json) || fail "no lavapipe ICD in /usr/share/vulkan/icd.d"
export VK_DRIVER_FILES
export APPIMAGE_EXTRACT_AND_RUN=1 PHOTON_SEED=1 GALLIVM_PERF=no_aos_sampling SWIFT_BACKTRACE=enable=no NO_AT_BRIDGE=1
cp "$ai" /tmp/photon2.AppImage; chmod +x /tmp/photon2.AppImage
# Under an emulator (Rosetta / qemu-user) the AppImage magic bytes are refused; zero them in the copy.
printf '\000\000\000' | dd of=/tmp/photon2.AppImage bs=1 seek=8 count=3 conv=notrunc 2> /dev/null
p() { /tmp/photon2.AppImage "$@"; }
want=$(basename "$ai" "-$(uname -m).AppImage"); want=${want#photon2-}
CI_STEP="--version"
v=$(p --version 2> "$out/version.txt") || die_log "$out/version.txt" "--version" $?
[ "$v" = "photon-linux $want" ] || fail "--version says '$v', the AppImage is $want"
echo "--version: $v"
CI_STEP="info"
p info > "$out/info.txt" 2>&1 || die_log "$out/info.txt" "info" $?
cat "$out/info.txt"
CI_STEP="self-test"
p desktop --self-test > "$out/self-test.txt" 2>&1 || die_log "$out/self-test.txt" "self-test" $?
tail -1 "$out/self-test.txt"
# stdout and stderr apart: the error is on stderr, and stdout (block-buffered when it is a file) may come after it.
for id in images effects particles text perspective; do
  CI_STEP="render $id"
  PHOTON_WE_ASSETS=/src/Tests/scenes/assets p render "/src/Tests/scenes/$id" "$out/lx_$id.png" 2 640 360 \
      > "$out/$id.txt" 2> "$out/$id.err" || {
    rc=$?; cat "$out/$id.txt" >> "$out/$id.err"
    die_log "$out/$id.err" "render $id" $rc
  }
done
echo "5 scenes rendered"
CI_STEP="web scene"
Xvfb :97 -screen 0 640x360x24 > /dev/null 2>&1 & sleep 1
eval "$(dbus-launch --sh-syntax 2>/dev/null)" || true
DISPLAY=:97 WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 p desktop /src/Tests/scenes/web --seconds 6 \
  --eval 'document.getElementById("log").textContent' > "$out/web.txt" 2>&1 &
host=$!; sleep 5; DISPLAY=:97 import -window root "$out/lx_web.png" || true
wait $host || die_log "$out/web.txt" "web scene" $?
sed -n '/textContent =$/,$p' "$out/web.txt" | tail -n +2 > "$out/web.log"
# The first line that differs from the reference (no diff in the Fedora image).
mismatch=$(awk 'NR == FNR { want[FNR] = $0; n = FNR; next }
  { m = FNR; if (FNR > n || want[FNR] != $0) { printed = 1; printf "line %d: expected \"%s\", got \"%s\"", FNR, (FNR > n ? "(end)" : want[FNR]), $0; exit } }
  END { if (m < n && !printed) printf "line %d: expected \"%s\", got (end)", m + 1, want[m + 1] }' /src/Tests/scenes/web.log "$out/web.log")
if [ -z "$mismatch" ]; then echo "web page log matches"; else tail -n 20 "$out/web.txt"; fail "web page log differs: $mismatch"; fi
echo "AppImage runs ($PRETTY_NAME)"
