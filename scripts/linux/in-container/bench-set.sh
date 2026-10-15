#!/bin/sh
# In the container: bench-set.sh <photon-linux> "<modes>" <id…>   (see scripts/linux/bench.sh)
. /scripts/in-container/lib.sh
bin=$1; modes=$2; shift 2
frames=${PHOTON_BENCH_FRAMES:-60}; seconds=${PHOTON_BENCH_SECONDS:-30}
Xvfb :99 -screen 0 1280x720x24 >/dev/null 2>&1 &
xvfb=$!
sleep 1
for id in "$@"; do
  t=$(target $id)
  for m in $modes; do
    case $m in
      async) r=$($bin bench $t $frames 1280 720 2>/dev/null | grep '^bench') ;;
      sync|readback) r=$($bin bench $t $frames 1280 720 --$m 2>/dev/null | grep '^bench') ;;
      host|host-readback)
        extra=""; [ $m = host-readback ] && extra="--present readback"
        out=$(DISPLAY=:99 timeout $((seconds + 300)) $bin desktop $t --seconds $seconds --fps 1000 $extra 2>&1)
        # A binary without --present prints the usage; run it plain then (the baseline is readback-only).
        if echo "$out" | grep -q '^usage'; then out=$(DISPLAY=:99 timeout $((seconds + 300)) $bin desktop $t --seconds $seconds --fps 1000 2>&1); fi
        r="host $id $m: $(echo "$out" | grep -E '^steady state|→' | tr '\n' ' ')" ;;
    esac
    echo "$id $m | $r"
  done
done
kill $xvfb
