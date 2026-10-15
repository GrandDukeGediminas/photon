#!/usr/bin/env python3
"""Markdown fps table from scripts/linux/bench.sh outputs: benchtable.py <before.txt> <after.txt>

Columns: host fps before (readback + XShmPutImage, synchronous command buffers) and after (Vulkan swapchain,
asynchronous; and the readback fallback), headless fps before (sync) and after (async)."""
import re, sys

def parse(path):
    r = {}
    for line in open(path):
        m = re.match(r'(\d+) (\S+) \|', line)
        if not m: continue
        f = re.search(r'= ([\d.]+) fps', line)
        r[(m.group(1), m.group(2))] = float(f.group(1)) if f else None
    return r

b, a = parse(sys.argv[1]), parse(sys.argv[2])
ids = list(dict.fromkeys(k[0] for k in list(b) + list(a)))
fmt = lambda v: f'{v:.1f}' if v else 'crash'
def ratio(x, y): return f'{y / x:.2f}×' if x and y else ''
print('| Wallpaper | Host before | Host after (swapchain) | | Host after (readback) | Headless before (sync) | Headless after (async) | |')
print('|---|---|---|---|---|---|---|---|')
for i in ids:
    hb, ha, hr = b.get((i, 'host')), a.get((i, 'host')), a.get((i, 'host-readback'))
    sb, aa = b.get((i, 'sync')), a.get((i, 'async'))
    print(f'| {i} | {fmt(hb)} | {fmt(ha)} | {ratio(hb, ha)} | {fmt(hr)} | {fmt(sb)} | {fmt(aa)} | {ratio(sb, aa)} |')
