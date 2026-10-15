#!/usr/bin/env python3
"""Drop one library's symbol-version requirements from an ELF64 little-endian executable (docs/linux-port.md §6.2).

usage: elf-drop-verneed.py <file> <soname>

Removes the soname's entry from .gnu.version_r (unlinks it, lowers DT_VERNEEDNUM and the section's entry count) and
marks every dynamic symbol that used one of its versions as unversioned global (.gnu.version = 1). The binary then
binds those symbols to whatever libcurl.so.4 the system has: Ubuntu's names its symbols CURL_OPENSSL_4, Fedora's has
no version nodes, and with the requirement in place glibc prints "no version information available" at every start.
"""
import struct, sys

SHT_DYNAMIC, SHT_GNU_VERNEED, SHT_GNU_VERSYM = 6, 0x6ffffffe, 0x6fffffff
DT_VERNEED, DT_VERNEEDNUM = 0x6ffffffe, 0x6fffffff

path, soname = sys.argv[1], sys.argv[2].encode()
b = bytearray(open(path, 'rb').read())
assert b[:4] == b'\x7fELF' and b[4] == 2 and b[5] == 1, 'ELF64 little-endian only'
shoff, = struct.unpack_from('<Q', b, 0x28)
shentsize, shnum = struct.unpack_from('<HH', b, 0x3A)
secs = []
for i in range(shnum):
    o = shoff + i * shentsize
    name, typ, flags, addr, off, size, link, info, align, entsize = struct.unpack_from('<IIQQQQIIQQ', b, o)
    secs.append(dict(hdr=o, type=typ, addr=addr, off=off, size=size, link=link, info=info))
vn = next(s for s in secs if s['type'] == SHT_GNU_VERNEED)
strtab = secs[vn['link']]['off']
cstr = lambda o: bytes(b[strtab + o:b.index(0, strtab + o)])

prev, cur, removed = None, vn['off'], []
for _ in range(vn['info']):
    ver, cnt, file, aux, nxt = struct.unpack_from('<HHIII', b, cur)
    if cstr(file) == soname:
        a = cur + aux
        for _ in range(cnt):
            h, fl, other, nm, anext = struct.unpack_from('<IHHII', b, a)
            removed.append(other); a += anext
        if prev is None:  # the head: move the section start (and DT_VERNEED) to the next entry
            assert nxt, 'only entry'
            vn['off'] += nxt; vn['addr'] += nxt
            struct.pack_into('<QQ', b, vn['hdr'] + 16, vn['addr'], vn['off'])
        else:
            pver, pcnt, pfile, paux, pnext = struct.unpack_from('<HHIII', b, prev)
            struct.pack_into('<I', b, prev + 12, pnext + nxt if nxt else 0)
        break
    prev, cur = cur, cur + nxt
else:
    print(f'{soname.decode()}: no version requirement'); sys.exit(0)

struct.pack_into('<I', b, vn['hdr'] + 44, vn['info'] - 1)  # sh_info: entry count
dyn = next(s for s in secs if s['type'] == SHT_DYNAMIC)
for o in range(dyn['off'], dyn['off'] + dyn['size'], 16):
    tag, val = struct.unpack_from('<qQ', b, o)
    if tag == DT_VERNEEDNUM: struct.pack_into('<Q', b, o + 8, val - 1)
    if tag == DT_VERNEED and prev is None: struct.pack_into('<Q', b, o + 8, vn['addr'])
vs = next(s for s in secs if s['type'] == SHT_GNU_VERSYM)
n = 0
for o in range(vs['off'], vs['off'] + vs['size'], 2):
    v, = struct.unpack_from('<H', b, o)
    if v & 0x7fff in removed:
        struct.pack_into('<H', b, o, 1); n += 1
open(path, 'wb').write(b)
print(f'{soname.decode()}: dropped version indices {removed}, {n} symbols unversioned')
