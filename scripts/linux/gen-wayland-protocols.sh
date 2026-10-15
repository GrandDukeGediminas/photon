#!/bin/sh
# Regenerates Sources/CPhotonWayland/protocols (the Wayland protocol glue the layer-shell host uses) with the image's
# wayland-scanner: wlr-layer-shell, wlr-foreign-toplevel-management and wlr-virtual-pointer (the pointer test client)
# from vendor/wayland-protocols (wlroots' wlr-protocols, not packaged by Ubuntu), KDE's plasma-window-management and
# plasma-virtual-desktop (plasma-wayland-protocols 1.10.0, vendored next to them: the KWin rule inputs), xdg-shell,
# xdg-output, viewporter and fractional-scale from wayland-protocols.
#   scripts/linux/gen-wayland-protocols.sh
. "$(dirname "$0")/env.sh"
dst="$repo/Sources/CPhotonWayland/protocols"
mkdir -p "$dst" "$PHOTON_LX_OUT/wlgen"
lx 'set -e; o=/out/wlgen; rm -rf $o/*; P=/usr/share/wayland-protocols
for x in /src/vendor/wayland-protocols/wlr-layer-shell-unstable-v1.xml /src/vendor/wayland-protocols/wlr-foreign-toplevel-management-unstable-v1.xml \
         /src/vendor/wayland-protocols/wlr-virtual-pointer-unstable-v1.xml \
         /src/vendor/wayland-protocols/plasma-window-management.xml /src/vendor/wayland-protocols/plasma-virtual-desktop.xml \
         $P/stable/xdg-shell/xdg-shell.xml $P/unstable/xdg-output/xdg-output-unstable-v1.xml $P/stable/viewporter/viewporter.xml \
         $P/staging/fractional-scale/fractional-scale-v1.xml; do
  n=$(basename $x .xml)
  wayland-scanner client-header $x $o/$n-client-protocol.h
  wayland-scanner private-code $x $o/$n-protocol.c
done; wayland-scanner --version' && cp "$PHOTON_LX_OUT"/wlgen/* "$dst"/ && ls "$dst"
