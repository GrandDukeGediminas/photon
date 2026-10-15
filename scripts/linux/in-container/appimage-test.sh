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
echo "== $PRETTY_NAME: $(basename "$ai")"
case $ID in
  ubuntu|debian) export DEBIAN_FRONTEND=noninteractive; { apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      mesa-vulkan-drivers libvulkan1 xvfb dbus x11-utils imagemagick libx11-6 libxext6 libxrandr2 libxss1 libharfbuzz0b libfreetype6 fontconfig fonts-dejavu-core \
      libegl1 libgl1 libgbm1 libx11-xcb1 libwayland-client0 libasound2t64 libfribidi0 libpipewire-0.3-0t64 libgles2; } > "$out/install.log" 2>&1 ;;
  fedora) dnf install -y -q mesa-vulkan-drivers vulkan-loader xorg-x11-server-Xvfb dbus-daemon ImageMagick libXScrnSaver harfbuzz freetype fontconfig dejavu-sans-fonts \
      mesa-libEGL mesa-libGL mesa-libgbm libwayland-client alsa-lib fribidi pipewire-libs libglvnd-gles > "$out/install.log" 2>&1 ;;
esac || { tail -20 "$out/install.log"; exit 1; }
# lavapipe only: without /dev/dri, Fedora's PowerVR ICD fails vkEnumeratePhysicalDevices once the AppImage's libraries
# let it load, and the loader then reports no device at all.
VK_DRIVER_FILES=$(ls /usr/share/vulkan/icd.d/lvp_icd*.json); export VK_DRIVER_FILES
export APPIMAGE_EXTRACT_AND_RUN=1 PHOTON_SEED=1 GALLIVM_PERF=no_aos_sampling SWIFT_BACKTRACE=enable=no NO_AT_BRIDGE=1
cp "$ai" /tmp/photon2.AppImage; chmod +x /tmp/photon2.AppImage
# Under an emulator (Rosetta / qemu-user) the AppImage magic bytes are refused; zero them in the copy.
printf '\000\000\000' | dd of=/tmp/photon2.AppImage bs=1 seek=8 count=3 conv=notrunc 2> /dev/null
p() { /tmp/photon2.AppImage "$@"; }
want=$(basename "$ai" "-$(uname -m).AppImage"); want=${want#photon2-}
v=$(p --version)
[ "$v" = "photon-linux $want" ] || { echo "--version says '$v', the AppImage is $want"; exit 1; }
echo "--version: $v"
p info
p desktop --self-test > "$out/self-test.txt" 2>&1 || { tail -20 "$out/self-test.txt"; exit 1; }
tail -1 "$out/self-test.txt"
for id in images effects particles text perspective; do
  PHOTON_WE_ASSETS=/src/Tests/scenes/assets p render "/src/Tests/scenes/$id" "$out/lx_$id.png" 2 640 360 > "$out/$id.txt" 2>&1 \
    || { tail -20 "$out/$id.txt"; exit 1; }
done
echo "5 scenes rendered"
Xvfb :97 -screen 0 640x360x24 > /dev/null 2>&1 & sleep 1
eval "$(dbus-launch --sh-syntax 2>/dev/null)" || true
DISPLAY=:97 WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 p desktop /src/Tests/scenes/web --seconds 6 \
  --eval 'document.getElementById("log").textContent' > "$out/web.txt" 2>&1 &
host=$!; sleep 5; DISPLAY=:97 import -window root "$out/lx_web.png" || true; wait $host || { tail -20 "$out/web.txt"; exit 1; }
sed -n '/textContent =$/,$p' "$out/web.txt" | tail -n +2 > "$out/web.log"
if [ "$(cat /src/Tests/scenes/web.log)" = "$(cat "$out/web.log")" ]; then echo "web page log matches"; else tail -20 "$out/web.txt"; exit 1; fi
echo "AppImage runs ($PRETTY_NAME)"
