#!/bin/sh
# In the container: native geometry shaders against the emulation (scripts/linux/ci.sh --native-gs).
#   native-gs-check.sh <photon-linux> <out-dir> <id…>
# Per wallpaper, back to back: the emulation (default), the emulation drawn through a pass-through geometry stage
# (PHOTON_NATIVE_GS=passthrough) and the native geometry stage (PHOTON_NATIVE_GS=1). The native render must equal the
# pass-through render exactly: same triangles, same attribute bits. Against the plain emulation the two differ only
# by what lavapipe's geometry-stage vertex path does to positions (docs/linux-port.md §2.2); that difference is
# printed, not gated. A scene whose own renders differ run to run (clock seconds, measured frame rate) is reported
# and not gated.
. /scripts/in-container/lib.sh
bin=$1; out=$2; shift 2
mkdir -p $out
fail=0
for id in "$@"; do
  t=$(target $id)
  $bin render $t $out/emu_$id.png 2 1280 720 > $out/emu_$id.log 2>&1
  PHOTON_NATIVE_GS=passthrough $bin render $t $out/pt_$id.png 2 1280 720 > $out/pt_$id.log 2>&1
  PHOTON_NATIVE_GS=1 $bin render $t $out/gs_$id.png 2 1280 720 > $out/gs_$id.log 2>&1
  n=$(grep -c 'uses the native geometry stage' $out/gs_$id.log)
  if [ "$n" = 0 ]; then echo "$id: no geometry-shader programs"; continue; fi
  # Some scenes (e.g. 3509243656) vary by a pixel between otherwise identical renders, on either path. Retry the
  # pair up to twice before deciding; a real geometry-stage difference repeats every time.
  for retry in 1 2; do
    cmp -s $out/pt_$id.png $out/gs_$id.png && break
    PHOTON_NATIVE_GS=passthrough $bin render $t $out/pt_$id.png 2 1280 720 > $out/pt_$id.log 2>&1
    PHOTON_NATIVE_GS=1 $bin render $t $out/gs_$id.png 2 1280 720 > $out/gs_$id.log 2>&1
  done
  if cmp -s $out/pt_$id.png $out/gs_$id.png; then r="native == pass-through (exact)"
  else
    # Scenes that show the time to the second or frames per second change between back-to-back renders: a second
    # pass-through render tells that apart from a geometry-stage difference.
    PHOTON_NATIVE_GS=passthrough $bin render $t $out/pt2_$id.png 2 1280 720 > $out/pt2_$id.log 2>&1
    if cmp -s $out/pt_$id.png $out/pt2_$id.png; then r="native != pass-through  FAIL"; fail=1
    else r="not checked: two pass-through renders differ (time-dependent scene)"; fi
  fi
  s=$(python3 -c "
import numpy as np; from PIL import Image
a=np.asarray(Image.open('$out/emu_$id.png').convert('RGB')).astype(int); b=np.asarray(Image.open('$out/gs_$id.png').convert('RGB')).astype(int)
d=np.abs(a-b).max(axis=2); print(f'{int((d>0).sum())} px differ from the emulation, max {d.max()}, {int((d>8).sum())} over 8')")
  echo "$id: $n native program(s); $r; $s"
done
exit $fail
