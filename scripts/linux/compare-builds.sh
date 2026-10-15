#!/bin/sh
# Renders the test set with two photon-linux builds back to back (per wallpaper, so clock text shows the same minute)
# and requires identical PNGs: scripts/linux/compare-builds.sh <other-build-dir> [config] [id…]
# <other-build-dir> is a SwiftPM scratch directory of a reference build (e.g. the last commit's), mounted at /base.
# Renders: $PHOTON_LX_OUT/compare/{base,lx}_<id>.png. Extra container environment for the *new* build only goes in
# PHOTON_COMPARE_ENV (e.g. "PHOTON_NATIVE_GS=1").
. "$(dirname "$0")/env.sh"
base=${1:?usage: compare-builds.sh <other-build-dir> [config] [id…]}; shift
config=${1:-release}; [ $# -gt 0 ] && shift
ids=${*:-$(test_ids)}
prepare_gifs $ids || exit 1
mkdir -p "$PHOTON_LX_OUT/compare"
PHOTON_LX_DOCKER_ARGS="-v $base:/base:ro" lx ". /scripts/in-container/lib.sh; cd /out/compare; for id in $ids; do \
  /base/$config/photon-linux render \$(target \$id) base_\$id.png 2 1280 720 > base_\$id.log 2>&1; \
  env $PHOTON_COMPARE_ENV /build/$config/photon-linux render \$(target \$id) lx_\$id.png 2 1280 720 > lx_\$id.log 2>&1; \
  if cmp -s base_\$id.png lx_\$id.png; then echo \"\$id identical\"; else echo \"\$id DIFFERENT\"; fi; done"
