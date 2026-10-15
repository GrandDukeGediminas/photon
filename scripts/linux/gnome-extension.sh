#!/bin/sh
# Packs the photon2 GNOME Shell extension (packaging/gnome-shell/photon2@photon2.github.io, docs/linux-port.md §5.2)
# with `gnome-extensions pack` in the container: $PHOTON_LX_OUT/pkg/photon2@photon2.github.io.shell-extension.zip, the
# file users install with `gnome-extensions install --force <zip>` (or upload to extensions.gnome.org).
#   scripts/linux/gnome-extension.sh
. "$(dirname "$0")/env.sh"
mkdir -p "$PHOTON_LX_OUT/pkg"
lx 'set -e; d=/tmp/ext; uuid=photon2@photon2.github.io; mkdir -p $d; cp -r /src/packaging/gnome-shell/$uuid $d/
    python3 -c "import json, sys; m = json.load(open(sys.argv[1])); assert m[\"uuid\"] == sys.argv[2], m; print(\"metadata:\", m[\"name\"], \"for GNOME\", \", \".join(m[\"shell-version\"]))" $d/$uuid/metadata.json $uuid
    gnome-extensions pack --force --out-dir /out/pkg $d/$uuid
    unzip -l /out/pkg/$uuid.shell-extension.zip'
