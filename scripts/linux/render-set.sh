#!/bin/sh
# Renders the test set with the full renderer on lavapipe: scripts/linux/render-set.sh [config] [--mac DIR] [--tag NAME]
#   1280×720 at t = 2 s, PHOTON_SEED=1 → $PHOTON_LX_OUT/<tag>/lx_<id>.png (+ .log). Default tag: renders. gif-<n> ids
#   render the GIF wallpaper env.sh's prepare_gifs builds from item <n>'s preview.gif.
#   --mac DIR   also render each wallpaper on macOS with photon-tool right before the Linux render (DIR/<id>.png), so
#               wallpapers that show the time of day agree on the minute. Needs $PHOTON_TOOL (a macOS photon-tool).
#   Extra container environment (e.g. PHOTON_NATIVE_GS=1) goes in PHOTON_LX_DOCKER_ARGS ("-e PHOTON_NATIVE_GS=1").
. "$(dirname "$0")/env.sh"
config=release; mac=""; tag=renders
while [ $# -gt 0 ]; do
  case $1 in
    --mac) mac=$2; shift ;;
    --tag) tag=$2; shift ;;
    *) config=$1 ;;
  esac
  shift
done
ids=$(test_ids)
prepare_gifs $ids || exit 1
mkdir -p "$PHOTON_LX_OUT/$tag"
if [ -z "$mac" ]; then
  lx ". /scripts/in-container/lib.sh; for id in $ids; do timeout 900 /build/$config/photon-linux render \$(target \$id) /out/$tag/lx_\$id.png 2 1280 720 \
      > /out/$tag/lx_\$id.log 2>&1; echo \"\$id exit \$?\"; done"
else
  mkdir -p "$mac"
  for id in $ids; do
    PHOTON_SEED=1 "${PHOTON_TOOL:?set PHOTON_TOOL to a macOS photon-tool}" render "$(mac_target "$id")" "$mac/$id.png" 2 1280 720 > "$mac/$id.log" 2>&1
    lx ". /scripts/in-container/lib.sh; timeout 900 /build/$config/photon-linux render \$(target $id) /out/$tag/lx_$id.png 2 1280 720 \
        > /out/$tag/lx_$id.log 2>&1; echo '$id exit' \$?"
  done
fi
