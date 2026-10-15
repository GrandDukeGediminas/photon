#!/bin/sh
# Builds the Flatpak (packaging/flatpak/io.github.photon2.Photon.yml, docs/linux-port.md §6.2) with flatpak-builder in a
# privileged container, installs it there and runs it headlessly (in-container/flatpak-check.sh):
#   scripts/linux/flatpak.sh [--no-check]
# Output in $PHOTON_LX_OUT/flatpak: photon2-<arch>.flatpak (single-file bundle; `flatpak install photon2-<arch>.flatpak`
# pulls the GNOME runtime from Flathub), build.log, check/ (logs, fp_<id>.png renders).
# Image: $PHOTON_FLATPAK_IMAGE (default ghcr.io/flathub-infra/flatpak-github-actions:gnome-51, the CI job's). The
# runtimes, flatpak-builder's downloads and module cache live in the docker volume photon2-flatpak (about 4 GB;
# `docker volume rm photon2-flatpak` drops it). bubblewrap needs the privileged container.
. "$(dirname "$0")/env.sh"
check=1; [ "$1" = --no-check ] && check=0
: "${PHOTON_FLATPAK_IMAGE:=ghcr.io/flathub-infra/flatpak-github-actions:gnome-51}"
out=$PHOTON_LX_OUT/flatpak; mkdir -p "$out"
# shellcheck disable=SC2086
docker run --rm --privileged ${PHOTON_LX_PLATFORM:+--platform $PHOTON_LX_PLATFORM} -v photon2-flatpak:/var/fp \
  -v "$PHOTON_LX_SRC":/src:ro -v "$out":/out -e HOME=/var/fp/home -e CHECK=$check \
  ${PHOTON_FLATPAK_VIDEO:+-v "$PHOTON_FLATPAK_VIDEO":/video/clip.mp4:ro -e PHOTON_FLATPAK_VIDEO=/video/clip.mp4} \
  "$PHOTON_FLATPAK_IMAGE" sh -c '
set -e; arch=$(flatpak --default-arch); mkdir -p $HOME
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
echo "== flatpak-builder ($arch)"
flatpak-builder --user --install-deps-from=flathub --disable-rofiles-fuse --state-dir=/var/fp/state --force-clean \
  --repo=/var/fp/repo /var/fp/build /src/packaging/flatpak/io.github.photon2.Photon.yml > /out/build.log 2>&1 \
  || { grep -E "error:|^Error" /out/build.log | sort -u | head -30; tail -20 /out/build.log; exit 1; }
flatpak build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo /var/fp/repo /out/photon2-$arch.flatpak io.github.photon2.Photon
ls -la /out/photon2-$arch.flatpak
[ "$CHECK" = 1 ] || exit 0
flatpak install --user -y --noninteractive --reinstall /out/photon2-$arch.flatpak > /dev/null
sh /src/scripts/linux/in-container/flatpak-check.sh /src /out/check --user
'
