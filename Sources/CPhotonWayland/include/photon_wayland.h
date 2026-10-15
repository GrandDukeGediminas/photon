#ifndef PHOTON_WAYLAND_H
#define PHOTON_WAYLAND_H
// The Wayland side of photon2's desktop host (docs/linux-port.md §5.2) behind a small C interface, so Swift never sees
// libwayland's listener structs or the generated protocol code:
//
// - Outputs: wl_output (v4: name, description, scale) with zxdg_output_v1 logical geometry, tracked across hotplug
//   (registry global / global_remove).
// - Background surfaces: one zwlr_layer_surface_v1 per output on the `background` layer, anchored to all four edges,
//   exclusive zone -1, no keyboard focus. The buffer size follows wp_fractional_scale_v1 (preferred scale in 120ths)
//   through wp_viewporter, else the output's integer scale (wl_surface.set_buffer_scale). Frames arrive either through
//   a Vulkan swapchain on the wl_surface (VK_KHR_wayland_surface; photon_wl_surface_handle) or as wl_shm buffers.
// - Pause-rule inputs: zwlr_foreign_toplevel_manager_v1 (wlroots compositors: sway, labwc, Hyprland, river, Wayfire; not
//   GNOME or KDE) gives each toplevel's activated / maximized / minimized / fullscreen state and the outputs it is on.
// - KWin (Plasma): org_kde_plasma_window_management gives each window's state flags (active, minimized, maximized,
//   fullscreen, skip-taskbar, …), geometry in global logical coordinates, pid and app_id; org_kde_plasma_virtual_desktop_
//   management says which virtual desktops are current. KWin advertises the first only to clients whose .desktop entry
//   lists it in X-KDE-Wayland-Interfaces (packaging/linux/photon2-kwin.desktop).
// - GNOME (no layer-shell): plain xdg_toplevel surfaces that the photon2 GNOME Shell extension shows in the background
//   (photon_wl_toplevel_surface_create; packaging/gnome-shell).
// - A test client (xdg_toplevel, fullscreen / maximized / plain) for checking the rules under a headless compositor.

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct photon_wl photon_wl;
typedef struct photon_wl_surface photon_wl_surface;

typedef struct {
    uint32_t global;             // registry name: stable for the output's lifetime
    char name[64];               // connector (wl_output.name v4 or zxdg_output_v1.name), e.g. "HEADLESS-1", "DP-1"
    char description[128];
    int32_t x, y, width, height; // logical geometry (zxdg_output_v1), else the mode divided by the scale
    int32_t mode_width, mode_height;
    int32_t scale;               // wl_output.scale (integer)
    int done;                    // the output's first `done` arrived
} photon_wl_output;

typedef struct {
    uint32_t id;                 // client-side counter
    int activated, maximized, minimized, fullscreen;
    int n_outputs;
    uint32_t outputs[8];         // output globals, in output_enter order
    char app_id[128];
    char title[128];
} photon_wl_toplevel;

/// A window from org_kde_plasma_window_management (KWin).
typedef struct {
    uint32_t id;                 // client-side counter
    uint32_t state;              // org_kde_plasma_window_management.state flags: active 1, minimized 2, maximized 4,
                                 // fullscreen 8, keep_below 32, on_all_desktops 64, skiptaskbar 4096, skipswitcher 1 << 18
    int32_t x, y, width, height; // geometry in global logical coordinates (0 × 0 until the compositor sent it)
    uint32_t pid;
    int on_current_desktop;      // on all desktops, on none in particular, or on an activated virtual desktop
    int ready;                   // initial_state arrived
    char app_id[128];
    char title[128];
} photon_wl_plasma_window;

typedef struct {
    int configured;              // a layer-surface configure was acknowledged
    int closed;                  // the compositor closed the layer surface (output gone)
    int width, height;           // logical size from the last configure
    int scale120;                // preferred scale in 120ths (fractional-scale), or the integer output scale × 120
    int buffer_width, buffer_height; // the buffer size that maps 1:1 onto the output's pixels
    uint32_t changes;            // increments on every configure or scale change
} photon_wl_surface_state;

/// Connects (NULL: $WAYLAND_DISPLAY) and binds the globals with two roundtrips. NULL on failure, with `error` set.
photon_wl *photon_wl_connect(const char *display_name, char *error, size_t error_size);
void photon_wl_disconnect(photon_wl *wl);
/// The `struct wl_display *` (VK_KHR_wayland_surface).
void *photon_wl_display(photon_wl *wl);
/// Sends pending requests, waits up to `timeout_ms` (0: no wait) for events and dispatches them. -1 when the connection
/// is gone.
int photon_wl_dispatch(photon_wl *wl, int timeout_ms);
int photon_wl_roundtrip(photon_wl *wl);
/// 1 when the compositor advertised the global interface (e.g. "zwlr_layer_shell_v1") and it was bound.
int photon_wl_has(photon_wl *wl, const char *interface);

/// Increments whenever an output appears, disappears or changes geometry, name or scale.
uint32_t photon_wl_outputs_serial(photon_wl *wl);
int photon_wl_output_count(photon_wl *wl);
/// Outputs in advertisement order. 0 when `index` is out of range.
int photon_wl_output_get(photon_wl *wl, int index, photon_wl_output *out);

/// Toplevels known through wlr-foreign-toplevel-management (0 without the protocol).
int photon_wl_toplevel_count(photon_wl *wl);
int photon_wl_toplevel_get(photon_wl *wl, int index, photon_wl_toplevel *out);

/// Windows known through org_kde_plasma_window_management (0 without the protocol, i.e. not KWin or not permitted).
int photon_wl_plasma_window_count(photon_wl *wl);
int photon_wl_plasma_window_get(photon_wl *wl, int index, photon_wl_plasma_window *out);
/// KWin's "show desktop" mode is on (every window is hidden).
int photon_wl_plasma_showing_desktop(photon_wl *wl);

/// A background layer surface on the output with registry name `output_global` (NULL when that output or layer-shell
/// is missing). The first configure arrives with a later dispatch.
photon_wl_surface *photon_wl_surface_create(photon_wl *wl, uint32_t output_global, const char *name_space);
// A layer surface over a split region of the output: (x, y) from the output's top-left, w × h, logical units.
photon_wl_surface *photon_wl_surface_create_region(photon_wl *wl, uint32_t output_global, const char *name_space,
                                                   int x, int y, int w, int h);
void photon_wl_surface_get_state(photon_wl_surface *s, photon_wl_surface_state *out);
/// GNOME: an xdg_toplevel sized to the output's logical size, with `app_id` and `title` (the Shell extension matches
/// both and shows the window inside the monitor's background actors). NULL without xdg_wm_base or the output.
photon_wl_surface *photon_wl_toplevel_surface_create(photon_wl *wl, uint32_t output_global, const char *app_id, const char *title);
// GNOME, a split region: the window has the region's size (the title tells the extension where it goes).
photon_wl_surface *photon_wl_toplevel_surface_create_region(photon_wl *wl, uint32_t output_global, const char *app_id, const char *title,
                                                            int w, int h);
/// The `struct wl_surface *` (VK_KHR_wayland_surface).
void *photon_wl_surface_handle(photon_wl_surface *s);
/// Sets the surface state that maps a buffer of `buffer_width` × `buffer_height` onto the logical size (viewport
/// destination or buffer scale) and the opaque region. Takes effect with the next commit: the Vulkan present's, or
/// `photon_wl_surface_commit`.
void photon_wl_surface_prepare(photon_wl_surface *s);
void photon_wl_surface_commit(photon_wl_surface *s);
/// Readback path: copies tightly packed BGRA8 rows (`width` × `height`, the buffer size) into a wl_shm XRGB8888 buffer,
/// attaches, damages and commits. 0 when no buffer could be made.
int photon_wl_surface_present_shm(photon_wl_surface *s, const void *bgra, int width, int height);
void photon_wl_surface_destroy(photon_wl_surface *s);

/// The pointer on the seat (wl_seat / wl_pointer): which of this connection's layer surfaces it is over (NULL: none,
/// i.e. over a window or another client's surface), the surface-local logical position, and the left button.
/// Events reach a layer surface only while nothing is above it, which is what "on the desktop" means here.
typedef struct {
    int has_pointer;              // the seat has a pointer capability
    photon_wl_surface *focus;     // the surface under the pointer, or NULL
    double x, y;                  // surface-local logical coordinates of the last enter / motion
    int left;                     // BTN_LEFT is held (pressed on one of our surfaces)
    uint32_t buttons;             // left-button presses seen so far
} photon_wl_pointer;

void photon_wl_pointer_get(photon_wl *wl, photon_wl_pointer *out);

/// A stand-in application for testing the pause rules: an xdg_toplevel with `app_id` (NULL: "photon2-test-client"),
/// fullscreen ("fullscreen"), maximized ("maximized") or neither ("plain"), filled with `rgb`, kept for `seconds`.
/// 0 on success.
int photon_wl_test_client(const char *mode, int width, int height, uint32_t rgb, double seconds, const char *app_id);
/// The same, fullscreen on the output named `output_name` (wl_output v4 name; NULL: the compositor's choice).
int photon_wl_test_client_on(const char *mode, int width, int height, uint32_t rgb, double seconds, const char *app_id,
                             const char *output_name);

/// A stand-in mouse (zwlr_virtual_pointer_v1, wlroots compositors): `actions` are "move X Y", "press", "release",
/// "click X Y" (move, press, release) and "wait S", separated by ';', with X and Y in a layout of
/// `layout_width` × `layout_height` logical pixels. 0 on success, 1 without the protocol.
int photon_wl_pointer_test(int layout_width, int layout_height, const char *actions);

#ifdef __cplusplus
}
#endif
#endif
