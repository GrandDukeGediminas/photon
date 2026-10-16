#!/bin/sh
# In the container: the Wayland host under KWin 5.27 (kwin_wayland --virtual, two 1280×720 outputs), with the playback
# rules fed by org_kde_plasma_window_management (docs/linux-port.md §5.2, scripts/linux/ci.sh --kde).
#   kde-check.sh <photon-linux> [wallpaper dir or id]   (default: the CC0 scene Tests/scenes/effects)
#   1. KWin grants org_kde_plasma_window_management only to clients whose .desktop entry lists it: with the packaged
#      photon2-kwin.desktop (Exec=/usr/bin/photon-linux, X-KDE-Wayland-Interfaces) installed the host binds it.
#   2. The layer-shell surfaces through the Vulkan swapchain: KWin's screenshot of each output (ScreenShot2) equals the
#      headless render of the same frame.
#   2b. A split output (docs/re/09 §8.3): two hosts with --region on Virtual-0 (layer surfaces anchored top-left with
#      the region's size and offset as margins); each half of the screenshot equals that wallpaper's headless render at
#      640×720.
#   3. A fullscreen client on Virtual-1 pauses Virtual-1 and not Virtual-0, and both run again when it closes; a
#      maximized client pauses the output KWin puts it on and not the other.
#   4. An application rule by app_id: a fullscreen toplevel of an application with a mute rule mutes instead of pausing.
#   5. Without the .desktop entry KWin hides the protocol and the host says so.
#   6. Virtual desktops (org_kde_plasma_virtual_desktop_management): a maximized window pauses its output; switching to
#      a second desktop (KWin's VirtualDesktopManager over D-Bus) resumes it while the window stays open; switching back
#      pauses it again. (Without panels the active maximized window covers its output, so the log names the pause
#      "fullscreen", as the X11 probe's geometry rule does.)
bin=$1; wp=${2:-/src/Tests/scenes/effects}
case $wp in /*) ;; *) wp=/workshop/$wp ;; esac
[ -d /src/Tests/scenes/assets ] && [ "$wp" != "${wp#/src/Tests/scenes}" ] && export PHOTON_WE_ASSETS=/src/Tests/scenes/assets
t=/tmp/kdecheck; rm -rf $t; mkdir -p $t/xdg $t/home/.local/share/applications; chmod 700 $t/xdg
export XDG_RUNTIME_DIR=$t/xdg HOME=$t/home XDG_DATA_HOME=$t/home/.local/share XDG_CURRENT_DESKTOP=KDE
# KService's application cache (ksycoca, which KWin reads the .desktop entries from) per run.
export XDG_CACHE_HOME=$t/cache-noentry
# photon-linux where the packages put it (the throwaway container's /usr/bin): KWin compares the entry's Exec path with
# /proc/<pid>/exe, so a symlink or another directory does not match.
cp "$(readlink -f $bin)" /usr/bin/photon-linux
fail=0
note() { printf '\n-- %s\n' "$*"; }

# waitfor <log> <pattern> [count] [seconds]: until the log has <count> (default 1) lines matching the pattern. KWin checks
# every new client against the .desktop entries, which takes longer the larger the executable (about 1 s per connection
# for the 62 MB packaged binary, and the Vulkan loader's device-select layer opens two more connections), so the steps
# wait for the host instead of sleeping a fixed time.
waitfor() {
  n=${3:-1}; end=$(( $(date +%s) + ${4:-40} ))
  while [ "$(grep -c -- "$2" "$1" 2>/dev/null)" -lt "$n" ]; do
    [ "$(date +%s)" -ge $end ] && { echo "kde: timed out waiting for '$2' in $(basename "$1")"; return 1; }
    sleep 0.2
  done
}
# ready <log>: the host configured both outputs (swapchains made); then a moment for its first frame to be presented.
ready() { waitfor "$1" ': configured' 2 && sleep 1.5; }

# start_kwin: KWin with two virtual outputs on its own session bus (started by the caller: dbus-run-session).
start_kwin() {
  rm -f $XDG_RUNTIME_DIR/wayland-k*
  KWIN_SCREENSHOT_NO_PERMISSION_CHECKS=1 kwin_wayland --virtual --no-lockscreen --no-global-shortcuts --no-kactivities \
    --width 1280 --height 720 --output-count 2 --socket wayland-k > $t/kwin.log 2>&1 & compositor=$!
  for i in $(seq 1 30); do [ -S $XDG_RUNTIME_DIR/wayland-k ] && break; sleep 0.3; done
  sleep 1
  export WAYLAND_DISPLAY=wayland-k
}
stop_kwin() { kill $compositor 2>/dev/null; wait $compositor 2>/dev/null; }

# same <a.png> <b.png> <label>: exact pixel equality (RGB).
same() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys, numpy as np
from PIL import Image
a = np.asarray(Image.open(sys.argv[1]).convert('RGB')).astype(np.int16)
b = np.asarray(Image.open(sys.argv[2]).convert('RGB')).astype(np.int16)
if a.shape != b.shape:
    print(f'kde: {sys.argv[3]}: size {a.shape[1]}x{a.shape[0]} vs {b.shape[1]}x{b.shape[0]}  FAIL'); sys.exit(1)
d = np.abs(a - b).max(axis=2)
print(f'kde: {sys.argv[3]}: max diff {d.max()}, {int(np.sum(d > 0))} differing px' + ('' if d.max() == 0 else '  FAIL'))
sys.exit(0 if d.max() == 0 else 1)
PY
}

kwin_version=$(kwin_wayland --version 2>/dev/null | head -1)
echo "kde: $kwin_version"
PHOTON_WARMUP=0 photon-linux render $wp $t/headless.png 2 1280 720 > /dev/null 2>&1

note "5. without the .desktop entry"
start_kwin
photon-linux desktop $wp --backend wayland --seconds 2 --fps 2 --still --time 2 --no-sound > $t/noentry.log 2>&1
grep '^wayland' $t/noentry.log
grep -q 'KWin did not grant org_kde_plasma_window_management' $t/noentry.log \
  && echo "kde: without X-KDE-Wayland-Interfaces the protocol is withheld and the host says so" \
  || { echo "kde: no message without the .desktop entry  FAIL"; fail=1; }
stop_kwin

# The packaged entry (Exec=/usr/bin/photon-linux, X-KDE-Wayland-Interfaces=…), with a fresh application cache.
cp /src/packaging/linux/photon2-kwin.desktop $XDG_DATA_HOME/applications/photon2-kwin.desktop
export XDG_CACHE_HOME=$t/cache
grep '^X-KDE-Wayland-Interfaces' $XDG_DATA_HOME/applications/photon2-kwin.desktop

note "1, 2. protocol granted; both outputs through the swapchain vs headless"
start_kwin
photon-linux desktop --list-outputs --backend wayland
photon-linux desktop $wp --backend wayland --seconds 60 --fps 2 --still --time 2 --hold 60 --no-sound > $t/still.log 2>&1 & host=$!
ready $t/still.log || fail=1
python3 /scripts/in-container/kwin_screenshot.py Virtual-0 $t/shot-0.png || fail=1
python3 /scripts/in-container/kwin_screenshot.py Virtual-1 $t/shot-1.png || fail=1
kill $host; wait $host
grep -E '^wayland|^output' $t/still.log
grep -q 'org_kde_plasma_window_management yes' $t/still.log && grep -q 'window rules from org_kde_plasma_window_management' $t/still.log \
  || { echo "kde: org_kde_plasma_window_management not bound  FAIL"; fail=1; }
grep -q 'Vulkan swapchain' $t/still.log || { echo "kde: swapchain path not used  FAIL"; fail=1; }
same $t/headless.png $t/shot-0.png "Virtual-0 vs headless" || fail=1
same $t/headless.png $t/shot-1.png "Virtual-1 vs headless" || fail=1

note "2b. a split output: a host per region"
wp2=/src/Tests/scenes/images
PHOTON_WARMUP=0 photon-linux render $wp $t/split-l.png 2 640 720 > /dev/null 2>&1
PHOTON_WARMUP=0 photon-linux render $wp2 $t/split-r.png 2 640 720 > /dev/null 2>&1
photon-linux desktop $wp --backend wayland --seconds 60 --fps 2 --still --time 2 --hold 60 --no-sound --region Virtual-0=0,0,640,720 \
  > $t/split-l.log 2>&1 & h1=$!
photon-linux desktop $wp2 --backend wayland --seconds 60 --fps 2 --still --time 2 --hold 60 --no-sound --region Virtual-0=640,0,640,720 \
  > $t/split-r.log 2>&1 & h2=$!
ready $t/split-l.log || fail=1
ready $t/split-r.log || fail=1
python3 /scripts/in-container/kwin_screenshot.py Virtual-0 $t/split.png || fail=1
kill $h1 $h2; wait $h1 $h2
grep -h '^output' $t/split-l.log $t/split-r.log
python3 -c "import sys; from PIL import Image; i = Image.open(sys.argv[1]).convert('RGB'); i.crop((0, 0, 640, 720)).save(sys.argv[2]); i.crop((640, 0, 1280, 720)).save(sys.argv[3])" \
  $t/split.png $t/split-l-shot.png $t/split-r-shot.png
same $t/split-l.png $t/split-l-shot.png "Virtual-0 left region vs headless 640x720" || fail=1
same $t/split-r.png $t/split-r-shot.png "Virtual-0 right region vs headless 640x720" || fail=1

note "3. fullscreen on Virtual-1, then maximized"
photon-linux desktop $wp --backend wayland --seconds 90 --fps 10 --fullscreen pause --maximized pause --no-sound > $t/rules.log 2>&1 & host=$!
ready $t/rules.log || fail=1
photon-linux desktop --wl-test-client fullscreen --output Virtual-1 --seconds 3 > $t/client-fs.log 2>&1
waitfor $t/rules.log 'resumed' 1 || fail=1
photon-linux desktop --wl-test-client maximized --seconds 3 > $t/client-max.log 2>&1
waitfor $t/rules.log 'resumed' 2 10
kill $host; wait $host
grep '^playback' $t/rules.log
python3 - $t/rules.log <<'PY' || fail=1
import sys
lines = [l.strip() for l in open(sys.argv[1]) if l.startswith('playback:')]
def idx(s):
    return next((i for i, l in enumerate(lines) if s in l), None)
fs1, r1 = idx('Virtual-1 paused (fullscreen)'), idx('Virtual-1 resumed')
ok = fs1 is not None and r1 is not None and r1 > fs1
# The fullscreen client must not pause Virtual-0.
first_v0 = idx('Virtual-0 paused')
ok_fs_only = first_v0 is None or (r1 is not None and first_v0 > r1)
# The maximized client (KWin puts it on Virtual-0, the active output) pauses one output and that output resumes.
after = lines[r1 + 1:] if r1 is not None else []
paused = [l for l in after if 'paused (' in l]
resumed = [l for l in after if 'resumed' in l]
ok_max = len(paused) == 1 and len(resumed) == 1 and paused[0].split()[1] == resumed[0].split()[1]
print(f'kde: fullscreen on Virtual-1 pauses it and resumes: {ok}; Virtual-0 keeps running meanwhile: {ok_fs_only}; '
      f'maximized pauses one output ({paused[0].split()[1] if paused else "none"}) and resumes it: {ok_max}'
      + ('' if ok and ok_fs_only and ok_max else '  FAIL'))
sys.exit(0 if ok and ok_fs_only and ok_max else 1)
PY

note "4. an application rule by app_id"
rules='[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FD","application":"mygame","condition":3,"action":1}]'
photon-linux desktop $wp --backend wayland --seconds 90 --fps 10 --fullscreen pause --no-sound --app-rules "$rules" > $t/rule.log 2>&1 & host=$!
ready $t/rule.log || fail=1
photon-linux desktop --wl-test-client fullscreen --output Virtual-0 --app-id org.example.mygame --seconds 3 > /dev/null 2>&1
waitfor $t/rule.log 'playback: unmute' 1 10
kill $host; wait $host
grep '^playback' $t/rule.log
grep -q 'playback: mute' $t/rule.log && ! grep -q 'paused (fullscreen)' $t/rule.log \
  && echo "kde: the fullscreen app_id org.example.mygame mutes through its rule" || { echo "kde: app rule  FAIL"; fail=1; }

note "6. virtual desktops"
vdm() { gdbus call --session -d org.kde.KWin -o /VirtualDesktopManager -m "$@"; }
vdm org.kde.KWin.VirtualDesktopManager.createDesktop 1 Two > /dev/null
ids=$(vdm org.freedesktop.DBus.Properties.Get org.kde.KWin.VirtualDesktopManager desktops | grep -o "'[0-9a-f-]\{36\}'" | tr -d "'")
one=$(echo "$ids" | sed -n 1p); two=$(echo "$ids" | sed -n 2p)
echo "kde: desktops $one $two"
photon-linux desktop $wp --backend wayland --seconds 90 --fps 10 --fullscreen run --maximized pause --no-sound > $t/desktops.log 2>&1 & host=$!
ready $t/desktops.log || fail=1
photon-linux desktop --wl-test-client maximized --seconds 30 > /dev/null 2>&1 & client=$!
waitfor $t/desktops.log 'paused' 1 || fail=1
vdm org.freedesktop.DBus.Properties.Set org.kde.KWin.VirtualDesktopManager current "<'$two'>" > /dev/null
waitfor $t/desktops.log 'resumed' 1 10
vdm org.freedesktop.DBus.Properties.Set org.kde.KWin.VirtualDesktopManager current "<'$one'>" > /dev/null
waitfor $t/desktops.log 'paused' 2 10
kill $client; wait $client
waitfor $t/desktops.log 'resumed' 2 10
kill $host; wait $host
grep '^playback' $t/desktops.log
[ "$(grep -c 'Virtual-0 paused' $t/desktops.log)" = 2 ] && [ "$(grep -c 'Virtual-0 resumed' $t/desktops.log)" = 2 ] \
  && echo "kde: a maximized window on another virtual desktop does not pause" || { echo "kde: virtual desktops  FAIL"; fail=1; }
stop_kwin

[ $fail = 0 ] && echo "kde checks passed" || echo "kde checks FAILED"
exit $fail
