#!/bin/sh
# Frames per second on lavapipe for the test set: scripts/linux/bench.sh [config] [mode…]
#   modes: async sync readback (headless `photon-linux bench`), host (X11 desktop host under Xvfb, default
#   presentation), host-readback (host forced onto readback + XShmPutImage). Default: async sync readback host host-readback.
#   PHOTON_BENCH_FRAMES (default 60), PHOTON_BENCH_SECONDS (host run length, default 30), PHOTON_BENCH_IDS (ids file).
# Results: one line per wallpaper and mode on stdout and in $PHOTON_LX_OUT/bench-<config>.txt.
. "$(dirname "$0")/env.sh"
config=${1:-release}; [ $# -gt 0 ] && shift
modes=${*:-async sync readback host host-readback}
ids=$(PHOTON_TEST_IDS=${PHOTON_BENCH_IDS:-$here/wallpapers.txt} test_ids)
prepare_gifs $ids || exit 1
lx "PHOTON_BENCH_FRAMES=${PHOTON_BENCH_FRAMES:-60} PHOTON_BENCH_SECONDS=${PHOTON_BENCH_SECONDS:-30} \
    /scripts/in-container/bench-set.sh /build/$config/photon-linux '$modes' $ids" | tee "$PHOTON_LX_OUT/bench-$config.txt"
