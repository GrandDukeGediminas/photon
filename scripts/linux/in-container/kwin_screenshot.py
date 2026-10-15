#!/usr/bin/env python3
"""KWin's screenshot D-Bus API (org.kde.KWin.ScreenShot2.CaptureScreen) to a PNG, for the KDE check
(docs/linux-port.md §5.2). KWin must run with KWIN_SCREENSHOT_NO_PERMISSION_CHECKS=1 (it otherwise answers only
clients whose .desktop entry lists the interface).

    kwin_screenshot.py <output name> <out.png>
"""
import os
import sys

import numpy as np
from gi.repository import Gio, GLib
from PIL import Image


def main(name, path):
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    r, w = os.pipe()
    fds = Gio.UnixFDList.new()
    idx = fds.append(w)
    res, _ = bus.call_with_unix_fd_list_sync(
        'org.kde.KWin', '/org/kde/KWin/ScreenShot2', 'org.kde.KWin.ScreenShot2', 'CaptureScreen',
        GLib.Variant('(sa{sv}h)', (name, {'native-resolution': GLib.Variant('b', True)}, idx)),
        GLib.VariantType('(a{sv})'), Gio.DBusCallFlags.NONE, 10000, fds, None)
    os.close(w)
    for fd in fds.steal_fds():  # the list holds its own copy of the write end
        os.close(fd)
    data = bytearray()
    with os.fdopen(r, 'rb') as f:
        while chunk := f.read(1 << 20):
            data += chunk
    meta = res.unpack()[0]
    width, height, stride, fmt = meta['width'], meta['height'], meta['stride'], meta['format']
    # QImage::Format_RGB32 (4), ARGB32 (5), ARGB32_Premultiplied (6): 0xAARRGGBB words, little-endian B, G, R, A.
    if fmt not in (4, 5, 6):
        sys.exit(f'unexpected QImage format {fmt}')
    px = np.frombuffer(bytes(data), np.uint8)[:stride * height].reshape(height, stride)[:, :width * 4].reshape(height, width, 4)
    Image.fromarray(px[:, :, [2, 1, 0]].copy()).save(path)
    print(f'kwin screenshot {name}: {width}x{height} → {path}')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
