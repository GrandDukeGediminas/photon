#!/bin/sh
# The macOS web host's output for the web API test page (scripts/linux/web-test/api), the reference web-check.sh compares
# against: scripts/linux/web-mac-ref.sh <photon-tool> <out dir>   → webapi.log/.png, webapi-cc.log/.png
# photon-tool render loads the page in an offscreen WKWebView (no window is shown) and logs the page console
# (PHOTON_WEBDEBUG=1). The directory properties point at a host copy of the two test images.
set -e
tool=$1; out=$2
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"; work="$out/page"; rm -rf "$work"; cp -R "$here/web-test/api" "$work"; mkdir -p "$work/pics"
python3 - "$work" <<'PY'
import json, sys
from PIL import Image
d = sys.argv[1]
Image.new('RGB', (4, 4), (255, 0, 0)).save(f'{d}/pics/a.png'); Image.new('RGB', (4, 4), (0, 255, 0)).save(f'{d}/pics/b.png')
p = json.load(open(f'{d}/project.json'))
for k in ('folder', 'lazy'): p['general']['properties'][k]['value'] = f'{d}/pics'
json.dump(p, open(f'{d}/project.json', 'w'))
PY
PHOTON_WEBDEBUG=1 "$tool" render "$work" "$out/webapi.png" 4 1280 720 2>&1 | sed 's/^.*photon web: //' > "$out/webapi.log"
PHOTON_WEBDEBUG=1 PHOTON_GENERAL='{"wec_e":true,"wec_hue":75,"wec_sa":20,"alignmentfliph":true}' \
  "$tool" render "$work" "$out/webapi-cc.png" 4 1280 720 2>&1 | sed 's/^.*photon web: //' > "$out/webapi-cc.log"
grep -c 'log: ' "$out/webapi.log"
