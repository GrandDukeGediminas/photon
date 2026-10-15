#!/bin/sh
# Text shaping against CoreText (docs/linux-port.md §3.3): scripts/linux/text-check.sh [config] [--mac]
# Lays out every line of text-cases.txt with the Linux CoreText stand-in (photon-linux text-shape: FreeType, HarfBuzz,
# fontconfig; in the container) and requires the output to equal CoreText's: runs, glyph ids, advances, positions,
# string indices and line metrics, to 4 decimals. The reference is text-coretext.txt (photon-tool text-shape on
# macOS 26); --mac regenerates it first with $PHOTON_TOOL. Outputs $PHOTON_LX_OUT/text-{coretext,linux}.txt; exit 1 on
# any difference.
. "$(dirname "$0")/env.sh"
config=release; mac=0
for a in "$@"; do case $a in --mac) mac=1 ;; *) config=$a ;; esac; done
ref=$here/text-coretext.txt
if [ $mac = 1 ]; then
  ref=$PHOTON_LX_OUT/text-coretext.txt
  "$here/in-container/text-cases.sh" "${PHOTON_TOOL:?set PHOTON_TOOL to a macOS photon-tool}" "$PHOTON_WE/fonts" "$here/text-cases.txt" > "$ref"
fi
lx "/scripts/in-container/text-cases.sh /build/$config/photon-linux /we/assets/fonts /scripts/text-cases.txt" > "$PHOTON_LX_OUT/text-linux.txt"
n=$(grep -c '^== ' "$ref")
if grep -v '^#' "$ref" | diff - "$PHOTON_LX_OUT/text-linux.txt" > "$PHOTON_LX_OUT/text-diff.txt"; then
  echo "text shaping: $n cases identical to CoreText"
else
  echo "text shaping: FAILED, output differs from CoreText (diff in $PHOTON_LX_OUT/text-diff.txt):"
  head -20 "$PHOTON_LX_OUT/text-diff.txt"
  exit 1
fi
