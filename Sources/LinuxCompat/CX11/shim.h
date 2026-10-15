#ifndef PHOTON_CX11_SHIM_H
#define PHOTON_CX11_SHIM_H
// Xlib, XRandR (per-monitor geometry), MIT-SHM, and DPMS + MIT-SCREEN-SAVER (display sleep and screensaver for the
// playback rules) for the X11 desktop host (docs/linux-port.md §5); XInput 2 raw button events (desktop clicks) and
// XTEST (the pointer test client).
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/extensions/Xrandr.h>
#include <X11/extensions/XShm.h>
#include <X11/extensions/dpms.h>
#include <X11/extensions/scrnsaver.h>
#include <X11/extensions/XInput2.h>
#include <X11/extensions/XTest.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#endif
