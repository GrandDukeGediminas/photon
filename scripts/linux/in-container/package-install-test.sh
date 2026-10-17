#!/bin/sh
# In a fresh distribution container (ubuntu:24.04, debian:12, fedora:40; docs/linux-port.md §6.2): installs a photon2
# package with the distribution's package manager, then runs the installed /usr/bin/photon-linux.
#   package-install-test.sh <package file> <outdir> [mhr file]
# Checks: the package manager resolves every dependency (apt / dnf), a plain `dpkg -i` / `rpm -i --replacepkgs` of the
# same file then succeeds without --force, nothing in ldd is missing and OpenAL / stb come from /usr/lib/photon2,
# `photon-linux --version` equals the package's upstream version, `photon-linux info` (lavapipe), `desktop --self-test`,
# `sound-check` (the bundled OpenAL Soft 1.21.1 against photon2's voice model, limit 1e-6), the five CC0 scene renders
# into <outdir> (compared with the references afterwards by package.sh), and `app --help` / `desktop --list-outputs`
# under Xvfb. Debian 12 renders on its own Mesa 22.3 lavapipe; PHOTON_MESA_BACKPORTS=1 installs bookworm-backports'
# Mesa first.
set -e
pkg=$1; out=$2; mhr=$3
mkdir -p "$out"; log=$out/install.log
. /etc/os-release
. "$(dirname "$0")/ci-lib.sh"
CI_CONTEXT="package test on $PRETTY_NAME"; CI_STEP="package install"; ci_trap
echo "== $PRETTY_NAME ($(uname -m)): install $(basename "$pkg")"
case $ID in
  ubuntu|debian)
    apt_prepare
    retry_install "$log" "package install" "$(apt_update) && apt-get install -y -qq --no-install-recommends $APT_NET '$pkg' xvfb" \
      || die_log "$log" "package install" $?
    dpkg -s photon2 | grep -E '^(Status|Version)'
    pkgversion=$(dpkg-query -W -f '${Version}' photon2 | sed 's/-[^-]*$//')
    dpkg -i "$pkg" >> "$log" 2>&1 || die_log "$log" "dpkg -i" $?
    echo "dpkg -i: ok"; apt-get check -qq && echo "apt-get check: ok"
    ;;
  fedora)
    retry_install "$log" "package install" "dnf install -y -q '$pkg' xorg-x11-server-Xvfb" || die_log "$log" "package install" $?
    rpm -q photon2
    pkgversion=$(rpm -q --qf '%{VERSION}' photon2)
    rpm -i --replacepkgs "$pkg" >> "$log" 2>&1 || die_log "$log" "rpm -i" $?
    echo "rpm -i: ok"; rpm -V photon2 && echo "rpm -V: ok"
    ;;
  *) ci_reported=1; ci_annotate error "$CI_CONTEXT: unsupported distribution $ID"; exit 2 ;;
esac

echo "== installed binary"
CI_STEP="installed binary (ldd, --version, info)"
command -v photon-linux
ldd /usr/bin/photon-linux > "$out/ldd.txt"
if grep 'not found' "$out/ldd.txt"; then fail "missing libraries: $(grep 'not found' "$out/ldd.txt" | tr -s ' \t' ' ' | tr '\n' ';')"; fi
grep -E 'lib(openal|stb)\.so' "$out/ldd.txt"
[ "$(grep -cE 'lib(openal|stb)\.so.* => /usr/bin/../lib/photon2/' "$out/ldd.txt")" = 2 ] || fail "the private OpenAL / stb in /usr/lib/photon2 are not used"
export GALLIVM_PERF=no_aos_sampling PHOTON_SEED=1 SWIFT_BACKTRACE=enable=no
v=$(photon-linux --version)
[ "$v" = "photon-linux $pkgversion" ] || fail "photon-linux --version says '$v', the package is $pkgversion"
echo "--version: $v"
if [ "$ID$VERSION_ID" = debian12 ] && [ "$PHOTON_MESA_BACKPORTS" = 1 ]; then
  # Optional: bookworm-backports' Mesa instead of Debian 12's own 22.3 (whose lavapipe needs the sampler-descriptor
  # workaround, VulkanDevice.writesAllSamplers; docs/linux-port.md §6.2).
  echo "deb http://deb.debian.org/debian bookworm-backports main" > /etc/apt/sources.list.d/backports.list
  retry_install "$out/backports.log" "bookworm-backports Mesa" \
    "$(apt_update) && apt-get install -y -qq -t bookworm-backports $APT_NET mesa-vulkan-drivers" \
    || die_log "$out/backports.log" "bookworm-backports Mesa" $?
  echo "Mesa from bookworm-backports: $(dpkg-query -W -f '${Version}' mesa-vulkan-drivers)"
fi
if [ "$ID" = fedora ]; then rpm -q mesa-vulkan-drivers; else echo "mesa-vulkan-drivers $(dpkg-query -W -f '${Version}' mesa-vulkan-drivers)"; fi
photon-linux info | tee "$out/info.txt"
if [ "$ID$VERSION_ID" = debian12 ] && [ "$PHOTON_MESA_BACKPORTS" != 1 ] && ! grep -q 'every sampler descriptor written' "$out/info.txt"; then
  fail "Mesa 22.3 lavapipe without the sampler-descriptor workaround"
fi
CI_STEP="self-test"
photon-linux desktop --self-test > "$out/self-test.txt" 2>&1 || die_log "$out/self-test.txt" "self-test" $?
tail -1 "$out/self-test.txt"
if [ -n "$mhr" ]; then
  CI_STEP="sound-check"
  photon-linux sound-check --mhr "$mhr" > "$out/sound-check.txt" 2>&1 || die_log "$out/sound-check.txt" "sound-check" $?
  grep -E '^(speaker|hrtf):|sound-check:' "$out/sound-check.txt"
fi

echo "== CC0 scenes"
for id in images effects particles text perspective; do
  CI_STEP="render $id"
  PHOTON_WE_ASSETS=/src/Tests/scenes/assets photon-linux render "/src/Tests/scenes/$id" "$out/lx_$id.png" 2 640 360 \
    > "$out/$id.txt" 2> "$out/$id.err" || { rc=$?; cat "$out/$id.txt" >> "$out/$id.err"; die_log "$out/$id.err" "render $id" $rc; }
done
ls "$out"/lx_*.png | wc -l | sed 's/$/ scenes rendered/'

echo "== app and outputs (Xvfb)"
CI_STEP="app --help and --list-outputs"
photon-linux app --help | head -3
Xvfb :95 -screen 0 1280x720x24 > /dev/null 2>&1 & xv=$!; sleep 1
DISPLAY=:95 photon-linux desktop --list-outputs
kill $xv
echo "installed package runs ($PRETTY_NAME)"
