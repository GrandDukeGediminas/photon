#!/usr/bin/env python3
"""Writes the synthetic test textures (CC0) as Wallpaper Engine .tex files.

Format (PhotonCore/TexFile.swift): "TEXV0005\0" "TEXI0001\0" i32 format (0 = RGBA8888), i32 flags, i32 texture w/h,
i32 image w/h, i32 unused; "TEXB0003\0" i32 image count, i32 image format (-1 = raw pixels), then per image i32 mip count
and per mip i32 w, h, i32 compression (0), i32 decompressed size, i32 byte count, RGBA8 rows (top row first).
Every texture is generated from code, so the output is reproducible: `python3 make_tex.py` rewrites them all.
"""
import math
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def tex(width, height, pixels, flags=0, mips=True):
    """pixels: bytes, RGBA8, width*height*4. Mips are box-filtered down to 1x1."""
    levels = [(width, height, bytes(pixels))]
    while mips and (levels[-1][0] > 1 or levels[-1][1] > 1):
        w, h, p = levels[-1]
        nw, nh = max(w // 2, 1), max(h // 2, 1)
        out = bytearray(nw * nh * 4)
        for y in range(nh):
            for x in range(nw):
                for c in range(4):
                    s = 0
                    n = 0
                    for dy in (0, 1):
                        for dx in (0, 1):
                            sx, sy = min(2 * x + dx, w - 1), min(2 * y + dy, h - 1)
                            s += p[(sy * w + sx) * 4 + c]
                            n += 1
                    out[(y * nw + x) * 4 + c] = (s + n // 2) // n
        levels.append((nw, nh, bytes(out)))
    b = bytearray()
    b += b"TEXV0005\0TEXI0001\0"
    b += struct.pack("<7i", 0, flags, width, height, width, height, 0)
    b += b"TEXB0003\0"
    b += struct.pack("<iii", 1, -1, len(levels))
    for w, h, p in levels:
        b += struct.pack("<5i", w, h, 0, len(p), len(p))
        b += p
    return bytes(b)


def clamp8(v):
    return max(0, min(255, int(round(v))))


def image(w, h, fn):
    px = bytearray(w * h * 4)
    for y in range(h):
        for x in range(w):
            r, g, b, a = fn(x / (w - 1), y / (h - 1))
            i = (y * w + x) * 4
            px[i:i + 4] = bytes((clamp8(r * 255), clamp8(g * 255), clamp8(b * 255), clamp8(a * 255)))
    return px


def gradient(u, v):
    return (0.15 + 0.7 * u, 0.2 + 0.5 * v, 0.6 - 0.4 * u * v, 1)


def checker(u, v):
    c = (int(u * 8) + int(v * 8)) % 2
    return (0.9, 0.85, 0.2, 1) if c else (0.2, 0.3, 0.85, 1)


def disc(u, v):
    d = math.hypot(u - 0.5, v - 0.5) * 2
    a = max(0.0, min(1.0, (1 - d) * 8))  # soft edge
    return (1.0, 0.4 + 0.5 * v, 0.3, a)


def ring(u, v):
    d = math.hypot(u - 0.5, v - 0.5) * 2
    a = max(0.0, 1 - abs(d - 0.7) * 10)
    return (0.3, 1.0, 0.6, a)


def stripes(u, v):
    s = 0.5 + 0.5 * math.sin((u * 6 + v * 2) * math.pi * 2)
    return (0.2 + 0.6 * s, 0.25, 0.8 - 0.5 * s, 1)


def spark(u, v):
    d = math.hypot(u - 0.5, v - 0.5) * 2
    a = max(0.0, 1 - d) ** 2
    return (1, 1, 1, a)


def white(u, v):
    return (1, 1, 1, 1)


TEXTURES = {
    # images
    "images/materials/gradient.tex": (256, 144, gradient),
    "images/materials/checker.tex": (128, 128, checker),
    "images/materials/disc.tex": (128, 128, disc),
    "images/materials/ring.tex": (128, 128, ring),
    # effects
    "effects/materials/stripes.tex": (256, 144, stripes),
    "effects/materials/checker.tex": (128, 128, checker),
    # particles
    "particles/materials/gradient.tex": (128, 72, gradient),
    "particles/materials/spark.tex": (32, 32, spark),
    # text
    "text/materials/gradient.tex": (128, 72, gradient),
    # perspective
    "perspective/materials/checker.tex": (128, 128, checker),
    "perspective/materials/gradient.tex": (128, 72, gradient),
}


def main():
    for rel, (w, h, fn) in TEXTURES.items():
        path = os.path.join(ROOT, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(tex(w, h, image(w, h, fn)))
        print("wrote", rel)


if __name__ == "__main__":
    sys.exit(main())
