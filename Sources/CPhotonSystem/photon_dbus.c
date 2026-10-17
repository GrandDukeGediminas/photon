// D-Bus services for photon2 on Linux (photon_system.h, docs/linux-port.md §5.1): MPRIS polling and the playback-rule
// signal watcher, on GIO.
#include "photon_system.h"

#include <gio/gio.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// MARK: - MPRIS

static char *dup_or_empty(const char *s) { return g_strdup(s ? s : ""); }

/// A string or a string list (xesam:artist, xesam:genre, xesam:albumArtist are `as`) as one string joined with ", ".
static char *variant_text(GVariant *v) {
    if (!v) return g_strdup("");
    if (g_variant_is_of_type(v, G_VARIANT_TYPE_STRING) || g_variant_is_of_type(v, G_VARIANT_TYPE_OBJECT_PATH))
        return g_strdup(g_variant_get_string(v, NULL));
    if (g_variant_is_of_type(v, G_VARIANT_TYPE_STRING_ARRAY)) {
        const gchar **list = g_variant_get_strv(v, NULL);
        char *joined = g_strjoinv(", ", (gchar **)list);
        g_free(list);
        return joined;
    }
    return g_strdup("");
}

static int64_t variant_int(GVariant *v) {
    if (!v) return 0;
    if (g_variant_is_of_type(v, G_VARIANT_TYPE_INT64)) return g_variant_get_int64(v);
    if (g_variant_is_of_type(v, G_VARIANT_TYPE_UINT64)) return (int64_t)g_variant_get_uint64(v);
    if (g_variant_is_of_type(v, G_VARIANT_TYPE_INT32)) return g_variant_get_int32(v);
    if (g_variant_is_of_type(v, G_VARIANT_TYPE_UINT32)) return g_variant_get_uint32(v);
    if (g_variant_is_of_type(v, G_VARIANT_TYPE_DOUBLE)) return (int64_t)g_variant_get_double(v);
    return 0;
}

/// Properties.GetAll(interface) of `name` at /org/mpris/MediaPlayer2, as an a{sv} dictionary (NULL on failure).
static GVariant *get_all(GDBusConnection *bus, const char *name, const char *interface) {
    GVariant *r = g_dbus_connection_call_sync(bus, name, "/org/mpris/MediaPlayer2", "org.freedesktop.DBus.Properties", "GetAll",
                                              g_variant_new("(s)", interface), G_VARIANT_TYPE("(a{sv})"),
                                              G_DBUS_CALL_FLAGS_NONE, 500, NULL, NULL);
    if (!r) return NULL;
    GVariant *dict = g_variant_get_child_value(r, 0);
    g_variant_unref(r);
    return dict;
}

static GVariant *lookup(GVariant *dict, const char *key) {
    return dict ? g_variant_lookup_value(dict, key, NULL) : NULL;
}

static char *lookup_text(GVariant *dict, const char *key) {
    GVariant *v = lookup(dict, key);
    char *s = variant_text(v);
    if (v) g_variant_unref(v);
    return s;
}

static char *player_status(GDBusConnection *bus, const char *name) {
    GVariant *r = g_dbus_connection_call_sync(bus, name, "/org/mpris/MediaPlayer2", "org.freedesktop.DBus.Properties", "Get",
                                              g_variant_new("(ss)", "org.mpris.MediaPlayer2.Player", "PlaybackStatus"),
                                              G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 500, NULL, NULL);
    if (!r) return g_strdup("");
    GVariant *v = NULL;
    g_variant_get(r, "(v)", &v);
    char *s = variant_text(v);
    if (v) g_variant_unref(v);
    g_variant_unref(r);
    return s;
}

static int compare_names(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

int photon_mpris_poll(photon_mpris_info *out) {
    memset(out, 0, sizeof *out);
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    if (!bus) return 0;
    GVariant *r = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                                              "ListNames", NULL, G_VARIANT_TYPE("(as)"), G_DBUS_CALL_FLAGS_NONE, 500, NULL, NULL);
    if (!r) { g_object_unref(bus); return 0; }
    GVariant *names = g_variant_get_child_value(r, 0);
    gsize n = 0;
    const gchar **all = g_variant_get_strv(names, &n);
    char **players = g_new0(char *, n + 1);
    gsize count = 0;
    for (gsize i = 0; i < n; i++)
        if (g_str_has_prefix(all[i], "org.mpris.MediaPlayer2.")) players[count++] = g_strdup(all[i]);
    g_free(all);
    g_variant_unref(names);
    g_variant_unref(r);
    qsort(players, count, sizeof *players, compare_names);
    // The session to show: Playing first, then Paused, then any (WinRT shows the current session; MPRIS has no such
    // notion, so a playing player wins).
    int chosen = -1, rank = 99;
    for (gsize i = 0; i < count; i++) {
        char *st = player_status(bus, players[i]);
        int k = strcmp(st, "Playing") == 0 ? 0 : strcmp(st, "Paused") == 0 ? 1 : 2;
        g_free(st);
        if (k < rank) { rank = k; chosen = (int)i; }
    }
    if (chosen >= 0) {
        const char *name = players[chosen];
        out->found = 1;
        out->bus_name = g_strdup(name);
        GVariant *root = get_all(bus, name, "org.mpris.MediaPlayer2");
        out->identity = lookup_text(root, "Identity");
        out->desktop_entry = lookup_text(root, "DesktopEntry");
        if (root) g_variant_unref(root);
        GVariant *player = get_all(bus, name, "org.mpris.MediaPlayer2.Player");
        out->status = lookup_text(player, "PlaybackStatus");
        GVariant *pos = lookup(player, "Position");
        out->position_us = variant_int(pos);
        if (pos) g_variant_unref(pos);
        GVariant *rate = lookup(player, "Rate");
        out->rate = rate && g_variant_is_of_type(rate, G_VARIANT_TYPE_DOUBLE) ? g_variant_get_double(rate) : 1.0;
        if (rate) g_variant_unref(rate);
        GVariant *meta = lookup(player, "Metadata");
        out->title = lookup_text(meta, "xesam:title");
        out->artist = lookup_text(meta, "xesam:artist");
        out->album = lookup_text(meta, "xesam:album");
        out->album_artist = lookup_text(meta, "xesam:albumArtist");
        out->genres = lookup_text(meta, "xesam:genre");
        out->art_url = lookup_text(meta, "mpris:artUrl");
        GVariant *len = lookup(meta, "mpris:length");
        out->length_us = variant_int(len);
        if (len) g_variant_unref(len);
        if (meta) g_variant_unref(meta);
        if (player) g_variant_unref(player);
    }
    for (gsize i = 0; i < count; i++) g_free(players[i]);
    g_free(players);
    g_object_unref(bus);
    if (!out->found) {
        out->bus_name = dup_or_empty(NULL); out->identity = dup_or_empty(NULL); out->desktop_entry = dup_or_empty(NULL);
        out->status = dup_or_empty(NULL); out->title = dup_or_empty(NULL); out->artist = dup_or_empty(NULL);
        out->album = dup_or_empty(NULL); out->album_artist = dup_or_empty(NULL); out->genres = dup_or_empty(NULL);
        out->art_url = dup_or_empty(NULL); out->rate = 1;
    }
    return 1;
}

void photon_mpris_info_free(photon_mpris_info *i) {
    if (!i) return;
    g_free(i->bus_name); g_free(i->identity); g_free(i->desktop_entry); g_free(i->status); g_free(i->title);
    g_free(i->artist); g_free(i->album); g_free(i->album_artist); g_free(i->genres); g_free(i->art_url);
    memset(i, 0, sizeof *i);
}

// MARK: - Playback-rule signals

static pthread_mutex_t state_lock = PTHREAD_MUTEX_INITIALIZER;
static photon_system_state state;
static pthread_once_t watch_once = PTHREAD_ONCE_INIT;

#define UPDATE(stmt) do { pthread_mutex_lock(&state_lock); stmt; pthread_mutex_unlock(&state_lock); } while (0)

static void set_battery(int v) { UPDATE(if (state.on_battery != v) state.battery_events++; state.on_battery = v; state.upower = 1); }
static void set_locked(int v) { UPDATE(if (state.locked != v) state.lock_events++; state.locked = v); }
static void set_screensaver(int v) { UPDATE(if (state.screensaver != v) state.screensaver_events++; state.screensaver = v); }

static void on_upower_changed(GDBusConnection *c, const gchar *sender, const gchar *path, const gchar *iface, const gchar *signal,
                              GVariant *params, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface; (void)signal; (void)data;
    const gchar *interface = NULL;
    GVariant *changed = NULL;
    g_variant_get(params, "(&s@a{sv}@as)", &interface, &changed, NULL);
    if (interface && strcmp(interface, "org.freedesktop.UPower") == 0) {
        GVariant *v = g_variant_lookup_value(changed, "OnBattery", G_VARIANT_TYPE_BOOLEAN);
        if (v) { set_battery(g_variant_get_boolean(v)); g_variant_unref(v); }
    }
    if (changed) g_variant_unref(changed);
}

static void set_power_saver(const char *profile) {
    UPDATE(state.power_profiles = 1; state.power_saver = profile && strcmp(profile, "power-saver") == 0);
}

// power-profiles-daemon: org.freedesktop.UPower.PowerProfiles (0.20+) or the older net.hadess.PowerProfiles name, same
// object layout.
static const char *const power_profile_names[][2] = {
    {"org.freedesktop.UPower.PowerProfiles", "/org/freedesktop/UPower/PowerProfiles"},
    {"net.hadess.PowerProfiles", "/net/hadess/PowerProfiles"},
};

static void on_power_profile_changed(GDBusConnection *c, const gchar *sender, const gchar *path, const gchar *iface,
                                     const gchar *signal, GVariant *params, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface; (void)signal; (void)data;
    const gchar *interface = NULL;
    GVariant *changed = NULL;
    g_variant_get(params, "(&s@a{sv}@as)", &interface, &changed, NULL);
    if (interface && (strcmp(interface, power_profile_names[0][0]) == 0 || strcmp(interface, power_profile_names[1][0]) == 0)) {
        GVariant *v = g_variant_lookup_value(changed, "ActiveProfile", G_VARIANT_TYPE_STRING);
        if (v) { set_power_saver(g_variant_get_string(v, NULL)); g_variant_unref(v); }
    }
    if (changed) g_variant_unref(changed);
}

/// The ActiveProfile string of the first power-profiles-daemon name that answers (g_free it), or NULL.
static char *active_power_profile(GDBusConnection *bus) {
    for (size_t i = 0; i < sizeof power_profile_names / sizeof power_profile_names[0]; i++) {
        GVariant *r = g_dbus_connection_call_sync(bus, power_profile_names[i][0], power_profile_names[i][1], "org.freedesktop.DBus.Properties",
                                                  "Get", g_variant_new("(ss)", power_profile_names[i][0], "ActiveProfile"),
                                                  G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 1000, NULL, NULL);
        if (!r) continue;
        GVariant *v = NULL;
        g_variant_get(r, "(v)", &v);
        char *out = v && g_variant_is_of_type(v, G_VARIANT_TYPE_STRING) ? g_strdup(g_variant_get_string(v, NULL)) : NULL;
        if (v) g_variant_unref(v);
        g_variant_unref(r);
        if (out) return out;
    }
    return NULL;
}

static void on_prepare_for_sleep(GDBusConnection *c, const gchar *sender, const gchar *path, const gchar *iface, const gchar *signal,
                                 GVariant *params, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface; (void)signal; (void)data;
    gboolean start = FALSE;
    g_variant_get(params, "(b)", &start);
    UPDATE(state.preparing_sleep = start ? 1 : 0; state.sleep_events++);
}

static void on_session_lock(GDBusConnection *c, const gchar *sender, const gchar *path, const gchar *iface, const gchar *signal,
                            GVariant *params, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface; (void)params; (void)data;
    set_locked(strcmp(signal, "Lock") == 0);
}

static void on_session_changed(GDBusConnection *c, const gchar *sender, const gchar *path, const gchar *iface, const gchar *signal,
                               GVariant *params, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface; (void)signal; (void)data;
    const gchar *interface = NULL;
    GVariant *changed = NULL;
    g_variant_get(params, "(&s@a{sv}@as)", &interface, &changed, NULL);
    if (interface && strcmp(interface, "org.freedesktop.login1.Session") == 0) {
        GVariant *v = g_variant_lookup_value(changed, "LockedHint", G_VARIANT_TYPE_BOOLEAN);
        if (v) { set_locked(g_variant_get_boolean(v)); g_variant_unref(v); }
    }
    if (changed) g_variant_unref(changed);
}

static void on_screensaver(GDBusConnection *c, const gchar *sender, const gchar *path, const gchar *iface, const gchar *signal,
                           GVariant *params, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface; (void)signal; (void)data;
    gboolean active = FALSE;
    if (g_variant_is_of_type(params, G_VARIANT_TYPE("(b)"))) g_variant_get(params, "(b)", &active);
    set_screensaver(active);
}

/// Properties.Get returning a boolean, or -1.
static int get_bool(GDBusConnection *bus, const char *name, const char *path, const char *iface, const char *prop) {
    GVariant *r = g_dbus_connection_call_sync(bus, name, path, "org.freedesktop.DBus.Properties", "Get", g_variant_new("(ss)", iface, prop),
                                              G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 1000, NULL, NULL);
    if (!r) return -1;
    GVariant *v = NULL;
    g_variant_get(r, "(v)", &v);
    int out = v && g_variant_is_of_type(v, G_VARIANT_TYPE_BOOLEAN) ? (g_variant_get_boolean(v) ? 1 : 0) : -1;
    if (v) g_variant_unref(v);
    g_variant_unref(r);
    return out;
}

/// The logind session object of this process: GetSessionByPID, else GetSession($XDG_SESSION_ID), else "auto".
static char *session_path(GDBusConnection *bus) {
    GVariant *r = g_dbus_connection_call_sync(bus, "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager",
                                              "GetSessionByPID", g_variant_new("(u)", (guint32)getpid()), G_VARIANT_TYPE("(o)"),
                                              G_DBUS_CALL_FLAGS_NONE, 1000, NULL, NULL);
    if (!r) {
        const char *id = getenv("XDG_SESSION_ID");
        r = g_dbus_connection_call_sync(bus, "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager",
                                        "GetSession", g_variant_new("(s)", id && *id ? id : "auto"), G_VARIANT_TYPE("(o)"),
                                        G_DBUS_CALL_FLAGS_NONE, 1000, NULL, NULL);
    }
    if (!r) return NULL;
    const gchar *p = NULL;
    g_variant_get(r, "(&o)", &p);
    char *out = g_strdup(p);
    g_variant_unref(r);
    return out;
}

static int screensaver_active(GDBusConnection *bus, const char *name, const char *path, const char *iface) {
    GVariant *r = g_dbus_connection_call_sync(bus, name, path, iface, "GetActive", NULL, G_VARIANT_TYPE("(b)"),
                                              G_DBUS_CALL_FLAGS_NONE, 1000, NULL, NULL);
    if (!r) return -1;
    gboolean a = FALSE;
    g_variant_get(r, "(b)", &a);
    g_variant_unref(r);
    return a ? 1 : 0;
}

static void *watch_thread(void *arg) {
    (void)arg;
    GMainContext *ctx = g_main_context_new();
    g_main_context_push_thread_default(ctx);
    GDBusConnection *sys = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, NULL);
    GDBusConnection *ses = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    UPDATE(state.system_bus = sys != NULL; state.session_bus = ses != NULL);
    if (sys) {
        // Subscriptions first, then the initial values, so a change in between is not lost.
        g_dbus_connection_signal_subscribe(sys, NULL, "org.freedesktop.DBus.Properties", "PropertiesChanged", "/org/freedesktop/UPower",
                                           NULL, G_DBUS_SIGNAL_FLAGS_NONE, on_upower_changed, NULL, NULL);
        g_dbus_connection_signal_subscribe(sys, NULL, "org.freedesktop.login1.Manager", "PrepareForSleep", "/org/freedesktop/login1",
                                           NULL, G_DBUS_SIGNAL_FLAGS_NONE, on_prepare_for_sleep, NULL, NULL);
        int b = get_bool(sys, "org.freedesktop.UPower", "/org/freedesktop/UPower", "org.freedesktop.UPower", "OnBattery");
        if (b >= 0) set_battery(b);
        for (size_t i = 0; i < sizeof power_profile_names / sizeof power_profile_names[0]; i++) {
            g_dbus_connection_signal_subscribe(sys, NULL, "org.freedesktop.DBus.Properties", "PropertiesChanged", power_profile_names[i][1],
                                               NULL, G_DBUS_SIGNAL_FLAGS_NONE, on_power_profile_changed, NULL, NULL);
        }
        char *profile = active_power_profile(sys);
        if (profile) { set_power_saver(profile); g_free(profile); }
        char *sp = session_path(sys);
        if (sp) {
            UPDATE(state.logind = 1);
            g_dbus_connection_signal_subscribe(sys, NULL, "org.freedesktop.login1.Session", "Lock", sp, NULL, G_DBUS_SIGNAL_FLAGS_NONE,
                                               on_session_lock, NULL, NULL);
            g_dbus_connection_signal_subscribe(sys, NULL, "org.freedesktop.login1.Session", "Unlock", sp, NULL, G_DBUS_SIGNAL_FLAGS_NONE,
                                               on_session_lock, NULL, NULL);
            g_dbus_connection_signal_subscribe(sys, NULL, "org.freedesktop.DBus.Properties", "PropertiesChanged", sp, NULL,
                                               G_DBUS_SIGNAL_FLAGS_NONE, on_session_changed, NULL, NULL);
            int l = get_bool(sys, "org.freedesktop.login1", sp, "org.freedesktop.login1.Session", "LockedHint");
            if (l >= 0) set_locked(l);
            g_free(sp);
        }
    }
    if (ses) {
        // freedesktop (KDE, Xfce, MATE, LXQt) and GNOME screensaver interfaces; both send ActiveChanged(b).
        g_dbus_connection_signal_subscribe(ses, NULL, "org.freedesktop.ScreenSaver", "ActiveChanged", NULL, NULL,
                                           G_DBUS_SIGNAL_FLAGS_NONE, on_screensaver, NULL, NULL);
        g_dbus_connection_signal_subscribe(ses, NULL, "org.gnome.ScreenSaver", "ActiveChanged", NULL, NULL,
                                           G_DBUS_SIGNAL_FLAGS_NONE, on_screensaver, NULL, NULL);
        int a = screensaver_active(ses, "org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver");
        if (a < 0) a = screensaver_active(ses, "org.gnome.ScreenSaver", "/org/gnome/ScreenSaver", "org.gnome.ScreenSaver");
        if (a >= 0) set_screensaver(a);
    }
    if (!sys && !ses) return NULL;
    GMainLoop *loop = g_main_loop_new(ctx, FALSE);
    g_main_loop_run(loop);
    return NULL;
}

static void start_watch(void) {
    pthread_t t;
    if (pthread_create(&t, NULL, watch_thread, NULL) == 0) pthread_detach(t);
}

void photon_system_watch_start(void) { pthread_once(&watch_once, start_watch); }

void photon_system_state_get(photon_system_state *out) {
    pthread_mutex_lock(&state_lock);
    *out = state;
    pthread_mutex_unlock(&state_lock);
}
