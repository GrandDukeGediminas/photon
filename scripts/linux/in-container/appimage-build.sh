#!/bin/sh
# In photon2-linux:bookworm (glibc 2.36, so the AppImage starts on Debian 12 / Ubuntu 22.04+ era systems; docs/linux-port.md
# §6.2), after `package.sh --distro debian12` built /build/static-debian12/release/photon-linux:
#   appimage-build.sh <version> <outdir>
# linuxdeploy with its GTK and GStreamer plugins bundles GTK 3, GDK-Pixbuf loaders, GIO modules, GStreamer with its
# plugins (base, good, libav) and every library they link; the host keeps libc, the X11 / Wayland client libraries,
# the Vulkan loader and its drivers (linuxdeploy's excludelist). OpenAL Soft 1.21.1, libstb, glslangValidator and
# spirv-cross go into usr/lib/photon2 as in the packages.
# WebKitGTK starts its helper processes (WebKitWebProcess, WebKitNetworkProcess) from the directory compiled into
# libwebkit2gtk (/usr/lib/<triplet>/webkit2gtk-4.1); there is no run-time override outside developer builds. The
# bundled library gets the same-length substitution /usr -> ././ (the approach Tauri's AppImage bundler uses), and the
# AppRun hook changes to $APPDIR/usr before photon starts, so those paths resolve inside the AppImage.
set -e
. "$(dirname "$0")/ci-lib.sh"
CI_CONTEXT="AppImage build"; CI_STEP="setup"; ci_trap
version=${1:?version}; out=${2:-/out/appimage}
arch=$(uname -m); triplet=$arch-linux-gnu
bin=/build/static-debian12/release/photon-linux
[ -x $bin ] || fail "no $bin: run scripts/linux/package.sh --distro debian12 first"
[ "$($bin --version)" = "photon-linux $version" ] \
  || fail "$bin is $($bin --version), not $version: run scripts/linux/package.sh $version --distro debian12"
tools=/build/appimage-tools; mkdir -p $tools "$out"
# The AppImage type-2 magic (bytes 8 to 10 of the ELF header) makes binfmt_misc emulators (qemu-user, Rosetta in Docker
# Desktop) refuse the file with "Exec format error"; zeroing it changes nothing for a native run.
unmagic() { printf '\000\000\000' | dd of="$1" bs=1 seek=8 count=3 conv=notrunc 2> /dev/null; }
get() {
  CI_STEP="download $1"
  [ -s "$tools/$1" ] || curl -fsSL --retry 3 --retry-delay 10 --retry-all-errors "$2" -o "$tools/$1" || fail "download of $2 failed"
  chmod +x "$tools/$1"; case $1 in *.AppImage) unmagic "$tools/$1" ;; esac
}
get linuxdeploy-$arch.AppImage https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-$arch.AppImage
get linuxdeploy-plugin-appimage-$arch.AppImage https://github.com/linuxdeploy/linuxdeploy-plugin-appimage/releases/download/continuous/linuxdeploy-plugin-appimage-$arch.AppImage
get linuxdeploy-plugin-gtk.sh https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh
get linuxdeploy-plugin-gstreamer.sh https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gstreamer/master/linuxdeploy-plugin-gstreamer.sh
export PATH=$tools:$PATH APPIMAGE_EXTRACT_AND_RUN=1 NO_STRIP=1
CI_STEP="package install"
if ! command -v gst-inspect-1.0 > /dev/null; then
  apt_prepare
  retry_install /tmp/appimage-deps.log "package install" "$(apt_update) && apt-get install -y -qq --no-install-recommends $APT_NET \
    gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-libav file patchelf \
    librsvg2-common libgdk-pixbuf2.0-bin" || die_log /tmp/appimage-deps.log "package install" $?
fi
CI_STEP="AppDir and linuxdeploy"

app=/tmp/AppDir; rm -rf $app; mkdir -p $app/usr/bin $app/usr/lib/photon2
install -m755 $bin $app/usr/bin/photon-linux; strip $app/usr/bin/photon-linux
install -m644 "$(readlink -f /usr/local/lib/libopenal.so.1)" $app/usr/lib/photon2/libopenal.so.1
install -m644 "$(readlink -f "$(ldconfig -p | awk '$1 == "libstb.so.0" {print $NF; exit}')")" $app/usr/lib/photon2/libstb.so.0
install -m755 "$(readlink -f /usr/bin/glslangValidator)" $app/usr/lib/photon2/glslangValidator
install -m755 "$(readlink -f /usr/bin/spirv-cross)" $app/usr/lib/photon2/spirv-cross
mkdir -p $app/usr/lib/$triplet
cp -a /usr/lib/$triplet/webkit2gtk-4.1 $app/usr/lib/$triplet/
rm -f $app/usr/lib/$triplet/webkit2gtk-4.1/MiniBrowser
grep -v '^SingleMainWindow=' /src/packaging/linux/photon2.desktop > /tmp/photon2.desktop
rsvg-convert -w 256 -h 256 /src/packaging/linux/photon2.svg -o /tmp/photon2.png

# AppRun hook (runs before photon-linux): the WebKit helper paths resolve from $APPDIR/usr; OWD (set by the AppImage
# runtime) keeps the caller's directory for relative arguments.
mkdir -p $app/apprun-hooks
cat > $app/apprun-hooks/photon2-webkit.sh <<'EOF'
export PHOTON_APPIMAGE_OWD="${OWD:-$PWD}"
cd "$APPDIR/usr" || exit 1
EOF

export DEPLOY_GTK_VERSION=3 GSTREAMER_VERSION=1.0 GSTREAMER_INCLUDE_BAD_PLUGINS=0 \
       GSTREAMER_PLUGINS_DIR=/usr/lib/$triplet/gstreamer-1.0 GSTREAMER_HELPERS_DIR=/usr/lib/$triplet/gstreamer1.0/gstreamer-1.0
set --
for e in WebKitWebProcess WebKitNetworkProcess WebKitGPUProcess; do
  [ -x $app/usr/lib/$triplet/webkit2gtk-4.1/$e ] && set -- "$@" --executable $app/usr/lib/$triplet/webkit2gtk-4.1/$e
done
linuxdeploy-$arch.AppImage --appdir $app --executable $app/usr/bin/photon-linux "$@" \
  --library $app/usr/lib/$triplet/webkit2gtk-4.1/injected-bundle/libwebkit2gtkinjectedbundle.so \
  --desktop-file /tmp/photon2.desktop --icon-file /tmp/photon2.png --icon-filename photon2 \
  --plugin gtk --plugin gstreamer > /tmp/linuxdeploy.log 2>&1 || die_log /tmp/linuxdeploy.log "linuxdeploy" $?
# JACK is not a dependency of anything photon uses; its plugin only warns at every plugin scan without libjack.
rm -f $app/usr/lib/gstreamer-1.0/libgstjack.so
# linuxdeploy sets the binary's RUNPATH to $ORIGIN/../lib, where it copied OpenAL Soft 1.21.1 and libstb as well;
# usr/lib/photon2 keeps the shader tools (and the copies the packages use).
cmp -s $app/usr/lib/libopenal.so.1 $app/usr/lib/photon2/libopenal.so.1 || fail "usr/lib/libopenal.so.1 is not the 1.21.1 build"
# The helpers and the injected bundle sit two levels below usr/lib, where linuxdeploy put their libraries.
for f in $app/usr/lib/$triplet/webkit2gtk-4.1/WebKit*Process $app/usr/lib/$triplet/webkit2gtk-4.1/injected-bundle/*.so; do
  patchelf --set-rpath '$ORIGIN/../..:$ORIGIN/../../..' "$f"
done
sed -i 's|/usr|././|g' $app/usr/lib/libwebkit2gtk-4.1.so.0
grep -c '././/lib' $app/usr/lib/libwebkit2gtk-4.1.so.0 > /dev/null
# The helpers find their libraries in usr/lib through RUNPATH set by linuxdeploy.
ARCH=$arch VERSION=$version OUTPUT=$out/photon2-$version-$arch.AppImage \
  linuxdeploy-plugin-appimage-$arch.AppImage --appdir $app > /tmp/appimage.log 2>&1 || die_log /tmp/appimage.log "appimage plugin" $?
ls -la "$out/photon2-$version-$arch.AppImage"
