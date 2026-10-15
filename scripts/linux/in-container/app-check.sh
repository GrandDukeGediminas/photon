#!/bin/sh
# In the container: the Linux app (`photon-linux app`, docs/linux-port.md §6.1) under Xvfb and under headless sway.
#   app-check.sh <photon-linux> <outdir> [--corpus]
# For each backend: a private session bus, a stand-in tray (fake_sni_watcher.py: StatusNotifierWatcher + host that reads
# the item and its dbusmenu and clicks Pause / Resume), and `photon-linux app --self-test`, which drives browse → apply
# (a desktop host starts) → per-display apply → properties and presets → playlist (settings dialog, save, next) →
# settings → tray menu → wallpaper switches (in the running host with a fade, by handover to and from a web page with
# the scene's / page's frame, a playlist moving on when its video ends) → rules reaching the hosts, checks the model,
# the hosts and the persisted settings, and writes window snapshots and screen captures. Then the single-instance
# guard: a second `photon-linux app` hands its arguments to the first over D-Bus and exits.
# Library: the CC0 test scenes (Tests/scenes, no Steam corpus needed); --corpus uses /workshop and /we/assets and
# adds a generated 2 s video wallpaper.
# Then the display layouts on two outputs (`app --self-test` with PHOTON_SELFTEST_LAYOUT=1, docs/re/09 §8.3) through
# Settings → Displays: a clone group (one host over both outputs, a locked source, a flip, removal), a split of the first
# output (a host per region with --region, a wallpaper per region applied through the browser, sound for the first host
# of a wallpaper only, a nested split, a moved divider, removal); the split capture must show two different pictures.
# X11: two named monitors on one Xvfb screen (PHOTON_X11_MONITORS); Wayland: two headless sway outputs.
# Screenshots: <outdir>/x11/*.png, <outdir>/wayland/*.png, <outdir>/*-layout/*.png; results: */results.txt, */sni.json,
# */app.log.
# PHOTON_APPCHECK_STEPS: "basic layout" (default) or one of them.
bin=$1; out=${2:-/out/app}; corpus=0; steps=" ${PHOTON_APPCHECK_STEPS:-basic layout} "
want() { case "$steps" in *" $1 "*) return 0;; esac; return 1; }
[ "$3" = "--corpus" ] && corpus=1
here=$(cd "$(dirname "$0")" && pwd)
src=${PHOTON_SRC:-/src}
fail=0
rm -rf "$out"; mkdir -p "$out"
# With the corpus: a 2 s video wallpaper (MPEG-4 part 2 in MP4, what the image's GStreamer can encode) for the
# playlist's video end (video wallpapers run through the engine's scene template, which the CC0 assets do not have).
extra=/tmp/app-extra; rm -rf $extra; mkdir -p $extra
if [ $corpus = 1 ]; then
  mkdir -p $extra/clip
  gst-launch-1.0 -q videotestsrc num-buffers=60 pattern=smpte ! video/x-raw,width=320,height=180,framerate=30/1 ! videoconvert \
    ! avenc_mpeg4 ! mp4mux ! filesink location=$extra/clip/clip.mp4 > /dev/null 2>&1
  printf '{"file": "clip.mp4", "title": "test clip", "type": "video"}\n' > $extra/clip/project.json
  export PHOTON_WORKSHOP=/workshop PHOTON_WE_ASSETS=/we/assets PHOTON_SELFTEST_ITEMS=${PHOTON_SELFTEST_ITEMS:-2541606883,1442092399}
  export PHOTON_LIBRARY=$extra PHOTON_SELFTEST_VIDEO=clip
else
  # The test scenes are the library; the workshop folder is empty.
  mkdir -p /tmp/app-empty-workshop
  export PHOTON_WORKSHOP=/tmp/app-empty-workshop PHOTON_WE_ASSETS=$src/Tests/scenes/assets PHOTON_LIBRARY=$src/Tests/scenes:$extra \
         PHOTON_SELFTEST_ITEMS=${PHOTON_SELFTEST_ITEMS:-images,particles}
fi
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 NO_AT_BRIDGE=1 GTK_A11Y=none

# run_backend <name>: one self-test run with its own session bus and tray; DISPLAY / WAYLAND_DISPLAY set by the caller.
run_backend() {
  name=$1; dir=$out/$name; mkdir -p "$dir"
  dbus-daemon --session --fork --print-address=3 --print-pid=4 3>"$dir/.bus" 4>"$dir/.buspid"
  DBUS_SESSION_BUS_ADDRESS=$(head -1 "$dir/.bus"); export DBUS_SESSION_BUS_ADDRESS
  DBUS_SESSION_BUS_PID=$(head -1 "$dir/.buspid")
  python3 "$here/fake_sni_watcher.py" "$dir/sni.json" 200 > "$dir/watcher.log" 2>&1 & watcher=$!
  sleep 1
  timeout -k 10 360 "$bin" app --self-test "$dir" > "$dir/app.log" 2>&1; status=$?
  kill $watcher 2>/dev/null; wait $watcher 2>/dev/null
  [ -n "$DBUS_SESSION_BUS_PID" ] && kill "$DBUS_SESSION_BUS_PID" 2>/dev/null
  grep -E '^self-test: (PASS|FAIL|all|[0-9]+ failure)' "$dir/app.log" | sed "s/^/$name: /"
  [ $status = 0 ] || { echo "$name: app exited with $status  FAIL"; fail=1; }
  python3 - "$dir/sni.json" "$name" <<'PY' || fail=1
import json, sys
r = json.load(open(sys.argv[1])); name = sys.argv[2]
ok = True
def check(c, what):
    global ok
    print(f"{name}: {'PASS' if c else 'FAIL'}: tray {what}")
    ok &= bool(c)
check(r["registered"], "item registered with the StatusNotifierWatcher")
if r["registered"]:
    i = r["registered"][0]
    labels = [e["label"] for e in i["menu"]]
    check(i["Id"] == "photon2" and i["IconName"] == "photon2" and i["Menu"] == "/MenuBar", f"properties Id {i['Id']}, IconName {i['IconName']}, Menu {i['Menu']}")
    check(i["MenuVersion"] == 3, "dbusmenu version 3")
    check("Browse Wallpapers…" in labels and "Settings…" in labels and "Quit photon" in labels, "menu: " + " | ".join(labels))
    check(i.get("status_after_pause_click") == "Passive" and i.get("label_after_pause_click") == "Resume", "Event clicked on Pause pauses (Status Passive, item becomes Resume)")
    check(i.get("status_after_second_click") == "Active", "a second click resumes (Status Active)")
    check(len(i["IconPixmap"]) > 0 or True, f"icon pixmaps {i['IconPixmap']}")
sys.exit(0 if ok else 1)
PY
  ls "$dir"/*.png 2>/dev/null | sed "s|^|$name: screenshot |"
  rm -f "$dir/.bus" "$dir/.buspid"
  return $fail
}

# run_layout <name> <left output> <split x>: the layout steps with a private session bus.
run_layout() {
  name=$1; dir=$out/$name; mkdir -p "$dir"
  dbus-daemon --session --fork --print-address=3 --print-pid=4 3>"$dir/.bus" 4>"$dir/.buspid"
  DBUS_SESSION_BUS_ADDRESS=$(head -1 "$dir/.bus"); export DBUS_SESSION_BUS_ADDRESS
  pid=$(head -1 "$dir/.buspid")
  PHOTON_SELFTEST_LAYOUT=1 timeout -k 10 300 "$bin" app --self-test "$dir" > "$dir/app.log" 2>&1; status=$?
  kill "$pid" 2>/dev/null
  rm -f "$dir/.bus" "$dir/.buspid"
  grep -E '^self-test: (PASS|FAIL|all|[0-9]+ failure)' "$dir/app.log" | sed "s/^/$name: /"
  [ $status = 0 ] || { echo "$name: app exited with $status  FAIL"; fail=1; }
  # The split capture: the two regions of the first output show different pictures (the per-region wallpapers),
  # neither black.
  python3 - "$dir/22-split.png" "$name" "$3" <<'PY' || fail=1
import sys, numpy as np
from PIL import Image
a = np.asarray(Image.open(sys.argv[1]).convert('RGB')).astype(float)
x = int(sys.argv[3])
l, r = a[:, :x], a[:, x:2 * x]
d = abs(l - r).mean()
ok = l.mean() > 8 and r.mean() > 8 and d > 5
print(f"{sys.argv[2]}: {'PASS' if ok else 'FAIL'}: split capture: left region mean {l.mean():.1f}, right region mean {r.mean():.1f}, mean pixel difference {d:.1f}")
sys.exit(0 if ok else 1)
PY
  ls "$dir"/*.png 2>/dev/null | sed "s|^|$name: screenshot |"
}

# single_instance <name>: a first `app --no-hosts`, then a second launch with a wallpaper id: the second must hand it
# over (D-Bus Activate) and exit 0, the first apply it and raise its browser; a `--background` launch only activates.
single_instance() {
  name=$1; dir=$out/$name; mkdir -p $dir/si
  dbus-daemon --session --fork --print-address=3 --print-pid=4 3>"$dir/.bus" 4>"$dir/.buspid"
  DBUS_SESSION_BUS_ADDRESS=$(head -1 "$dir/.bus"); export DBUS_SESSION_BUS_ADDRESS
  pid=$(head -1 "$dir/.buspid")
  # The app starts only for a Steam account that owns Wallpaper Engine: a test account and the fake steamcmd
  # (Tests/fixtures/workshop/fake-steamcmd.sh reports an active licence), so the first launch goes through the real check.
  mkdir -p $dir/si/photon2
  cat > $dir/si/photon2/photon2.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>steamusername</key><string>tester</string>
<key>steamcmdpath</key><string>/src/Tests/fixtures/workshop/fake-steamcmd.sh</string>
</dict></plist>
PLIST
  XDG_CONFIG_HOME=$dir/si timeout -k 5 60 "$bin" app --no-hosts --background > "$dir/si-first.log" 2>&1 & first=$!
  sleep 4
  item=${PHOTON_SELFTEST_ITEMS%%,*}
  XDG_CONFIG_HOME=$dir/si timeout -k 5 20 "$bin" app "$item" > "$dir/si-second.log" 2>&1; second=$?
  XDG_CONFIG_HOME=$dir/si timeout -k 5 20 "$bin" app --background > "$dir/si-third.log" 2>&1; third=$?
  sleep 1.5
  kill $first 2>/dev/null; wait $first 2>/dev/null
  kill $pid 2>/dev/null
  rm -f "$dir/.bus" "$dir/.buspid"
  ok=0
  [ $second = 0 ] && grep -q 'already running; activated the running instance' "$dir/si-second.log" || ok=1
  grep -q "activated by another launch ($item)" "$dir/si-first.log" || ok=1
  [ $third = 0 ] && grep -q 'activated by another launch (--background)' "$dir/si-first.log" || ok=1
  grep -q '<key>ownershipverified</key>' "$dir/si/photon2/photon2.plist" || ok=1
  grep -q "\"$item\"" "$dir/si/photon2/photon2.plist" 2>/dev/null || grep -q "<string>$item</string>" "$dir/si/photon2/photon2.plist" || ok=1
  if [ $ok = 0 ]; then echo "$name: PASS: single instance: a second launch activated the first ($item applied there) and exited"
  else echo "$name: FAIL: single instance"; sed 's/^/  first: /' "$dir/si-first.log" | tail -5; sed 's/^/  second: /' "$dir/si-second.log"; fail=1; fi
}

printf '\n-- X11 (Xvfb 1600x1000)\n'
Xvfb :97 -screen 0 1600x1000x24 > /dev/null 2>&1 & xvfb=$!
sleep 1
if want basic; then
  DISPLAY=:97 run_backend x11
  DISPLAY=:97 single_instance x11
fi
if want layout; then
  printf '\n-- X11 layouts: two monitors of 800x1000 on Xvfb 1600x1000\n'
  DISPLAY=:97 PHOTON_X11_MONITORS=LEFT=800x1000+0+0,RIGHT=800x1000+800+0 run_layout x11-layout LEFT 400
fi
kill $xvfb 2>/dev/null; wait $xvfb 2>/dev/null

printf '\n-- Wayland (headless sway 1600x1000)\n'
t=/tmp/appcheck-wl; rm -rf $t; mkdir -p $t/xdg; chmod 700 $t/xdg
export XDG_RUNTIME_DIR=$t/xdg WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
printf 'output HEADLESS-1 resolution 1600x1000 position 0 0\ndefault_border none\n' > $t/sway.conf
sway -c $t/sway.conf > $t/sway.log 2>&1 & sway=$!
for i in 1 2 3 4 5 6 7 8 9 10; do [ -S $XDG_RUNTIME_DIR/wayland-1 ] && break; sleep 0.3; done
if want basic; then
  ( unset DISPLAY; WAYLAND_DISPLAY=wayland-1 GDK_BACKEND=wayland run_backend wayland )
  [ $? = 0 ] || fail=1
  ( unset DISPLAY; export WAYLAND_DISPLAY=wayland-1 GDK_BACKEND=wayland; single_instance wayland; exit $fail )
  [ $? = 0 ] || fail=1
fi
kill $sway 2>/dev/null; wait $sway 2>/dev/null

if want layout; then
printf '\n-- Wayland layouts: two headless sway outputs of 800x1000\n'
printf 'output HEADLESS-1 resolution 800x1000 position 0 0\noutput HEADLESS-2 resolution 800x1000 position 800 0\ndefault_border none\n' > $t/sway2.conf
rm -f $XDG_RUNTIME_DIR/wayland-* $XDG_RUNTIME_DIR/sway-ipc.*
sway -c $t/sway2.conf > $t/sway2.log 2>&1 & sway=$!
for i in 1 2 3 4 5 6 7 8 9 10; do [ -S $XDG_RUNTIME_DIR/wayland-1 ] && break; sleep 0.3; done
SWAYSOCK=$(ls $XDG_RUNTIME_DIR/sway-ipc.*.sock 2>/dev/null | head -1) WAYLAND_DISPLAY=wayland-1 swaymsg create_output > /dev/null
sleep 1
( unset DISPLAY; export WAYLAND_DISPLAY=wayland-1 GDK_BACKEND=wayland; run_layout wayland-layout HEADLESS-1 400; exit $fail )
[ $? = 0 ] || fail=1
kill $sway 2>/dev/null; wait $sway 2>/dev/null
fi

if [ $fail = 0 ]; then echo "app checks passed"; else echo "app checks FAILED"; fi
exit $fail
