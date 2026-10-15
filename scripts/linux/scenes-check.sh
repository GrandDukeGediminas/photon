#!/bin/sh
# Renders the synthetic CC0 test scenes (Tests/scenes, no Steam corpus or Wallpaper Engine install needed) in the
# container and compares them with the committed references (docs/linux-port.md §7).
#
#   scripts/linux/scenes-check.sh [release|debug] [--update] [--mac PHOTON_TOOL]
#     --update   write the Linux renders over Tests/scenes/refs/<arch> (after checking them by eye)
#     --mac T    also render the scenes on this Mac with photon-tool T into $PHOTON_LX_OUT/scenes-mac and compare them
#                with Tests/scenes/refs-mac (Metal vs Metal) and with the Linux renders (Metal vs lavapipe, report only)
#
# Scenes render with `photon-linux render <dir> out.png 2 640 360` (PHOTON_SEED=1, PHOTON_WE_ASSETS=Tests/scenes/assets,
# the CC0 stand-in for the engine's assets). The web wallpaper runs in the desktop host under a 640x360 Xvfb and the root
# window is captured after the page has loaded; its page log (properties received) must match Tests/scenes/web.log.
# References: Tests/scenes/refs/<arch>/ (aarch64, x86_64: the container's `uname -m`, so PHOTON_LX_PLATFORM=linux/amd64
# checks x86_64 on an arm64 host) with driver.txt, the Mesa package version and lavapipe device line they were rendered
# with. lavapipe is deterministic for one Mesa/LLVM build on one architecture, so when the container's driver.txt
# equals the committed one the five rendered scenes must be byte-identical (pixeldiff --exact); otherwise (Ubuntu
# updated Mesa) the comparison falls back to the limits and says so. Limits: Tests/scenes/thresholds.tsv (Linux vs the
# Linux refs, every scene including web) and Tests/scenes/thresholds-mac.tsv (macOS vs refs-mac).
set -e
. "$(dirname "$0")/env.sh"
config=release; update=0; mac_tool=""
while [ $# -gt 0 ]; do
  case $1 in
    release|debug) config=$1 ;;
    --update) update=1 ;;
    --mac) mac_tool=$2; shift ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
  shift
done
scenes=$repo/Tests/scenes
out=$PHOTON_LX_OUT/scenes
rm -rf "$out"; mkdir -p "$out"
ids=$(grep -v '^#' "$scenes/scenes.txt" | awk 'NF {print $1}' | tr '\n' ' ')
fail=0

echo "== render the synthetic scenes (Linux, lavapipe)"
lx "export PHOTON_WE_ASSETS=/src/Tests/scenes/assets; bin=/build/$config/photon-linux; rc=0
    uname -m > /out/scenes/arch.txt
    { echo \"mesa-vulkan-drivers \$(dpkg-query -W -f '\${Version}' mesa-vulkan-drivers)\"; \$bin info | head -1; } > /out/scenes/driver.txt
    for id in $ids; do
      if [ \$id = web ]; then
        Xvfb :97 -screen 0 640x360x24 >/dev/null 2>&1 & xv=\$!; sleep 1
        DISPLAY=:97 WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 \$bin desktop /src/Tests/scenes/web --seconds 6 \
          --eval 'document.getElementById(\"log\").textContent' > /out/scenes/web.txt 2>&1 &
        host=\$!; sleep 5; DISPLAY=:97 import -window root /out/scenes/lx_web.png; wait \$host || rc=1; kill \$xv
        sed -n '/textContent =\$/,\$p' /out/scenes/web.txt | tail -n +2 > /out/scenes/web.log
      else
        \$bin render /src/Tests/scenes/\$id /out/scenes/lx_\$id.png 2 640 360 > /out/scenes/\$id.txt 2>&1 || { rc=1; cat /out/scenes/\$id.txt; }
      fi
    done; exit \$rc" || fail=1

echo "== web page log"
if diff -u "$scenes/web.log" "$out/web.log"; then echo "web page log matches"; else fail=1; fi

arch=$(cat "$out/arch.txt"); refs=$scenes/refs/$arch
echo "== Linux renders vs Tests/scenes/refs/$arch ($(paste -sd';' "$out/driver.txt"))"
if [ ! -d "$refs" ]; then
  echo "no references for $arch (scenes-check.sh --update writes them)"; [ $update = 1 ] || fail=1
else
  PHOTON_LX_DOCKER_ARGS="-v $out:/renders:ro" lx "python3 /scripts/pixeldiff.py /src/Tests/scenes/refs/$arch /renders \
      --ids /src/Tests/scenes/scenes.txt --thresholds /src/Tests/scenes/thresholds.tsv" | tee "$out/diff-linux.md"
  grep -q FAIL "$out/diff-linux.md" && fail=1
  grep -v '^web' "$scenes/scenes.txt" > "$out/ids-exact.txt"
  if cmp -s "$refs/driver.txt" "$out/driver.txt"; then
    echo "== byte-identical to the $arch references (same lavapipe build)"
    PHOTON_LX_DOCKER_ARGS="-v $out:/renders:ro" lx "python3 /scripts/pixeldiff.py /src/Tests/scenes/refs/$arch /renders \
        --ids /renders/ids-exact.txt --exact" | tee "$out/diff-exact.md"
    grep -q FAIL "$out/diff-exact.md" && fail=1
  else
    echo "== not byte-compared: the references were rendered with"
    sed 's/^/   /' "$refs/driver.txt" 2>/dev/null || echo "   (no driver.txt)"
  fi
fi

if [ -n "$mac_tool" ]; then
  echo "== macOS renders (photon-tool) vs Tests/scenes/refs-mac"
  mac=$PHOTON_LX_OUT/scenes-mac; rm -rf "$mac"; mkdir -p "$mac"
  for id in $ids; do
    [ "$id" = web ] && continue
    PHOTON_SEED=1 PHOTON_WE_ASSETS=$scenes/assets "$mac_tool" render "$scenes/$id" "$mac/mac_$id.png" 2 640 360 > "$mac/$id.txt" 2>&1 \
      || { fail=1; cat "$mac/$id.txt"; }
  done
  grep -v '^web' "$scenes/scenes.txt" > "$mac/ids.txt"
  PHOTON_LX_DOCKER_ARGS="-v $mac:/mac:ro -v $out:/renders:ro" lx "python3 /scripts/pixeldiff.py /src/Tests/scenes/refs-mac /mac \
      --ids /mac/ids.txt --prefix mac_ --thresholds /src/Tests/scenes/thresholds-mac.tsv" | tee "$mac/diff-mac.md"
  grep -q FAIL "$mac/diff-mac.md" && fail=1
  echo "== macOS (Metal) vs Linux (lavapipe), report only"
  PHOTON_LX_DOCKER_ARGS="-v $mac:/mac:ro -v $out:/renders:ro" lx "python3 /scripts/pixeldiff.py /mac /renders \
      --ids /mac/ids.txt --ref-prefix mac_" | tee "$mac/diff-mac-linux.md" || true
fi

if [ $update = 1 ]; then
  mkdir -p "$refs"
  for id in $ids; do cp "$out/lx_$id.png" "$refs/$id.png"; done
  cp "$out/driver.txt" "$refs/driver.txt"
  # photon-linux writes PNGs with little compression; the committed copies are recompressed (same pixels).
  PHOTON_LX_DOCKER_ARGS="-v $refs:/refs" lx "python3 -c \"from PIL import Image; import glob
for f in glob.glob('/refs/*.png'): im = Image.open(f); im.load(); im.save(f, optimize=True)\""
  cp "$out/web.log" "$scenes/web.log"
  echo "updated Tests/scenes/refs/$arch"
fi
[ $fail = 0 ] && echo "scenes check passed" || echo "scenes check FAILED"
exit $fail
