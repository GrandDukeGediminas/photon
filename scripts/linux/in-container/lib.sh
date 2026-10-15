# Sourced by the in-container scripts and `lx` command strings: target <id> is what `photon-linux render` takes for a
# test id (gif-<n> → the GIF wallpaper directory scripts/linux/env.sh prepare_gifs made under /out/gifwp).
target() { case $1 in gif-*) echo "/out/gifwp/$1" ;; *) echo "$1" ;; esac; }
