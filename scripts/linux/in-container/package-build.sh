#!/bin/sh
# In a build container (photon2-linux:dev for Ubuntu 24.04, photon2-linux:bookworm for Debian 12; docs/linux-port.md §6.2):
# builds the static-Swift photon-linux, stages the /usr tree with the private libraries and writes the packages.
#   package-build.sh <version> [outdir]          (scripts/linux/package.sh runs it)
# The binary is stamped with <version> (-Xcc -DPHOTON_VERSION, Sources/CPhotonVersion): `photon-linux --version` prints it.
# Output: <outdir>/photon2_<version>-1~<distro>_<arch>.deb; on Ubuntu 24.04 also photon2-<version>-1.<arch>.rpm and
# photon2-<version>-<arch>.tar.gz (the staged /usr tree; relocatable). Both of those also carry glslangValidator and
# spirv-cross in /usr/lib/photon2.
#
# Private libraries in /usr/lib/photon2 (the binary's RUNPATH is $ORIGIN/../lib/photon2, so the tarball is relocatable):
#   libopenal.so.1  OpenAL Soft 1.21.1 with the fastf2i rounding patch, built in the image (§3.6). Distributions ship
#                   1.23 or newer, whose mixer and HRTF code give different samples for the same calls; `sound-check`
#                   holds the bundled library to photon2's voice model within 1e-6.
#   libstb.so.0     stb_image as Debian builds it (GIF decoding, §3.5). Fedora has no shared libstb.
set -e
version=${1:?version}; out=${2:-/out/pkg}
. /etc/os-release
case "$ID$VERSION_ID" in
  ubuntu24.04) distro=ubuntu24.04; scratch=/build/static ;;
  debian12) distro=deb12; scratch=/build/static-debian12 ;;
  *) distro=$ID$VERSION_ID; scratch=/build/static-$ID$VERSION_ID ;;
esac
arch=$(dpkg --print-architecture); rarch=$(uname -m)
mkdir -p "$out"

echo "== build ($PRETTY_NAME, $rarch)"
# PHOTON_PKG_PREBUILT=1 packages the binary already in the scratch path (repackaging only).
# shellcheck disable=SC2016
[ -n "$PHOTON_PKG_PREBUILT" ] || swift build --scratch-path "$scratch" -c release --static-swift-stdlib --product photon-linux \
    -Xcc "-DPHOTON_VERSION=\"$version\"" -Xlinker -rpath -Xlinker '$ORIGIN/../lib/photon2' > "$scratch.log" 2>&1 \
  || { grep -E 'error:' "$scratch.log" | sort -u | head -30; tail -20 "$scratch.log"; exit 1; }
bin=$scratch/release/photon-linux
stamped=$("$bin" --version)
[ "$stamped" = "photon-linux $version" ] || { echo "the binary says '$stamped', not 'photon-linux $version'"; exit 1; }
echo "$stamped"

echo "== stage"
root=/tmp/pkgroot; rm -rf $root; mkdir -p $root
install -Dm755 "$bin" $root/usr/bin/photon-linux
strip $root/usr/bin/photon-linux
mkdir -p $root/usr/lib/photon2
openal=$(readlink -f /usr/local/lib/libopenal.so.1)
case $openal in *1.21.1) ;; *) echo "OpenAL Soft in the image is $openal, not 1.21.1"; exit 1 ;; esac
install -m644 "$openal" $root/usr/lib/photon2/libopenal.so.1
stb=$(ldconfig -p | awk '$1 == "libstb.so.0" {print $NF; exit}')
install -m644 "$(readlink -f "$stb")" $root/usr/lib/photon2/libstb.so.0
strip --strip-unneeded $root/usr/lib/photon2/*.so.*
install -Dm644 /src/packaging/linux/photon2.desktop $root/usr/share/applications/photon2.desktop
install -Dm644 /src/packaging/linux/photon2-autostart.desktop $root/usr/share/photon2/photon2-autostart.desktop
# KWin grants org_kde_plasma_window_management (the playback rules' window list) to /usr/bin/photon-linux through this
# hidden entry; the GNOME Shell extension that hosts the GNOME background windows (docs/linux-port.md §5.2).
install -Dm644 /src/packaging/linux/photon2-kwin.desktop $root/usr/share/applications/photon2-kwin.desktop
for f in metadata.json extension.js; do
  install -Dm644 /src/packaging/gnome-shell/photon2@photon2.github.io/$f $root/usr/share/gnome-shell/extensions/photon2@photon2.github.io/$f
done
install -Dm644 /src/packaging/linux/photon2.service $root/usr/lib/systemd/user/photon2.service
install -Dm644 /src/packaging/linux/photon2.svg $root/usr/share/icons/hicolor/scalable/apps/photon2.svg
for s in 32 48 64 128 256; do
  mkdir -p $root/usr/share/icons/hicolor/${s}x${s}/apps
  rsvg-convert -w $s -h $s /src/packaging/linux/photon2.svg -o $root/usr/share/icons/hicolor/${s}x${s}/apps/photon2.png
done
# The AppStream id stays io.github.photon2.Photon; the packages' desktop entry is photon2.desktop.
mkdir -p $root/usr/share/metainfo
sed 's|<launchable type="desktop-id">.*</launchable>|<launchable type="desktop-id">photon2.desktop</launchable>|' \
  /src/packaging/linux/io.github.photon2.Photon.metainfo.xml > $root/usr/share/metainfo/io.github.photon2.Photon.metainfo.xml
doc=$root/usr/share/doc/photon2; mkdir -p $doc
install -m644 /src/docs/linux-port.md $doc/linux-port.md
cat > $doc/copyright <<EOF
photon2 (photon-linux). Wallpaper Engine is not included; photon reads the user's own install.

/usr/lib/photon2/libopenal.so.1: OpenAL Soft 1.21.1, LGPL-2.0-or-later (the text is in openal-soft-COPYING).
  Source: https://github.com/kcat/openal-soft/archive/refs/tags/1.21.1.tar.gz
  (sha256 8ac17e4e3b32c1af3d5508acfffb838640669b4274606b7892aa796ca9d7467f), built with
  -DALSOFT_EMBED_HRTF_DATA=ON and one change: common/alnumeric.h fastf2i returns
  static_cast<int>(__builtin_lrintf(f)) (round to nearest on every CPU, as 1.21.1 does on x86).
  Replace the library by putting another libopenal.so.1 in front with LD_LIBRARY_PATH.
/usr/lib/photon2/libstb.so.0: stb_image by Sean Barrett, public domain (Unlicense) or MIT.
EOF
cp /usr/share/common-licenses/LGPL-2 $doc/openal-soft-COPYING
# SingleMainWindow is a Desktop Entry 1.5 key; Debian 12's validator predates it.
validate() {
  desktop-file-validate "$1" && return
  grep -v '^SingleMainWindow=' "$1" > /tmp/v.desktop && desktop-file-validate /tmp/v.desktop \
    && echo "($(basename "$1"): valid apart from SingleMainWindow, which this desktop-file-validate does not know)"
}
validate $root/usr/share/applications/photon2.desktop
validate $root/usr/share/photon2/photon2-autostart.desktop
validate $root/usr/share/applications/photon2-kwin.desktop
echo "desktop-file-validate: all three entries ok"
# Every library resolves, and the private ones from /usr/lib/photon2 (RUNPATH comes before the loader cache).
ldd $root/usr/bin/photon-linux > /tmp/ldd.txt
if grep 'not found' /tmp/ldd.txt; then exit 1; fi
grep -E 'lib(openal|stb)\.so' /tmp/ldd.txt
[ "$(grep -cE "lib(openal|stb)\.so.* => $root/usr/bin/../lib/photon2/" /tmp/ldd.txt)" = 2 ] || { echo "private libraries not picked up"; exit 1; }

echo "== .deb"
# Depends: the packages owning every library the binary and the private libraries name (DT_NEEDED through the loader
# cache and dpkg -S, so the names follow the distribution of the build image), libc6 at least the newest GLIBC symbol
# version used, plus the Vulkan driver, the shader tools and the GStreamer plugins.
needed() { objdump -p "$1" | awk '/NEEDED/ {print $2}'; }
libs=$( (needed $root/usr/bin/photon-linux; for l in $root/usr/lib/photon2/*; do needed "$l"; done) | sort -u \
  | grep -vE '^lib(openal|stb)\.so' \
  | while read -r so; do ldconfig -p | awk -v s="$so" '$1 == s {print $NF; exit}'; done)
pkgs=$(for l in $libs; do dpkg -S "$(readlink -f "$l")" 2>/dev/null || dpkg -S "$l"; done | cut -d: -f1 | sort -u)
glibc=$(for f in $root/usr/bin/photon-linux $root/usr/lib/photon2/*; do objdump -T "$f"; done \
  | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1)
deps=$(echo "$pkgs" | sed "s/^libc6\$/libc6 (>= $glibc)/" | paste -sd, | sed 's/,/, /g')
deps="$deps, mesa-vulkan-drivers | vulkan-icd, glslang-tools, spirv-cross, gstreamer1.0-plugins-base, gstreamer1.0-plugins-good, gstreamer1.0-libav"
debver=$version-1~$distro
mkdir -p $root/DEBIAN
cat > $root/DEBIAN/control <<CONTROL
Package: photon2
Version: $debver
Architecture: $arch
Maintainer: Gediminas <268065279+GrandDukeGediminas@users.noreply.github.com>
Section: graphics
Priority: optional
Depends: $deps
Recommends: fonts-croscore, fonts-crosextra-carlito, fonts-crosextra-caladea, fonts-noto-core, fonts-noto-cjk, fonts-noto-color-emoji, pipewire-pulse | pulseaudio
Description: Wallpaper Engine wallpapers on the Linux desktop
 photon draws Wallpaper Engine scene, video and web wallpapers behind the desktop on X11 and on Wayland compositors
 with layer-shell, from the user's own Wallpaper Engine install and Steam Workshop items, with a status icon, a
 wallpaper browser, properties, playlists and settings. Start it at login with
 'systemctl --user enable --now photon2.service'.
CONTROL
echo "Installed-Size: $(du -sk $root/usr | cut -f1)" >> $root/DEBIAN/control
deb=$out/photon2_${debver}_$arch.deb
dpkg-deb --root-owner-group -Zxz --build $root "$deb" > /dev/null
rm -rf $root/DEBIAN
echo "deb: $deb"; echo "Depends: $deps"

[ "$distro" = ubuntu24.04 ] || exit 0

# The .rpm and the tarball also carry the shader tools: Fedora packages glslang but not spirv-cross. photon looks for
# them in /usr/bin, /usr/local/bin, then next to its private libraries (PhotonRender ShaderCompiler.defaultTool).
install -m755 "$(readlink -f /usr/bin/glslangValidator)" $root/usr/lib/photon2/glslangValidator
install -m755 "$(readlink -f /usr/bin/spirv-cross)" $root/usr/lib/photon2/spirv-cross
strip $root/usr/lib/photon2/glslangValidator $root/usr/lib/photon2/spirv-cross
# Ubuntu's libcurl versions its symbols CURL_OPENSSL_4; Fedora's has no version nodes, so the loader prints "no
# version information available" at every start. The rpm and tarball binary drops those requirements (unversioned
# references bind to any libcurl.so.4; elf-drop-verneed.py).
python3 "$(dirname "$0")/elf-drop-verneed.py" $root/usr/bin/photon-linux libcurl.so.4
if objdump -T $root/usr/bin/photon-linux | grep -q CURL_OPENSSL_4; then echo "libcurl symbol versions left"; exit 1; fi
cat >> $root/usr/share/doc/photon2/copyright <<EOF2
/usr/lib/photon2/glslangValidator (.rpm and tarball): glslang $(dpkg-query -W -f '${Version}' glslang-tools), BSD-3-Clause and others.
/usr/lib/photon2/spirv-cross (.rpm and tarball): SPIRV-Cross $(dpkg-query -W -f '${Version}' spirv-cross), Apache-2.0.
EOF2

echo "== .rpm"
# Library requirements come from rpm's ELF dependency generator (sonames with symbol versions, e.g.
# libc.so.6(GLIBC_2.38)(64bit): Fedora 40 or newer). The private libraries are neither provided nor required, and
# Debian's CURL_OPENSSL_4 symbol version is dropped: Fedora's libcurl has no version nodes, which the loader accepts.
top=/tmp/rpmtop; rm -rf $top; mkdir -p $top/SPECS $top/BUILD $top/RPMS
cat > $top/SPECS/photon2.spec <<SPEC
%global __provides_exclude_from ^/usr/lib/photon2/.*\$
%global __requires_exclude ^(lib(openal|stb)\\\\.so.*|libcurl\\\\.so\\\\.4\\\\(CURL_OPENSSL_4\\\\).*)\$
%global debug_package %{nil}
%global __strip /bin/true
Name: photon2
Version: $version
Release: 1
Summary: Wallpaper Engine wallpapers on the Linux desktop
License: MIT AND LGPL-2.0-or-later
BuildArch: $rarch
Recommends: mesa-vulkan-drivers, gstreamer1-plugins-base, gstreamer1-plugins-good, google-arimo-fonts, google-noto-sans-cjk-fonts, pipewire-pulseaudio
Suggests: gstreamer1-plugin-libav, gstreamer1-plugin-openh264
%description
photon draws Wallpaper Engine scene, video and web wallpapers behind the desktop on X11 and on Wayland compositors with
layer-shell, with a status icon, a wallpaper browser, properties, playlists and settings.
%install
cp -a $root/usr %{buildroot}/
%files
/usr/bin/photon-linux
/usr/lib/photon2
/usr/share/applications/photon2.desktop
/usr/share/applications/photon2-kwin.desktop
/usr/share/gnome-shell/extensions/photon2@photon2.github.io
/usr/share/photon2
/usr/lib/systemd/user/photon2.service
/usr/share/icons/hicolor/*/apps/photon2.*
/usr/share/metainfo/io.github.photon2.Photon.metainfo.xml
/usr/share/doc/photon2
SPEC
rpmbuild --define "_topdir $top" --define '_build_id_links none' -bb $top/SPECS/photon2.spec > /tmp/rpmbuild.log 2>&1 \
  || { tail -20 /tmp/rpmbuild.log; exit 1; }
cp $top/RPMS/*/*.rpm "$out/"
rpm=$(ls "$out"/photon2-"$version"-1.*.rpm)
echo "rpm: $rpm"; rpm -qpR "$rpm" | grep -v '^rpmlib' | paste -sd' ' | sed 's/^/Requires: /'
if rpm -qpR "$rpm" | grep -qE 'lib(openal|stb)'; then echo "rpm requires a private library"; exit 1; fi

tar -C $root -czf "$out/photon2-$version-$rarch.tar.gz" usr
echo "tarball: $out/photon2-$version-$rarch.tar.gz"
