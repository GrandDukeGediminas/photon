#ifndef PHOTON_CPULSESIMPLE_SHIM_H
#define PHOTON_CPULSESIMPLE_SHIM_H
// PulseAudio's simple API: the `@DEFAULT_MONITOR@` record stream, the spectrum capture's fallback when no PipeWire
// daemon answers (docs/linux-port.md §3.6). Used from CPhotonSystem only.
#include <pulse/simple.h>
#include <pulse/error.h>
#endif
