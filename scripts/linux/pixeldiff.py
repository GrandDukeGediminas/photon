#!/usr/bin/env python3
"""Pixel-diff table and threshold check for the Linux test set (docs/linux-port.md §7).

usage: pixeldiff.py <refs-dir> <out-dir> [--ids FILE] [--thresholds FILE] [--exact] [--prefix lx_] [--markdown]

Compares <out-dir>/<prefix><id>.png against <refs-dir>/<id>.png for every id in the ids file. Prints one table row per
wallpaper: identical pixels, mean absolute per-channel difference (0..255), max channel difference, pixels whose largest
channel difference exceeds 8 and 32. With --thresholds, each row must stay within that file's limits (`id max_mean
max_px32`); with --exact every pixel must match (lavapipe against lavapipe). Exit status 1 when a check fails or a render
is missing.
"""
import argparse, os, sys
import numpy as np
from PIL import Image

here = os.path.dirname(os.path.abspath(__file__))
ap = argparse.ArgumentParser()
ap.add_argument('refs')
ap.add_argument('out')
ap.add_argument('--ids', default=os.path.join(here, 'wallpapers.txt'))
ap.add_argument('--thresholds')
ap.add_argument('--exact', action='store_true')
ap.add_argument('--prefix', default='lx_')
ap.add_argument('--ref-prefix', default='')
a = ap.parse_args()

ids = [l.split()[0] for l in open(a.ids) if l.strip() and not l.startswith('#')]
limits = {}
if a.thresholds:
    for l in open(a.thresholds):
        if l.strip() and not l.startswith('#'):
            f = l.split()
            limits[f[0]] = (float(f[1]), int(f[2]))

failed = []
print('| Wallpaper | Identical px | Mean abs diff | Max | Px > 8 | Px > 32 |' + (' Limit (mean, >32) |' if limits else ''))
print('|---|---|---|---|---|---|' + ('---|' if limits else ''))
for i in ids:
    rp = os.path.join(a.refs, a.ref_prefix + i + '.png')
    lp = os.path.join(a.out, a.prefix + i + '.png')
    if not os.path.exists(rp):
        print(f'| {i} | no reference | | | | |'); failed.append(i); continue
    if not os.path.exists(lp):
        print(f'| {i} | render failed | | | | |'); failed.append(i); continue
    r = np.asarray(Image.open(rp).convert('RGB')).astype(np.int16)
    o = np.asarray(Image.open(lp).convert('RGB')).astype(np.int16)
    if r.shape != o.shape:
        print(f'| {i} | size {o.shape} vs {r.shape} | | | | |'); failed.append(i); continue
    d = np.abs(r - o); px = d.max(axis=2)
    mean, p8, p32 = d.mean(), int(np.sum(px > 8)), int(np.sum(px > 32))
    row = f'| {i} | {np.mean(px == 0) * 100:.1f}% | {mean:.3f} | {px.max()} | {p8:,} | {p32:,} |'
    ok = True
    if a.exact and px.max() != 0: ok = False
    if limits:
        lm = limits.get(i)
        if lm is None: row += ' none |'; ok = False
        else:
            row += f' {lm[0]:.3f}, {lm[1]:,} |'
            if mean > lm[0] or p32 > lm[1]: ok = False
    if not ok: row += ' **FAIL**'; failed.append(i)
    print(row)
if failed:
    print(f'\nFAILED: {" ".join(failed)}')
    sys.exit(1)
print('\nall within limits' if (limits or a.exact) else '')
