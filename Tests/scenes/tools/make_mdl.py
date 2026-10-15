#!/usr/bin/env python3
"""Writes the synthetic test models (CC0) as Wallpaper Engine .mdl files (MDLV0017, one static mesh, no skeleton).

Layout read by PhotonCore/MdlFile.swift: "MDLV0017\0", u32 vertex flags, u32 materials per mesh (1), u32 mesh count (1);
per mesh: cstring material, u32 mesh flags (0: u16 indices), f32 bounds min[3] and max[3], u32 vertex flags, u32 byte
count + interleaved vertices (a_Position 0x1 float3, a_Normal 0x2 float3, a_TexCoord 0x8 float2), u32 byte count + u16
indices. `python3 make_mdl.py` rewrites them.
"""
import math
import os
import struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VFLAGS = 0x1 | 0x2 | 0x8


def mdl(material, vertices, indices):
    lo = [min(v[0][i] for v in vertices) for i in range(3)]
    hi = [max(v[0][i] for v in vertices) for i in range(3)]
    vb = b"".join(struct.pack("<8f", *p, *n, *uv) for p, n, uv in vertices)
    ib = struct.pack("<%dH" % len(indices), *indices)
    out = b"MDLV0017\0" + struct.pack("<III", VFLAGS, 1, 1)
    out += material.encode() + b"\0" + struct.pack("<I", 0) + struct.pack("<6f", *lo, *hi) + struct.pack("<I", VFLAGS)
    out += struct.pack("<I", len(vb)) + vb + struct.pack("<I", len(ib)) + ib
    return out


def cube(s):
    faces = [((1, 0, 0), (0, 0, -1), (0, 1, 0)), ((-1, 0, 0), (0, 0, 1), (0, 1, 0)),
             ((0, 1, 0), (1, 0, 0), (0, 0, -1)), ((0, -1, 0), (1, 0, 0), (0, 0, 1)),
             ((0, 0, 1), (1, 0, 0), (0, 1, 0)), ((0, 0, -1), (-1, 0, 0), (0, 1, 0))]
    verts, idx = [], []
    for n, u, v in faces:
        base = len(verts)
        for cu, cv in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
            p = tuple(s * (n[i] + cu * u[i] + cv * v[i]) for i in range(3))
            verts.append((p, n, ((cu + 1) / 2, (1 - cv) / 2)))
        idx += [base, base + 1, base + 2, base, base + 2, base + 3]
    return verts, idx


def torus(r1, r2, n1=32, n2=16):
    verts, idx = [], []
    for i in range(n1 + 1):
        a = 2 * math.pi * i / n1
        for j in range(n2 + 1):
            b = 2 * math.pi * j / n2
            c = (math.cos(a), math.sin(a))
            p = ((r1 + r2 * math.cos(b)) * c[0], (r1 + r2 * math.cos(b)) * c[1], r2 * math.sin(b))
            n = (math.cos(b) * c[0], math.cos(b) * c[1], math.sin(b))
            verts.append((p, n, (i / n1, j / n2)))
    for i in range(n1):
        for j in range(n2):
            a, b = i * (n2 + 1) + j, (i + 1) * (n2 + 1) + j
            idx += [a, b, a + 1, b, b + 1, a + 1]
    return verts, idx


MODELS = {
    "perspective/models/cube.mdl": ("materials/cube.json", cube(100)),
    "perspective/models/torus.mdl": ("materials/torus.json", torus(120, 40)),
}

if __name__ == "__main__":
    for rel, (mat, (v, i)) in MODELS.items():
        path = os.path.join(ROOT, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(mdl(mat, v, i))
        print("wrote", rel)
