#!/bin/sh
# Builds photon-linux in the container: scripts/linux/build.sh [debug|release]   (default release)
# The binary lands in $PHOTON_LX_BUILD/<config>/photon-linux (/build/<config>/photon-linux in the container); the full
# log in $PHOTON_LX_BUILD/build-<config>.log.
. "$(dirname "$0")/env.sh"
config=${1:-release}
lx "swift build --scratch-path /build -c $config --product photon-linux > /build/build-$config.log 2>&1; s=\$?; \
    grep -E 'error:' /build/build-$config.log | sort -u | head -40; tail -1 /build/build-$config.log; exit \$s"
