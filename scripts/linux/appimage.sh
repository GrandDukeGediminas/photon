#!/bin/sh
# AppImage of photon (docs/linux-port.md §6.2), built in photon2-linux:bookworm from the Debian 12 build and run in fresh
# ubuntu:24.04 and fedora:40 containers:
#   scripts/linux/appimage.sh [version] [--no-test]     (after scripts/linux/package.sh --distro debian12 with the same
#                                                       version; default: env.sh photon_version, as package.sh)
# Output: $PHOTON_LX_OUT/appimage/photon2-<version>-<arch>.AppImage; test logs and renders in $PHOTON_LX_OUT/appimage/test-*.
. "$(dirname "$0")/env.sh"
version=$(photon_version); test=1
for a in "$@"; do case $a in --no-test) test=0 ;; *) version=$a ;; esac; done
: "${PHOTON_LX_BOOKWORM_IMAGE:=photon2-linux:bookworm}"
out=$PHOTON_LX_OUT/appimage; mkdir -p "$out"
PHOTON_LX_IMAGE=$PHOTON_LX_BOOKWORM_IMAGE lx "/scripts/in-container/appimage-build.sh $version /out/appimage" || exit 1
[ $test = 1 ] || exit 0
arch=$(PHOTON_LX_IMAGE=$PHOTON_LX_BOOKWORM_IMAGE lx "uname -m")
. "$repo/scripts/linux/in-container/ci-lib.sh"
fail=0
for img in ubuntu:24.04 fedora:40; do
  t=test-$(echo "$img" | tr -d ':.')
  docker_pull "$img" "${PHOTON_LX_PLATFORM:+--platform $PHOTON_LX_PLATFORM}" || { fail=1; continue; }
  # shellcheck disable=SC2086
  docker run --rm ${PHOTON_LX_PLATFORM:+--platform $PHOTON_LX_PLATFORM} -v "$out":/ai -v "$repo":/src:ro "$img" \
    sh /src/scripts/linux/in-container/appimage-test.sh "/ai/photon2-$version-$arch.AppImage" "/ai/$t" || fail=1
done
[ $fail = 0 ] && echo "AppImage ran in ubuntu:24.04 and fedora:40" || echo "AppImage test FAILED"
exit $fail
