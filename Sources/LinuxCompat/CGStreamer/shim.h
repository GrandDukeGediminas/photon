#ifndef PHOTON_CGSTREAMER_SHIM_H
#define PHOTON_CGSTREAMER_SHIM_H
// GStreamer (decodebin → videoconvert → appsink) for video textures, video wallpapers and their audio
// (docs/linux-port.md §3.5). Swift calls it only through CPhotonMedia, which keeps GLib's variadic API on the C side;
// this module exists so SwiftPM passes pkg-config's include and link flags to that target.
#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include <gst/video/video.h>
#endif
