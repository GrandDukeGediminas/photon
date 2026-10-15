#!/bin/sh
# Linux packages of photon (docs/linux-port.md §6.2), built in containers and installed in fresh distribution containers:
#   scripts/linux/package.sh [version] [--distro ubuntu24.04|debian12|all] [--no-test | --test-only] [--backports]
# The version defaults to env.sh photon_version (git describe, else PHOTON_VERSION_BASE in
# Sources/CPhotonVersion/include/photon_version.h); the binary is stamped with it (`photon-linux --version`).
# Output in $PHOTON_LX_OUT/pkg:
#   ubuntu24.04 (image $PHOTON_LX_IMAGE):  photon2_<version>-1~ubuntu24.04_<arch>.deb, photon2-<version>-1.<arch>.rpm
#                                          (Fedora 40+), photon2-<version>-<arch>.tar.gz (relocatable /usr tree)
#   debian12 (image $PHOTON_LX_BOOKWORM_IMAGE, docker/linux/Dockerfile.bookworm): photon2_<version>-1~deb12_<arch>.deb
# The build (in-container/package-build.sh): static Swift runtime, OpenAL Soft 1.21.1 and libstb private in
# /usr/lib/photon2 (RUNPATH $ORIGIN/../lib/photon2), Depends from the libraries the binary names.
# The test (in-container/package-install-test.sh): ubuntu:24.04 / debian:12 install the .deb with apt, fedora:40 the .rpm
# with dnf, then plain dpkg -i / rpm -i, ldd, --version, info, desktop --self-test, sound-check, the CC0 scenes (compared
# here with Tests/scenes/refs/<arch> within Tests/scenes/thresholds.tsv), app --help and desktop --list-outputs under
# Xvfb. Debian 12 renders on its stock Mesa 22.3 lavapipe; --backports renders a second set on bookworm-backports' Mesa.
# The architecture is the containers' (PHOTON_LX_PLATFORM=linux/amd64 builds x86_64 packages on an arm64 host).
. "$(dirname "$0")/env.sh"
version=$(photon_version); distros=ubuntu24.04; test=1; build=1; backports=0
while [ $# -gt 0 ]; do
  case $1 in
    --distro) distros=$2; shift ;;
    --no-test) test=0 ;;
    --test-only) build=0 ;;
    --backports) backports=1 ;;
    -*) echo "unknown option $1"; exit 2 ;;
    *) version=$1 ;;
  esac
  shift
done
[ "$distros" = all ] && distros="ubuntu24.04 debian12"
: "${PHOTON_LX_BOOKWORM_IMAGE:=photon2-linux:bookworm}"
platform=${PHOTON_LX_PLATFORM:+--platform $PHOTON_LX_PLATFORM}
pkg=$PHOTON_LX_OUT/pkg; tests=$PHOTON_LX_OUT/pkg-test
mkdir -p "$pkg" "$tests"
fail=0

for d in $distros; do
  [ $build = 1 ] || break
  case $d in
    ubuntu24.04) image=$PHOTON_LX_IMAGE ;;
    debian12)
      image=$PHOTON_LX_BOOKWORM_IMAGE
      # shellcheck disable=SC2086
      docker image inspect "$image" > /dev/null 2>&1 \
        || docker build $platform -t "$image" -f "$repo/docker/linux/Dockerfile.bookworm" "$repo/docker/linux" || exit 1 ;;
    *) echo "unknown distribution $d"; exit 2 ;;
  esac
  echo "== $d packages ($image)"
  PHOTON_LX_IMAGE=$image lx "/scripts/in-container/package-build.sh $version /out/pkg" || exit 1
done
[ $test = 1 ] || exit 0

# The build image of the first distribution supplies the HRTF set sound-check compares with (the one OpenAL Soft 1.21.1
# embeds) and runs the render comparison.
case $distros in debian12*) tools=$PHOTON_LX_BOOKWORM_IMAGE ;; *) tools=$PHOTON_LX_IMAGE ;; esac
PHOTON_LX_IMAGE=$tools lx "cp /usr/local/share/openal/default-hrtf-1.21.1.mhr /out/pkg-test/" || exit 1
# shellcheck disable=SC2086
rarch=$(docker run --rm $platform "$tools" uname -m)
# shellcheck disable=SC2086
darch=$(docker run --rm $platform "$tools" dpkg --print-architecture)

# install_test <image> <package file name> <name> [report [docker args]]: with "report" the renders are compared but not
# gated (another distribution's Mesa: lavapipe differs between Mesa releases).
install_test() {
  rm -rf "${tests:?}/$3"
  # shellcheck disable=SC2086
  docker run --rm $platform $5 -v "$pkg":/pkg:ro -v "$repo":/src:ro -v "$tests":/out "$1" \
    sh /src/scripts/linux/in-container/package-install-test.sh "/pkg/$2" "/out/$3" /out/default-hrtf-1.21.1.mhr \
    || { echo "install test FAILED: $3"; fail=1; return; }
  PHOTON_LX_IMAGE=$tools PHOTON_LX_DOCKER_ARGS="-v $tests/$3:/renders:ro" lx "grep -v '^web' /src/Tests/scenes/scenes.txt > /tmp/ids.txt;
      python3 /scripts/pixeldiff.py /src/Tests/scenes/refs/$rarch /renders --ids /tmp/ids.txt \
      --thresholds /src/Tests/scenes/thresholds.tsv" | tee "$tests/$3/diff.md"
  if grep -q FAIL "$tests/$3/diff.md"; then
    if [ "$4" = report ]; then echo "(report only: $3 has its own Mesa)"; else fail=1; fi
  fi
}
for d in $distros; do
  case $d in
    ubuntu24.04)
      install_test ubuntu:24.04 "photon2_$version-1~ubuntu24.04_$darch.deb" ubuntu24.04
      install_test fedora:40 "photon2-$version-1.$rarch.rpm" fedora40 report ;;
    debian12)
      install_test debian:12 "photon2_$version-1~deb12_$darch.deb" debian12 report
      [ $backports = 1 ] && install_test debian:12 "photon2_$version-1~deb12_$darch.deb" debian12-backports report \
        "-e PHOTON_MESA_BACKPORTS=1" ;;
  esac
done
[ $fail = 0 ] && echo "packages installed and ran: $distros" || echo "package tests FAILED"
exit $fail
