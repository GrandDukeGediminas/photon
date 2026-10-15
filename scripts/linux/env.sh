# Shared settings for scripts/linux/*.sh (sourced). Every value can be overridden from the environment.
#   PHOTON_LX_SRC     source tree mounted read-only at /src            (default: this repository)
#   PHOTON_LX_BUILD   SwiftPM scratch directory mounted at /build      (default: /tmp/photon2-lx)
#   PHOTON_LX_CACHE   ~/.cache in the container (SPIR-V cache)         (default: /tmp/photon2-lx-cache)
#   PHOTON_LX_OUT     output directory mounted at /out                 (default: /tmp/photon2-lx-out)
#   PHOTON_LX_IMAGE   image tag                                        (default: photon2-linux:dev)
#   PHOTON_LX_PLATFORM  docker --platform for the containers, e.g. linux/amd64 on an arm64 host (default: the host's)
#   PHOTON_WS / PHOTON_WE  Steam workshop content/431960 and the Wallpaper Engine assets directory on the host
#   PHOTON_TEST_IDS   test set file (default: scripts/linux/wallpapers.txt)
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
: "${PHOTON_LX_SRC:=$repo}"
: "${PHOTON_LX_BUILD:=/tmp/photon2-lx}"
: "${PHOTON_LX_CACHE:=/tmp/photon2-lx-cache}"
: "${PHOTON_LX_OUT:=/tmp/photon2-lx-out}"
: "${PHOTON_LX_IMAGE:=photon2-linux:dev}"
: "${PHOTON_WS:=$HOME/Library/Application Support/Steam/steamapps/workshop/content/431960}"
: "${PHOTON_WE:=$HOME/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/common/wallpaper_engine/assets}"
mkdir -p "$PHOTON_LX_BUILD" "$PHOTON_LX_CACHE" "$PHOTON_LX_OUT"

# lx <command…>: runs a shell command in a throwaway container (removed on exit, also on Ctrl-C) with the source tree,
# build directory, SPIR-V cache, workshop corpus, engine assets, output directory and scripts/linux (/scripts) mounted.
# Extra `docker run` arguments go in PHOTON_LX_DOCKER_ARGS (word-split: no spaces inside paths). Swift's crash
# backtracer is off: in the container it can hang a crashed process for minutes.
lx() {
    name="photon2-lx-$$-$(date +%s)"
    # The install's default projects (web wallpapers def_corsair_*) and the web host binary whose injected runtime
    # script photon2 reads (docs/linux-port.md §5.3), when the install has them.
    cmd="$*"
    we_root=$(dirname "$PHOTON_WE")
    set --
    [ -d "$we_root/projects" ] && set -- "$@" -v "$we_root/projects":/we/projects:ro
    [ -f "$we_root/distribution/bin/webwallpaper64.exe" ] && \
        set -- "$@" -v "$we_root/distribution/bin/webwallpaper64.exe":/we/distribution/bin/webwallpaper64.exe:ro
    trap 'docker rm -f "$name" >/dev/null 2>&1' INT TERM
    # shellcheck disable=SC2086
    docker run --rm --name "$name" ${PHOTON_LX_PLATFORM:+--platform $PHOTON_LX_PLATFORM} \
        -v "$PHOTON_LX_SRC":/src:ro -v "$PHOTON_LX_BUILD":/build -v "$PHOTON_LX_CACHE":/root/.cache \
        -v "$PHOTON_WS":/workshop:ro -v "$PHOTON_WE":/we/assets:ro -v "$PHOTON_LX_OUT":/out \
        -v "$repo/scripts/linux":/scripts:ro "$@" \
        -e PHOTON_SEED=1 -e TZ=Europe/London -e SWIFT_BACKTRACE=enable=no $PHOTON_LX_DOCKER_ARGS "$PHOTON_LX_IMAGE" sh -c "$cmd"
    rc=$?
    trap - INT TERM
    return $rc
}

# photon_version: the version the packaging scripts stamp by default (docs/linux-port.md §6.2). In a checkout with a
# v<version> tag, `git describe` (v0.6.0-3-gabc1234 -> 0.6.0+3.gabc1234, valid for dpkg and rpm); otherwise
# PHOTON_VERSION_BASE from Sources/CPhotonVersion/include/photon_version.h, the version's one written-down source.
photon_version() {
    if v=$(git -C "$repo" describe --tags --match 'v[0-9]*' 2> /dev/null); then
        echo "${v#v}" | sed 's/-\([0-9]*\)-g/+\1.g/'
    else
        sed -n 's/^#define PHOTON_VERSION_BASE "\(.*\)"$/\1/p' "$repo/Sources/CPhotonVersion/include/photon_version.h"
    fi
}

# Test set ids (wallpapers.txt): a workshop id, or gif-<workshop id> for a GIF wallpaper built from that item's
# preview.gif (the corpus has no GIF wallpapers; the engine runs a `.gif` project file through its GIF scene template).
test_ids() { grep -v '^#' "${PHOTON_TEST_IDS:-$here/wallpapers.txt}" | awk 'NF {print $1}' | tr '\n' ' '; }

# prepare_gifs <id…>: $PHOTON_LX_OUT/gifwp/gif-<n>/ with project.json {"file": "preview.gif"} and the item's preview.gif
# (seen as /out/gifwp/gif-<n> in the container).
prepare_gifs() {
    for id in "$@"; do
        case $id in
            gif-*)
                d="$PHOTON_LX_OUT/gifwp/$id"; mkdir -p "$d"
                cp "$PHOTON_WS/${id#gif-}/preview.gif" "$d/preview.gif" || return 1
                printf '{"file": "preview.gif", "title": "GIF test %s", "type": "scene"}\n' "${id#gif-}" > "$d/project.json" ;;
        esac
    done
}

# mac_target <id>: what photon-tool render takes for a test id on the host.
mac_target() { case $1 in gif-*) echo "$PHOTON_LX_OUT/gifwp/$1" ;; *) echo "$1" ;; esac; }
