#!/bin/sh
# Builds photon.app: scripts/macos/bundle.sh [version] [destination dir]   (defaults: PHOTON_VERSION_BASE, ./dist)
# A release build stamped with the version (photon_version.h), an Info.plist (menu-bar app, no Dock icon), a generated
# icon, and an ad-hoc signature. Settings live in the "photon2" defaults suite, so they don't depend on the bundle id.
#   PHOTON_UNIVERSAL=1        build arm64 + x86_64 (release builds)
#   PHOTON_HELPERS=<dir>      copy glslangValidator and spirv-cross from <dir> (scripts/macos/shader-tools.sh) into
#                             Contents/Helpers, so the app runs without Homebrew
set -e
repo=$(cd "$(dirname "$0")/../.." && pwd)
version=${1:-$(sed -n 's/^#define PHOTON_VERSION_BASE "\(.*\)"$/\1/p' "$repo/Sources/CPhotonVersion/include/photon_version.h")}
dest=${2:-$repo/dist}
cd "$repo"
if [ "$PHOTON_UNIVERSAL" = 1 ]; then
  swift build -c release --arch arm64 --arch x86_64 --product photon -Xcc "-DPHOTON_VERSION=\"$version\""
  bin=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/photon
else
  swift build -c release --product photon -Xcc "-DPHOTON_VERSION=\"$version\""
  bin=.build/release/photon
fi
work=$(mktemp -d)
app=$work/photon.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/photon"
if [ -n "$PHOTON_HELPERS" ]; then
  mkdir -p "$app/Contents/Helpers"
  for t in glslangValidator spirv-cross; do
    cp "$PHOTON_HELPERS/$t" "$app/Contents/Helpers/$t"
    codesign --force --sign - "$app/Contents/Helpers/$t"
  done
fi
swift "$repo/scripts/macos/make-icon.swift" "$work/photon.iconset"
iconutil -c icns "$work/photon.iconset" -o "$app/Contents/Resources/photon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>photon</string>
    <key>CFBundleDisplayName</key><string>photon</string>
    <key>CFBundleIdentifier</key><string>io.github.photon2.photon</string>
    <key>CFBundleExecutable</key><string>photon</string>
    <key>CFBundleIconFile</key><string>photon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
mkdir -p "$dest"
rm -rf "$dest/photon.app"
mv "$app" "$dest/photon.app"
rm -rf "$work"
echo "$dest/photon.app ($version)"
