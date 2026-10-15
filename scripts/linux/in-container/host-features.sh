#!/bin/sh
# In the container: the desktop-host features the macOS app has beyond drawing (scripts/linux/ci.sh --x11,
# docs/linux-port.md §5.4), on Xvfb with synthetic wallpapers (solid colours, a generated MPEG-4 video).
#   host-features.sh <photon-linux> [macOS transition references dir]
#   1. Transitions: `photon-linux transition` draws all 27 effects at progress 0.5 and 1; with references from
#      `photon-tool transition` (PHOTON_TRANSITION_SEED=7, `mac_<effect>_0.5.png`) each frame is compared with macOS:
#      equal, or for the effects whose pattern is the shader's sin hash, the same mean colour.
#   2. Switches inside a host (`load`): fade (red → blue through the mix, no black frame), −2 hold (red until blue, no
#      black), "none" between scenes (frozen, no black), "none" scene → video (cut), random from a pool; screenshots of
#      the root window every 0.1 s.
#   3. Stretch and clone across two monitors (--monitors): stretch must equal the headless render of the bounding box,
#      halves byte for byte; clone shows the first monitor's frame cover-fitted and mirrored on a --clone-flip monitor.
#      3b: a clone group on two of three monitors (--output, --clone-source on the third): the source equals the render,
#      the flipped member is the mirrored cover fit, the monitor outside the group is left alone.
#      3c: a split monitor (profile `splits`, nested): one host per region (--region), three running at once; each region
#      of the root window equals its wallpaper's headless render at the region's size, byte for byte.
#   4. The cursor: XTEST moves and clicks; the host logs the position in the scene's UV and the desktop press, and a
#      press on an application window is not a desktop press.
#   5. Application rules: a running process (condition 0, pause), a fullscreen window of a named class with a mute
#      rule (the global fullscreen rule then does not pause it).
#   6. "Another application plays audio": PipeWire + pipewire-pulse with a null sink; a tone from another process
#      pauses the host (--audio pause), the host's own sound objects do not.
#   7. pausevram: PHOTON_VRAM_TEST drives the budget: 90 % stops, 30 % resumes; the real VK_EXT_memory_budget reading
#      is printed.
#   8. A video wallpaper reports its loops (`video: ended`, the playlists' videosequence input).
bin=$1; ref=$2; t=/tmp/hostfeat; rm -rf $t; mkdir -p $t/run; chmod 700 $t/run
export XDG_RUNTIME_DIR=$t/run PHOTON_WE_ASSETS=${PHOTON_WE_ASSETS:-/we/assets}
fail=0
note() { printf '\n-- %s\n' "$*"; }
check() { if [ "$1" = 0 ]; then echo "PASS: $2"; else echo "FAIL: $2"; fail=1; fi; }
has() { grep -q "$2" "$1"; }

# Wallpapers: solid colour scenes and a 2 s video.
mkscene() {
  mkdir -p $t/wp/$1
  python3 - $t/wp/$1 "$2" <<'PY'
import json, sys
d, color = sys.argv[1], sys.argv[2]
scene = {"camera": {"center": "960 540 -1", "eye": "960 540 0", "up": "0 1 0"},
         "general": {"clearcolor": color, "clearenabled": True, "orthogonalprojection": {"width": 1920, "height": 1080}},
         "objects": [{"id": 1, "name": "bg", "image": "models/util/solidlayer.json", "color": color, "origin": "960 540 0", "size": "1920 1080"},
                     {"id": 2, "name": "mark", "image": "models/util/solidlayer.json", "color": "1 1 1", "origin": "300 540 0", "size": "200 1080"}],
         "version": 1}
json.dump(scene, open(f'{d}/scene.json', 'w'))
json.dump({"file": "scene.json", "title": d.split('/')[-1], "type": "scene"}, open(f'{d}/project.json', 'w'))
PY
}
mkscene red "0.86 0.24 0.16"
mkscene blue "0.12 0.24 0.78"
mkscene green "0.2 0.7 0.3"
mkdir -p $t/wp/video
gst-launch-1.0 -q videotestsrc num-buffers=60 pattern=smpte ! video/x-raw,width=320,height=180,framerate=30/1 ! videoconvert \
  ! avenc_mpeg4 ! mp4mux ! filesink location=$t/wp/video/clip.mp4 > /dev/null 2>&1
printf '{"file": "clip.mp4", "title": "video", "type": "video"}\n' > $t/wp/video/project.json

Xvfb :96 -screen 0 1280x720x24 > /dev/null 2>&1 & xvfb=$!
sleep 1
export DISPLAY=:96

# pixel <png> <x> <y>: "r g b"
pixel() { python3 -c "from PIL import Image; print(*Image.open('$1').convert('RGB').getpixel(($2, $3)))"; }

note "1. transition effects (photon-linux transition)"
mkdir -p $t/tr
for e in $(seq 0 26); do
  for p in 0.5 1; do
    PHOTON_TRANSITION_SEED=7 $bin transition color:220,60,40 color:30,60,200 $e $p $t/tr/lx_${e}_$p.png 320 180 > /dev/null 2>&1 \
      || { echo "FAIL: effect $e progress $p did not render"; fail=1; }
  done
done
python3 - $t/tr "$ref" <<'PY' || fail=1
import sys, os, numpy as np
from PIL import Image
d, ref = sys.argv[1], sys.argv[2]
new = np.array([30, 60, 200]); old = np.array([220, 60, 40])
ok = True; exact = 0; hashed = []
for e in range(27):
    a = np.asarray(Image.open(f'{d}/lx_{e}_0.5.png').convert('RGB')).astype(int)
    b = np.asarray(Image.open(f'{d}/lx_{e}_1.png').convert('RGB')).astype(int)
    mid = min(np.abs(a - new).max(axis=2).mean(), np.abs(a - old).max(axis=2).mean())
    line = f'effect {e:2d}: progress 0.5 mean diff to the nearer frame {mid:.1f}, progress 1 max diff to the new frame {np.abs(b - new).max()}'
    good = True
    if ref and os.path.exists(f'{ref}/mac_{e}_0.5.png'):
        m = np.asarray(Image.open(f'{ref}/mac_{e}_0.5.png').convert('RGB')).astype(int)
        diff = np.abs(a - m).max(axis=2)
        colour = np.abs(a.reshape(-1, 3).mean(0) - m.reshape(-1, 3).mean(0)).max()
        # Effects whose pattern comes from the shader's nrand (frac(sin(x) · 43758.5453)) differ per pixel between GPUs
        # (sin precision); the same picture is then checked by its mean colour.
        if diff.mean() < 0.05:
            exact += 1
            line += f'; vs macOS mean {diff.mean():.3f}'
        else:
            hashed.append(e)
            good = colour < 12
            line += f'; vs macOS mean {diff.mean():.1f} (sin-hash pattern), mean colour within {colour:.1f}'
    print(('PASS: ' if good else 'FAIL: ') + line)
    ok &= good
if ref:
    print(f'NOTE: {exact} effects equal to macOS (mean < 0.05), {len(hashed)} with GPU-dependent noise: {hashed}')
sys.exit(0 if ok else 1)
PY

# switch_run <name> <transition json> <from> <to> [extra host args]: a host on <from>, `load` <to> once it is ready,
# root-window screenshots every 0.1 s; the centre-right pixel of each (x 900) goes to $t/<name>.seq.
switch_run() {
  name=$1; tr=$2; from=$3; to=$4; shift 4
  mkfifo $t/$name.ctl
  ( $bin desktop $t/wp/$from --control --fps 30 --no-sound "$@" < $t/$name.ctl > $t/$name.log 2>&1 ) &
  hostpid=$!
  exec 7> $t/$name.ctl
  for i in $(seq 1 100); do has $t/$name.log 'host: ready' && break; sleep 0.1; done
  sleep 0.5
  printf 'load {"dir": "%s", "transition": %s}\n' "$t/wp/$to" "$tr" >&7
  : > $t/$name.seq
  for i in $(seq 1 30); do
    import -window root -crop 1x1+900+360 txt:- 2>/dev/null | tail -1 | sed -E 's/.*\(([0-9]+),([0-9]+),([0-9]+).*/\1 \2 \3/' >> $t/$name.seq
    sleep 0.1
  done
  echo quit >&7; exec 7>&-
  wait $hostpid
  rm -f $t/$name.ctl
  grep -E '^switch:' $t/$name.log | sed "s/^/$name: /"
}
# seq_check <name> <expect>: the colour sequence: never black; starts at the first colour, ends at the second,
# and with "mix" passes through a colour between them.
seq_check() {
  python3 - $t/$1.seq "$2" "$1" <<'PY'
import sys
seq = [tuple(int(v) for v in l.split()) for l in open(sys.argv[1]) if len(l.split()) == 3]
mode, name = sys.argv[2], sys.argv[3]
first, last = seq[0], seq[-1]
near = lambda c, r: max(abs(a - b) for a, b in zip(c, r)) <= 6
black = [c for c in seq if max(c) < 20]
mix = [c for c in seq if not near(c, first) and not near(c, last) and max(c) >= 20]
ok = len(seq) >= 10 and first[0] > first[2] and last[2] > last[0]   # red, then blue
if mode != "cut": ok &= not black
if mode == "mix": ok &= len(mix) >= 2
if mode in ("hold", "frozen"): ok &= not mix
print(f"{'PASS' if ok else 'FAIL'}: {name}: {len(seq)} samples, first {first}, last {last}, {len(mix)} between, {len(black)} black")
sys.exit(0 if ok else 1)
PY
}

note "2. switches inside one host (load)"
switch_run fade '{"transition": "0", "transitiontime": 1500}' red blue
seq_check fade mix || fail=1
has $t/fade.log 'effect 0 started' && has $t/fade.log 'finished'; check $? "fade: effect 0 started after the new scene loaded and finished"
switch_run hold '{"transition": "-2", "transitiontime": 1500}' red blue
seq_check hold hold || fail=1
has $t/hold.log 'hold shown'; check $? "-2: the old frame held while the new scene loads"
switch_run frozen '{"transition": "none"}' red blue
seq_check frozen frozen || fail=1
has $t/frozen.log 'frozen shown'; check $? "none between scenes: the old frame stays frozen"
switch_run random '{"transition": "random", "transitionpool": ["5", "7"], "transitiontime": 800}' red blue
grep -Eq 'effect (5|7), 800 ms' $t/random.log; check $? "random from the pool [5, 7]: $(grep -oE 'effect [0-9]+, 800 ms' $t/random.log | head -1)"
switch_run cut '{"transition": "none"}' red video
has $t/cut.log 'cut shown'; check $? "none from a scene to a video: the old wallpaper is cut (black until the video draws)"
switch_run toVideo '{"transition": "1", "transitiontime": 600}' red video
has $t/toVideo.log 'effect 1 started'; check $? "an effect from a scene to a video wallpaper"

note "3. stretch and clone across two monitors"
kill $xvfb; wait $xvfb 2>/dev/null
Xvfb :96 -screen 0 2560x720x24 > /dev/null 2>&1 & xvfb=$!
sleep 1
id=${PHOTON_FEATURES_SCENE:-2541606883}
PHOTON_WARMUP=0 $bin render $id $t/box.png 2 2560 720 > /dev/null 2>&1
PHOTON_WARMUP=0 $bin render $id $t/one.png 2 1280 720 > /dev/null 2>&1
$bin desktop $id --monitors 1280x720+0+0,1280x720+1280+0 --layout stretch --still --time 2 --seconds 1 --fps 2 --no-sound \
  --screenshot $t/stretch.png > $t/stretch.log 2>&1
$bin desktop $id --monitors 1280x720+0+0,1280x720+1280+0 --layout stretch --still --time 2 --seconds 1 --fps 2 --no-sound \
  --present readback --screenshot $t/stretch-rb.png > $t/stretch-rb.log 2>&1
$bin desktop $id --monitors 1280x720+0+0,640x360+1280+0 --layout clone --clone-flip monitor1 --still --time 2 --seconds 1 --fps 2 \
  --no-sound --screenshot $t/clone.png > $t/clone.log 2>&1
python3 - $t <<'PY' || fail=1
import sys, numpy as np
from PIL import Image
t = sys.argv[1]
img = lambda n: np.asarray(Image.open(f'{t}/{n}.png').convert('RGB')).astype(int)
ok = True
box = img('box')
for n in ('stretch', 'stretch-rb'):
    s = img(n)
    d = np.abs(s - box).max(axis=2)
    good = s.shape == box.shape and d.max() == 0
    print(f"{'PASS' if good else 'FAIL'}: stretch ({n}): two 1280x720 monitors vs the 2560x720 headless render: max diff {d.max()}")
    ok &= good
c = img('clone'); one = img('one')
a = c[:, :1280]
d = np.abs(a - one).max(axis=2)
good = d.max() == 0
print(f"{'PASS' if good else 'FAIL'}: clone source monitor equals the 1280x720 render: max diff {d.max()}")
ok &= good
# The 640x360 clone target: the source scaled by half (same aspect: the whole frame), mirrored.
small = np.asarray(Image.fromarray(one.astype(np.uint8)).resize((640, 360), Image.BILINEAR)).astype(int)[:, ::-1]
b = c[:360, 1280:1920]
m = np.abs(b - small).mean(); um = np.abs(b - small[:, ::-1]).mean()
good = m < 4 and um > m * 2
print(f"{'PASS' if good else 'FAIL'}: flipped clone target vs the mirrored, scaled source: mean diff {m:.2f} (unmirrored {um:.2f})")
ok &= good
sys.exit(0 if ok else 1)
PY

note "3b. a clone group on two of three monitors with a chosen source"
# The app's plan for a profile clone group (LayoutPlan.hostGroups, docs/re/09 §8.3): one host over the group's outputs,
# --clone-source the size / orientation rule's pick or the profile's `source`, --clone-flip the members' flips.
kill $xvfb; wait $xvfb 2>/dev/null
Xvfb :96 -screen 0 3200x720x24 > /dev/null 2>&1 & xvfb=$!
sleep 1
$bin desktop $id --monitors 1280x720+0+0,640x360+1280+0,1280x720+1920+0 --output monitor1,monitor2 --layout clone \
  --clone-source monitor2 --clone-flip monitor1 --still --time 2 --seconds 1 --fps 2 --no-sound --screenshot $t/group.png > $t/group.log 2>&1
grep -E '^output|^layout' $t/group.log
has $t/group.log '^layout clone over 2 output(s), source monitor2'; check $? "the host covers the group's two outputs, source monitor2"
python3 - $t <<'PY' || fail=1
import sys, numpy as np
from PIL import Image
t = sys.argv[1]
img = lambda n: np.asarray(Image.open(f'{t}/{n}.png').convert('RGB')).astype(int)
g = img('group'); one = img('one')
ok = True
d = np.abs(g[:, 1920:3200] - one).max()
good = d == 0
print(f"{'PASS' if good else 'FAIL'}: the clone source monitor2 (third monitor) equals the 1280x720 render: max diff {d}")
ok &= good
small = np.asarray(Image.fromarray(one.astype(np.uint8)).resize((640, 360), Image.BILINEAR)).astype(int)[:, ::-1]
b = g[:360, 1280:1920]
m = np.abs(b - small).mean(); um = np.abs(b - small[:, ::-1]).mean()
good = m < 4 and um > m * 2
print(f"{'PASS' if good else 'FAIL'}: flipped group member monitor1 vs the mirrored, scaled source: mean diff {m:.2f} (unmirrored {um:.2f})")
ok &= good
o = np.abs(g[:, :1280] - one).mean()
good = o > 10
print(f"{'PASS' if good else 'FAIL'}: monitor0, outside the group, is not drawn by the group's host: mean diff to the render {o:.1f}")
ok &= good
sys.exit(0 if ok else 1)
PY

note "3c. a split monitor: a host per region"
# The app's plan for `splits: {monitor0: {direction 0, position 0.5}, monitor0/R: {direction 1, position 0.5}}`
# (LayoutPlan.hostGroups, docs/re/09 §8.3): monitor0/L 640x720 at 0,0; monitor0/R/L 640x360 at 640,0; monitor0/R/R
# 640x360 at 640,360, each its own host and wallpaper.
kill $xvfb; wait $xvfb 2>/dev/null
Xvfb :96 -screen 0 1280x720x24 > /dev/null 2>&1 & xvfb=$!
sleep 1
PHOTON_WARMUP=0 $bin render $id $t/split-l.png 2 640 720 > /dev/null 2>&1
PHOTON_WARMUP=0 $bin render $t/wp/blue $t/split-rl.png 2 640 360 > /dev/null 2>&1
PHOTON_WARMUP=0 $bin render $id $t/split-rr.png 2 640 360 > /dev/null 2>&1
common="--monitors 1280x720+0+0 --still --time 2 --fps 2 --no-sound"
$bin desktop $id $common --region monitor0=0,0,640,720 --seconds 9 > $t/split-l.log 2>&1 & h1=$!
$bin desktop $t/wp/blue $common --region monitor0=640,0,640,360 --seconds 9 > $t/split-rl.log 2>&1 & h2=$!
sleep 4
$bin desktop $id $common --region monitor0=640,360,640,360 --seconds 2 --screenshot $t/split.png > $t/split-rr.log 2>&1
wait $h1 $h2
grep -h '^output' $t/split-l.log $t/split-rl.log $t/split-rr.log
has $t/split-rl.log '^output monitor0 640x360+640+0 primary (region of 1280x720+0+0)'; check $? "the host's window covers its region of the monitor"
python3 - $t <<'PY' || fail=1
import sys, numpy as np
from PIL import Image
t = sys.argv[1]
img = lambda n: np.asarray(Image.open(f'{t}/{n}.png').convert('RGB')).astype(int)
s = img('split'); ok = True
for name, (x, y, w, h) in (('split-l', (0, 0, 640, 720)), ('split-rl', (640, 0, 640, 360)), ('split-rr', (640, 360, 640, 360))):
    d = np.abs(s[y:y + h, x:x + w] - img(name)).max()
    good = d == 0
    print(f"{'PASS' if good else 'FAIL'}: region {w}x{h}+{x}+{y} equals its wallpaper rendered at {w}x{h}: max diff {d}")
    ok &= good
sys.exit(0 if ok else 1)
PY
kill $xvfb; wait $xvfb 2>/dev/null
Xvfb :96 -screen 0 1280x720x24 > /dev/null 2>&1 & xvfb=$!
sleep 1

note "4. the cursor (XInput 2 raw buttons, XTEST)"
PHOTON_POINTER_LOG=1 $bin desktop $t/wp/red --seconds 9 --fps 20 --no-sound > $t/pointer.log 2>&1 & host=$!
sleep 2.5
$bin desktop --pointer-test move 320 180 wait 0.3 click 640 360 wait 0.5 > /dev/null 2>&1
$bin desktop --test-client plain 800 100 400 300 --seconds 3 > /dev/null 2>&1 &
sleep 1
$bin desktop --pointer-test click 1000 250 wait 0.3 move 100 600 > /dev/null 2>&1
wait $host
grep '^pointer' $t/pointer.log
has $t/pointer.log 'pointer: 320,180 uv 0.250,0.250'; check $? "cursor position mapped to the output's UV"
[ "$(grep -c 'pointer: down' $t/pointer.log)" = 1 ] && has $t/pointer.log 'pointer: down at 640,360'
check $? "a click on the desktop is a press; a click on an application window is not"
has $t/pointer.log 'pointer: 100,600 uv 0.078,0.833'; check $? "the cursor is followed over other windows too"

note "5. application rules"
sleep 300 & sleeper=$!
rules='[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","application":"sleep","condition":0,"action":2}]'
$bin desktop $t/wp/red --seconds 5 --fps 10 --no-sound --app-rules "$rules" > $t/rule-running.log 2>&1 & host=$!
sleep 3; kill $sleeper; wait $host
grep '^playback' $t/rule-running.log
has $t/rule-running.log 'paused (application rule)' && has $t/rule-running.log 'resumed'
check $? "a running process with a pause rule pauses, and its end resumes"
rules='[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FE","application":"mygame","condition":3,"action":1}]'
$bin desktop $t/wp/red --seconds 6 --fps 10 --no-sound --fullscreen pause --app-rules "$rules" > $t/rule-fs.log 2>&1 & host=$!
sleep 1.5; $bin desktop --test-client fullscreen 0 0 1280 720 --seconds 2.5 --class mygame > /dev/null 2>&1
wait $host
grep '^playback' $t/rule-fs.log
has $t/rule-fs.log 'playback: mute' && ! has $t/rule-fs.log 'paused (fullscreen)'
check $? "a fullscreen window of an application with a mute rule mutes instead of the global fullscreen pause"
$bin desktop $t/wp/red --seconds 6 --fps 10 --no-sound --fullscreen pause > $t/rule-fs2.log 2>&1 & host=$!
sleep 1.5; $bin desktop --test-client fullscreen 0 0 1280 720 --seconds 2.5 --class othergame > /dev/null 2>&1
wait $host
has $t/rule-fs2.log 'paused (fullscreen)'; check $? "without a rule the same window pauses through the global rule"

note "6. another application plays audio"
dbus-daemon --session --address=unix:path=$t/session.sock --fork --print-pid > $t/session.pid
export DBUS_SESSION_BUS_ADDRESS=unix:path=$t/session.sock
pipewire > $t/pipewire.log 2>&1 &
sleep 0.5
wireplumber > $t/wireplumber.log 2>&1 &
pipewire-pulse > $t/pipewire-pulse.log 2>&1 &
sleep 2
pactl load-module module-null-sink sink_name=photon_null > /dev/null
pactl set-default-sink photon_null
python3 - $t/tone.wav <<'PY'
import sys, wave, numpy as np
r = 48000; t = np.arange(r * 6) / r
s = (0.3 * np.sin(2 * np.pi * 440 * t) * 32767).astype('<i2')
w = wave.open(sys.argv[1], 'wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(r); w.writeframes(s.tobytes()); w.close()
PY
mkdir -p $t/wp/sound/sounds; cp $t/tone.wav $t/wp/sound/sounds/tone.wav
python3 - $t/wp/sound <<'PY'
import json, sys
d = sys.argv[1]
scene = {"camera": {"center": "960 540 -1", "eye": "960 540 0", "up": "0 1 0"},
         "general": {"clearcolor": "0.1 0.2 0.3", "clearenabled": True, "orthogonalprojection": {"width": 1920, "height": 1080}},
         "objects": [{"id": 1, "name": "tone", "sound": ["sounds/tone.wav"], "playbackmode": "loop", "volume": 1, "origin": "960 540 0"}],
         "version": 1}
json.dump(scene, open(f'{d}/scene.json', 'w'))
json.dump({"file": "scene.json", "title": "sound", "type": "scene"}, open(f'{d}/project.json', 'w'))
PY
# The host's own sound objects through OpenAL's PulseAudio backend: photon's stream, not another application's.
PHOTON_AUDIO_STREAMS_LOG=1 ALSOFT_DRIVERS=pulse $bin desktop $t/wp/sound --seconds 9 --fps 10 --volume 100 --audio pause \
  --window-update-rate 500 > $t/audio.log 2>&1 & host=$!
sleep 3.5
if command -v paplay > /dev/null; then paplay $t/tone.wav & else pw-play $t/tone.wav & fi
player=$!
sleep 2.5; kill $player 2>/dev/null; wait $player 2>/dev/null
wait $host
grep -E '^playback|audio stream' $t/audio.log | sort | uniq -c | sort -rn | head -8
has $t/audio.log '(photon)'; check $? "the host's own OpenAL stream is seen and recognised as photon's"
has $t/audio.log 'paused (audio)' && has $t/audio.log 'resumed'
check $? "a tone from another process pauses the host (--audio pause) and it resumes when the tone ends"
kill $(cat $t/session.pid) 2>/dev/null
pkill -f pipewire-pulse; pkill wireplumber; pkill -x pipewire
unset DBUS_SESSION_BUS_ADDRESS

note "7. pausevram"
echo "100 1000" > $t/vram.txt
PHOTON_VRAM_TEST=$t/vram.txt $bin desktop $t/wp/red --seconds 6 --fps 10 --no-sound --pause-vram --window-update-rate 250 > $t/vram.log 2>&1 & host=$!
sleep 1.5; echo "900 1000" > $t/vram.txt; sleep 1.5; echo "300 1000" > $t/vram.txt
wait $host
grep -E '^playback|^vram' $t/vram.log
has $t/vram.log '^vram: .* MB in use (VK_EXT_memory_budget)'; check $? "VK_EXT_memory_budget reading"
has $t/vram.log 'VRAM exhausted (900 of 1000 MB)' && has $t/vram.log 'playback: stop' && has $t/vram.log 'resume from stop'
check $? "90 % of the budget stops the wallpaper, 30 % lets it run again"

note "8. video loops"
$bin desktop $t/wp/video --seconds 6 --fps 20 --no-sound > $t/video.log 2>&1
grep -E '^video' $t/video.log
has $t/video.log 'video: ended 1' && has $t/video.log 'video: ended 2'; check $? "the 2 s video reports its loops"

kill $xvfb 2>/dev/null
[ $fail = 0 ] && echo "host feature checks passed" || echo "host feature checks FAILED"
exit $fail
