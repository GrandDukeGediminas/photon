#ifndef PHOTON_CGIO_SHIM_H
#define PHOTON_CGIO_SHIM_H
// GIO's D-Bus client (MPRIS media sessions, UPower, logind, the screensaver interfaces; docs/linux-port.md §5.1).
// Used from CPhotonSystem only, so Swift never sees GLib's variadic API.
#include <gio/gio.h>
#endif
