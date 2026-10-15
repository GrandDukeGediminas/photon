#!/bin/sh
# text-cases.sh <photon-tool|photon-linux> <fonts dir> <cases file>: `text-shape` for every case (font|size|text), each
# after a "== case" header. Runs on macOS (photon-tool, CoreText) and in the container (photon-linux, the stand-in).
tool=$1; fonts=$2
grep -v '^#' "$3" | while IFS='|' read -r font size text; do
  [ -n "$font" ] || continue
  echo "== $font|$size|$text"
  case $font in *.ttf|*.otf|*.TTF|*.OTF) f="$fonts/$font" ;; *) f=$font ;; esac
  "$tool" text-shape "$f" "$size" "$text" 2>&1
done
