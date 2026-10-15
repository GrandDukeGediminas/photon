#ifndef PHOTON_CPIPEWIRE_SHIM_H
#define PHOTON_CPIPEWIRE_SHIM_H
// PipeWire (pw_stream on the default sink's monitor) for the audio spectrum capture (docs/linux-port.md §3.6). Swift
// calls it only through CPhotonSystem (the SPA pod builders are macros and inline functions); this module exists so
// SwiftPM passes pkg-config's include and link flags to that target.
#include <pipewire/pipewire.h>
#endif
