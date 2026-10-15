// Wayland client side of the desktop host (photon_wayland.h, docs/linux-port.md §5.2).
#define _GNU_SOURCE
#include "photon_wayland.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

#include "protocols/fractional-scale-v1-client-protocol.h"
#include "protocols/plasma-virtual-desktop-client-protocol.h"
#include "protocols/plasma-window-management-client-protocol.h"
#include "protocols/viewporter-client-protocol.h"
#include "protocols/wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"
#include "protocols/wlr-layer-shell-unstable-v1-client-protocol.h"
#include "protocols/wlr-virtual-pointer-unstable-v1-client-protocol.h"
#include "protocols/xdg-output-unstable-v1-client-protocol.h"
#include "protocols/xdg-shell-client-protocol.h"

#define MAX_OUTPUTS 32
#define MAX_TOPLEVELS 256
#define MAX_BOUND 32
#define MAX_SURFACES 32
#define MAX_PLASMA_WINDOWS 256
#define MAX_DESKTOPS 32
#define MAX_WINDOW_DESKTOPS 8
#define BTN_LEFT_CODE 0x110

typedef struct {
    photon_wl_output info;
    struct wl_output *output;
    struct zxdg_output_v1 *xdg;
    int have_logical;
} output_rec;

typedef struct toplevel_rec {
    photon_wl_toplevel info;
    struct zwlr_foreign_toplevel_handle_v1 *handle;
    photon_wl_toplevel pending;
} toplevel_rec;

// A window as org_kde_plasma_window describes it (KWin), with the virtual desktops it is on.
typedef struct plasma_window_rec {
    photon_wl_plasma_window info;
    struct org_kde_plasma_window *window;
    char desktops[MAX_WINDOW_DESKTOPS][64];
    int n_desktops;
    struct photon_wl *wl;
} plasma_window_rec;

typedef struct desktop_rec {
    char id[64];
    int activated;
    struct org_kde_plasma_virtual_desktop *desktop;
    struct photon_wl *wl;
} desktop_rec;

struct photon_wl {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    struct zwlr_layer_shell_v1 *layer_shell;
    struct zxdg_output_manager_v1 *xdg_output_manager;
    struct wp_viewporter *viewporter;
    struct wp_fractional_scale_manager_v1 *fractional;
    struct zwlr_foreign_toplevel_manager_v1 *toplevels_manager;
    output_rec *outputs[MAX_OUTPUTS];
    int n_outputs;
    uint32_t outputs_serial;
    toplevel_rec *toplevels[MAX_TOPLEVELS];
    int n_toplevels;
    uint32_t next_toplevel;
    char bound[MAX_BOUND][64];
    int n_bound;
    struct wl_seat *seat;
    struct wl_pointer *pointer;
    photon_wl_pointer pointer_state;
    photon_wl_surface *surfaces[MAX_SURFACES];
    int n_surfaces;
    struct xdg_wm_base *wm_base;
    struct org_kde_plasma_window_management *plasma;
    struct org_kde_plasma_virtual_desktop_management *plasma_desktops;
    plasma_window_rec *plasma_windows[MAX_PLASMA_WINDOWS];
    int n_plasma_windows;
    uint32_t next_plasma_window;
    int showing_desktop;
    desktop_rec *desktops[MAX_DESKTOPS];
    int n_desktops;
};

typedef struct {
    struct wl_buffer *buffer;
    void *data;
    size_t size;
    int width, height, busy;
} shm_buffer;

struct photon_wl_surface {
    photon_wl *wl;
    uint32_t output_global;
    struct wl_surface *surface;
    struct zwlr_layer_surface_v1 *layer;
    // GNOME (no layer-shell): a plain xdg_toplevel the shell extension shows in the background (photon_wl_toplevel_surface_create).
    struct xdg_surface *xsurface;
    struct xdg_toplevel *xtoplevel;
    struct wp_viewport *viewport;
    struct wp_fractional_scale_v1 *fractional;
    photon_wl_surface_state state;
    int preferred120;           // from wp_fractional_scale_v1, 0 until the first event
    shm_buffer buffers[2];
    // A split region (docs/re/09 §8.3): the surface covers only this logical size of its output (0: the whole output).
    int region_w, region_h;
};

// MARK: - Outputs

static output_rec *output_by_proxy(photon_wl *wl, struct wl_output *o) {
    for (int i = 0; i < wl->n_outputs; i++) if (wl->outputs[i]->output == o) return wl->outputs[i];
    return NULL;
}

static output_rec *output_by_global(photon_wl *wl, uint32_t g) {
    for (int i = 0; i < wl->n_outputs; i++) if (wl->outputs[i]->info.global == g) return wl->outputs[i];
    return NULL;
}

static void out_geometry(void *d, struct wl_output *o, int32_t x, int32_t y, int32_t pw, int32_t ph, int32_t sub,
                         const char *make, const char *model, int32_t transform) {
    output_rec *r = d;
    if (!r->have_logical) { r->info.x = x; r->info.y = y; }
}
static void out_mode(void *d, struct wl_output *o, uint32_t flags, int32_t w, int32_t h, int32_t refresh) {
    output_rec *r = d;
    if (flags & WL_OUTPUT_MODE_CURRENT) { r->info.mode_width = w; r->info.mode_height = h; }
}
static void out_done(void *d, struct wl_output *o) {
    output_rec *r = d;
    if (!r->have_logical && r->info.scale > 0) {
        r->info.width = r->info.mode_width / r->info.scale;
        r->info.height = r->info.mode_height / r->info.scale;
    }
    r->info.done = 1;
}
static void out_scale(void *d, struct wl_output *o, int32_t f) { ((output_rec *)d)->info.scale = f; }
static void out_name(void *d, struct wl_output *o, const char *n) {
    snprintf(((output_rec *)d)->info.name, sizeof ((output_rec *)d)->info.name, "%s", n);
}
static void out_description(void *d, struct wl_output *o, const char *n) {
    snprintf(((output_rec *)d)->info.description, sizeof ((output_rec *)d)->info.description, "%s", n);
}

// The serial is bumped from the wrappers below, which know the photon_wl.
typedef struct { photon_wl *wl; output_rec *rec; } output_ctx;

static void out_done_wrap(void *d, struct wl_output *o) {
    output_ctx *c = d;
    out_done(c->rec, o);
    c->wl->outputs_serial++;
}
static void out_geometry_wrap(void *d, struct wl_output *o, int32_t x, int32_t y, int32_t pw, int32_t ph, int32_t sub,
                              const char *make, const char *model, int32_t transform) {
    out_geometry(((output_ctx *)d)->rec, o, x, y, pw, ph, sub, make, model, transform);
}
static void out_mode_wrap(void *d, struct wl_output *o, uint32_t f, int32_t w, int32_t h, int32_t r) {
    out_mode(((output_ctx *)d)->rec, o, f, w, h, r);
}
static void out_scale_wrap(void *d, struct wl_output *o, int32_t f) { out_scale(((output_ctx *)d)->rec, o, f); }
static void out_name_wrap(void *d, struct wl_output *o, const char *n) { out_name(((output_ctx *)d)->rec, o, n); }
static void out_description_wrap(void *d, struct wl_output *o, const char *n) { out_description(((output_ctx *)d)->rec, o, n); }

static const struct wl_output_listener output_listener = {
    .geometry = out_geometry_wrap, .mode = out_mode_wrap, .done = out_done_wrap, .scale = out_scale_wrap,
    .name = out_name_wrap, .description = out_description_wrap,
};

static void xdg_logical_position(void *d, struct zxdg_output_v1 *x, int32_t px, int32_t py) {
    output_ctx *c = d;
    c->rec->info.x = px; c->rec->info.y = py; c->rec->have_logical = 1;
}
static void xdg_logical_size(void *d, struct zxdg_output_v1 *x, int32_t w, int32_t h) {
    output_ctx *c = d;
    c->rec->info.width = w; c->rec->info.height = h; c->rec->have_logical = 1;
}
static void xdg_done(void *d, struct zxdg_output_v1 *x) { ((output_ctx *)d)->wl->outputs_serial++; }
static void xdg_name(void *d, struct zxdg_output_v1 *x, const char *n) {
    output_ctx *c = d;
    if (!c->rec->info.name[0]) snprintf(c->rec->info.name, sizeof c->rec->info.name, "%s", n);
}
static void xdg_description(void *d, struct zxdg_output_v1 *x, const char *n) {
    output_ctx *c = d;
    if (!c->rec->info.description[0]) snprintf(c->rec->info.description, sizeof c->rec->info.description, "%s", n);
}
static const struct zxdg_output_v1_listener xdg_output_listener = {
    .logical_position = xdg_logical_position, .logical_size = xdg_logical_size, .done = xdg_done,
    .name = xdg_name, .description = xdg_description,
};

static void attach_xdg_output(photon_wl *wl, output_rec *r, output_ctx *ctx) {
    if (!wl->xdg_output_manager || r->xdg) return;
    r->xdg = zxdg_output_manager_v1_get_xdg_output(wl->xdg_output_manager, r->output);
    zxdg_output_v1_add_listener(r->xdg, &xdg_output_listener, ctx);
}

// MARK: - Foreign toplevels

static toplevel_rec *toplevel_by_handle(photon_wl *wl, struct zwlr_foreign_toplevel_handle_v1 *h) {
    for (int i = 0; i < wl->n_toplevels; i++) if (wl->toplevels[i]->handle == h) return wl->toplevels[i];
    return NULL;
}

typedef struct { photon_wl *wl; toplevel_rec *rec; } toplevel_ctx;

static void tl_title(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, const char *t) {
    toplevel_ctx *c = d; snprintf(c->rec->pending.title, sizeof c->rec->pending.title, "%s", t);
}
static void tl_app_id(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, const char *t) {
    toplevel_ctx *c = d; snprintf(c->rec->pending.app_id, sizeof c->rec->pending.app_id, "%s", t);
}
static void tl_output_enter(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_output *o) {
    toplevel_ctx *c = d;
    output_rec *r = output_by_proxy(c->wl, o);
    if (!r) return;
    photon_wl_toplevel *p = &c->rec->pending;
    for (int i = 0; i < p->n_outputs; i++) if (p->outputs[i] == r->info.global) return;
    if (p->n_outputs < 8) p->outputs[p->n_outputs++] = r->info.global;
}
static void tl_output_leave(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_output *o) {
    toplevel_ctx *c = d;
    output_rec *r = output_by_proxy(c->wl, o);
    if (!r) return;
    photon_wl_toplevel *p = &c->rec->pending;
    for (int i = 0; i < p->n_outputs; i++) {
        if (p->outputs[i] != r->info.global) continue;
        memmove(&p->outputs[i], &p->outputs[i + 1], (size_t)(p->n_outputs - i - 1) * sizeof p->outputs[0]);
        p->n_outputs--;
        return;
    }
}
static void tl_state(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_array *states) {
    toplevel_ctx *c = d;
    photon_wl_toplevel *p = &c->rec->pending;
    p->activated = p->maximized = p->minimized = p->fullscreen = 0;
    uint32_t *s;
    wl_array_for_each(s, states) {
        switch (*s) {
        case ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MAXIMIZED: p->maximized = 1; break;
        case ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MINIMIZED: p->minimized = 1; break;
        case ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED: p->activated = 1; break;
        case ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_FULLSCREEN: p->fullscreen = 1; break;
        }
    }
}
static void tl_done(void *d, struct zwlr_foreign_toplevel_handle_v1 *h) {
    toplevel_ctx *c = d;
    c->rec->info = c->rec->pending;
}
static void tl_closed(void *d, struct zwlr_foreign_toplevel_handle_v1 *h) {
    toplevel_ctx *c = d;
    photon_wl *wl = c->wl;
    for (int i = 0; i < wl->n_toplevels; i++) {
        if (wl->toplevels[i] != c->rec) continue;
        memmove(&wl->toplevels[i], &wl->toplevels[i + 1], (size_t)(wl->n_toplevels - i - 1) * sizeof wl->toplevels[0]);
        wl->n_toplevels--;
        break;
    }
    zwlr_foreign_toplevel_handle_v1_destroy(h);
    free(c->rec);
    free(c);
}
static void tl_parent(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct zwlr_foreign_toplevel_handle_v1 *p) {}
static const struct zwlr_foreign_toplevel_handle_v1_listener toplevel_listener = {
    .title = tl_title, .app_id = tl_app_id, .output_enter = tl_output_enter, .output_leave = tl_output_leave,
    .state = tl_state, .done = tl_done, .closed = tl_closed, .parent = tl_parent,
};

static void tlm_toplevel(void *d, struct zwlr_foreign_toplevel_manager_v1 *m, struct zwlr_foreign_toplevel_handle_v1 *h) {
    photon_wl *wl = d;
    toplevel_rec *r = calloc(1, sizeof *r);
    toplevel_ctx *c = calloc(1, sizeof *c);
    r->handle = h;
    r->pending.id = r->info.id = ++wl->next_toplevel;
    c->wl = wl; c->rec = r;
    if (wl->n_toplevels < MAX_TOPLEVELS) wl->toplevels[wl->n_toplevels++] = r;
    zwlr_foreign_toplevel_handle_v1_add_listener(h, &toplevel_listener, c);
}
static void tlm_finished(void *d, struct zwlr_foreign_toplevel_manager_v1 *m) {}
static const struct zwlr_foreign_toplevel_manager_v1_listener toplevel_manager_listener = {
    .toplevel = tlm_toplevel, .finished = tlm_finished,
};

// MARK: - Plasma window management (KWin)

static void pw_mark(plasma_window_rec *r);

static int desktop_active(photon_wl *wl, const char *id) {
    for (int i = 0; i < wl->n_desktops; i++) if (!strcmp(wl->desktops[i]->id, id)) return wl->desktops[i]->activated;
    return 0;
}

/// On the current virtual desktop: on all desktops, on none in particular, or on one that is activated. Without the
/// virtual-desktop protocol every window counts.
static void pw_update_desktop(plasma_window_rec *r) {
    photon_wl *wl = r->wl;
    int on = (r->info.state & ORG_KDE_PLASMA_WINDOW_MANAGEMENT_STATE_ON_ALL_DESKTOPS) || r->n_desktops == 0 || !wl->plasma_desktops;
    for (int i = 0; !on && i < r->n_desktops; i++) on = desktop_active(wl, r->desktops[i]);
    r->info.on_current_desktop = on;
}

static void pw_mark(plasma_window_rec *r) { pw_update_desktop(r); }

static void pw_title(void *d, struct org_kde_plasma_window *w, const char *t) {
    plasma_window_rec *r = d; snprintf(r->info.title, sizeof r->info.title, "%s", t ? t : "");
}
static void pw_app_id(void *d, struct org_kde_plasma_window *w, const char *t) {
    plasma_window_rec *r = d; snprintf(r->info.app_id, sizeof r->info.app_id, "%s", t ? t : "");
}
static void pw_state(void *d, struct org_kde_plasma_window *w, uint32_t flags) {
    plasma_window_rec *r = d; r->info.state = flags; pw_mark(r);
}
static void pw_vd_changed(void *d, struct org_kde_plasma_window *w, int32_t n) {}
static void pw_icon_name(void *d, struct org_kde_plasma_window *w, const char *n) {}
static void plasma_window_drop(plasma_window_rec *r) {
    photon_wl *wl = r->wl;
    for (int i = 0; i < wl->n_plasma_windows; i++) {
        if (wl->plasma_windows[i] != r) continue;
        memmove(&wl->plasma_windows[i], &wl->plasma_windows[i + 1], (size_t)(wl->n_plasma_windows - i - 1) * sizeof wl->plasma_windows[0]);
        wl->n_plasma_windows--;
        break;
    }
    if (org_kde_plasma_window_get_version(r->window) >= ORG_KDE_PLASMA_WINDOW_DESTROY_SINCE_VERSION) org_kde_plasma_window_destroy(r->window);
    else wl_proxy_destroy((struct wl_proxy *)r->window);
    free(r);
}
static void pw_unmapped(void *d, struct org_kde_plasma_window *w) { plasma_window_drop(d); }
static void pw_initial_state(void *d, struct org_kde_plasma_window *w) { ((plasma_window_rec *)d)->info.ready = 1; }
static void pw_parent(void *d, struct org_kde_plasma_window *w, struct org_kde_plasma_window *p) {}
static void pw_geometry(void *d, struct org_kde_plasma_window *w, int32_t x, int32_t y, uint32_t width, uint32_t height) {
    plasma_window_rec *r = d;
    r->info.x = x; r->info.y = y; r->info.width = (int32_t)width; r->info.height = (int32_t)height;
}
static void pw_icon_changed(void *d, struct org_kde_plasma_window *w) {}
static void pw_pid(void *d, struct org_kde_plasma_window *w, uint32_t pid) { ((plasma_window_rec *)d)->info.pid = pid; }
static void pw_vd_entered(void *d, struct org_kde_plasma_window *w, const char *id) {
    plasma_window_rec *r = d;
    for (int i = 0; i < r->n_desktops; i++) if (!strcmp(r->desktops[i], id)) return;
    if (r->n_desktops < MAX_WINDOW_DESKTOPS) snprintf(r->desktops[r->n_desktops++], 64, "%s", id);
    pw_mark(r);
}
static void pw_vd_left(void *d, struct org_kde_plasma_window *w, const char *id) {
    plasma_window_rec *r = d;
    for (int i = 0; i < r->n_desktops; i++) {
        if (strcmp(r->desktops[i], id)) continue;
        memmove(r->desktops[i], r->desktops[i + 1], (size_t)(r->n_desktops - i - 1) * 64);
        r->n_desktops--;
        break;
    }
    pw_mark(r);
}
static void pw_app_menu(void *d, struct org_kde_plasma_window *w, const char *s, const char *o) {}
static void pw_activity(void *d, struct org_kde_plasma_window *w, const char *id) {}
static void pw_resource_name(void *d, struct org_kde_plasma_window *w, const char *n) {}
static const struct org_kde_plasma_window_listener plasma_window_listener = {
    .title_changed = pw_title, .app_id_changed = pw_app_id, .state_changed = pw_state,
    .virtual_desktop_changed = pw_vd_changed, .themed_icon_name_changed = pw_icon_name, .unmapped = pw_unmapped,
    .initial_state = pw_initial_state, .parent_window = pw_parent, .geometry = pw_geometry, .icon_changed = pw_icon_changed,
    .pid_changed = pw_pid, .virtual_desktop_entered = pw_vd_entered, .virtual_desktop_left = pw_vd_left,
    .application_menu = pw_app_menu, .activity_entered = pw_activity, .activity_left = pw_activity,
    .resource_name_changed = pw_resource_name,
};

static void plasma_window_add(photon_wl *wl, struct org_kde_plasma_window *w) {
    if (!w) return;
    if (wl->n_plasma_windows >= MAX_PLASMA_WINDOWS) { wl_proxy_destroy((struct wl_proxy *)w); return; }
    plasma_window_rec *r = calloc(1, sizeof *r);
    r->window = w;
    r->wl = wl;
    r->info.id = ++wl->next_plasma_window;
    r->info.on_current_desktop = 1;
    wl->plasma_windows[wl->n_plasma_windows++] = r;
    org_kde_plasma_window_add_listener(w, &plasma_window_listener, r);
}

static void pwm_show_desktop(void *d, struct org_kde_plasma_window_management *m, uint32_t state) {
    ((photon_wl *)d)->showing_desktop = state == ORG_KDE_PLASMA_WINDOW_MANAGEMENT_SHOW_DESKTOP_ENABLED;
}
// Before version 13 windows are announced by internal id only; from 13 on by uuid (KWin 6 no longer sends `window`).
static void pwm_window(void *d, struct org_kde_plasma_window_management *m, uint32_t id) {
    photon_wl *wl = d;
    if (org_kde_plasma_window_management_get_version(m) >= ORG_KDE_PLASMA_WINDOW_MANAGEMENT_WINDOW_WITH_UUID_SINCE_VERSION) return;
    plasma_window_add(wl, org_kde_plasma_window_management_get_window(m, id));
}
static void pwm_stacking(void *d, struct org_kde_plasma_window_management *m, struct wl_array *ids) {}
static void pwm_stacking_uuid(void *d, struct org_kde_plasma_window_management *m, const char *uuids) {}
static void pwm_window_uuid(void *d, struct org_kde_plasma_window_management *m, uint32_t id, const char *uuid) {
    plasma_window_add(d, org_kde_plasma_window_management_get_window_by_uuid(m, uuid));
}
static const struct org_kde_plasma_window_management_listener plasma_management_listener = {
    .show_desktop_changed = pwm_show_desktop, .window = pwm_window, .stacking_order_changed = pwm_stacking,
    .stacking_order_uuid_changed = pwm_stacking_uuid, .window_with_uuid = pwm_window_uuid,
};

static void plasma_desktops_changed(photon_wl *wl) {
    for (int i = 0; i < wl->n_plasma_windows; i++) pw_update_desktop(wl->plasma_windows[i]);
}
static void vd_id(void *d, struct org_kde_plasma_virtual_desktop *v, const char *id) {}
static void vd_name(void *d, struct org_kde_plasma_virtual_desktop *v, const char *n) {}
static void vd_activated(void *d, struct org_kde_plasma_virtual_desktop *v) {
    desktop_rec *r = d; r->activated = 1; plasma_desktops_changed(r->wl);
}
static void vd_deactivated(void *d, struct org_kde_plasma_virtual_desktop *v) {
    desktop_rec *r = d; r->activated = 0; plasma_desktops_changed(r->wl);
}
static void vd_done(void *d, struct org_kde_plasma_virtual_desktop *v) {}
static void desktop_drop(photon_wl *wl, desktop_rec *r) {
    for (int i = 0; i < wl->n_desktops; i++) {
        if (wl->desktops[i] != r) continue;
        memmove(&wl->desktops[i], &wl->desktops[i + 1], (size_t)(wl->n_desktops - i - 1) * sizeof wl->desktops[0]);
        wl->n_desktops--;
        break;
    }
    org_kde_plasma_virtual_desktop_destroy(r->desktop);
    free(r);
    plasma_desktops_changed(wl);
}
static void vd_removed(void *d, struct org_kde_plasma_virtual_desktop *v) { desktop_rec *r = d; desktop_drop(r->wl, r); }
static const struct org_kde_plasma_virtual_desktop_listener virtual_desktop_listener = {
    .desktop_id = vd_id, .name = vd_name, .activated = vd_activated, .deactivated = vd_deactivated, .done = vd_done,
    .removed = vd_removed,
};
static void vdm_created(void *d, struct org_kde_plasma_virtual_desktop_management *m, const char *id, uint32_t pos) {
    photon_wl *wl = d;
    if (wl->n_desktops >= MAX_DESKTOPS) return;
    for (int i = 0; i < wl->n_desktops; i++) if (!strcmp(wl->desktops[i]->id, id)) return;
    desktop_rec *r = calloc(1, sizeof *r);
    snprintf(r->id, sizeof r->id, "%s", id);
    r->wl = wl;
    r->desktop = org_kde_plasma_virtual_desktop_management_get_virtual_desktop(m, id);
    org_kde_plasma_virtual_desktop_add_listener(r->desktop, &virtual_desktop_listener, r);
    wl->desktops[wl->n_desktops++] = r;
}
static void vdm_removed(void *d, struct org_kde_plasma_virtual_desktop_management *m, const char *id) {
    photon_wl *wl = d;
    for (int i = 0; i < wl->n_desktops; i++) if (!strcmp(wl->desktops[i]->id, id)) { desktop_drop(wl, wl->desktops[i]); return; }
}
static void vdm_done(void *d, struct org_kde_plasma_virtual_desktop_management *m) {}
static void vdm_rows(void *d, struct org_kde_plasma_virtual_desktop_management *m, uint32_t rows) {}
static const struct org_kde_plasma_virtual_desktop_management_listener virtual_desktop_management_listener = {
    .desktop_created = vdm_created, .desktop_removed = vdm_removed, .done = vdm_done, .rows = vdm_rows,
};

int photon_wl_plasma_window_count(photon_wl *wl) { return wl->n_plasma_windows; }
int photon_wl_plasma_window_get(photon_wl *wl, int index, photon_wl_plasma_window *out) {
    if (index < 0 || index >= wl->n_plasma_windows) return 0;
    *out = wl->plasma_windows[index]->info;
    return 1;
}
int photon_wl_plasma_showing_desktop(photon_wl *wl) { return wl->showing_desktop; }

// MARK: - xdg_wm_base

static void wm_ping(void *d, struct xdg_wm_base *wm, uint32_t serial) { xdg_wm_base_pong(wm, serial); }
static const struct xdg_wm_base_listener wm_base_listener = { .ping = wm_ping };

// MARK: - Seat and pointer

static photon_wl_surface *surface_for(photon_wl *wl, struct wl_surface *s);

static void ptr_enter(void *d, struct wl_pointer *p, uint32_t serial, struct wl_surface *s, wl_fixed_t x, wl_fixed_t y) {
    photon_wl *wl = d;
    wl->pointer_state.focus = s ? surface_for(wl, s) : NULL;
    wl->pointer_state.x = wl_fixed_to_double(x);
    wl->pointer_state.y = wl_fixed_to_double(y);
}
static void ptr_leave(void *d, struct wl_pointer *p, uint32_t serial, struct wl_surface *s) {
    ((photon_wl *)d)->pointer_state.focus = NULL;
}
static void ptr_motion(void *d, struct wl_pointer *p, uint32_t time, wl_fixed_t x, wl_fixed_t y) {
    photon_wl *wl = d;
    wl->pointer_state.x = wl_fixed_to_double(x);
    wl->pointer_state.y = wl_fixed_to_double(y);
}
static void ptr_button(void *d, struct wl_pointer *p, uint32_t serial, uint32_t time, uint32_t button, uint32_t state) {
    photon_wl *wl = d;
    if (button != BTN_LEFT_CODE) return;
    wl->pointer_state.left = state == WL_POINTER_BUTTON_STATE_PRESSED;
    if (wl->pointer_state.left) wl->pointer_state.buttons++;
}
static void ptr_axis(void *d, struct wl_pointer *p, uint32_t time, uint32_t axis, wl_fixed_t v) {}
static void ptr_frame(void *d, struct wl_pointer *p) {}
static void ptr_axis_source(void *d, struct wl_pointer *p, uint32_t s) {}
static void ptr_axis_stop(void *d, struct wl_pointer *p, uint32_t time, uint32_t axis) {}
static void ptr_axis_discrete(void *d, struct wl_pointer *p, uint32_t axis, int32_t discrete) {}
static const struct wl_pointer_listener pointer_listener = {
    .enter = ptr_enter, .leave = ptr_leave, .motion = ptr_motion, .button = ptr_button, .axis = ptr_axis,
    .frame = ptr_frame, .axis_source = ptr_axis_source, .axis_stop = ptr_axis_stop, .axis_discrete = ptr_axis_discrete,
};

static void seat_capabilities(void *d, struct wl_seat *seat, uint32_t caps) {
    photon_wl *wl = d;
    int has = (caps & WL_SEAT_CAPABILITY_POINTER) != 0;
    wl->pointer_state.has_pointer = has;
    if (has && !wl->pointer) {
        wl->pointer = wl_seat_get_pointer(seat);
        wl_pointer_add_listener(wl->pointer, &pointer_listener, wl);
    } else if (!has && wl->pointer) {
        if (wl_pointer_get_version(wl->pointer) >= 3) wl_pointer_release(wl->pointer); else wl_pointer_destroy(wl->pointer);
        wl->pointer = NULL;
        wl->pointer_state.focus = NULL;
        wl->pointer_state.left = 0;
    }
}
static void seat_name(void *d, struct wl_seat *seat, const char *name) {}
static const struct wl_seat_listener seat_listener = { .capabilities = seat_capabilities, .name = seat_name };

void photon_wl_pointer_get(photon_wl *wl, photon_wl_pointer *out) { *out = wl->pointer_state; }

// MARK: - Registry

static void note_bound(photon_wl *wl, const char *iface) {
    if (wl->n_bound < MAX_BOUND) snprintf(wl->bound[wl->n_bound++], 64, "%s", iface);
}

static uint32_t min_u(uint32_t a, uint32_t b) { return a < b ? a : b; }

static void reg_global(void *d, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t version) {
    photon_wl *wl = d;
    if (!strcmp(iface, wl_compositor_interface.name)) {
        wl->compositor = wl_registry_bind(reg, name, &wl_compositor_interface, min_u(version, 4));
        note_bound(wl, iface);
    } else if (!strcmp(iface, wl_shm_interface.name)) {
        wl->shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
        note_bound(wl, iface);
    } else if (!strcmp(iface, zwlr_layer_shell_v1_interface.name)) {
        wl->layer_shell = wl_registry_bind(reg, name, &zwlr_layer_shell_v1_interface, min_u(version, 4));
        note_bound(wl, iface);
    } else if (!strcmp(iface, zxdg_output_manager_v1_interface.name)) {
        wl->xdg_output_manager = wl_registry_bind(reg, name, &zxdg_output_manager_v1_interface, min_u(version, 3));
        note_bound(wl, iface);
        for (int i = 0; i < wl->n_outputs; i++) attach_xdg_output(wl, wl->outputs[i], wl_output_get_user_data(wl->outputs[i]->output));
    } else if (!strcmp(iface, wp_viewporter_interface.name)) {
        wl->viewporter = wl_registry_bind(reg, name, &wp_viewporter_interface, 1);
        note_bound(wl, iface);
    } else if (!strcmp(iface, wp_fractional_scale_manager_v1_interface.name)) {
        wl->fractional = wl_registry_bind(reg, name, &wp_fractional_scale_manager_v1_interface, 1);
        note_bound(wl, iface);
    } else if (!strcmp(iface, zwlr_foreign_toplevel_manager_v1_interface.name)) {
        wl->toplevels_manager = wl_registry_bind(reg, name, &zwlr_foreign_toplevel_manager_v1_interface, min_u(version, 3));
        zwlr_foreign_toplevel_manager_v1_add_listener(wl->toplevels_manager, &toplevel_manager_listener, wl);
        note_bound(wl, iface);
    } else if (!strcmp(iface, org_kde_plasma_window_management_interface.name)) {
        // KWin advertises it only to clients whose .desktop entry lists it in X-KDE-Wayland-Interfaces (photon2-kwin.desktop).
        wl->plasma = wl_registry_bind(reg, name, &org_kde_plasma_window_management_interface, min_u(version, 16));
        org_kde_plasma_window_management_add_listener(wl->plasma, &plasma_management_listener, wl);
        note_bound(wl, iface);
    } else if (!strcmp(iface, org_kde_plasma_virtual_desktop_management_interface.name)) {
        wl->plasma_desktops = wl_registry_bind(reg, name, &org_kde_plasma_virtual_desktop_management_interface, min_u(version, 2));
        org_kde_plasma_virtual_desktop_management_add_listener(wl->plasma_desktops, &virtual_desktop_management_listener, wl);
        note_bound(wl, iface);
    } else if (!strcmp(iface, xdg_wm_base_interface.name)) {
        wl->wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(wl->wm_base, &wm_base_listener, wl);
        note_bound(wl, iface);
    } else if (!strcmp(iface, wl_seat_interface.name) && !wl->seat) {
        // The first seat: the cursor over the background surfaces (desktop clicks and the cursor position).
        wl->seat = wl_registry_bind(reg, name, &wl_seat_interface, min_u(version, 5));
        wl_seat_add_listener(wl->seat, &seat_listener, wl);
        note_bound(wl, iface);
    } else if (!strcmp(iface, wl_output_interface.name) && wl->n_outputs < MAX_OUTPUTS) {
        output_rec *r = calloc(1, sizeof *r);
        output_ctx *c = calloc(1, sizeof *c);
        c->wl = wl; c->rec = r;
        r->info.global = name;
        r->info.scale = 1;
        r->output = wl_registry_bind(reg, name, &wl_output_interface, min_u(version, 4));
        wl_output_add_listener(r->output, &output_listener, c);
        wl->outputs[wl->n_outputs++] = r;
        attach_xdg_output(wl, r, c);
        wl->outputs_serial++;
    }
}

static void reg_global_remove(void *d, struct wl_registry *reg, uint32_t name) {
    photon_wl *wl = d;
    for (int i = 0; i < wl->n_outputs; i++) {
        output_rec *r = wl->outputs[i];
        if (r->info.global != name) continue;
        // Toplevels still listing it drop it.
        for (int t = 0; t < wl->n_toplevels; t++) {
            photon_wl_toplevel *p[2] = { &wl->toplevels[t]->info, &wl->toplevels[t]->pending };
            for (int k = 0; k < 2; k++)
                for (int j = 0; j < p[k]->n_outputs; j++)
                    if (p[k]->outputs[j] == name) {
                        memmove(&p[k]->outputs[j], &p[k]->outputs[j + 1], (size_t)(p[k]->n_outputs - j - 1) * sizeof(uint32_t));
                        p[k]->n_outputs--;
                        break;
                    }
        }
        output_ctx *c = wl_output_get_user_data(r->output);
        if (r->xdg) zxdg_output_v1_destroy(r->xdg);
        if (wl_output_get_version(r->output) >= 3) wl_output_release(r->output); else wl_output_destroy(r->output);
        free(c);
        free(r);
        memmove(&wl->outputs[i], &wl->outputs[i + 1], (size_t)(wl->n_outputs - i - 1) * sizeof wl->outputs[0]);
        wl->n_outputs--;
        wl->outputs_serial++;
        return;
    }
}

static const struct wl_registry_listener registry_listener = { .global = reg_global, .global_remove = reg_global_remove };

photon_wl *photon_wl_connect(const char *display_name, char *error, size_t error_size) {
    struct wl_display *d = wl_display_connect(display_name);
    if (!d) {
        if (error) snprintf(error, error_size, "cannot connect to Wayland display %s (%s)",
                            display_name ? display_name : (getenv("WAYLAND_DISPLAY") ? getenv("WAYLAND_DISPLAY") : "(WAYLAND_DISPLAY unset)"),
                            strerror(errno));
        return NULL;
    }
    photon_wl *wl = calloc(1, sizeof *wl);
    wl->display = d;
    wl->registry = wl_display_get_registry(d);
    wl_registry_add_listener(wl->registry, &registry_listener, wl);
    // Globals, then their initial events (output modes, names, xdg_output geometry, existing toplevels).
    wl_display_roundtrip(d);
    wl_display_roundtrip(d);
    wl_display_roundtrip(d);
    if (!wl->compositor) {
        if (error) snprintf(error, error_size, "the compositor has no wl_compositor");
        photon_wl_disconnect(wl);
        return NULL;
    }
    return wl;
}

void photon_wl_disconnect(photon_wl *wl) {
    if (!wl) return;
    for (int i = 0; i < wl->n_toplevels; i++) {
        free(zwlr_foreign_toplevel_handle_v1_get_user_data(wl->toplevels[i]->handle));
        zwlr_foreign_toplevel_handle_v1_destroy(wl->toplevels[i]->handle);
        free(wl->toplevels[i]);
    }
    for (int i = 0; i < wl->n_outputs; i++) {
        if (wl->outputs[i]->xdg) zxdg_output_v1_destroy(wl->outputs[i]->xdg);
        free(wl_output_get_user_data(wl->outputs[i]->output));
        wl_output_destroy(wl->outputs[i]->output);
        free(wl->outputs[i]);
    }
    if (wl->toplevels_manager) zwlr_foreign_toplevel_manager_v1_stop(wl->toplevels_manager);
    while (wl->n_plasma_windows > 0) plasma_window_drop(wl->plasma_windows[0]);
    while (wl->n_desktops > 0) {
        desktop_rec *r = wl->desktops[--wl->n_desktops];
        org_kde_plasma_virtual_desktop_destroy(r->desktop);
        free(r);
    }
    if (wl->plasma) org_kde_plasma_window_management_destroy(wl->plasma);
    if (wl->plasma_desktops) org_kde_plasma_virtual_desktop_management_destroy(wl->plasma_desktops);
    if (wl->wm_base) xdg_wm_base_destroy(wl->wm_base);
    if (wl->pointer) wl_pointer_destroy(wl->pointer);
    if (wl->seat) wl_seat_destroy(wl->seat);
    wl_display_flush(wl->display);
    wl_display_disconnect(wl->display);
    free(wl);
}

void *photon_wl_display(photon_wl *wl) { return wl->display; }

int photon_wl_dispatch(photon_wl *wl, int timeout_ms) {
    struct wl_display *d = wl->display;
    while (wl_display_prepare_read(d) != 0) {
        if (wl_display_dispatch_pending(d) < 0) return -1;
    }
    wl_display_flush(d);
    struct pollfd p = { .fd = wl_display_get_fd(d), .events = POLLIN };
    int r = poll(&p, 1, timeout_ms);
    if (r > 0 && (p.revents & POLLIN)) {
        if (wl_display_read_events(d) < 0) return -1;
    } else {
        wl_display_cancel_read(d);
        if (r > 0 && (p.revents & (POLLERR | POLLHUP))) return -1;
    }
    if (wl_display_dispatch_pending(d) < 0) return -1;
    return wl_display_get_error(d) ? -1 : 0;
}

int photon_wl_roundtrip(photon_wl *wl) { return wl_display_roundtrip(wl->display); }

int photon_wl_has(photon_wl *wl, const char *interface) {
    for (int i = 0; i < wl->n_bound; i++) if (!strcmp(wl->bound[i], interface)) return 1;
    return 0;
}

uint32_t photon_wl_outputs_serial(photon_wl *wl) { return wl->outputs_serial; }
int photon_wl_output_count(photon_wl *wl) { return wl->n_outputs; }
int photon_wl_output_get(photon_wl *wl, int index, photon_wl_output *out) {
    if (index < 0 || index >= wl->n_outputs) return 0;
    *out = wl->outputs[index]->info;
    return 1;
}

int photon_wl_toplevel_count(photon_wl *wl) { return wl->n_toplevels; }
int photon_wl_toplevel_get(photon_wl *wl, int index, photon_wl_toplevel *out) {
    if (index < 0 || index >= wl->n_toplevels) return 0;
    *out = wl->toplevels[index]->info;
    return 1;
}

// MARK: - Layer surfaces

static photon_wl_surface *surface_for(photon_wl *wl, struct wl_surface *s) {
    for (int i = 0; i < wl->n_surfaces; i++) if (photon_wl_surface_handle(wl->surfaces[i]) == s) return wl->surfaces[i];
    return NULL;
}

static int output_scale_of(photon_wl_surface *s) {
    output_rec *r = output_by_global(s->wl, s->output_global);
    return r && r->info.scale > 0 ? r->info.scale : 1;
}

/// buffer size = round(logical × scale), the rule wp_fractional_scale_v1 gives clients.
static void update_scale(photon_wl_surface *s) {
    int s120 = s->preferred120 > 0 ? s->preferred120 : output_scale_of(s) * 120;
    if (!s->wl->viewporter) s120 = output_scale_of(s) * 120; // integer scales only without a viewport
    int bw = (int)((s->state.width * s120 + 60) / 120), bh = (int)((s->state.height * s120 + 60) / 120);
    if (s120 != s->state.scale120 || bw != s->state.buffer_width || bh != s->state.buffer_height) {
        s->state.scale120 = s120;
        s->state.buffer_width = bw;
        s->state.buffer_height = bh;
        s->state.changes++;
    }
}

static void layer_configure(void *d, struct zwlr_layer_surface_v1 *l, uint32_t serial, uint32_t w, uint32_t h) {
    photon_wl_surface *s = d;
    zwlr_layer_surface_v1_ack_configure(l, serial);
    if ((int)w != s->state.width || (int)h != s->state.height) s->state.changes++;
    s->state.width = (int)w;
    s->state.height = (int)h;
    s->state.configured = 1;
    update_scale(s);
}
static void layer_closed(void *d, struct zwlr_layer_surface_v1 *l) {
    photon_wl_surface *s = d;
    s->state.closed = 1;
    s->state.changes++;
}
static const struct zwlr_layer_surface_v1_listener layer_listener = { .configure = layer_configure, .closed = layer_closed };

static void fractional_preferred(void *d, struct wp_fractional_scale_v1 *f, uint32_t scale) {
    photon_wl_surface *s = d;
    s->preferred120 = (int)scale;
    if (s->state.configured) update_scale(s);
}
static const struct wp_fractional_scale_v1_listener fractional_listener = { .preferred_scale = fractional_preferred };

photon_wl_surface *photon_wl_surface_create(photon_wl *wl, uint32_t output_global, const char *name_space) {
    return photon_wl_surface_create_region(wl, output_global, name_space, 0, 0, 0, 0);
}

// A split region: anchored top-left with the region's size and its offset as margins (layer-shell lays the surface
// out inside the output's area, so the region is where the margins put it).
photon_wl_surface *photon_wl_surface_create_region(photon_wl *wl, uint32_t output_global, const char *name_space,
                                                   int x, int y, int w, int h) {
    output_rec *r = output_by_global(wl, output_global);
    if (!r || !wl->layer_shell || !wl->compositor) return NULL;
    photon_wl_surface *s = calloc(1, sizeof *s);
    s->wl = wl;
    s->output_global = output_global;
    s->surface = wl_compositor_create_surface(wl->compositor);
    if (wl->viewporter) s->viewport = wp_viewporter_get_viewport(wl->viewporter, s->surface);
    if (wl->fractional) {
        s->fractional = wp_fractional_scale_manager_v1_get_fractional_scale(wl->fractional, s->surface);
        wp_fractional_scale_v1_add_listener(s->fractional, &fractional_listener, s);
    }
    s->layer = zwlr_layer_shell_v1_get_layer_surface(wl->layer_shell, s->surface, r->output, ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND,
                                                     name_space ? name_space : "photon2");
    zwlr_layer_surface_v1_add_listener(s->layer, &layer_listener, s);
    if (w > 0 && h > 0) {
        s->region_w = w;
        s->region_h = h;
        zwlr_layer_surface_v1_set_anchor(s->layer, ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT);
        zwlr_layer_surface_v1_set_size(s->layer, (uint32_t)w, (uint32_t)h);
        zwlr_layer_surface_v1_set_margin(s->layer, y, 0, 0, x);
    } else {
        zwlr_layer_surface_v1_set_anchor(s->layer, ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
                                                       ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
        zwlr_layer_surface_v1_set_size(s->layer, 0, 0);
    }
    zwlr_layer_surface_v1_set_exclusive_zone(s->layer, -1);
    zwlr_layer_surface_v1_set_keyboard_interactivity(s->layer, ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
    // The initial commit without a buffer asks for the first configure.
    wl_surface_commit(s->surface);
    wl_display_flush(wl->display);
    if (wl->n_surfaces < MAX_SURFACES) wl->surfaces[wl->n_surfaces++] = s;
    return s;
}

// GNOME: an xdg_toplevel the photon2 Shell extension finds by app_id and title and shows inside the background actors.
// Its size is the output's logical size whatever the compositor suggests (the extension scales its clone to the monitor
// anyway; min and max size ask the window manager not to resize it).
static void bg_toplevel_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *states) {}
static void bg_toplevel_close(void *d, struct xdg_toplevel *t) {
    photon_wl_surface *s = d;
    s->state.closed = 1;
    s->state.changes++;
}
static const struct xdg_toplevel_listener bg_toplevel_listener = { .configure = bg_toplevel_configure, .close = bg_toplevel_close };
static void bg_surface_configure(void *d, struct xdg_surface *x, uint32_t serial) {
    photon_wl_surface *s = d;
    xdg_surface_ack_configure(x, serial);
    output_rec *r = output_by_global(s->wl, s->output_global);
    int w = r ? r->info.width : 0, h = r ? r->info.height : 0;
    if (s->region_w > 0 && s->region_h > 0) { w = s->region_w; h = s->region_h; }
    if (w <= 0 || h <= 0) return;
    if (w != s->state.width || h != s->state.height) {
        s->state.changes++;
        xdg_toplevel_set_min_size(s->xtoplevel, w, h);
        xdg_toplevel_set_max_size(s->xtoplevel, w, h);
    }
    s->state.width = w;
    s->state.height = h;
    s->state.configured = 1;
    update_scale(s);
}
static const struct xdg_surface_listener bg_surface_listener = { .configure = bg_surface_configure };

photon_wl_surface *photon_wl_toplevel_surface_create(photon_wl *wl, uint32_t output_global, const char *app_id, const char *title) {
    return photon_wl_toplevel_surface_create_region(wl, output_global, app_id, title, 0, 0);
}

// A split region on GNOME: the window has the region's logical size; the extension places its clone at the region the
// title names ("photon2 background <connector> <x>,<y>,<w>,<h>").
photon_wl_surface *photon_wl_toplevel_surface_create_region(photon_wl *wl, uint32_t output_global, const char *app_id, const char *title,
                                                            int w, int h) {
    output_rec *r = output_by_global(wl, output_global);
    if (!r || !wl->wm_base || !wl->compositor) return NULL;
    photon_wl_surface *s = calloc(1, sizeof *s);
    s->wl = wl;
    s->output_global = output_global;
    s->surface = wl_compositor_create_surface(wl->compositor);
    if (wl->viewporter) s->viewport = wp_viewporter_get_viewport(wl->viewporter, s->surface);
    if (wl->fractional) {
        s->fractional = wp_fractional_scale_manager_v1_get_fractional_scale(wl->fractional, s->surface);
        wp_fractional_scale_v1_add_listener(s->fractional, &fractional_listener, s);
    }
    s->xsurface = xdg_wm_base_get_xdg_surface(wl->wm_base, s->surface);
    xdg_surface_add_listener(s->xsurface, &bg_surface_listener, s);
    s->xtoplevel = xdg_surface_get_toplevel(s->xsurface);
    xdg_toplevel_add_listener(s->xtoplevel, &bg_toplevel_listener, s);
    xdg_toplevel_set_app_id(s->xtoplevel, app_id ? app_id : "io.github.photon2.Photon.Background");
    xdg_toplevel_set_title(s->xtoplevel, title ? title : "photon2 background");
    if (w > 0 && h > 0) {
        s->region_w = w;
        s->region_h = h;
        xdg_toplevel_set_min_size(s->xtoplevel, w, h);
        xdg_toplevel_set_max_size(s->xtoplevel, w, h);
    } else if (r->info.width > 0 && r->info.height > 0) {
        xdg_toplevel_set_min_size(s->xtoplevel, r->info.width, r->info.height);
        xdg_toplevel_set_max_size(s->xtoplevel, r->info.width, r->info.height);
    }
    wl_surface_commit(s->surface);
    wl_display_flush(wl->display);
    if (wl->n_surfaces < MAX_SURFACES) wl->surfaces[wl->n_surfaces++] = s;
    return s;
}

void photon_wl_surface_get_state(photon_wl_surface *s, photon_wl_surface_state *out) { *out = s->state; }
void *photon_wl_surface_handle(photon_wl_surface *s) { return s->surface; }

void photon_wl_surface_prepare(photon_wl_surface *s) {
    if (!s->state.configured || s->state.width <= 0 || s->state.height <= 0) return;
    if (s->viewport) {
        wl_surface_set_buffer_scale(s->surface, 1);
        wp_viewport_set_destination(s->viewport, s->state.width, s->state.height);
    } else {
        wl_surface_set_buffer_scale(s->surface, s->state.scale120 / 120);
    }
    struct wl_region *opaque = wl_compositor_create_region(s->wl->compositor);
    wl_region_add(opaque, 0, 0, s->state.width, s->state.height);
    wl_surface_set_opaque_region(s->surface, opaque);
    wl_region_destroy(opaque);
}

void photon_wl_surface_commit(photon_wl_surface *s) {
    wl_surface_commit(s->surface);
    wl_display_flush(s->wl->display);
}

static void buffer_release(void *d, struct wl_buffer *b) { ((shm_buffer *)d)->busy = 0; }
static const struct wl_buffer_listener buffer_listener = { .release = buffer_release };

static void shm_free(shm_buffer *b) {
    if (b->buffer) wl_buffer_destroy(b->buffer);
    if (b->data) munmap(b->data, b->size);
    memset(b, 0, sizeof *b);
}

static int shm_alloc(struct wl_shm *shm, shm_buffer *b, int w, int h) {
    size_t stride = (size_t)w * 4, size = stride * (size_t)h;
    int fd = memfd_create("photon2-shm", MFD_CLOEXEC);
    if (fd < 0) return 0;
    if (ftruncate(fd, (off_t)size) < 0) { close(fd); return 0; }
    void *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data == MAP_FAILED) { close(fd); return 0; }
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    b->buffer = wl_shm_pool_create_buffer(pool, 0, w, h, (int32_t)stride, WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    b->data = data; b->size = size; b->width = w; b->height = h; b->busy = 0;
    wl_buffer_add_listener(b->buffer, &buffer_listener, b);
    return 1;
}

int photon_wl_surface_present_shm(photon_wl_surface *s, const void *bgra, int width, int height) {
    if (!s->wl->shm || width <= 0 || height <= 0) return 0;
    shm_buffer *b = NULL;
    for (int i = 0; i < 2 && !b; i++) if (!s->buffers[i].busy) b = &s->buffers[i];
    if (!b) { // both still held by the compositor: wait for a release
        wl_display_roundtrip(s->wl->display);
        for (int i = 0; i < 2 && !b; i++) if (!s->buffers[i].busy) b = &s->buffers[i];
        if (!b) return 0;
    }
    if (b->width != width || b->height != height) { shm_free(b); if (!shm_alloc(s->wl->shm, b, width, height)) return 0; }
    // XRGB8888 is little-endian B, G, R, X: the renderer's BGRA rows as they are.
    memcpy(b->data, bgra, (size_t)width * (size_t)height * 4);
    photon_wl_surface_prepare(s);
    wl_surface_attach(s->surface, b->buffer, 0, 0);
    wl_surface_damage_buffer(s->surface, 0, 0, width, height);
    b->busy = 1;
    photon_wl_surface_commit(s);
    return 1;
}

void photon_wl_surface_destroy(photon_wl_surface *s) {
    if (!s) return;
    photon_wl *wl = s->wl;
    for (int i = 0; i < wl->n_surfaces; i++) {
        if (wl->surfaces[i] != s) continue;
        memmove(&wl->surfaces[i], &wl->surfaces[i + 1], (size_t)(wl->n_surfaces - i - 1) * sizeof wl->surfaces[0]);
        wl->n_surfaces--;
        break;
    }
    if (wl->pointer_state.focus == s) wl->pointer_state.focus = NULL;
    for (int i = 0; i < 2; i++) shm_free(&s->buffers[i]);
    if (s->fractional) wp_fractional_scale_v1_destroy(s->fractional);
    if (s->viewport) wp_viewport_destroy(s->viewport);
    if (s->layer) zwlr_layer_surface_v1_destroy(s->layer);
    if (s->xtoplevel) xdg_toplevel_destroy(s->xtoplevel);
    if (s->xsurface) xdg_surface_destroy(s->xsurface);
    wl_surface_destroy(s->surface);
    wl_display_flush(s->wl->display);
    free(s);
}

// MARK: - Test client

typedef struct {
    struct wl_output *output;
    char name[64];
} tc_output;

typedef struct {
    struct wl_display *display;
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    struct xdg_wm_base *wm;
    tc_output outputs[8];
    int n_outputs;
    struct wl_surface *surface;
    struct xdg_surface *xsurface;
    struct xdg_toplevel *toplevel;
    shm_buffer buffer;
    int width, height, pending_w, pending_h, configured, closed;
    uint32_t rgb;
} test_client;

static void tco_geometry(void *d, struct wl_output *o, int32_t x, int32_t y, int32_t pw, int32_t ph, int32_t sub,
                         const char *make, const char *model, int32_t transform) {}
static void tco_mode(void *d, struct wl_output *o, uint32_t f, int32_t w, int32_t h, int32_t r) {}
static void tco_done(void *d, struct wl_output *o) {}
static void tco_scale(void *d, struct wl_output *o, int32_t f) {}
static void tco_name(void *d, struct wl_output *o, const char *n) { snprintf(((tc_output *)d)->name, 64, "%s", n); }
static void tco_description(void *d, struct wl_output *o, const char *n) {}
static const struct wl_output_listener tc_output_listener = {
    .geometry = tco_geometry, .mode = tco_mode, .done = tco_done, .scale = tco_scale, .name = tco_name, .description = tco_description,
};

static void tc_global(void *d, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t version) {
    test_client *c = d;
    if (!strcmp(iface, wl_compositor_interface.name)) c->compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
    else if (!strcmp(iface, wl_shm_interface.name)) c->shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, xdg_wm_base_interface.name)) c->wm = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
    else if (!strcmp(iface, wl_output_interface.name) && version >= 4 && c->n_outputs < 8) {
        tc_output *o = &c->outputs[c->n_outputs++];
        o->output = wl_registry_bind(reg, name, &wl_output_interface, 4);
        wl_output_add_listener(o->output, &tc_output_listener, o);
    }
}
static void tc_global_remove(void *d, struct wl_registry *reg, uint32_t name) {}
static const struct wl_registry_listener tc_registry = { .global = tc_global, .global_remove = tc_global_remove };
static void tc_ping(void *d, struct xdg_wm_base *wm, uint32_t serial) { xdg_wm_base_pong(wm, serial); }
static const struct xdg_wm_base_listener tc_wm = { .ping = tc_ping };

static void tc_draw(test_client *c) {
    if (c->buffer.width != c->width || c->buffer.height != c->height) {
        shm_free(&c->buffer);
        if (!shm_alloc(c->shm, &c->buffer, c->width, c->height)) return;
    }
    uint32_t *px = c->buffer.data;
    for (size_t i = 0; i < (size_t)c->width * (size_t)c->height; i++) px[i] = 0xff000000u | c->rgb;
    wl_surface_attach(c->surface, c->buffer.buffer, 0, 0);
    wl_surface_damage_buffer(c->surface, 0, 0, c->width, c->height);
    wl_surface_commit(c->surface);
}
static void tc_xconfigure(void *d, struct xdg_surface *x, uint32_t serial) {
    test_client *c = d;
    xdg_surface_ack_configure(x, serial);
    if (c->pending_w > 0 && c->pending_h > 0) { c->width = c->pending_w; c->height = c->pending_h; }
    c->configured = 1;
    tc_draw(c);
}
static const struct xdg_surface_listener tc_xsurface = { .configure = tc_xconfigure };
static void tc_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *states) {
    test_client *c = d; c->pending_w = w; c->pending_h = h;
}
static void tc_close(void *d, struct xdg_toplevel *t) { ((test_client *)d)->closed = 1; }
static const struct xdg_toplevel_listener tc_toplevel = { .configure = tc_configure, .close = tc_close };

int photon_wl_test_client(const char *mode, int width, int height, uint32_t rgb, double seconds, const char *app_id) {
    return photon_wl_test_client_on(mode, width, height, rgb, seconds, app_id, NULL);
}

int photon_wl_test_client_on(const char *mode, int width, int height, uint32_t rgb, double seconds, const char *app_id,
                             const char *output_name) {
    test_client c = { .width = width > 0 ? width : 640, .height = height > 0 ? height : 480, .rgb = rgb };
    c.display = wl_display_connect(NULL);
    if (!c.display) return 1;
    struct wl_registry *reg = wl_display_get_registry(c.display);
    wl_registry_add_listener(reg, &tc_registry, &c);
    wl_display_roundtrip(c.display);
    wl_display_roundtrip(c.display); // output names
    if (!c.compositor || !c.shm || !c.wm) { wl_display_disconnect(c.display); return 1; }
    struct wl_output *on = NULL;
    if (output_name && *output_name) {
        for (int i = 0; i < c.n_outputs; i++) if (!strcmp(c.outputs[i].name, output_name)) on = c.outputs[i].output;
        if (!on) fprintf(stderr, "test client: no output %s\n", output_name);
    }
    xdg_wm_base_add_listener(c.wm, &tc_wm, &c);
    c.surface = wl_compositor_create_surface(c.compositor);
    c.xsurface = xdg_wm_base_get_xdg_surface(c.wm, c.surface);
    xdg_surface_add_listener(c.xsurface, &tc_xsurface, &c);
    c.toplevel = xdg_surface_get_toplevel(c.xsurface);
    xdg_toplevel_add_listener(c.toplevel, &tc_toplevel, &c);
    xdg_toplevel_set_app_id(c.toplevel, app_id ? app_id : "photon2-test-client");
    xdg_toplevel_set_title(c.toplevel, mode);
    if (!strcmp(mode, "fullscreen")) xdg_toplevel_set_fullscreen(c.toplevel, on);
    else if (!strcmp(mode, "maximized")) xdg_toplevel_set_maximized(c.toplevel);
    wl_surface_commit(c.surface);
    struct timespec t0, t;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (;;) {
        clock_gettime(CLOCK_MONOTONIC, &t);
        double el = (double)(t.tv_sec - t0.tv_sec) + (double)(t.tv_nsec - t0.tv_nsec) / 1e9;
        if (el >= seconds || c.closed) break;
        wl_display_flush(c.display);
        struct pollfd p = { .fd = wl_display_get_fd(c.display), .events = POLLIN };
        if (poll(&p, 1, 50) > 0) { if (wl_display_dispatch(c.display) < 0) break; } else wl_display_dispatch_pending(c.display);
    }
    xdg_toplevel_destroy(c.toplevel);
    xdg_surface_destroy(c.xsurface);
    wl_surface_destroy(c.surface);
    shm_free(&c.buffer);
    wl_display_roundtrip(c.display);
    wl_display_disconnect(c.display);
    return 0;
}

// MARK: - Pointer test client

typedef struct {
    struct wl_seat *seat;
    struct zwlr_virtual_pointer_manager_v1 *manager;
} vp_client;

static void vp_global(void *d, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t version) {
    vp_client *c = d;
    if (!strcmp(iface, wl_seat_interface.name) && !c->seat) c->seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
    else if (!strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name))
        c->manager = wl_registry_bind(reg, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
}
static void vp_global_remove(void *d, struct wl_registry *reg, uint32_t name) {}
static const struct wl_registry_listener vp_registry = { .global = vp_global, .global_remove = vp_global_remove };

static uint32_t now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint32_t)(t.tv_sec * 1000 + t.tv_nsec / 1000000);
}

static void pause_for(struct wl_display *d, double seconds) {
    struct timespec t0, t;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (;;) {
        wl_display_flush(d);
        clock_gettime(CLOCK_MONOTONIC, &t);
        double el = (double)(t.tv_sec - t0.tv_sec) + (double)(t.tv_nsec - t0.tv_nsec) / 1e9;
        if (el >= seconds) break;
        struct pollfd p = { .fd = wl_display_get_fd(d), .events = POLLIN };
        if (poll(&p, 1, 20) > 0) wl_display_dispatch(d); else wl_display_dispatch_pending(d);
    }
}

int photon_wl_pointer_test(int layout_width, int layout_height, const char *actions) {
    struct wl_display *d = wl_display_connect(NULL);
    if (!d) return 1;
    vp_client c = { 0 };
    struct wl_registry *reg = wl_display_get_registry(d);
    wl_registry_add_listener(reg, &vp_registry, &c);
    wl_display_roundtrip(d);
    if (!c.manager) { fprintf(stderr, "no zwlr_virtual_pointer_manager_v1\n"); wl_display_disconnect(d); return 1; }
    struct zwlr_virtual_pointer_v1 *vp = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(c.manager, c.seat);
    wl_display_roundtrip(d);
    pause_for(d, 0.3); // the seat gains a pointer; clients bind it
    char *copy = strdup(actions ? actions : "");
    char *save = NULL;
    for (char *a = strtok_r(copy, ";", &save); a; a = strtok_r(NULL, ";", &save)) {
        while (*a == ' ') a++;
        double x = 0, y = 0, s = 0;
        if (sscanf(a, "move %lf %lf", &x, &y) == 2 || sscanf(a, "click %lf %lf", &x, &y) == 2) {
            zwlr_virtual_pointer_v1_motion_absolute(vp, now_ms(), (uint32_t)x, (uint32_t)y, (uint32_t)layout_width, (uint32_t)layout_height);
            zwlr_virtual_pointer_v1_frame(vp);
            wl_display_roundtrip(d);
            if (!strncmp(a, "move", 4)) continue;
            pause_for(d, 0.05);
        }
        if (!strncmp(a, "click", 5) || !strncmp(a, "press", 5)) {
            zwlr_virtual_pointer_v1_button(vp, now_ms(), BTN_LEFT_CODE, WL_POINTER_BUTTON_STATE_PRESSED);
            zwlr_virtual_pointer_v1_frame(vp);
            wl_display_roundtrip(d);
            if (!strncmp(a, "click", 5)) pause_for(d, 0.15);
        }
        if (!strncmp(a, "click", 5) || !strncmp(a, "release", 7)) {
            zwlr_virtual_pointer_v1_button(vp, now_ms(), BTN_LEFT_CODE, WL_POINTER_BUTTON_STATE_RELEASED);
            zwlr_virtual_pointer_v1_frame(vp);
            wl_display_roundtrip(d);
        }
        if (sscanf(a, "wait %lf", &s) == 1) pause_for(d, s);
    }
    free(copy);
    pause_for(d, 0.2);
    zwlr_virtual_pointer_v1_destroy(vp);
    zwlr_virtual_pointer_manager_v1_destroy(c.manager);
    if (c.seat) wl_seat_destroy(c.seat);
    wl_display_roundtrip(d);
    wl_display_disconnect(d);
    return 0;
}
