// Single instance for `photon-linux app` (photon_app.h, docs/linux-port.md §6.1): the first instance owns a well-known
// name on the session bus and exports Activate; a second launch calls it and exits, and the first raises its browser
// (or applies the wallpaper the second was given). The macOS app gets this from LaunchServices.
#include "photon_app.h"

#include <gio/gio.h>
#include <stdio.h>
#include <string.h>

static const char *INSTANCE_IFACE = "io.github.photon2.Photon";
static const char *INSTANCE_XML =
    "<node><interface name='io.github.photon2.Photon'>"
    "<method name='Activate'><arg type='as' name='arguments' direction='in'/><arg type='s' name='activation_token' direction='in'/></method>"
    "</interface></node>";

typedef struct {
    photon_activate_cb cb;
    void *context;
} instance;

static void instance_call(GDBusConnection *c, const gchar *sender, const gchar *path, const gchar *iface, const gchar *method,
                          GVariant *params, GDBusMethodInvocation *inv, gpointer data) {
    instance *in = data;
    if (strcmp(method, "Activate") != 0) {
        g_dbus_method_invocation_return_dbus_error(inv, "org.freedesktop.DBus.Error.UnknownMethod", method);
        return;
    }
    const gchar **args = NULL;
    const gchar *token = NULL;
    g_variant_get(params, "(^a&s&s)", &args, &token);
    int n = args ? (int)g_strv_length((gchar **)args) : 0;
    if (in->cb) in->cb(in->context, args, n, token ? token : "");
    g_free(args);
    g_dbus_method_invocation_return_value(inv, NULL);
}

static const GDBusInterfaceVTable instance_vtable = { instance_call, NULL, NULL, { 0 } };

int photon_instance_claim(const char *name, const char *path, photon_activate_cb cb, void *context) {
    GError *err = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &err);
    if (!bus) { if (err) g_error_free(err); return -1; }
    // RequestName with DO_NOT_QUEUE (4): 1 = primary owner, 3 = exists.
    GVariant *r = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                                              g_variant_new("(su)", name, 4u), G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 3000, NULL, &err);
    if (!r) { if (err) g_error_free(err); return -1; }
    guint32 reply = 0;
    g_variant_get(r, "(u)", &reply);
    g_variant_unref(r);
    if (reply != 1 && reply != 4) return 0; // 4: already the owner
    GDBusNodeInfo *info = g_dbus_node_info_new_for_xml(INSTANCE_XML, NULL);
    instance *in = g_new0(instance, 1);
    in->cb = cb; in->context = context;
    guint id = g_dbus_connection_register_object(bus, path, g_dbus_node_info_lookup_interface(info, INSTANCE_IFACE), &instance_vtable, in,
                                                 NULL, &err);
    if (!id && err) { fprintf(stderr, "photon: cannot export %s: %s\n", path, err->message); g_error_free(err); }
    return 1;
}

int photon_instance_activate(const char *name, const char *path, const char *const *args, int n, const char *token) {
    GError *err = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &err);
    if (!bus) { if (err) g_error_free(err); return 0; }
    GVariantBuilder b;
    g_variant_builder_init(&b, G_VARIANT_TYPE("as"));
    for (int i = 0; i < n; i++) g_variant_builder_add(&b, "s", args[i]);
    GVariant *r = g_dbus_connection_call_sync(bus, name, path, INSTANCE_IFACE, "Activate", g_variant_new("(ass)", &b, token ? token : ""),
                                              NULL, G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &err);
    if (!r) {
        fprintf(stderr, "photon: the running instance did not answer: %s\n", err ? err->message : "?");
        if (err) g_error_free(err);
        return 0;
    }
    g_variant_unref(r);
    return 1;
}
