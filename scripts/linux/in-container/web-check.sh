#!/bin/sh
# In the container: web wallpapers on WebKitGTK (scripts/linux/ci.sh --web, docs/linux-port.md §5.3).
#   web-check.sh <photon-linux> [macOS reference dir with webapi.log / webapi-cc.log / webapi*.png]
#   1. X11 (Xvfb): the API test page (scripts/linux/web-test/api) with a PipeWire test tone (440 Hz left, 2 kHz right),
#      a fake MPRIS player and a fullscreen test client: utilities, engine runtime, LED plugin, typed user properties,
#      general settings, fetchall and on-demand directory properties (files served from photon-web://local), the single
#      audio listener with the analyzer's 128 floats (peak bands 18 / 38), the five media listeners, pause and resume.
#      The page's lines that do not depend on the host's inputs must equal the macOS host's (photon-tool render).
#   2. The colour filter and flip general properties: the computed filter string equals macOS's, and sampled colours of
#      the filtered page are within 3 levels of the macOS render.
#   3. Wayland (sway, headless): the page in a gtk-layer-shell background surface, screenshotted with grim; a fullscreen
#      xdg_toplevel pauses it.
#   4. The install's web wallpapers def_corsair_collection and def_corsair_o_tron (projects/defaultprojects, when
#      mounted at /we/projects): load without script errors, draw, and corsair_o_tron receives audio frames.
bin=$1; ref=$2
here=$(dirname "$0"); api=$here/../web-test/api
t=/tmp/webcheck; rm -rf $t; mkdir -p $t/run $t/pics; chmod 700 $t/run
fail=0
note() { printf '\n-- %s\n' "$*"; }
export XDG_RUNTIME_DIR=$t/run WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 PHOTON_WEBDEBUG=1 NO_AT_BRIDGE=1
dbus-daemon --session --address=unix:path=$t/session.sock --fork --print-pid > $t/session.pid
export DBUS_SESSION_BUS_ADDRESS=unix:path=$t/session.sock
cp -R $api $t/api
python3 - $t <<'PY'
import sys
from PIL import Image
t = sys.argv[1]
Image.new('RGB', (4, 4), (255, 0, 0)).save(f'{t}/pics/a.png'); Image.new('RGB', (4, 4), (0, 255, 0)).save(f'{t}/pics/b.png')
Image.new('RGB', (300, 300), (200, 40, 40)).save(f'{t}/art.png')
PY
props="--property folder=$t/pics --property lazy=$t/pics"

# Audio: PipeWire with a null sink as the default output, a looping test tone into it (as audio-check.sh).
pipewire > $t/pipewire.log 2>&1 &
sleep 0.5
wireplumber > $t/wireplumber.log 2>&1 &
pipewire-pulse > $t/pipewire-pulse.log 2>&1 &
sleep 2
pactl load-module module-null-sink sink_name=photon_null sink_properties=device.description=photon-null > /dev/null
pactl set-default-sink photon_null
python3 - $t/tone.wav <<'PY'
import sys, wave, numpy as np
r = 48000; n = r * 60; t = np.arange(n) / r
s = np.stack([0.4 * np.sin(2 * np.pi * 440 * t), 0.4 * np.sin(2 * np.pi * 2000 * t)], 1)
w = wave.open(sys.argv[1], 'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(r)
w.writeframes((s * 32767).astype('<i2').tobytes()); w.close()
PY
pw-play --target photon_null $t/tone.wav > $t/pwplay.log 2>&1 & play=$!

Xvfb :99 -screen 0 1280x720x24 > /dev/null 2>&1 & xvfb=$!
sleep 1
export DISPLAY=:99

note "1. X11: the API page"
python3 $here/fake_dbus.py mpris 9 $t/art.png & fake=$!
( sleep 6; $bin desktop --test-client fullscreen 0 0 1280 720 --seconds 2 ) > $t/client.log 2>&1 &
( sleep 4; import -window root $t/x11.png ) & shot=$!
$bin desktop $t/api $props --seconds 11 --fullscreen pause --dump-text --eval 'photonAudioReport()' > $t/x11.log 2>&1 || fail=1
wait $fake $shot
grep -E '^web:|^playback' $t/x11.log | grep -v '^web: view 0 text' | head -20
python3 - $t/x11.log "$ref" <<'PY' || fail=1
import json, re, sys
log = open(sys.argv[1]).read().splitlines()
page = [l[len('photon web: log: '):] for l in log if l.startswith('photon web: log: ')]
ok = True
def check(c, what):
    global ok
    print(('  ok   ' if c else '  FAIL ') + what); ok &= bool(c)
def has(prefix): return [l for l in page if l.startswith(prefix)]
check('utils {"isScreensaver":false,"isWallpaper":true}' in page, 'wallpaperGetUtilities')
check('runtime object object' in page, "the engine's injected runtime (___wpxShared, wallpaperMediaIntegration)")
check('plugin led "1.2.0"' in page and 'plugin cue "1.2.0"' in page and 'cue devices 0' in page, 'LED plugin stubs')
check('user speed {"type":"slider","value":42} tint {"type":"color","value":"0.5 0.25 1"} folder directory/fetchall keys folder,lazy,speed,tint' in page,
      'typed user properties, keys in jsoncpp (sorted) order')
check('general fps,language,playbackaudio,playbackfocus,playbackfullscreen,playbackmaximized,playbackonbattery,playbacksleep,postprocessing' in page,
      'general settings (the macOS app\'s keys)')
check('dir folder a.png,b.png' in page, 'fetchall directory listed')
r = has('random lazy ')
check(r and r[0] in ('random lazy a.png', 'random lazy b.png') and 'img ok 4x4' in page, 'on-demand random file served from photon-web://local')
check('paused true' in page and 'paused false' in page and page.index('paused true') < page.index('paused false'),
      'fullscreen client pauses the page, closing it resumes')
check('media Status {"enabled":true}' in page, 'media status: enabled (session bus)')
check(any('"title":"First Song"' in l and '"artist":"Artist A"' in l for l in has('media Properties')), 'media properties from MPRIS')
check('media Playback {"state":1}' in page and 'media Playback {"state":2}' in page, 'media playback playing, then paused')
th = has('media Thumbnail data:image/png;base64, #C82727')
check(th, 'media thumbnail: PNG data URL, primary colour #C82727 (MediaColors of (200, 40, 40))')
check(any('"duration":200' in l for l in has('media Timeline')), 'media timeline (duration 200 s)')
rep = [l for l in log if l.startswith('audio calls ')]
m = re.match(r'audio calls (\d+) frames (\d+) peaks (-?\d+) (-?\d+)', rep[0]) if rep else None
if m:
    calls, frames, pl, pr = map(int, m.groups())
    print(f'  audio: {frames} frames, peaks {pl} / {pr}')
    check(calls == frames and frames >= 100, 'one audio listener (the second registration replaced the first, (1, 2) ignored), ~30 frames/s')
    check(abs(pl - 18) <= 1 and abs(pr - 38) <= 1, 'audio peak bands 18 (440 Hz left) and 38 (2 kHz right)')
else:
    check(False, 'audio report')
check('filter= transform=' in page, 'no colour filter without wec_e')
ref = sys.argv[2]
if ref:
    mac = [l.strip()[len('log: '):] for l in open(ref + '/webapi.log') if l.strip().startswith('log: ')]
    same = [l for l in mac if not l.startswith(('media ', 'general ', 'random ', 'paused'))]
    missing = [l for l in same if l not in page]
    check(not missing, f'{len(same)} host-independent lines equal to the macOS host' + (f': missing {missing}' if missing else ''))
print('web x11: ' + ('passed' if ok else 'FAILED'))
sys.exit(0 if ok else 1)
PY

note "2. colour filter and flip"
( sleep 4; import -window root $t/x11-cc.png ) & shot=$!
$bin desktop $t/api $props --seconds 5 --general '{"wec_e":true,"wec_hue":75,"wec_sa":20,"alignmentfliph":true}' > $t/x11-cc.log 2>&1 || fail=1
wait $shot
grep 'filter=' $t/x11-cc.log
python3 - $t "$ref" <<'PY' || fail=1
import sys, numpy as np
from PIL import Image
t, ref = sys.argv[1], sys.argv[2]
log = open(f'{t}/x11-cc.log').read()
want = "filter=contrast(1) brightness(1) saturate(0.4) hue-rotate(90deg) transform=scaleX(-1)"
ok = want in log
print(('  ok   ' if ok else '  FAIL ') + 'computed filter and transform: ' + want)
def px(p, x, y): return np.asarray(Image.open(p).convert('RGB'))[y, x].astype(int)
plain, cc = f'{t}/x11.png', f'{t}/x11-cc.png'
# Flipped: the blue half is now on the right. Sample away from the log text.
for x, y in ((100, 650), (1180, 650)):
    print(f'  ({x},{y}): plain {px(plain, x, y)}, filtered {px(cc, x, y)}')
if ref:
    for name, mine in (('webapi.png', plain), ('webapi-cc.png', cc)):
        for x, y in ((100, 650), (1180, 650)):
            a, b = px(f'{ref}/{name}', x, y), px(mine, x, y)
            good = int(np.abs(a - b).max()) <= 3
            print(('  ok   ' if good else '  FAIL ') + f'{name} ({x},{y}): macOS {a}, Linux {b}')
            ok &= good
print('web filter: ' + ('passed' if ok else 'FAILED'))
sys.exit(0 if ok else 1)
PY
kill $xvfb 2>/dev/null

note "3. Wayland (sway): gtk-layer-shell surface"
mkdir -p $t/xdgw; chmod 700 $t/xdgw
printf 'output HEADLESS-1 resolution 1280x720 position 0 0\n' > $t/sway.conf
( XDG_RUNTIME_DIR=$t/xdgw WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 sway -c $t/sway.conf > $t/sway.log 2>&1 ) & sway=$!
for i in 1 2 3 4 5 6 7 8 9 10; do [ -S $t/xdgw/wayland-1 ] && break; sleep 0.3; done
( export XDG_RUNTIME_DIR=$t/xdgw WAYLAND_DISPLAY=wayland-1; unset DISPLAY
  ( sleep 4; grim -o HEADLESS-1 $t/wayland.png ) &
  ( sleep 5; $bin desktop --wl-test-client fullscreen --seconds 2 ) > $t/wl-client.log 2>&1 &
  GDK_BACKEND=wayland $bin desktop $t/api $props --seconds 9 --fullscreen pause > $t/wayland.log 2>&1 )
kill $sway 2>/dev/null; wait $sway 2>/dev/null
grep -E '^web:|^playback' $t/wayland.log | head
python3 - $t <<'PY' || fail=1
import sys, numpy as np
from PIL import Image
t = sys.argv[1]
log = open(f'{t}/wayland.log').read()
ok = True
def check(c, what):
    global ok
    print(('  ok   ' if c else '  FAIL ') + what); ok &= bool(c)
check('WebKitGTK on wayland (layer-shell)' in log, 'GTK on Wayland with layer-shell')
check('log: paused true' in log and 'log: paused false' in log, 'fullscreen xdg_toplevel pauses the page, closing it resumes')
try:
    w = np.asarray(Image.open(f'{t}/wayland.png').convert('RGB')).astype(int)
    x = np.asarray(Image.open(f'{t}/x11.png').convert('RGB')).astype(int)
    for p in ((100, 650), (1180, 650)):
        a, b = x[p[1], p[0]], w[p[1], p[0]]
        check(np.abs(a - b).max() <= 1, f'grim pixel {p}: {b} (X11 {a})')
except Exception as e:
    check(False, f'grim screenshot: {e}')
print('web wayland: ' + ('passed' if ok else 'FAILED'))
sys.exit(0 if ok else 1)
PY

note "4. corpus web wallpapers"
Xvfb :98 -screen 0 1280x720x24 > /dev/null 2>&1 & xvfb=$!
sleep 1
export DISPLAY=:98
for p in corsair_collection corsair_o_tron; do
  d=/we/projects/defaultprojects/$p
  [ -d $d ] || { echo "$d not mounted: skipped"; continue; }
  ( sleep 7; import -window root $t/$p.png ) & shot=$!
  $bin desktop $d --seconds 9 --eval 'typeof window.__photonAudioListener === "function" ? "audio listener" : "no audio listener"' > $t/$p.log 2>&1 || fail=1
  wait $shot
  python3 - $t $p <<'PY' || fail=1
import sys, numpy as np
from PIL import Image
t, p = sys.argv[1], sys.argv[2]
log = open(f'{t}/{p}.log').read()
ok = True
def check(c, what):
    global ok
    print(('  ok   ' if c else '  FAIL ') + f'{p}: {what}'); ok &= bool(c)
check('loaded photon-web://wallpaper/' in log, 'page loaded')
errs = [l for l in log.splitlines() if 'uncaught' in l or 'log: error' in l.lower() or 'load failed' in l]
check(not errs, 'no script errors' + (f': {errs[:3]}' if errs else ''))
img = np.asarray(Image.open(f'{t}/{p}.png').convert('RGB')).astype(int)
check(img.std() > 10, f'drawn (pixel std {img.std():.1f})')
if p == 'corsair_o_tron':
    check('=\naudio listener' in log, 'registered an audio listener')
print(f'web {p}: ' + ('passed' if ok else 'FAILED'))
sys.exit(0 if ok else 1)
PY
done
kill $xvfb $play 2>/dev/null
kill $(cat $t/session.pid) 2>/dev/null
[ $fail = 0 ] && echo "web checks passed" || echo "web checks FAILED"
exit $fail
