// Web wallpapers on WebKitGTK 4.1 (photon_web.h, docs/linux-port.md §5.3).
#include "photon_web.h"

#include <gdk/gdk.h>
#include <gtk-layer-shell/gtk-layer-shell.h>
#include <gtk/gtk.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <webkit2/webkit2.h>
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif

#define MAX_VIEWS 64
#define MAX_SCRIPTS 16
#define MAX_ROOTS 32

typedef struct {
    int alive;
    GtkWidget *window;
    WebKitWebView *view;
    WebKitUserContentManager *ucm;
    // The wallpaper-switch overlay above the page (photon_web_view_set_overlay): a drawing area in a GtkOverlay,
    // painting a premultiplied BGRA image over the web view.
    GtkWidget *overlay_area;
    cairo_surface_t *overlay_image;
} view_rec;

struct photon_web {
    photon_web_cb cb;
    void *context;
    WebKitWebContext *web_context;
    char *root;
    char *extra[MAX_ROOTS];
    int n_extra;
    char *scripts[MAX_SCRIPTS];
    int n_scripts;
    view_rec views[MAX_VIEWS];
};

typedef struct { photon_web *w; int view; } view_ref;

int photon_web_init(void) {
    // The web process inherits the environment; it renders through GL when it can and falls back to software.
    return gtk_init_check(NULL, NULL) ? 1 : 0;
}

const char *photon_web_backend(void) {
#ifdef GDK_WINDOWING_WAYLAND
    if (GDK_IS_WAYLAND_DISPLAY(gdk_display_get_default())) return "wayland";
#endif
    return "x11";
}

int photon_web_layer_shell(void) { return gtk_layer_is_supported() ? 1 : 0; }

// MARK: - photon-web:// scheme

static int under(const char *path, const char *root) {
    size_t n = strlen(root);
    return strncmp(path, root, n) == 0 && (path[n] == '/' || path[n] == 0);
}

static void scheme_request(WebKitURISchemeRequest *req, gpointer data) {
    photon_web *w = data;
    const char *uri = webkit_uri_scheme_request_get_uri(req);
    GUri *u = g_uri_parse(uri, G_URI_FLAGS_ENCODED_PATH, NULL);
    char *file = NULL;
    int allowed = 0;
    if (u) {
        char *rel = g_uri_unescape_string(g_uri_get_path(u), NULL);
        const char *host = g_uri_get_host(u);
        if (rel && host && !strcmp(host, "local")) {
            // Folders of `directory` properties: photon-web://local/<absolute path>.
            file = g_canonicalize_filename(rel, "/");
            for (int i = 0; i < w->n_extra && !allowed; i++) allowed = under(file, w->extra[i]) && strcmp(file, w->extra[i]) != 0;
        } else if (rel) {
            char *joined = g_build_filename(w->root, rel, NULL);
            file = g_canonicalize_filename(joined, "/");
            g_free(joined);
            allowed = under(file, w->root);
        }
        g_free(rel);
        g_uri_unref(u);
    }
    gchar *contents = NULL;
    gsize length = 0;
    if (!allowed || !file || !g_file_get_contents(file, &contents, &length, NULL)) {
        GError *e = g_error_new_literal(G_IO_ERROR, G_IO_ERROR_NOT_FOUND, "not found");
        webkit_uri_scheme_request_finish_error(req, e);
        g_error_free(e);
        g_free(file);
        return;
    }
    gboolean uncertain = FALSE;
    gchar *type = g_content_type_guess(file, (const guchar *)contents, length, &uncertain);
    gchar *mime = type ? g_content_type_get_mime_type(type) : NULL;
    // g_content_type_guess sniffs .js as text/plain on some shared-mime-info versions; scripts must be served as
    // JavaScript for module scripts and strict MIME checks.
    const char *m = mime ? mime : "application/octet-stream";
    if (g_str_has_suffix(file, ".js") || g_str_has_suffix(file, ".mjs")) m = "text/javascript";
    else if (g_str_has_suffix(file, ".css")) m = "text/css";
    else if (g_str_has_suffix(file, ".html") || g_str_has_suffix(file, ".htm")) m = "text/html";
    else if (g_str_has_suffix(file, ".json")) m = "application/json";
    else if (g_str_has_suffix(file, ".wasm")) m = "application/wasm";
    else if (g_str_has_suffix(file, ".svg")) m = "image/svg+xml";
    GInputStream *stream = g_memory_input_stream_new_from_data(contents, (gssize)length, g_free);
    WebKitURISchemeResponse *resp = webkit_uri_scheme_response_new(stream, (gint64)length);
    webkit_uri_scheme_response_set_content_type(resp, m);
    webkit_uri_scheme_response_set_status(resp, 200, "OK");
    SoupMessageHeaders *h = soup_message_headers_new(SOUP_MESSAGE_HEADERS_RESPONSE);
    soup_message_headers_append(h, "Access-Control-Allow-Origin", "*");
    soup_message_headers_append(h, "Content-Type", m);
    webkit_uri_scheme_response_set_http_headers(resp, h);
    webkit_uri_scheme_request_finish_with_response(req, resp);
    g_object_unref(resp);
    g_object_unref(stream);
    g_free(mime);
    g_free(type);
    g_free(file);
}

// MARK: - Host

static void monitors_changed(GdkDisplay *d, GdkMonitor *m, gpointer data) {
    photon_web *w = data;
    if (w->cb) w->cb(w->context, -1, PHOTON_WEB_MONITORS, "");
}

photon_web *photon_web_create(photon_web_cb cb, void *context, const char *root, const char *const *extra_roots, int n_extra) {
    photon_web *w = calloc(1, sizeof *w);
    w->cb = cb;
    w->context = context;
    w->root = g_canonicalize_filename(root ? root : "/", "/");
    for (int i = 0; i < n_extra && i < MAX_ROOTS; i++) w->extra[w->n_extra++] = g_canonicalize_filename(extra_roots[i], "/");
    w->web_context = webkit_web_context_new();
    webkit_web_context_register_uri_scheme(w->web_context, "photon-web", scheme_request, w, NULL);
    WebKitSecurityManager *sm = webkit_web_context_get_security_manager(w->web_context);
    webkit_security_manager_register_uri_scheme_as_secure(sm, "photon-web");
    webkit_security_manager_register_uri_scheme_as_cors_enabled(sm, "photon-web");
    GdkDisplay *d = gdk_display_get_default();
    g_signal_connect(d, "monitor-added", G_CALLBACK(monitors_changed), w);
    g_signal_connect(d, "monitor-removed", G_CALLBACK(monitors_changed), w);
    return w;
}

void photon_web_add_user_script(photon_web *w, const char *source) {
    if (w->n_scripts < MAX_SCRIPTS) w->scripts[w->n_scripts++] = g_strdup(source);
}

int photon_web_monitor_count(photon_web *w) { return gdk_display_get_n_monitors(gdk_display_get_default()); }

int photon_web_monitor_get(photon_web *w, int index, photon_web_monitor *out) {
    GdkMonitor *m = gdk_display_get_monitor(gdk_display_get_default(), index);
    if (!m) return 0;
    GdkRectangle g;
    gdk_monitor_get_geometry(m, &g);
    memset(out, 0, sizeof *out);
    out->x = g.x; out->y = g.y; out->width = g.width; out->height = g.height;
    out->scale = gdk_monitor_get_scale_factor(m);
    const char *model = gdk_monitor_get_model(m);
    snprintf(out->connector, sizeof out->connector, "%s", model ? model : "");
    return 1;
}

static view_rec *rec(photon_web *w, int view) {
    return view >= 0 && view < MAX_VIEWS && w->views[view].alive ? &w->views[view] : NULL;
}

static void on_message(WebKitUserContentManager *ucm, WebKitJavascriptResult *r, gpointer data) {
    view_ref *ref = data;
    JSCValue *v = webkit_javascript_result_get_js_value(r);
    char *s = jsc_value_to_string(v);
    if (ref->w->cb && rec(ref->w, ref->view)) ref->w->cb(ref->w->context, ref->view, PHOTON_WEB_MESSAGE, s ? s : "");
    g_free(s);
}

static void on_load_changed(WebKitWebView *v, WebKitLoadEvent e, gpointer data) {
    view_ref *ref = data;
    if (e == WEBKIT_LOAD_FINISHED && ref->w->cb && rec(ref->w, ref->view)) {
        const char *uri = webkit_web_view_get_uri(v);
        ref->w->cb(ref->w->context, ref->view, PHOTON_WEB_LOADED, uri ? uri : "");
    }
}

static gboolean on_load_failed(WebKitWebView *v, WebKitLoadEvent e, gchar *uri, GError *err, gpointer data) {
    view_ref *ref = data;
    char buf[512];
    snprintf(buf, sizeof buf, "%s: %s", uri ? uri : "", err ? err->message : "");
    if (ref->w->cb && rec(ref->w, ref->view)) ref->w->cb(ref->w->context, ref->view, PHOTON_WEB_FAILED, buf);
    return FALSE;
}

static void on_crashed(WebKitWebView *v, WebKitWebProcessTerminationReason reason, gpointer data) {
    view_ref *ref = data;
    const char *why = reason == WEBKIT_WEB_PROCESS_CRASHED ? "crashed" : reason == WEBKIT_WEB_PROCESS_EXCEEDED_MEMORY_LIMIT ? "memory limit" : "terminated";
    if (ref->w->cb && rec(ref->w, ref->view)) ref->w->cb(ref->w->context, ref->view, PHOTON_WEB_CRASHED, why);
}

/// Windows never take the pointer or keyboard from the desktop (the engine's wallpaper window gets input through its
/// own hooks, which photon2 does not reproduce on Linux).
// `region` (w > 0): a split region of the monitor (docs/re/09 §8.3), logical units from its top-left.
static void place_window(GtkWindow *win, GdkMonitor *mon, const GdkRectangle *region) {
    int cut = region && region->width > 0 && region->height > 0;
    if (gtk_layer_is_supported()) {
        gtk_layer_init_for_window(win);
        gtk_layer_set_layer(win, GTK_LAYER_SHELL_LAYER_BACKGROUND);
        gtk_layer_set_anchor(win, GTK_LAYER_SHELL_EDGE_TOP, TRUE);
        gtk_layer_set_anchor(win, GTK_LAYER_SHELL_EDGE_BOTTOM, !cut);
        gtk_layer_set_anchor(win, GTK_LAYER_SHELL_EDGE_LEFT, TRUE);
        gtk_layer_set_anchor(win, GTK_LAYER_SHELL_EDGE_RIGHT, !cut);
        if (cut) {
            gtk_layer_set_margin(win, GTK_LAYER_SHELL_EDGE_TOP, region->y);
            gtk_layer_set_margin(win, GTK_LAYER_SHELL_EDGE_LEFT, region->x);
            gtk_widget_set_size_request(GTK_WIDGET(win), region->width, region->height);
        }
        gtk_layer_set_exclusive_zone(win, -1);
        gtk_layer_set_keyboard_mode(win, GTK_LAYER_SHELL_KEYBOARD_MODE_NONE);
        gtk_layer_set_namespace(win, "photon2");
        if (mon) gtk_layer_set_monitor(win, mon);
        return;
    }
    // X11: a desktop-type window over the monitor (the X11 host's window, docs/linux-port.md §5).
    gtk_window_set_type_hint(win, GDK_WINDOW_TYPE_HINT_DESKTOP);
    gtk_window_set_decorated(win, FALSE);
    gtk_window_set_skip_taskbar_hint(win, TRUE);
    gtk_window_set_skip_pager_hint(win, TRUE);
    gtk_window_set_accept_focus(win, FALSE);
    gtk_window_set_keep_below(win, TRUE);
    gtk_window_stick(win);
    gtk_window_set_title(win, "photon2 desktop");
    if (mon) {
        GdkRectangle g;
        gdk_monitor_get_geometry(mon, &g);
        if (cut) { g.x += region->x; g.y += region->y; g.width = region->width; g.height = region->height; }
        gtk_window_move(win, g.x, g.y);
        gtk_window_set_default_size(win, g.width, g.height);
        gtk_widget_set_size_request(GTK_WIDGET(win), g.width, g.height);
    }
}

/// The overlay image scaled onto the view (OVER with a premultiplied ARGB32 source: out = overlay + page · (1 − α), the
/// way DWM composes the engine's premultiplied overlay swap chain).
static gboolean on_overlay_draw(GtkWidget *widget, cairo_t *cr, gpointer data) {
    view_rec *r = data;
    if (!r->overlay_image) return FALSE;
    int w = gtk_widget_get_allocated_width(widget), h = gtk_widget_get_allocated_height(widget);
    int iw = cairo_image_surface_get_width(r->overlay_image), ih = cairo_image_surface_get_height(r->overlay_image);
    if (w <= 0 || h <= 0 || iw <= 0 || ih <= 0) return FALSE;
    cairo_save(cr);
    cairo_scale(cr, (double)w / iw, (double)h / ih);
    cairo_set_source_surface(cr, r->overlay_image, 0, 0);
    cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_BILINEAR);
    cairo_set_operator(cr, CAIRO_OPERATOR_OVER);
    cairo_paint(cr);
    cairo_restore(cr);
    return FALSE;
}

int photon_web_view_create(photon_web *w, int monitor) { return photon_web_view_create_region(w, monitor, 0, 0, 0, 0); }

int photon_web_view_create_region(photon_web *w, int monitor, int rx, int ry, int rw, int rh) {
    int id = -1;
    for (int i = 0; i < MAX_VIEWS; i++) if (!w->views[i].alive) { id = i; break; }
    if (id < 0) return -1;
    view_rec *r = &w->views[id];
    memset(r, 0, sizeof *r);
    view_ref *ref = g_new0(view_ref, 1);
    ref->w = w;
    ref->view = id;
    r->ucm = webkit_user_content_manager_new();
    for (int i = 0; i < w->n_scripts; i++) {
        WebKitUserScript *s = webkit_user_script_new(w->scripts[i], WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
                                                     WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, NULL, NULL);
        webkit_user_content_manager_add_script(r->ucm, s);
        webkit_user_script_unref(s);
    }
    g_signal_connect_data(r->ucm, "script-message-received::photon", G_CALLBACK(on_message), ref, (GClosureNotify)g_free, 0);
    webkit_user_content_manager_register_script_message_handler(r->ucm, "photon");
    r->view = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW, "web-context", w->web_context, "user-content-manager", r->ucm, NULL));
    WebKitSettings *s = webkit_web_view_get_settings(r->view);
    webkit_settings_set_allow_file_access_from_file_urls(s, TRUE);
    webkit_settings_set_media_playback_requires_user_gesture(s, FALSE);
    webkit_settings_set_enable_webgl(s, TRUE);
    webkit_settings_set_javascript_can_access_clipboard(s, FALSE);
    if (getenv("PHOTON_WEBDEBUG")) webkit_settings_set_enable_developer_extras(s, TRUE);
    // The macOS host draws no page background (drawsBackground false) over a black view; the same here.
    GdkRGBA black = { 0, 0, 0, 1 };
    webkit_web_view_set_background_color(r->view, &black);
    g_signal_connect(r->view, "load-changed", G_CALLBACK(on_load_changed), ref);
    g_signal_connect(r->view, "load-failed", G_CALLBACK(on_load_failed), ref);
    g_signal_connect(r->view, "web-process-terminated", G_CALLBACK(on_crashed), ref);
    r->window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    GdkRectangle region = { rx, ry, rw, rh };
    place_window(GTK_WINDOW(r->window), gdk_display_get_monitor(gdk_display_get_default(), monitor), &region);
    // The page under a pass-through drawing area for the switch overlay (the engine's transition child window).
    GtkWidget *stack = gtk_overlay_new();
    gtk_container_add(GTK_CONTAINER(stack), GTK_WIDGET(r->view));
    r->overlay_area = gtk_drawing_area_new();
    gtk_widget_set_app_paintable(r->overlay_area, TRUE);
    g_signal_connect(r->overlay_area, "draw", G_CALLBACK(on_overlay_draw), r);
    gtk_overlay_add_overlay(GTK_OVERLAY(stack), r->overlay_area);
    gtk_overlay_set_overlay_pass_through(GTK_OVERLAY(stack), r->overlay_area, TRUE);
    gtk_container_add(GTK_CONTAINER(r->window), stack);
    gtk_widget_show_all(r->window);
    gtk_widget_hide(r->overlay_area);
    r->alive = 1;
    return id;
}

void photon_web_view_load(photon_web *w, int view, const char *uri) {
    view_rec *r = rec(w, view);
    if (r) webkit_web_view_load_uri(r->view, uri);
}

typedef struct { photon_web *w; int view, tag; } query_ref;

static void query_done(GObject *obj, GAsyncResult *res, gpointer data) {
    query_ref *q = data;
    GError *err = NULL;
    JSCValue *v = webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(obj), res, &err);
    if (q->tag >= 0 && q->w->cb && rec(q->w, q->view)) {
        char *s = v ? jsc_value_to_string(v) : g_strdup_printf("error: %s", err ? err->message : "?");
        q->w->cb(q->w->context, q->view | (q->tag << 16), PHOTON_WEB_RESULT, s ? s : "");
        g_free(s);
    }
    if (v) g_object_unref(v);
    if (err) g_error_free(err);
    g_free(q);
}

static void evaluate(photon_web *w, int view, const char *js, int tag) {
    view_rec *r = rec(w, view);
    if (!r) return;
    query_ref *q = g_new0(query_ref, 1);
    q->w = w; q->view = view; q->tag = tag;
    webkit_web_view_evaluate_javascript(r->view, js, -1, NULL, NULL, NULL, query_done, q);
}

void photon_web_view_run(photon_web *w, int view, const char *js) { evaluate(w, view, js, -1); }
void photon_web_view_query(photon_web *w, int view, const char *js, int tag) { evaluate(w, view, js, tag); }

void photon_web_view_set_muted(photon_web *w, int view, int muted) {
    view_rec *r = rec(w, view);
    if (r) webkit_web_view_set_is_muted(r->view, muted ? TRUE : FALSE);
}

void photon_web_view_set_overlay(photon_web *w, int view, const void *bgra, int width, int height) {
    view_rec *r = rec(w, view);
    if (!r) return;
    if (!bgra || width <= 0 || height <= 0) {
        if (r->overlay_image) { cairo_surface_destroy(r->overlay_image); r->overlay_image = NULL; }
        gtk_widget_hide(r->overlay_area);
        return;
    }
    if (!r->overlay_image || cairo_image_surface_get_width(r->overlay_image) != width || cairo_image_surface_get_height(r->overlay_image) != height) {
        if (r->overlay_image) cairo_surface_destroy(r->overlay_image);
        r->overlay_image = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
    }
    cairo_surface_flush(r->overlay_image);
    unsigned char *dst = cairo_image_surface_get_data(r->overlay_image);
    int stride = cairo_image_surface_get_stride(r->overlay_image);
    // CAIRO_FORMAT_ARGB32 is premultiplied, native-endian 32-bit ARGB: B, G, R, A bytes on little-endian, the
    // overlay's BGRA8 rows as they are.
    for (int y = 0; y < height; y++) memcpy(dst + (size_t)y * stride, (const unsigned char *)bgra + (size_t)y * width * 4, (size_t)width * 4);
    cairo_surface_mark_dirty(r->overlay_image);
    gtk_widget_show(r->overlay_area);
    gtk_widget_queue_draw(r->overlay_area);
}

typedef struct { photon_web *w; int view; char *path; } snapshot_ref;

static void snapshot_done(GObject *obj, GAsyncResult *res, gpointer data) {
    snapshot_ref *q = data;
    GError *err = NULL;
    cairo_surface_t *img = webkit_web_view_get_snapshot_finish(WEBKIT_WEB_VIEW(obj), res, &err);
    int ok = 0;
    if (img && cairo_surface_get_type(img) == CAIRO_SURFACE_TYPE_IMAGE) {
        cairo_surface_flush(img);
        int w = cairo_image_surface_get_width(img), h = cairo_image_surface_get_height(img), stride = cairo_image_surface_get_stride(img);
        const unsigned char *src = cairo_image_surface_get_data(img);
        FILE *f = src && w > 0 && h > 0 ? fopen(q->path, "wb") : NULL;
        if (f) {
            uint32_t hdr[2] = { (uint32_t)w, (uint32_t)h };
            fwrite("PSN1", 1, 4, f);
            fwrite(hdr, 4, 2, f); // little-endian hosts
            unsigned char *row = malloc((size_t)w * 4);
            for (int y = 0; y < h; y++) {
                memcpy(row, src + (size_t)y * stride, (size_t)w * 4);
                for (int x = 0; x < w; x++) row[x * 4 + 3] = 0xff; // opaque, as the engine's readback forces alpha
                fwrite(row, 1, (size_t)w * 4, f);
            }
            free(row);
            ok = fclose(f) == 0;
        }
    }
    if (img) cairo_surface_destroy(img);
    if (err) g_error_free(err);
    if (q->w->cb && rec(q->w, q->view)) q->w->cb(q->w->context, q->view, PHOTON_WEB_SNAPSHOT, ok ? q->path : "");
    g_free(q->path);
    g_free(q);
}

void photon_web_view_snapshot(photon_web *w, int view, const char *path) {
    view_rec *r = rec(w, view);
    if (!r) return;
    snapshot_ref *q = g_new0(snapshot_ref, 1);
    q->w = w; q->view = view; q->path = g_strdup(path);
    webkit_web_view_get_snapshot(r->view, WEBKIT_SNAPSHOT_REGION_VISIBLE, WEBKIT_SNAPSHOT_OPTIONS_NONE, NULL, snapshot_done, q);
}

void photon_web_view_destroy(photon_web *w, int view) {
    view_rec *r = rec(w, view);
    if (!r) return;
    r->alive = 0;
    if (r->overlay_image) cairo_surface_destroy(r->overlay_image);
    gtk_widget_destroy(r->window);
    g_object_unref(r->ucm);
    memset(r, 0, sizeof *r);
}

void photon_web_destroy(photon_web *w) {
    if (!w) return;
    for (int i = 0; i < MAX_VIEWS; i++) photon_web_view_destroy(w, i);
    g_signal_handlers_disconnect_by_data(gdk_display_get_default(), w);
    g_object_unref(w->web_context);
    for (int i = 0; i < w->n_scripts; i++) g_free(w->scripts[i]);
    for (int i = 0; i < w->n_extra; i++) g_free(w->extra[i]);
    g_free(w->root);
    free(w);
}

static gboolean wake(gpointer data) { *(int *)data = 1; return G_SOURCE_REMOVE; }

int photon_web_iterate(int timeout_ms) {
    int n = 0;
    while (n < 1000 && g_main_context_pending(NULL)) { g_main_context_iteration(NULL, FALSE); n++; }
    if (n == 0 && timeout_ms > 0) {
        int fired = 0;
        guint id = g_timeout_add((guint)timeout_ms, wake, &fired);
        g_main_context_iteration(NULL, TRUE);
        if (!fired) g_source_remove(id);
        n = 1;
    }
    return n;
}
