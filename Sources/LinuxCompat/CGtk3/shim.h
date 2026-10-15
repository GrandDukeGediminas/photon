#ifndef PHOTON_CGTK3_SHIM_H
#define PHOTON_CGTK3_SHIM_H
// GTK 3 for the Linux app's windows (`photon-linux app`, docs/linux-port.md §6.1). GTK 3 rather than 4: photon-linux
// already links WebKitGTK 4.1 (GTK 3) for web wallpapers and javascriptcoregtk-4.1 for SceneScript, and one process
// cannot load GTK 3 and GTK 4 together.
#include <gtk/gtk.h>
#include <glib-unix.h>
#endif
