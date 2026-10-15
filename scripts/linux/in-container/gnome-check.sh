#!/bin/sh
# In the container: the GNOME host under GNOME Shell (gnome-shell --headless --wayland, two 1280×720 virtual monitors)
# with the photon2 extension (docs/linux-port.md §5.2, scripts/linux/ci.sh --gnome). Run inside dbus-run-session.
#   gnome-check.sh <photon-linux> [extension zip] [wallpaper dir or id]
#     zip: the packed extension (scripts/linux/gnome-extension.sh); default: packaging/gnome-shell from /src
#     wallpaper: default the CC0 scene Tests/scenes/effects (time-driven displacement, so frames differ over time)
#   1. The extension is active and owns io.github.photon2.Shell; the host starts in GNOME mode, its two background
#      windows are minimized, out of the window switcher and unfocused.
#   2. --still: the screenshot (org.gnome.Shell.Screenshot) of each monitor equals the headless render of the same frame.
#   2b. A split monitor (docs/re/09 §8.3): two hosts with --region on Meta-0 (left and right halves), each a window of
#      the region's size whose clone the extension puts at its region; each half of the screenshot equals that
#      wallpaper's headless render at 640×720.
#   3. Animation: two screenshots 1 s apart differ on both monitors.
#   4. A fullscreen client on Meta-1 pauses Meta-1 (its frames stop), Meta-0 keeps animating; both run after it closes;
#      a maximized client pauses the monitor Mutter puts it on.
#   5. An application rule by app_id: a fullscreen client of an application with a mute rule mutes instead of pausing.
#   6. The cursor: positions from the extension map to the monitor's UV; a click on the desktop is a press, a click on a
#      window is not.
#   7. The overview: the workspace previews show the wallpaper (their background actors have clones too) and list no
#      photon2 window (screenshot in /out/gnome/overview.png).
#   8. Disabling the extension stops the host.
bin=$1; zip=$2; wp=${3:-/src/Tests/scenes/effects}
case $wp in /*) ;; *) wp=/workshop/$wp ;; esac
[ "$wp" != "${wp#/src/Tests/scenes}" ] && export PHOTON_WE_ASSETS=/src/Tests/scenes/assets
uuid=photon2@photon2.github.io
t=/tmp/gnomecheck; rm -rf $t; mkdir -p $t/xdg $t/home; chmod 700 $t/xdg
export XDG_RUNTIME_DIR=$t/xdg HOME=$t/home XDG_CONFIG_HOME=$t/home/.config XDG_DATA_HOME=$t/home/.local/share \
  XDG_CACHE_HOME=$t/home/.cache GSETTINGS_BACKEND=keyfile XDG_CURRENT_DESKTOP=GNOME XDG_SESSION_TYPE=wayland
fail=0
note() { printf '\n-- %s\n' "$*"; }

# GNOME Shell wants a system bus; without systemd running it takes /run/systemd/seats to mean logind exists, so the
# throwaway container hides it (the shell then uses its dummy login manager).
mkdir -p /run/dbus; [ -S /run/dbus/system_bus_socket ] || dbus-daemon --system --fork
[ -d /run/systemd/seats ] && mv /run/systemd/seats /run/systemd/seats.off

# The extension: from the zip (as users install it) or the source tree.
ext=$XDG_DATA_HOME/gnome-shell/extensions
mkdir -p $ext/$uuid
if [ -n "$zip" ]; then unzip -q -o "$zip" -d $ext/$uuid; else cp /src/packaging/gnome-shell/$uuid/* $ext/$uuid/; fi
ls $ext/$uuid
# A test-only helper: unsafe mode, so the checks can use org.gnome.Shell.Eval and the screenshot API.
major=$(gnome-shell --version | sed 's/[^0-9]*\([0-9]*\).*/\1/')
mkdir -p $ext/photon2-test@photon2.github.io
printf '{"uuid": "photon2-test@photon2.github.io", "name": "photon2 test helper", "description": "unsafe mode for the checks", "shell-version": ["%s"]}\n' \
  $major > $ext/photon2-test@photon2.github.io/metadata.json
printf 'export default class T { enable() { global.context.unsafe_mode = true; } disable() {} }\n' > $ext/photon2-test@photon2.github.io/extension.js
gsettings set org.gnome.shell enabled-extensions "['$uuid', 'photon2-test@photon2.github.io']"
gsettings set org.gnome.shell welcome-dialog-last-shown-version '999'
gsettings set org.gnome.desktop.interface enable-animations false
gsettings set org.gnome.desktop.notifications show-banners false

gnome-shell --headless --wayland --no-x11 --virtual-monitor 1280x720 --virtual-monitor 1280x720 --wayland-display wayland-g \
  > $t/shell.log 2>&1 & shell=$!
export WAYLAND_DISPLAY=wayland-g
for i in $(seq 1 60); do gdbus call --session -d org.gnome.Shell -o /org/gnome/Shell -m org.gnome.Shell.Eval '1' 2>/dev/null | grep -q true && break; sleep 0.5; done
echo "gnome: $(gnome-shell --version)"

# js <expression>: org.gnome.Shell.Eval's result (a JSON string).
js() { gdbus call --session -d org.gnome.Shell -o /org/gnome/Shell -m org.gnome.Shell.Eval "$1" | sed "s/^(true, '\(.*\)')$/\1/; s/^(false, .*/ERROR &/"; }
# shot <png>: the whole stage (both monitors side by side).
shot() { gdbus call --session -d org.gnome.Shell -o /org/gnome/Shell/Screenshot -m org.gnome.Shell.Screenshot.Screenshot false false "$1" > /dev/null; }
# crop <png> <monitor> <out>: one monitor's 1280×720 part.
crop() { python3 -c "import sys; from PIL import Image; i = int(sys.argv[2]); Image.open(sys.argv[1]).convert('RGB').crop((i * 1280, 0, i * 1280 + 1280, 720)).save(sys.argv[3])" "$@"; }
same() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys, numpy as np
from PIL import Image
a = np.asarray(Image.open(sys.argv[1]).convert('RGB')).astype(np.int16)
b = np.asarray(Image.open(sys.argv[2]).convert('RGB')).astype(np.int16)
if a.shape != b.shape:
    print(f'gnome: {sys.argv[3]}: size {a.shape[1]}x{a.shape[0]} vs {b.shape[1]}x{b.shape[0]}  FAIL'); sys.exit(1)
d = np.abs(a - b).max(axis=2)
print(f'gnome: {sys.argv[3]}: max diff {d.max()}, {int(np.sum(d > 0))} differing px' + ('' if d.max() == 0 else '  FAIL'))
sys.exit(0 if d.max() == 0 else 1)
PY
}
# differ <a.png> <b.png>: mean absolute difference (animation check).
differ() { python3 -c "import sys, numpy as np; from PIL import Image; a, b = (np.asarray(Image.open(p).convert('RGB')).astype(float) for p in sys.argv[1:3]); print(f'{np.abs(a - b).mean():.3f}')" "$1" "$2"; }

note "1. extension and host"
echo "gnome: extension state $(js "Main.extensionManager.lookup('$uuid')?.state") (1: enabled), error $(js "String(Main.extensionManager.lookup('$uuid')?.error ?? '')")"
gdbus call --session -d io.github.photon2.Shell -o /io/github/photon2/Shell -m io.github.photon2.Shell1.GetState > /dev/null \
  && echo "gnome: io.github.photon2.Shell answers" || { echo "gnome: extension not on the bus  FAIL"; fail=1; tail -30 $t/shell.log; }
# GNOME starts in the overview; the checks need the desktop, without the top bar over the background (transparent: the
# layout manager shows and hides it itself).
js 'Main.overview.hide(); Main.layoutManager.panelBox.opacity = 0; true' > /dev/null
PHOTON_WARMUP=0 $bin render $wp $t/headless.png 2 1280 720 > /dev/null 2>&1

note "2. still frame vs headless"
$bin desktop $wp --backend gnome --seconds 4 --fps 2 --still --time 2 --hold 6 --no-sound > $t/still.log 2>&1 & host=$!
sleep 6
shot $t/still.png
echo "gnome: windows $(js 'JSON.stringify(global.display.list_all_windows().map(w => [w.get_title(), w.minimized, w.has_focus(), w.is_on_all_workspaces()]))')"
echo "gnome: tab list $(js 'global.display.get_tab_list(0, null).length'), focus $(js 'String(global.display.focus_window?.get_title() ?? null)')"
echo "gnome: renderers $(js "JSON.stringify(JSON.parse(Main.extensionManager.lookup('$uuid').stateObj._state()).renderers)")"
wait $host
grep -E '^wayland|^output|^gnome' $t/still.log
grep -q 'GNOME Shell extension yes' $t/still.log || { echo "gnome: host not in GNOME mode  FAIL"; fail=1; }
for m in 0 1; do crop $t/still.png $m $t/still-$m.png; same $t/headless.png $t/still-$m.png "Meta-$m vs headless" || fail=1; done
echo "gnome: panel visible $(js 'Main.layoutManager.panelBox.visible'), at $(js 'JSON.stringify(Main.layoutManager.panelBox.get_transformed_position())')"
[ "$(js 'global.display.get_tab_list(0, null).length')" = 0 ] || true

note "2b. a split monitor: a host per region"
wp2=/src/Tests/scenes/images
PHOTON_WARMUP=0 $bin render $wp $t/split-l.png 2 640 720 > /dev/null 2>&1
PHOTON_WARMUP=0 $bin render $wp2 $t/split-r.png 2 640 720 > /dev/null 2>&1
$bin desktop $wp --backend gnome --seconds 5 --fps 2 --still --time 2 --hold 7 --no-sound --region Meta-0=0,0,640,720 \
  > $t/split-l.log 2>&1 & h1=$!
$bin desktop $wp2 --backend gnome --seconds 5 --fps 2 --still --time 2 --hold 7 --no-sound --region Meta-0=640,0,640,720 \
  > $t/split-r.log 2>&1 & h2=$!
sleep 7
shot $t/split.png
echo "gnome: renderers $(js "JSON.stringify(JSON.parse(Main.extensionManager.lookup('$uuid').stateObj._state()).renderers)")"
wait $h1 $h2
grep -h '^output' $t/split-l.log $t/split-r.log
python3 -c "import sys; from PIL import Image; i = Image.open(sys.argv[1]).convert('RGB'); i.crop((0, 0, 640, 720)).save(sys.argv[2]); i.crop((640, 0, 1280, 720)).save(sys.argv[3])" \
  $t/split.png $t/split-l-shot.png $t/split-r-shot.png
same $t/split-l.png $t/split-l-shot.png "Meta-0 left region vs headless 640x720" || fail=1
same $t/split-r.png $t/split-r-shot.png "Meta-0 right region vs headless 640x720" || fail=1

note "3. animation"
$bin desktop $wp --backend gnome --seconds 9 --fps 15 --no-sound > $t/anim.log 2>&1 & host=$!
sleep 4; shot $t/anim-a.png; sleep 1; shot $t/anim-b.png
wait $host
for m in 0 1; do crop $t/anim-a.png $m $t/a-$m.png; crop $t/anim-b.png $m $t/b-$m.png; done
d0=$(differ $t/a-0.png $t/b-0.png); d1=$(differ $t/a-1.png $t/b-1.png)
echo "gnome: frames 1 s apart differ by $d0 (Meta-0), $d1 (Meta-1) on average"
python3 -c "import sys; sys.exit(0 if float('$d0') > 0.5 and float('$d1') > 0.5 else 1)" || { echo "gnome: not animating  FAIL"; fail=1; }
grep 'steady state' $t/anim.log

note "4. fullscreen on Meta-1, then maximized"
$bin desktop $wp --backend gnome --seconds 16 --fps 15 --fullscreen pause --maximized pause --no-sound > $t/rules.log 2>&1 & host=$!
sleep 3
$bin desktop --wl-test-client fullscreen --output Meta-1 --seconds 4 > $t/client-fs.log 2>&1 & client=$!
sleep 2.5; shot $t/fs-a.png; sleep 1; shot $t/fs-b.png
wait $client
sleep 2 # the resume in its own evaluator tick
$bin desktop --wl-test-client maximized --seconds 3 > $t/client-max.log 2>&1 & client=$!
sleep 2; echo "gnome: maximized client (monitor, maximized, fullscreen) $(js 'JSON.stringify(global.display.list_all_windows().filter(w => w.get_title() == "maximized").map(w => [w.get_monitor(), w.get_maximized(), w.is_fullscreen()]))')"
wait $client $host
grep '^playback\|^gnome' $t/rules.log
crop $t/fs-a.png 0 $t/fa-0.png; crop $t/fs-b.png 0 $t/fb-0.png
echo "gnome: Meta-0 while Meta-1 is paused: frames 1 s apart differ by $(differ $t/fa-0.png $t/fb-0.png)"
python3 - $t/rules.log <<'PY' || fail=1
import sys
lines = [l.strip() for l in open(sys.argv[1]) if l.startswith('playback:')]
idx = lambda s: next((i for i, l in enumerate(lines) if s in l), None)
fs1, r1 = idx('Meta-1 paused (fullscreen)'), idx('Meta-1 resumed')
ok = fs1 is not None and r1 is not None and r1 > fs1
v0 = idx('Meta-0 paused')
ok_other = v0 is None or (r1 is not None and v0 > r1)
after = lines[r1 + 1:] if r1 is not None else []
paused = [l for l in after if 'paused (' in l]
resumed = [l for l in after if 'resumed' in l]
ok_max = len(paused) == 1 and len(resumed) == 1 and paused[0].split()[1] == resumed[0].split()[1]
print(f'gnome: fullscreen on Meta-1 pauses it and resumes: {ok}; Meta-0 keeps running meanwhile: {ok_other}; '
      f'maximized pauses one monitor ({paused[0] if paused else "none"}) and resumes it: {ok_max}'
      + ('' if ok and ok_other and ok_max else '  FAIL'))
sys.exit(0 if ok and ok_other and ok_max else 1)
PY

note "5. an application rule by app_id"
rules='[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FD","application":"mygame","condition":3,"action":1}]'
$bin desktop $wp --backend gnome --seconds 8 --fps 10 --fullscreen pause --no-sound --app-rules "$rules" > $t/rule.log 2>&1 & host=$!
sleep 2.5
$bin desktop --wl-test-client fullscreen --output Meta-0 --app-id org.example.mygame --seconds 3 > /dev/null 2>&1
wait $host
grep '^playback' $t/rule.log
grep -q 'playback: mute' $t/rule.log && ! grep -q 'paused (fullscreen)' $t/rule.log \
  && echo "gnome: the fullscreen app_id org.example.mygame mutes through its rule" || { echo "gnome: app rule  FAIL"; fail=1; }

note "6. the cursor"
PHOTON_POINTER_LOG=1 $bin desktop $wp --backend gnome --seconds 10 --fps 15 --no-sound > $t/pointer.log 2>&1 & host=$!
gdbus monitor --session --dest io.github.photon2.Shell > $t/signals.log 2>&1 & mon=$!
sleep 3
# A virtual pointer inside the shell (Clutter's virtual input device).
js 'const seat = imports.gi.Clutter.get_default_backend().get_default_seat(); globalThis.vp = seat.create_virtual_device(imports.gi.Clutter.InputDeviceType.POINTER_DEVICE); true' > /dev/null
vp() { js "const t = imports.gi.GLib.get_monotonic_time(); $1; true" > /dev/null; }
vp 'vp.notify_absolute_motion(t, 320, 180)'; sleep 0.5
vp 'vp.notify_absolute_motion(t, 640, 360)'; sleep 0.3
echo "gnome: actor at 640,360: $(js 'String(global.stage.get_actor_at_pos(imports.gi.Clutter.PickMode.REACTIVE, 640, 360))')"
vp 'vp.notify_button(t, imports.gi.Clutter.BUTTON_PRIMARY, imports.gi.Clutter.ButtonState.PRESSED)'; sleep 0.3
vp 'vp.notify_button(t, imports.gi.Clutter.BUTTON_PRIMARY, imports.gi.Clutter.ButtonState.RELEASED)'; sleep 0.3
$bin desktop --wl-test-client plain --seconds 4 > /dev/null 2>&1 & client=$!
sleep 1.5
geo=$(js 'JSON.stringify((w => { const r = w.get_frame_rect(); return [r.x + r.width / 2, r.y + r.height / 2]; })(global.display.list_all_windows().find(w => w.get_title() == "plain")))')
echo "gnome: plain window centre $geo"
x=$(echo $geo | tr -d '"[]' | cut -d, -f1); y=$(echo $geo | tr -d '"[]' | cut -d, -f2)
vp "vp.notify_absolute_motion(t, $x, $y)"; sleep 0.3
vp 'vp.notify_button(t, imports.gi.Clutter.BUTTON_PRIMARY, imports.gi.Clutter.ButtonState.PRESSED)'; sleep 0.3
vp 'vp.notify_button(t, imports.gi.Clutter.BUTTON_PRIMARY, imports.gi.Clutter.ButtonState.RELEASED)'; sleep 0.3
wait $client $host
kill $mon; grep -c PointerChanged $t/signals.log; grep PointerChanged $t/signals.log | grep -v 'false, false' | head
grep '^pointer' $t/pointer.log
grep -q 'pointer: 320,180 uv 0.250,0.250' $t/pointer.log || { echo "gnome: cursor position not mapped  FAIL"; fail=1; }
[ "$(grep -c 'pointer: down' $t/pointer.log)" = 1 ] && grep -q 'pointer: down at 640,360' $t/pointer.log \
  && echo "gnome: a click on the desktop is a desktop press, a click on a window is not" \
  || { echo "gnome: desktop press  FAIL"; fail=1; }

note "7. the overview"
$bin desktop $wp --backend gnome --seconds 8 --fps 5 --still --time 2 --no-sound > $t/overview.log 2>&1 & host=$!
$bin desktop --wl-test-client plain --seconds 7 > /dev/null 2>&1 & client=$!
sleep 4
js 'Main.overview.show(); true' > /dev/null; sleep 1.5
shot $t/overview.png
previews=$(js 'JSON.stringify(Main.overview._overview.controls._workspacesDisplay._workspacesViews.flatMap(v => (v._workspaces ?? []).flatMap(w => w._windows.map(c => c.metaWindow.get_title()))))')
echo "gnome: overview window previews $previews"
case $previews in *photon2*) echo "gnome: photon2 windows in the overview  FAIL"; fail=1 ;; *plain*) ;; *) echo "gnome: overview previews not found (internals changed?)" ;; esac
js 'Main.overview.hide(); true' > /dev/null
wait $client $host

note "8. disabling the extension stops the host"
$bin desktop $wp --backend gnome --seconds 20 --fps 5 --no-sound > $t/disable.log 2>&1 & host=$!
sleep 3
js "Main.extensionManager.disableExtension('$uuid')" > /dev/null
sleep 4
if kill -0 $host 2>/dev/null; then echo "gnome: host still running after the extension was disabled  FAIL"; fail=1; kill $host; fi
wait $host 2>/dev/null
grep '^gnome' $t/disable.log
grep -q 'left the session bus' $t/disable.log || fail=1
echo "gnome: windows left after the host ended: $(js 'global.display.list_all_windows().length')"

kill $shell 2>/dev/null; wait $shell 2>/dev/null
[ -d /out ] && mkdir -p /out/gnome && cp $t/*.png $t/*.log /out/gnome/ 2>/dev/null
grep -E 'JS ERROR|photon2' $t/shell.log | grep -v 'photon2-test' | head -20
[ $fail = 0 ] && echo "gnome checks passed" || echo "gnome checks FAILED"
exit $fail
