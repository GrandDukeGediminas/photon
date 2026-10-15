#ifndef PHOTON_WEB_H
#define PHOTON_WEB_H
// Web wallpapers on Linux (docs/linux-port.md §5.3): WebKitGTK 4.1 web views in GTK 3 windows below the desktop, behind
// a small C interface so Swift never sees GObject signals or GTK types.
//
// - One window per monitor. Wayland with wlr-layer-shell: a gtk-layer-shell surface on the `background` layer, anchored
//   to all edges, exclusive zone -1, no keyboard focus, namespace "photon2". X11: an undecorated window with the
//   DESKTOP type hint, kept below, sticky, out of the taskbar and pager, at the monitor's geometry.
// - Pages load from `photon-web://wallpaper/<file>` (the wallpaper folder) and `photon-web://local/<absolute path>`
//   (folders of `directory` user properties), a secure, CORS-enabled scheme served from disk, like the macOS
//   WKURLSchemeHandler. Scripts run at document start in the main frame; `window.webkit.messageHandlers.photon
//   .postMessage(string)` reaches the host.
// - The GLib main loop is run by the host (photon_web_iterate) on the thread that called photon_web_init; every callback
//   arrives on that thread.

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct photon_web photon_web;

typedef struct {
    int x, y, width, height;   // logical geometry
    int scale;                 // integer scale factor (GTK 3 has no fractional scale)
    char connector[64];        // gdk_monitor_get_model (the connector on most compositors) or ""
} photon_web_monitor;

enum {
    PHOTON_WEB_LOADED = 0,     // the page finished loading (text: URI)
    PHOTON_WEB_MESSAGE = 1,    // window.webkit.messageHandlers.photon.postMessage(text)
    PHOTON_WEB_MONITORS = 2,   // a monitor was added or removed (view -1)
    PHOTON_WEB_CRASHED = 3,    // the web process ended (text: reason)
    PHOTON_WEB_RESULT = 4,     // photon_web_view_query result (text: the value as a string; tag in `view`'s high bits: see below)
    PHOTON_WEB_FAILED = 5,     // the load failed (text: error)
    PHOTON_WEB_SNAPSHOT = 6,   // photon_web_view_snapshot finished (text: the file, or "" when it failed)
};

/// Host callback: `view` is the view id (for RESULT: view | tag << 16).
typedef void (*photon_web_cb)(void *context, int view, int kind, const char *text);

/// gtk_init_check. 0 when there is no display to open.
int photon_web_init(void);
/// "wayland" or "x11" (the GDK backend in use).
const char *photon_web_backend(void);
/// 1 when windows can become layer-shell surfaces (Wayland compositor with zwlr_layer_shell_v1).
int photon_web_layer_shell(void);

/// The host. `root` is the wallpaper folder; `extra_roots` the folders `photon-web://local/` may serve.
photon_web *photon_web_create(photon_web_cb cb, void *context, const char *root, const char *const *extra_roots, int n_extra);
void photon_web_add_user_script(photon_web *w, const char *source);

int photon_web_monitor_count(photon_web *w);
int photon_web_monitor_get(photon_web *w, int index, photon_web_monitor *out);

/// A web view in a background window over monitor `monitor`; returns its id (≥ 0) or -1.
int photon_web_view_create(photon_web *w, int monitor);
/// The same over a split region of the monitor (x, y from its top-left, w × h; logical units).
int photon_web_view_create_region(photon_web *w, int monitor, int x, int y, int width, int height);
void photon_web_view_load(photon_web *w, int view, const char *uri);
/// Runs a script in the page's main world (result ignored).
void photon_web_view_run(photon_web *w, int view, const char *js);
/// Runs a script; the result as a string arrives as PHOTON_WEB_RESULT with `tag`.
void photon_web_view_query(photon_web *w, int view, const char *js, int tag);
void photon_web_view_set_muted(photon_web *w, int view, int muted);
/// The wallpaper-switch overlay over the page: premultiplied BGRA8 rows (`width` × `height`, scaled onto the view),
/// composited OVER the page; NULL removes it.
void photon_web_view_set_overlay(photon_web *w, int view, const void *bgra, int width, int height);
/// Writes the page's visible frame to `path` (a photon2 host snapshot: "PSN1", width, height, opaque BGRA8 rows) for
/// the host that takes over after a switch; PHOTON_WEB_SNAPSHOT reports it.
void photon_web_view_snapshot(photon_web *w, int view, const char *path);
void photon_web_view_destroy(photon_web *w, int view);
void photon_web_destroy(photon_web *w);

/// Dispatches pending GLib events and waits up to `timeout_ms` for more. Returns the number of events handled.
int photon_web_iterate(int timeout_ms);

#ifdef __cplusplus
}
#endif
#endif
