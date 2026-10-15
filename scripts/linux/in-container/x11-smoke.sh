#!/bin/sh
# In the container: X11 host smoke test under Xvfb (scripts/linux/ci.sh --x11).
#   1. PhotonProto through the host (readback) must equal the headless prototype render exactly.
#   2. The full renderer through the Vulkan swapchain and through readback + XShmPutImage (--still: one scene time,
#      prepared like `render` with no warm-up frames), must both equal the headless render of the same frame.
bin=$1; id=${2:-2541606883}; t=/tmp/x11smoke; mkdir -p $t
Xvfb :99 -screen 0 1280x720x24 >/dev/null 2>&1 & xvfb=$!
sleep 1
export DISPLAY=:99
fail=0
$bin render-proto $id $t/proto.png 1 1280 720 >/dev/null 2>&1
$bin desktop $id --proto --seconds 2 --screenshot $t/proto-host.png > $t/proto.log 2>&1 || fail=1
$bin desktop $id --seconds 0.5 --fps 1 --still --time 2 --screenshot $t/swapchain.png > $t/sc.log 2>&1 || fail=1
$bin desktop $id --seconds 0.5 --fps 1 --still --time 2 --present readback --screenshot $t/readback.png > $t/rb.log 2>&1 || fail=1
grep -q 'Vulkan swapchain' $t/sc.log || { echo "swapchain path not used:"; cat $t/sc.log; fail=1; }
grep -q 'readback' $t/rb.log || { echo "readback path not used:"; cat $t/rb.log; fail=1; }
PHOTON_WARMUP=0 $bin render $id $t/headless.png 2 1280 720 >/dev/null 2>&1
python3 - $t <<'PY' || fail=1
import sys, numpy as np
from PIL import Image
t = sys.argv[1]
def img(n): return np.asarray(Image.open(f'{t}/{n}.png').convert('RGB')).astype(np.int16)
ok = True
for a, b in (('proto', 'proto-host'), ('headless', 'swapchain'), ('headless', 'readback'), ('swapchain', 'readback')):
    d = np.abs(img(a) - img(b)).max(axis=2)
    same = int(d.max()) == 0
    print(f'x11: {a} vs {b}: max diff {d.max()}, {np.sum(d > 0)} differing px' + ('' if same else '  FAIL'))
    ok &= same
sys.exit(0 if ok else 1)
PY
kill $xvfb
[ $fail = 0 ] && echo "x11 smoke test passed" || echo "x11 smoke test FAILED"
exit $fail
