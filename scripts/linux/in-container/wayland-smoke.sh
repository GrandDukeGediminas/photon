#!/bin/sh
# In the container: Wayland host checks under headless compositors (scripts/linux/ci.sh --wayland,
# docs/linux-port.md §5.2).
#   wayland-smoke.sh <photon-linux> [wallpaper id]
#   1. sway (wlroots, headless backend, pixman renderer), one 1280×720 output: the full renderer through the Vulkan
#      swapchain on the layer surface and through readback + wl_shm (--still: each surface shows one frame prepared like
#      `render`), screenshotted with grim, must equal the headless render of the same frame exactly.
#   2. Fractional scale: the output at 1920×1080 with scale 1.5 (logical 1280×720). The buffer must be 1920×1080
#      (wp_fractional_scale_v1 + wp_viewporter) and grim's capture equal the headless render at 1920×1080.
#   3. Hotplug: a second output (1024×576) created while the host runs (swaymsg create_output) gets its own surface,
#      equal to the headless render at that size; unplugging it removes the surface.
#   4. Pause rules from wlr-foreign-toplevel-management: a fullscreen test client (xdg_toplevel) pauses the output and
#      the output resumes when it closes; under labwc (a stacking compositor: sway has no maximized state) a maximized
#      client pauses it too.
#   5. The GNOME fallback (no layer-shell): --static-background writes one frame and sets it as
#      org.gnome.desktop.background picture-uri (gsettings keyfile backend); the PNG must equal the headless render.
#   6. Stretch across two outputs (--layout stretch): each output's grim capture equals its half of the headless render
#      of the 2560×720 bounding box, byte for byte.
#   7. Clone (--layout clone --clone-flip HEADLESS-2): the second output (1024×576) shows the first output's frame
#      cover-fitted and mirrored. 7b: a clone group on two of three outputs (--output, --clone-source HEADLESS-3): the
#      source equals the render, the flipped member is the mirrored cover fit, the third output is not drawn.
#      7c: a split output (profile `splits`, nested): three hosts at once, each a layer surface over its region
#      (--region: anchored top-left, region size, offset as margins); each region of grim's capture equals its
#      wallpaper's headless render at the region size.
#   8. The cursor through wlr-virtual-pointer: positions in the output's UV, a click on the background surface is a
#      desktop press, a click on a window is not.
#   9. A switch inside the host (`load`, fade): red → blue through the mix, never black (grim samples).
#  10. An application rule by app_id: a fullscreen toplevel of an application with a mute rule mutes instead of the
#      global fullscreen pause.
bin=$1; id=${2:-2541606883}; t=/tmp/wlsmoke; rm -rf $t; mkdir -p $t/xdg; chmod 700 $t/xdg
export XDG_RUNTIME_DIR=$t/xdg WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
fail=0
note() { printf '\n-- %s\n' "$*"; }

# start_sway <config text>: starts sway, sets WAYLAND_DISPLAY and SWAYSOCK.
start_sway() {
  printf '%s\n' "$1" > $t/sway.conf
  rm -f $XDG_RUNTIME_DIR/wayland-* $XDG_RUNTIME_DIR/sway-ipc.*
  sway -c $t/sway.conf > $t/sway.log 2>&1 & compositor=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -S $XDG_RUNTIME_DIR/wayland-1 ] && break; sleep 0.3; done
  export WAYLAND_DISPLAY=wayland-1
  SWAYSOCK=$(ls $XDG_RUNTIME_DIR/sway-ipc.*.sock 2>/dev/null | head -1); export SWAYSOCK
}
stop_compositor() { kill $compositor 2>/dev/null; wait $compositor 2>/dev/null; }

# same <a.png> <b.png> <label>: exact pixel equality (RGB).
same() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys, numpy as np
from PIL import Image
a = np.asarray(Image.open(sys.argv[1]).convert('RGB')).astype(np.int16)
b = np.asarray(Image.open(sys.argv[2]).convert('RGB')).astype(np.int16)
if a.shape != b.shape:
    print(f'wayland: {sys.argv[3]}: size {a.shape[1]}x{a.shape[0]} vs {b.shape[1]}x{b.shape[0]}  FAIL'); sys.exit(1)
d = np.abs(a - b).max(axis=2)
print(f'wayland: {sys.argv[3]}: max diff {d.max()}, {int(np.sum(d > 0))} differing px' + ('' if d.max() == 0 else '  FAIL'))
sys.exit(0 if d.max() == 0 else 1)
PY
}

# host <log> <args…>: runs the host in the background (pid in $host).
host() { log=$1; shift; $bin desktop $id --backend wayland "$@" > $log 2>&1 & host=$!; }

note "1. sway, 1280x720: swapchain and readback vs headless"
PHOTON_WARMUP=0 $bin render $id $t/headless.png 2 1280 720 > /dev/null 2>&1
PHOTON_WARMUP=0 $bin render $id $t/headless-1080.png 2 1920 1080 > /dev/null 2>&1
PHOTON_WARMUP=0 $bin render $id $t/headless-576.png 2 1024 576 > /dev/null 2>&1
start_sway "output HEADLESS-1 resolution 1280x720 position 0 0"
for mode in swapchain readback; do
  host $t/$mode.log --seconds 3 --fps 2 --still --time 2 --present $mode --hold 4
  sleep 5; grim -o HEADLESS-1 $t/$mode.png; wait $host || fail=1
  grep -E '^wayland:|^output' $t/$mode.log
  same $t/headless.png $t/$mode.png "$mode vs headless" || fail=1
done
grep -q 'Vulkan swapchain' $t/swapchain.log || { echo "swapchain path not used"; fail=1; }
grep -q 'readback, wl_shm' $t/readback.log || { echo "readback path not used"; fail=1; }
stop_compositor

note "2. fractional scale 1.5"
start_sway "output HEADLESS-1 resolution 1920x1080 position 0 0 scale 1.5"
host $t/scale.log --seconds 3 --fps 2 --still --time 2 --hold 4
sleep 5; grim -o HEADLESS-1 $t/scale.png; wait $host || fail=1
grep -E '^output' $t/scale.log
grep -q 'configured 1280x720 logical, scale 1.5, buffer 1920x1080' $t/scale.log || { echo "buffer not sized for scale 1.5"; fail=1; }
same $t/headless-1080.png $t/scale.png "scale 1.5 vs headless 1920x1080" || fail=1
stop_compositor

note "3. output hotplug"
start_sway "output HEADLESS-1 resolution 1280x720 position 0 0
output HEADLESS-2 resolution 1024x576 position 1280 0"
host $t/hotplug.log --seconds 9 --fps 2 --still --time 2
sleep 3; swaymsg create_output > /dev/null; sleep 3
grim -o HEADLESS-2 $t/hotplug-2.png
swaymsg output HEADLESS-2 unplug > /dev/null; sleep 1.5
wait $host || fail=1
grep -E '^output' $t/hotplug.log
grep -q 'output HEADLESS-2 1024x576+1280+0 (integer scale 1) added' $t/hotplug.log || { echo "hotplugged output not picked up"; fail=1; }
grep -Eq 'output HEADLESS-2 (removed|: layer surface closed)' $t/hotplug.log || { echo "unplugged output not removed"; fail=1; }
same $t/headless-576.png $t/hotplug-2.png "hotplugged HEADLESS-2 vs headless" || fail=1
stop_compositor

note "4. pause rules (foreign-toplevel)"
start_sway "output HEADLESS-1 resolution 1280x720 position 0 0"
host $t/rules-fs.log --seconds 9 --fps 10 --fullscreen pause --no-sound
( sleep 3; $bin desktop --wl-test-client fullscreen --seconds 3 ) > $t/client-fs.log 2>&1
wait $host
grep -E 'playback|foreign' $t/rules-fs.log
grep -q 'HEADLESS-1 paused (fullscreen)' $t/rules-fs.log && grep -q 'HEADLESS-1 resumed' $t/rules-fs.log \
  || { echo "fullscreen client did not pause and resume the output"; fail=1; }
stop_compositor
if command -v labwc > /dev/null; then
  mkdir -p $t/labwc
  printf '<?xml version="1.0"?>\n<labwc_config></labwc_config>\n' > $t/labwc/rc.xml
  rm -f $XDG_RUNTIME_DIR/wayland-*
  labwc -C $t/labwc > $t/labwc.log 2>&1 & compositor=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -S $XDG_RUNTIME_DIR/wayland-0 ] && break; sleep 0.3; done
  export WAYLAND_DISPLAY=wayland-0
  host $t/rules-max.log --seconds 9 --fps 10 --maximized pause --no-sound
  ( sleep 3; $bin desktop --wl-test-client maximized --seconds 3 ) > $t/client-max.log 2>&1
  wait $host
  grep -E 'playback|^output|^wayland' $t/rules-max.log
  grep -q 'paused (maximized)' $t/rules-max.log && grep -Eq 'resumed' $t/rules-max.log \
    || { echo "maximized client did not pause and resume the output (labwc)"; fail=1; }
  stop_compositor
fi

note "5. GNOME fallback: still frame as org.gnome.desktop.background"
export XDG_CONFIG_HOME=$t/config XDG_CACHE_HOME=$t/cache GSETTINGS_BACKEND=keyfile
$bin desktop $id --static-background 1280x720 --time 2 > $t/static.log 2>&1 || fail=1
cat $t/static.log | grep 'static background'
uri=$(gsettings get org.gnome.desktop.background picture-uri)
echo "picture-uri $uri, picture-options $(gsettings get org.gnome.desktop.background picture-options)"
[ "$uri" = "'file://$t/cache/photon2/background.png'" ] || { echo "picture-uri not set"; fail=1; }
same $t/headless.png $t/cache/photon2/background.png "static background vs headless" || fail=1

unset XDG_CONFIG_HOME XDG_CACHE_HOME GSETTINGS_BACKEND

note "6. stretch across two outputs"
PHOTON_WARMUP=0 $bin render $id $t/box.png 2 2560 720 > /dev/null 2>&1
PHOTON_WARMUP=0 $bin render $id $t/headless.png 2 1280 720 > /dev/null 2>&1
start_sway "output HEADLESS-1 resolution 1280x720 position 0 0
output HEADLESS-2 resolution 1280x720 position 1280 0"
swaymsg create_output > /dev/null; sleep 1
host $t/stretch.log --seconds 3 --fps 2 --still --time 2 --hold 4 --layout stretch --no-sound
sleep 5; grim -o HEADLESS-1 $t/stretch-1.png; grim -o HEADLESS-2 $t/stretch-2.png; wait $host
grep -E '^output|^layout' $t/stretch.log
python3 - $t <<'PY' || fail=1
import sys, numpy as np
from PIL import Image
t = sys.argv[1]
box = np.asarray(Image.open(f'{t}/box.png').convert('RGB')).astype(int)
ok = True
for i, x in ((1, 0), (2, 1280)):
    s = np.asarray(Image.open(f'{t}/stretch-{i}.png').convert('RGB')).astype(int)
    d = np.abs(s - box[:, x:x + 1280]).max(axis=2)
    good = s.shape == (720, 1280, 3) and d.max() == 0
    print(f"wayland: stretch HEADLESS-{i} vs its half of the 2560x720 render: max diff {d.max()}" + ('' if good else '  FAIL'))
    ok &= good
sys.exit(0 if ok else 1)
PY
stop_compositor

note "7. clone with a flipped output"
start_sway "output HEADLESS-1 resolution 1280x720 position 0 0
output HEADLESS-2 resolution 1024x576 position 1280 0"
swaymsg create_output > /dev/null; sleep 1
host $t/clone.log --seconds 3 --fps 2 --still --time 2 --hold 4 --layout clone --clone-flip HEADLESS-2 --no-sound
sleep 5; grim -o HEADLESS-1 $t/clone-1.png; grim -o HEADLESS-2 $t/clone-2.png; wait $host
python3 - $t <<'PY' || fail=1
import sys, numpy as np
from PIL import Image
t = sys.argv[1]
one = np.asarray(Image.open(f'{t}/headless.png').convert('RGB')).astype(int)
a = np.asarray(Image.open(f'{t}/clone-1.png').convert('RGB')).astype(int)
b = np.asarray(Image.open(f'{t}/clone-2.png').convert('RGB')).astype(int)
ok = np.abs(a - one).max() == 0
print(f"wayland: clone source HEADLESS-1 vs the 1280x720 render: max diff {np.abs(a - one).max()}" + ('' if ok else '  FAIL'))
small = np.asarray(Image.fromarray(one.astype(np.uint8)).resize((1024, 576), Image.BILINEAR)).astype(int)
m, um = np.abs(b - small[:, ::-1]).mean(), np.abs(b - small).mean()
good = b.shape == (576, 1024, 3) and m < 4 and um > 2 * m
print(f"wayland: flipped clone HEADLESS-2 vs the mirrored, scaled source: mean diff {m:.2f} (unmirrored {um:.2f})" + ('' if good else '  FAIL'))
sys.exit(0 if ok and good else 1)
PY
stop_compositor

note "7b. a clone group on two of three outputs, source chosen"
# A profile clone group (docs/re/09 §8.3): the app runs one host over the group's outputs with --clone-source.
start_sway "output HEADLESS-1 resolution 1280x720 position 0 0
output HEADLESS-2 resolution 1024x576 position 1280 0
output HEADLESS-3 resolution 1280x720 position 2304 0"
swaymsg create_output > /dev/null; swaymsg create_output > /dev/null; sleep 1
host $t/group.log --seconds 3 --fps 2 --still --time 2 --hold 4 --output HEADLESS-2,HEADLESS-3 --layout clone \
  --clone-source HEADLESS-3 --clone-flip HEADLESS-2 --no-sound
sleep 5; grim -o HEADLESS-1 $t/group-1.png; grim -o HEADLESS-2 $t/group-2.png; grim -o HEADLESS-3 $t/group-3.png; wait $host
grep -E '^output|^layout' $t/group.log
python3 - $t <<'PY' || fail=1
import sys, numpy as np
from PIL import Image
t = sys.argv[1]
one = np.asarray(Image.open(f'{t}/headless.png').convert('RGB')).astype(int)
img = lambda n: np.asarray(Image.open(f'{t}/group-{n}.png').convert('RGB')).astype(int)
a, b, c = img(1), img(2), img(3)
ok = c.shape == one.shape and np.abs(c - one).max() == 0
print(f"wayland: group clone source HEADLESS-3 vs the 1280x720 render: max diff {np.abs(c - one).max() if c.shape == one.shape else 'shape'}" + ('' if ok else '  FAIL'))
small = np.asarray(Image.fromarray(one.astype(np.uint8)).resize((1024, 576), Image.BILINEAR)).astype(int)
m, um = np.abs(b - small[:, ::-1]).mean(), np.abs(b - small).mean()
good = b.shape == (576, 1024, 3) and m < 4 and um > 2 * m
print(f"wayland: flipped group member HEADLESS-2 vs the mirrored, scaled source: mean diff {m:.2f} (unmirrored {um:.2f})" + ('' if good else '  FAIL'))
o = np.abs(a - one).mean()
out = o > 10
print(f"wayland: HEADLESS-1, outside the group, has no surface of this host: mean diff to the render {o:.1f}" + ('' if out else '  FAIL'))
sys.exit(0 if ok and good and out else 1)
PY
stop_compositor

# Solid-colour scenes for the switch and cursor checks.
for c in "red 0.86 0.24 0.16" "blue 0.12 0.24 0.78"; do
  set -- $c
  mkdir -p $t/wp/$1
  printf '{"camera": {"center": "960 540 -1", "eye": "960 540 0", "up": "0 1 0"}, "general": {"clearcolor": "%s %s %s", "clearenabled": true, "orthogonalprojection": {"width": 1920, "height": 1080}}, "objects": [{"id": 1, "name": "bg", "image": "models/util/solidlayer.json", "color": "%s %s %s", "origin": "960 540 0", "size": "1920 1080"}], "version": 1}\n' \
    $2 $3 $4 $2 $3 $4 > $t/wp/$1/scene.json
  printf '{"file": "scene.json", "title": "%s", "type": "scene"}\n' $1 > $t/wp/$1/project.json
done

note "7c. a split output: a host per region"
PHOTON_WARMUP=0 $bin render $id $t/split-l.png 2 640 720 > /dev/null 2>&1
PHOTON_WARMUP=0 $bin render $t/wp/blue $t/split-rl.png 2 640 360 > /dev/null 2>&1
PHOTON_WARMUP=0 $bin render $id $t/split-rr.png 2 640 360 > /dev/null 2>&1
start_sway "output HEADLESS-1 resolution 1280x720 position 0 0"
common="--backend wayland --still --time 2 --fps 2 --no-sound --seconds 3 --hold 5"
$bin desktop $id $common --region HEADLESS-1=0,0,640,720 > $t/split-l.log 2>&1 & h1=$!
$bin desktop $t/wp/blue $common --region HEADLESS-1=640,0,640,360 > $t/split-rl.log 2>&1 & h2=$!
$bin desktop $id $common --region HEADLESS-1=640,360,640,360 > $t/split-rr.log 2>&1 & h3=$!
sleep 6; grim -o HEADLESS-1 $t/split.png; wait $h1 $h2 $h3
grep -h '^output' $t/split-l.log $t/split-rl.log $t/split-rr.log
python3 - $t <<'PY' || fail=1
import sys, numpy as np
from PIL import Image
t = sys.argv[1]
img = lambda n: np.asarray(Image.open(f'{t}/{n}.png').convert('RGB')).astype(int)
s = img('split'); ok = True
for name, (x, y, w, h) in (('split-l', (0, 0, 640, 720)), ('split-rl', (640, 0, 640, 360)), ('split-rr', (640, 360, 640, 360))):
    d = np.abs(s[y:y + h, x:x + w] - img(name)).max()
    print(f"wayland: split region {w}x{h}+{x}+{y} vs its wallpaper rendered at {w}x{h}: max diff {d}" + ('' if d == 0 else '  FAIL'))
    ok &= d == 0
sys.exit(0 if ok else 1)
PY
stop_compositor

note "8. the cursor (wlr-virtual-pointer)"
start_sway "output HEADLESS-1 resolution 1280x720 position 0 0"
PHOTON_POINTER_LOG=1 $bin desktop $t/wp/red --backend wayland --seconds 10 --fps 20 --no-sound > $t/pointer.log 2>&1 & host=$!
sleep 2.5
$bin desktop --wl-pointer-test 1280 720 move 320 180 wait 0.3 click 640 360 wait 0.5 > $t/vp1.log 2>&1
$bin desktop --wl-test-client plain --seconds 4 > /dev/null 2>&1 &
sleep 1.5
$bin desktop --wl-pointer-test 1280 720 click 900 400 wait 0.3 > $t/vp2.log 2>&1
wait $host
grep '^pointer' $t/pointer.log
grep -q 'pointer: 320,180 uv 0.250,0.250' $t/pointer.log || { echo "wayland: cursor position not mapped  FAIL"; fail=1; }
[ "$(grep -c 'pointer: down' $t/pointer.log)" = 1 ] && grep -q 'pointer: down at 640,360' $t/pointer.log \
  && echo "wayland: a click on the background is a desktop press, a click on a window is not" \
  || { echo "wayland: desktop press  FAIL"; fail=1; }
stop_compositor

note "9. a switch inside the host (fade)"
start_sway "output HEADLESS-1 resolution 1280x720 position 0 0"
mkfifo $t/ctl
( $bin desktop $t/wp/red --backend wayland --control --fps 30 --no-sound < $t/ctl > $t/switch.log 2>&1 ) & host=$!
exec 7> $t/ctl
for i in $(seq 1 100); do grep -q 'host: ready' $t/switch.log && break; sleep 0.1; done
sleep 0.5
printf 'load {"dir": "%s", "transition": {"transition": "0", "transitiontime": 1500}}\n' $t/wp/blue >&7
: > $t/switch.seq
for i in $(seq 1 25); do
  grim -g "900,360 1x1" - 2>/dev/null | python3 -c "import sys, io; from PIL import Image; print(*Image.open(io.BytesIO(sys.stdin.buffer.read())).convert('RGB').getpixel((0, 0)))" >> $t/switch.seq
  sleep 0.1
done
echo quit >&7; exec 7>&-; wait $host
grep '^switch' $t/switch.log
python3 - $t/switch.seq <<'PY' || fail=1
import sys
seq = [tuple(int(v) for v in l.split()) for l in open(sys.argv[1]) if len(l.split()) == 3]
first, last = seq[0], seq[-1]
near = lambda c, r: max(abs(a - b) for a, b in zip(c, r)) <= 6
mix = [c for c in seq if not near(c, first) and not near(c, last)]
black = [c for c in seq if max(c) < 20]
ok = first[0] > first[2] and last[2] > last[0] and len(mix) >= 2 and not black
print(f"wayland: fade: {len(seq)} samples, first {first}, last {last}, {len(mix)} between, {len(black)} black" + ('' if ok else '  FAIL'))
sys.exit(0 if ok else 1)
PY
stop_compositor

note "10. an application rule by app_id"
start_sway "output HEADLESS-1 resolution 1280x720 position 0 0"
rules='[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FD","application":"mygame","condition":3,"action":1}]'
host $t/rule.log --seconds 8 --fps 10 --fullscreen pause --no-sound --app-rules "$rules"
( sleep 2.5; $bin desktop --wl-test-client fullscreen --app-id org.example.mygame --seconds 3 ) > /dev/null 2>&1
wait $host
grep '^playback' $t/rule.log
grep -q 'playback: mute' $t/rule.log && ! grep -q 'paused (fullscreen)' $t/rule.log \
  && echo "wayland: the fullscreen app_id org.example.mygame mutes through its rule" || { echo "wayland: app rule  FAIL"; fail=1; }
stop_compositor

[ $fail = 0 ] && echo "wayland smoke test passed" || echo "wayland smoke test FAILED"
exit $fail
