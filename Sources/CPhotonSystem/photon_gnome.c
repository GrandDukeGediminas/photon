// The photon2 GNOME Shell extension's D-Bus side, as the GNOME host reads it (photon_system.h, docs/linux-port.md §5.2):
// io.github.photon2.Shell at /io/github/photon2/Shell, interface io.github.photon2.Shell1. GetState and the StateChanged
// signal carry the window list as JSON (states, monitors, workspaces, pids, app ids: the rule inputs Mutter keeps from
// clients), PointerChanged the cursor and the left button over the desktop. A thread with its own GLib main loop
// subscribes, asks for the state whenever the extension appears on the bus, and keeps the last values for the host.
#include "photon_system.h"

#include <gio/gio.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#define SHELL_NAME "io.github.photon2.Shell"
#define SHELL_PATH "/io/github/photon2/Shell"
#define SHELL_IFACE "io.github.photon2.Shell1"

static pthread_once_t gnome_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t gnome_lock = PTHREAD_MUTEX_INITIALIZER;
static char *gnome_json;            // last state (g_malloc)
static photon_gnome_shell_info gnome_info;
static GDBusConnection *gnome_bus;

static void set_json(const char *json) {
    pthread_mutex_lock(&gnome_lock);
    g_free(gnome_json);
    gnome_json = g_strdup(json ? json : "");
    gnome_info.state_serial++;
    pthread_mutex_unlock(&gnome_lock);
}

static void got_state(GObject *src, GAsyncResult *res, gpointer user) {
    GVariant *r = g_dbus_connection_call_finish(G_DBUS_CONNECTION(src), res, NULL);
    if (!r) return;
    const char *json = NULL;
    g_variant_get(r, "(&s)", &json);
    set_json(json);
    g_variant_unref(r);
}

static void request_state(void) {
    g_dbus_connection_call(gnome_bus, SHELL_NAME, SHELL_PATH, SHELL_IFACE, "GetState", NULL, G_VARIANT_TYPE("(s)"),
                           G_DBUS_CALL_FLAGS_NO_AUTO_START, 2000, NULL, got_state, NULL);
}

static void on_signal(GDBusConnection *c, const char *sender, const char *path, const char *iface, const char *signal,
                      GVariant *params, gpointer user) {
    if (!strcmp(signal, "StateChanged") && g_variant_is_of_type(params, G_VARIANT_TYPE("(s)"))) {
        const char *json = NULL;
        g_variant_get(params, "(&s)", &json);
        set_json(json);
    } else if (!strcmp(signal, "PointerChanged") && g_variant_is_of_type(params, G_VARIANT_TYPE("(ddbb)"))) {
        double x, y;
        gboolean desktop, pressed;
        g_variant_get(params, "(ddbb)", &x, &y, &desktop, &pressed);
        pthread_mutex_lock(&gnome_lock);
        gnome_info.pointer_known = 1;
        gnome_info.x = x;
        gnome_info.y = y;
        gnome_info.over_desktop = desktop;
        if (pressed && !gnome_info.pressed) gnome_info.presses++;
        gnome_info.pressed = pressed;
        pthread_mutex_unlock(&gnome_lock);
    }
}

static void name_appeared(GDBusConnection *c, const char *name, const char *owner, gpointer user) {
    pthread_mutex_lock(&gnome_lock);
    gnome_info.present = 1;
    pthread_mutex_unlock(&gnome_lock);
    request_state();
}

static void name_vanished(GDBusConnection *c, const char *name, gpointer user) {
    pthread_mutex_lock(&gnome_lock);
    gnome_info.present = 0;
    gnome_info.pressed = 0;
    pthread_mutex_unlock(&gnome_lock);
    set_json("");
}

static void *gnome_thread(void *arg) {
    GMainContext *ctx = arg;
    g_main_context_push_thread_default(ctx);
    gnome_bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    if (gnome_bus) {
        pthread_mutex_lock(&gnome_lock);
        gnome_info.bus = 1;
        pthread_mutex_unlock(&gnome_lock);
        g_dbus_connection_signal_subscribe(gnome_bus, SHELL_NAME, SHELL_IFACE, NULL, SHELL_PATH, NULL, G_DBUS_SIGNAL_FLAGS_NONE,
                                           on_signal, NULL, NULL);
        g_bus_watch_name_on_connection(gnome_bus, SHELL_NAME, G_BUS_NAME_WATCHER_FLAGS_NONE, name_appeared, name_vanished,
                                       NULL, NULL);
        GMainLoop *loop = g_main_loop_new(ctx, FALSE);
        g_main_loop_run(loop);
    }
    pthread_mutex_lock(&gnome_lock);
    gnome_info.started = 1; // the thread is past its setup (with or without a bus)
    pthread_mutex_unlock(&gnome_lock);
    return NULL;
}

static void start_gnome(void) {
    pthread_t t;
    GMainContext *ctx = g_main_context_new();
    if (pthread_create(&t, NULL, gnome_thread, ctx) == 0) pthread_detach(t);
}

void photon_gnome_shell_watch_start(void) { pthread_once(&gnome_once, start_gnome); }

void photon_gnome_shell_get(photon_gnome_shell_info *out) {
    pthread_mutex_lock(&gnome_lock);
    *out = gnome_info;
    pthread_mutex_unlock(&gnome_lock);
}

char *photon_gnome_shell_state_json(uint32_t *serial) {
    pthread_mutex_lock(&gnome_lock);
    char *s = strdup(gnome_json ? gnome_json : "");
    if (serial) *serial = gnome_info.state_serial;
    pthread_mutex_unlock(&gnome_lock);
    return s;
}

int photon_gnome_shell_ping(int timeout_ms) {
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    if (!bus) return 0;
    GVariant *r = g_dbus_connection_call_sync(bus, SHELL_NAME, SHELL_PATH, SHELL_IFACE, "GetState", NULL, G_VARIANT_TYPE("(s)"),
                                              G_DBUS_CALL_FLAGS_NO_AUTO_START, timeout_ms, NULL, NULL);
    g_object_unref(bus);
    if (!r) return 0;
    const char *json = NULL;
    g_variant_get(r, "(&s)", &json);
    set_json(json);
    g_variant_unref(r);
    return 1;
}
