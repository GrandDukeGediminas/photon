#!/bin/sh
# In the container: phase-4 audio and system-integration checks (scripts/linux/ci.sh --audio, docs/linux-port.md §7).
#   audio-check.sh <photon-linux> [macOS sound-ref dir]
#   1. sound-check: OpenAL Soft 1.21.1 (loopback device) against photon2's voice model, and against the macOS
#      reference from `photon-tool sound-ref` when given.
#   2. Spectrum capture of a test tone (440 Hz left, 2 kHz right) played into a PipeWire null sink: through the
#      PipeWire monitor stream and through the PulseAudio API (pipewire-pulse).
#   3. Sound objects in the X11 host: a synthetic scene with a looping, spatialised mono tone, rendered by OpenAL's wave
#      writer; a fullscreen test client pauses the output (playback rules) and the sound must stop and resume. Then the
#      same scene through OpenAL's PulseAudio backend into the null sink while the spectrum capture listens.
#   4. MPRIS: a fake player (fake_dbus.py) → `media-check` (ScriptMedia events).
#   5. Playback-rule signals: fake UPower / logind / screensaver → `system-check`, and the host's rule log.
bin=$1; ref=$2
here=$(dirname "$0")
t=/tmp/audiocheck; rm -rf $t; mkdir -p $t/run; chmod 700 $t/run
fail=0
note() { printf '\n-- %s\n' "$*"; }
export XDG_RUNTIME_DIR=$t/run
dbus-daemon --session --address=unix:path=$t/session.sock --fork --print-pid > $t/session.pid
# A private bus with the session policy stands in for the system bus (UPower and logind are faked on it).
dbus-daemon --config-file=/usr/share/dbus-1/session.conf --address=unix:path=$t/system.sock --fork --print-pid > $t/system.pid
export DBUS_SESSION_BUS_ADDRESS=unix:path=$t/session.sock DBUS_SYSTEM_BUS_ADDRESS=unix:path=$t/system.sock

note "1. sound-check"
$bin sound-check $ref --out $t/sound 2>&1 | grep -v '(EE)' || true
$bin sound-check $ref >/dev/null 2>&1 || fail=1

note "2. spectrum capture"
pipewire > $t/pipewire.log 2>&1 &
sleep 0.5
wireplumber > $t/wireplumber.log 2>&1 &
pipewire-pulse > $t/pipewire-pulse.log 2>&1 &
sleep 2
pactl load-module module-null-sink sink_name=photon_null sink_properties=device.description=photon-null >/dev/null
pactl set-default-sink photon_null
python3 - $t/tone.wav <<'PY'
import sys, wave, numpy as np
r = 48000; n = r * 30; t = np.arange(n) / r
s = np.stack([0.4 * np.sin(2 * np.pi * 440 * t), 0.4 * np.sin(2 * np.pi * 2000 * t)], 1)
w = wave.open(sys.argv[1], 'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(r)
w.writeframes((s * 32767).astype('<i2').tobytes()); w.close()
PY
pw-play --target photon_null $t/tone.wav > $t/pwplay.log 2>&1 & play=$!
sleep 1
PHOTON_AUDIO_BACKEND=pipewire $bin spectrum-check 4 440 2000 || fail=1
PHOTON_AUDIO_BACKEND=pulse $bin spectrum-check 4 440 2000 || fail=1
kill $play 2>/dev/null; wait $play 2>/dev/null

note "3. sound objects in the X11 host"
wp=$t/wp; mkdir -p $wp/sounds
python3 - $wp <<'PY'
import json, sys, wave, numpy as np
d = sys.argv[1]; r = 44100; n = r                                # 1 s, 44.1 kHz: OpenAL resamples to the device rate
s = 0.5 * np.sin(2 * np.pi * 440 * np.arange(n) / r)
w = wave.open(f'{d}/sounds/tone.wav', 'wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(r)
w.writeframes((s * 32767).astype('<i2').tobytes()); w.close()
scene = {"camera": {"center": "960 540 -1", "eye": "960 540 0", "up": "0 1 0"},
         "general": {"clearcolor": "0.1 0.2 0.3", "clearenabled": True, "orthogonalprojection": {"width": 1920, "height": 1080}},
         "objects": [{"id": 1, "name": "bg", "image": "models/util/solidlayer.json", "color": "0.2 0.4 0.6",
                      "origin": "960 540 0", "size": "1920 1080"},
                     {"id": 2, "name": "tone", "sound": ["sounds/tone.wav"], "playbackmode": "loop", "volume": 1,
                      "origin": "1800 540 0", "spatialization": True, "attenuation": 1, "mindistance": 1}],
         "version": 1}
json.dump(scene, open(f'{d}/scene.json', 'w'))
json.dump({"file": "scene.json", "title": "sound test", "type": "scene"}, open(f'{d}/project.json', 'w'))
PY
printf '[general]\ndrivers = wave\nfrequency = 48000\n[wave]\nfile = %s/host.wav\n' $t > $t/alsoft-wave.conf
Xvfb :98 -screen 0 1280x720x24 >/dev/null 2>&1 & xvfb=$!
sleep 1
export DISPLAY=:98
( sleep 3; $bin desktop --test-client fullscreen 0 0 1280 720 --seconds 2.5 ) > $t/client.log 2>&1 &
ALSOFT_CONF=$t/alsoft-wave.conf $bin desktop $wp --seconds 9 --fps 20 --volume 100 > $t/host-wave.log 2>&1 || fail=1
grep -E 'OpenAL|playback' $t/host-wave.log
python3 - $t/host.wav <<'PY' || fail=1
import sys, struct, numpy as np
b = open(sys.argv[1], 'rb').read()
fmt = None; data = None; i = 12
while i + 8 <= len(b):
    tag, size = b[i:i + 4], struct.unpack('<I', b[i + 4:i + 8])[0]
    if tag == b'fmt ': fmt = struct.unpack('<HHIIHH', b[i + 8:i + 24])
    if tag == b'data': data = b[i + 8:i + 8 + size] if size not in (0, 0xffffffff) else b[i + 8:]
    i += 8 + size + (size & 1) if size not in (0, 0xffffffff) else len(b)
tag, ch, rate, _, _, bits = fmt
x = np.frombuffer(data[:len(data) // (ch * bits // 8) * ch * bits // 8], '<f4' if bits == 32 and tag in (3, 0xfffe) else '<i2' if bits == 16 else '<f4')
x = x.reshape(-1, ch).astype(np.float64)
if bits == 16: x /= 32768
win = rate // 10
rms = np.sqrt((x[:len(x) // win * win].reshape(-1, win, ch) ** 2).mean(1))
loud = rms.max(1) > 0.02
print(f'host.wav: {ch} ch, {rate} Hz, {len(x) / rate:.2f} s; per 0.1 s loud: ' + ''.join('#' if l else '.' for l in loud))
sel = loud.nonzero()[0]
ok = len(sel) > 0
if ok:
    first, last = sel[0], sel[-1]
    gaps = [j for j in range(first, last) if not loud[j]]
    lr = rms[sel, 0].mean() / max(rms[sel, 1].mean(), 1e-9)
    f = np.abs(np.fft.rfft(x[first * win:(first + 5) * win, 1])); hz = np.argmax(f) * rate / (5 * win)
    print(f'host.wav: L/R level {lr:.3f} (source on the right), tone {hz:.0f} Hz, silent stretch inside the sound {len(gaps) / 10:.1f} s')
    ok = lr < 0.8 and abs(hz - 440) < 5 and len(gaps) >= 5 and loud[last] and loud[first]
print('host sound: ' + ('passed' if ok else 'FAILED'))
sys.exit(0 if ok else 1)
PY
# OpenAL through its PulseAudio backend (pipewire-pulse) into the null sink, heard by the spectrum capture.
$bin desktop $wp --seconds 7 --fps 20 --volume 100 > $t/host-pulse.log 2>&1 & host=$!
sleep 2
PHOTON_AUDIO_BACKEND=pipewire $bin spectrum-check 4 440 440 || fail=1
wait $host || fail=1
grep -E 'OpenAL' $t/host-pulse.log
kill $xvfb 2>/dev/null

note "4. MPRIS"
python3 -c "from PIL import Image; Image.new('RGB', (300, 300), (200, 40, 40)).save('$t/art.png')"
python3 $here/fake_dbus.py mpris 7 $t/art.png & fake=$!
sleep 0.5
$bin media-check 6 > $t/media.jsonl 2>&1
wait $fake
cat $t/media.jsonl
python3 - $t/media.jsonl <<'PY' || fail=1
import json, sys
ev = [json.loads(l) for l in open(sys.argv[1]) if l.startswith('{')]
def has(f): return [e for e in ev if e['flags'] & f]
ok = True
def check(c, what):
    global ok
    print(('  ok   ' if c else '  FAIL ') + what); ok &= bool(c)
first = ev[0] if ev else {}
check(first.get('flags', 0) & 0x10 and first.get('enabled'), 'status enabled with the player on the bus')
check(any(e['state'] == 1 for e in has(4)) and any(e['state'] == 2 for e in has(4)), 'playback: playing, then paused')
p = [e['props'] for e in has(1)]
check(p and p[0].get('title') == 'First Song' and p[0].get('artist') == 'Artist A' and p[0].get('albumTitle') == 'Album X'
      and p[0].get('genres') == 'Rock, Pop' and p[0].get('albumArtist') == 'Album Artist', 'properties of the first song')
check(any(q.get('title') == 'Second Song' and q.get('artist') == 'B1, B2' for q in p), 'properties change to the second song')
th = has(2)
check(th and th[0].get('thumb') and th[0].get('image') == [300, 300] and (th[0]['colors'][0] & 0xFFFFFF) == 0x2727C8,
      'thumbnail decoded (300×300), primary colour 0x2727C8 (MediaColors.dominant of (200, 40, 40))')
tl = has(8)
check(tl and abs(tl[0]['duration'] - 200) < 1e-3 and tl[0]['position'] >= 10, 'timeline: duration 200 s, position from 10 s')
check(any(e['position'] >= 99 for e in tl), 'timeline event on the seek to 100 s')
print('media: ' + ('passed' if ok else 'FAILED'))
sys.exit(0 if ok else 1)
PY

note "5. playback-rule signals"
python3 $here/fake_dbus.py system 8 & fake=$!
sleep 0.3
$bin system-check 8 > $t/system.txt 2>&1
wait $fake
cat $t/system.txt
python3 - $t/system.txt <<'PY' || fail=1
import re, sys
rows = [l for l in open(sys.argv[1]) if l.startswith('t=')]
def seen(pat): return any(re.search(pat, l) for l in rows)
checks = [('upower 1 on_battery 1', 'UPower OnBattery true'), ('upower 1 on_battery 0', 'UPower OnBattery back to false'),
          (r'locked 1', 'session Lock'), (r'preparing_sleep 1', 'PrepareForSleep(true)'),
          (r'screensaver 1', 'screensaver ActiveChanged(true)'), (r'sleep 2, lock 2, screensaver 2, battery 2', 'every event pair counted')]
ok = True
for pat, what in checks:
    s = seen(pat); ok &= s; print(('  ok   ' if s else '  FAIL ') + what)
print('system signals: ' + ('passed' if ok else 'FAILED'))
sys.exit(0 if ok else 1)
PY
Xvfb :97 -screen 0 640x360x24 >/dev/null 2>&1 & xvfb=$!
sleep 1
python3 $here/fake_dbus.py system 9 & fake=$!
DISPLAY=:97 $bin desktop $wp --proto --seconds 9 --fps 10 --battery pause --sleep pause > $t/host-rules.log 2>&1
wait $fake
kill $xvfb 2>/dev/null
grep playback: $t/host-rules.log
python3 - $t/host-rules.log <<'PY' || fail=1
import sys
log = [l.strip() for l in open(sys.argv[1]) if l.startswith('playback:')]
want = ['on battery', 'paused (battery)', 'session locked', 'session unlocked', 'sleep (PrepareForSleep): pause', 'wake',
        'on AC power', 'resumed']
ok = all(any(w in l for l in log) for w in want)
print('host rules: ' + ('passed' if ok else 'FAILED (want ' + ', '.join(w for w in want if not any(w in l for l in log)) + ')'))
sys.exit(0 if ok else 1)
PY

kill $(cat $t/session.pid) $(cat $t/system.pid) 2>/dev/null
pkill -x pipewire-pulse 2>/dev/null; pkill -x wireplumber 2>/dev/null; pkill -x pipewire 2>/dev/null
[ $fail = 0 ] && echo "audio and system checks passed" || echo "audio and system checks FAILED"
exit $fail
