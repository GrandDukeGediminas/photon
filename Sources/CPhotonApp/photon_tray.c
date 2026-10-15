// StatusNotifierItem + com.canonical.dbusmenu for the Linux app's status icon (photon_app.h, docs/linux-port.md §6.1).
// The item follows the freedesktop StatusNotifierItem specification as KDE Plasma, waybar, the GNOME AppIndicator
// extension, xfce4-panel's sn plugin and swaybar's tray implement it; the menu is the libdbusmenu protocol (version 3)
// those hosts read through the item's `Menu` object path.
#include "photon_app.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define SNI_PATH "/StatusNotifierItem"
#define MENU_PATH "/MenuBar"
#define WATCHER_NAME "org.kde.StatusNotifierWatcher"
#define WATCHER_PATH "/StatusNotifierWatcher"

static const char sni_xml[] =
    "<node>"
    " <interface name='org.kde.StatusNotifierItem'>"
    "  <property name='Category' type='s' access='read'/>"
    "  <property name='Id' type='s' access='read'/>"
    "  <property name='Title' type='s' access='read'/>"
    "  <property name='Status' type='s' access='read'/>"
    "  <property name='WindowId' type='i' access='read'/>"
    "  <property name='IconName' type='s' access='read'/>"
    "  <property name='IconThemePath' type='s' access='read'/>"
    "  <property name='IconPixmap' type='a(iiay)' access='read'/>"
    "  <property name='OverlayIconName' type='s' access='read'/>"
    "  <property name='OverlayIconPixmap' type='a(iiay)' access='read'/>"
    "  <property name='AttentionIconName' type='s' access='read'/>"
    "  <property name='AttentionIconPixmap' type='a(iiay)' access='read'/>"
    "  <property name='AttentionMovieName' type='s' access='read'/>"
    "  <property name='ToolTip' type='(sa(iiay)ss)' access='read'/>"
    "  <property name='ItemIsMenu' type='b' access='read'/>"
    "  <property name='Menu' type='o' access='read'/>"
    "  <method name='ContextMenu'><arg name='x' type='i' direction='in'/><arg name='y' type='i' direction='in'/></method>"
    "  <method name='Activate'><arg name='x' type='i' direction='in'/><arg name='y' type='i' direction='in'/></method>"
    "  <method name='SecondaryActivate'><arg name='x' type='i' direction='in'/><arg name='y' type='i' direction='in'/></method>"
    "  <method name='Scroll'><arg name='delta' type='i' direction='in'/><arg name='orientation' type='s' direction='in'/></method>"
    "  <signal name='NewTitle'/><signal name='NewIcon'/><signal name='NewAttentionIcon'/><signal name='NewOverlayIcon'/>"
    "  <signal name='NewToolTip'/><signal name='NewStatus'><arg name='status' type='s'/></signal>"
    " </interface>"
    "</node>";

static const char menu_xml[] =
    "<node>"
    " <interface name='com.canonical.dbusmenu'>"
    "  <property name='Version' type='u' access='read'/>"
    "  <property name='TextDirection' type='s' access='read'/>"
    "  <property name='Status' type='s' access='read'/>"
    "  <property name='IconThemePath' type='as' access='read'/>"
    "  <method name='GetLayout'>"
    "   <arg type='i' name='parentId' direction='in'/><arg type='i' name='recursionDepth' direction='in'/>"
    "   <arg type='as' name='propertyNames' direction='in'/>"
    "   <arg type='u' name='revision' direction='out'/><arg type='(ia{sv}av)' name='layout' direction='out'/>"
    "  </method>"
    "  <method name='GetGroupProperties'>"
    "   <arg type='ai' name='ids' direction='in'/><arg type='as' name='propertyNames' direction='in'/>"
    "   <arg type='a(ia{sv})' name='properties' direction='out'/>"
    "  </method>"
    "  <method name='GetProperty'>"
    "   <arg type='i' name='id' direction='in'/><arg type='s' name='name' direction='in'/><arg type='v' name='value' direction='out'/>"
    "  </method>"
    "  <method name='Event'>"
    "   <arg type='i' name='id' direction='in'/><arg type='s' name='eventId' direction='in'/>"
    "   <arg type='v' name='data' direction='in'/><arg type='u' name='timestamp' direction='in'/>"
    "  </method>"
    "  <method name='EventGroup'>"
    "   <arg type='a(isvu)' name='events' direction='in'/><arg type='ai' name='idErrors' direction='out'/>"
    "  </method>"
    "  <method name='AboutToShow'><arg type='i' name='id' direction='in'/><arg type='b' name='needUpdate' direction='out'/></method>"
    "  <method name='AboutToShowGroup'>"
    "   <arg type='ai' name='ids' direction='in'/><arg type='ai' name='updatesNeeded' direction='out'/>"
    "   <arg type='ai' name='idErrors' direction='out'/>"
    "  </method>"
    "  <signal name='ItemsPropertiesUpdated'><arg type='a(ia{sv})' name='updatedProps'/><arg type='a(ia{s})' name='removedProps'/></signal>"
    "  <signal name='LayoutUpdated'><arg type='u' name='revision'/><arg type='i' name='parent'/></signal>"
    "  <signal name='ItemActivationRequested'><arg type='i' name='id'/><arg type='u' name='timestamp'/></signal>"
    " </interface>"
    "</node>";

typedef struct {
    int id, parent, separator, enabled, toggle, checked;
    char *label;
} tray_entry;

struct photon_tray {
    photon_tray_cb cb;
    void *context;
    char *id, *title, *icon_name, *status, *tip_title, *tip_text;
    GVariant *pixmap;             // a(iiay), floating ref sunk
    GDBusConnection *bus;
    GDBusNodeInfo *sni_info, *menu_info;
    guint sni_reg, menu_reg, own_id, watch_id;
    char bus_name[128];
    int registered;
    guint32 revision;
    tray_entry *entries;
    int n_entries;
};

static int instance_counter = 0;

// MARK: menu layout

static GVariant *entry_props(const tray_entry *e, int has_children) {
    GVariantBuilder b;
    g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
    if (e->separator) {
        g_variant_builder_add(&b, "{sv}", "type", g_variant_new_string("separator"));
    } else {
        g_variant_builder_add(&b, "{sv}", "label", g_variant_new_string(e->label ? e->label : ""));
        g_variant_builder_add(&b, "{sv}", "enabled", g_variant_new_boolean(e->enabled != 0));
        if (e->toggle) {
            g_variant_builder_add(&b, "{sv}", "toggle-type", g_variant_new_string("checkmark"));
            g_variant_builder_add(&b, "{sv}", "toggle-state", g_variant_new_int32(e->checked ? 1 : 0));
        }
        if (has_children) g_variant_builder_add(&b, "{sv}", "children-display", g_variant_new_string("submenu"));
    }
    g_variant_builder_add(&b, "{sv}", "visible", g_variant_new_boolean(TRUE));
    return g_variant_builder_end(&b);
}

static int has_children(photon_tray *t, int id) {
    for (int i = 0; i < t->n_entries; i++) if (t->entries[i].parent == id) return 1;
    return 0;
}

static const tray_entry *find_entry(photon_tray *t, int id) {
    for (int i = 0; i < t->n_entries; i++) if (t->entries[i].id == id) return &t->entries[i];
    return NULL;
}

/// (ia{sv}av) for `id` with children to `depth` (-1 = all).
static GVariant *layout_node(photon_tray *t, int id, int depth) {
    GVariantBuilder props, kids;
    GVariant *p;
    if (id == 0) {
        g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
        g_variant_builder_add(&props, "{sv}", "children-display", g_variant_new_string("submenu"));
        p = g_variant_builder_end(&props);
    } else {
        const tray_entry *e = find_entry(t, id);
        tray_entry none = {0};
        p = entry_props(e ? e : &none, has_children(t, id));
    }
    g_variant_builder_init(&kids, G_VARIANT_TYPE("av"));
    if (depth != 0) {
        for (int i = 0; i < t->n_entries; i++) {
            if (t->entries[i].parent != id) continue;
            g_variant_builder_add(&kids, "v", layout_node(t, t->entries[i].id, depth < 0 ? -1 : depth - 1));
        }
    }
    return g_variant_new("(i@a{sv}av)", id, p, &kids);
}

static void emit(photon_tray *t, const char *path, const char *iface, const char *signal, GVariant *params) {
    if (!t->bus) { if (params) g_variant_unref(g_variant_ref_sink(params)); return; }
    g_dbus_connection_emit_signal(t->bus, NULL, path, iface, signal, params, NULL);
}

// MARK: dbusmenu

static void menu_call(GDBusConnection *c, const gchar *sender, const gchar *path, const gchar *iface, const gchar *method,
                      GVariant *params, GDBusMethodInvocation *inv, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface;
    photon_tray *t = data;
    if (strcmp(method, "GetLayout") == 0) {
        gint32 parent, depth;
        g_variant_get(params, "(ii^a&s)", &parent, &depth, NULL);
        g_dbus_method_invocation_return_value(inv, g_variant_new("(u@(ia{sv}av))", t->revision, layout_node(t, parent, depth)));
    } else if (strcmp(method, "GetGroupProperties") == 0) {
        GVariantIter *ids;
        g_variant_get(params, "(ai^a&s)", &ids, NULL);
        GVariantBuilder b;
        g_variant_builder_init(&b, G_VARIANT_TYPE("a(ia{sv})"));
        gint32 id;
        while (g_variant_iter_next(ids, "i", &id)) {
            const tray_entry *e = find_entry(t, id);
            if (e) g_variant_builder_add(&b, "(i@a{sv})", id, entry_props(e, has_children(t, id)));
        }
        g_variant_iter_free(ids);
        g_dbus_method_invocation_return_value(inv, g_variant_new("(a(ia{sv}))", &b));
    } else if (strcmp(method, "GetProperty") == 0) {
        gint32 id;
        const char *name;
        g_variant_get(params, "(i&s)", &id, &name);
        const tray_entry *e = find_entry(t, id);
        if (!e) {
            g_dbus_method_invocation_return_dbus_error(inv, "com.canonical.dbusmenu.Error", "unknown id");
            return;
        }
        GVariant *props = entry_props(e, has_children(t, id));
        GVariant *v = g_variant_lookup_value(props, name, NULL);
        g_variant_unref(g_variant_ref_sink(props));
        if (!v) v = g_variant_new_string("");
        g_dbus_method_invocation_return_value(inv, g_variant_new("(v)", v));
    } else if (strcmp(method, "Event") == 0) {
        gint32 id;
        const char *event;
        g_variant_get(params, "(i&svu)", &id, &event, NULL, NULL);
        g_dbus_method_invocation_return_value(inv, NULL);
        if (strcmp(event, "clicked") == 0 && t->cb) t->cb(t->context, PHOTON_TRAY_MENU_ITEM, id);
        if (strcmp(event, "opened") == 0 && id == 0 && t->cb) t->cb(t->context, PHOTON_TRAY_MENU_OPENING, 0);
    } else if (strcmp(method, "EventGroup") == 0) {
        GVariantIter *events;
        g_variant_get(params, "(a(isvu))", &events);
        gint32 id;
        const char *event;
        GVariant *d;
        guint32 ts;
        int clicked[64], n = 0;
        while (g_variant_iter_next(events, "(i&svu)", &id, &event, &d, &ts)) {
            if (strcmp(event, "clicked") == 0 && n < 64) clicked[n++] = id;
            g_variant_unref(d);
        }
        g_variant_iter_free(events);
        g_dbus_method_invocation_return_value(inv, g_variant_new("(@ai)", g_variant_new_array(G_VARIANT_TYPE_INT32, NULL, 0)));
        for (int i = 0; i < n; i++) if (t->cb) t->cb(t->context, PHOTON_TRAY_MENU_ITEM, clicked[i]);
    } else if (strcmp(method, "AboutToShow") == 0) {
        gint32 id;
        g_variant_get(params, "(i)", &id);
        guint32 before = t->revision;
        if (id == 0 && t->cb) t->cb(t->context, PHOTON_TRAY_MENU_OPENING, 0);
        g_dbus_method_invocation_return_value(inv, g_variant_new("(b)", t->revision != before));
    } else if (strcmp(method, "AboutToShowGroup") == 0) {
        GVariantIter *ids;
        g_variant_get(params, "(ai)", &ids);
        gint32 id;
        int root = 0;
        while (g_variant_iter_next(ids, "i", &id)) if (id == 0) root = 1;
        g_variant_iter_free(ids);
        guint32 before = t->revision;
        if (root && t->cb) t->cb(t->context, PHOTON_TRAY_MENU_OPENING, 0);
        GVariantBuilder upd;
        g_variant_builder_init(&upd, G_VARIANT_TYPE("ai"));
        if (t->revision != before) g_variant_builder_add(&upd, "i", 0);
        g_dbus_method_invocation_return_value(inv, g_variant_new("(@ai@ai)", g_variant_builder_end(&upd),
                                                                 g_variant_new_array(G_VARIANT_TYPE_INT32, NULL, 0)));
    } else {
        g_dbus_method_invocation_return_dbus_error(inv, "org.freedesktop.DBus.Error.UnknownMethod", method);
    }
}

static GVariant *menu_get(GDBusConnection *c, const gchar *sender, const gchar *path, const gchar *iface, const gchar *prop,
                          GError **error, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface; (void)error; (void)data;
    if (strcmp(prop, "Version") == 0) return g_variant_new_uint32(3);
    if (strcmp(prop, "TextDirection") == 0) return g_variant_new_string("ltr");
    if (strcmp(prop, "Status") == 0) return g_variant_new_string("normal");
    if (strcmp(prop, "IconThemePath") == 0) return g_variant_new_strv(NULL, 0);
    return NULL;
}

// MARK: item

static GVariant *empty_pixmaps(void) { return g_variant_new_array(G_VARIANT_TYPE("(iiay)"), NULL, 0); }

static void sni_call(GDBusConnection *c, const gchar *sender, const gchar *path, const gchar *iface, const gchar *method,
                     GVariant *params, GDBusMethodInvocation *inv, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface;
    photon_tray *t = data;
    gint32 x = 0, y = 0;
    if (strcmp(method, "Scroll") != 0) g_variant_get(params, "(ii)", &x, &y);
    g_dbus_method_invocation_return_value(inv, NULL);
    if (!t->cb) return;
    if (strcmp(method, "Activate") == 0) t->cb(t->context, PHOTON_TRAY_ACTIVATE, 0);
    else if (strcmp(method, "SecondaryActivate") == 0) t->cb(t->context, PHOTON_TRAY_SECONDARY, 0);
    else if (strcmp(method, "ContextMenu") == 0) t->cb(t->context, PHOTON_TRAY_CONTEXT_MENU, ((x & 0xffff) << 16) | (y & 0xffff));
}

static GVariant *sni_get(GDBusConnection *c, const gchar *sender, const gchar *path, const gchar *iface, const gchar *prop,
                         GError **error, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface; (void)error;
    photon_tray *t = data;
    if (strcmp(prop, "Category") == 0) return g_variant_new_string("ApplicationStatus");
    if (strcmp(prop, "Id") == 0) return g_variant_new_string(t->id);
    if (strcmp(prop, "Title") == 0) return g_variant_new_string(t->title);
    if (strcmp(prop, "Status") == 0) return g_variant_new_string(t->status);
    if (strcmp(prop, "WindowId") == 0) return g_variant_new_int32(0);
    if (strcmp(prop, "IconName") == 0) return g_variant_new_string(t->icon_name);
    if (strcmp(prop, "IconThemePath") == 0) return g_variant_new_string("");
    if (strcmp(prop, "IconPixmap") == 0) return t->pixmap ? g_variant_ref(t->pixmap) : empty_pixmaps();
    if (strcmp(prop, "OverlayIconName") == 0 || strcmp(prop, "AttentionIconName") == 0 || strcmp(prop, "AttentionMovieName") == 0)
        return g_variant_new_string("");
    if (strcmp(prop, "OverlayIconPixmap") == 0 || strcmp(prop, "AttentionIconPixmap") == 0) return empty_pixmaps();
    if (strcmp(prop, "ToolTip") == 0)
        return g_variant_new("(s@a(iiay)ss)", t->icon_name, t->pixmap ? g_variant_ref(t->pixmap) : empty_pixmaps(),
                             t->tip_title ? t->tip_title : t->title, t->tip_text ? t->tip_text : "");
    if (strcmp(prop, "ItemIsMenu") == 0) return g_variant_new_boolean(FALSE);
    if (strcmp(prop, "Menu") == 0) return g_variant_new_object_path(MENU_PATH);
    return NULL;
}

static const GDBusInterfaceVTable sni_vtable = { sni_call, sni_get, NULL, { 0 } };
static const GDBusInterfaceVTable menu_vtable = { menu_call, menu_get, NULL, { 0 } };

static void registered_cb(GObject *src, GAsyncResult *res, gpointer data) {
    photon_tray *t = data;
    GError *err = NULL;
    GVariant *r = g_dbus_connection_call_finish(G_DBUS_CONNECTION(src), res, &err);
    if (r) {
        g_variant_unref(r);
        t->registered = 1;
        if (t->cb) t->cb(t->context, PHOTON_TRAY_REGISTERED, 1);
    } else {
        fprintf(stderr, "photon: StatusNotifierWatcher refused the item: %s\n", err ? err->message : "?");
        if (err) g_error_free(err);
        t->registered = 0;
        if (t->cb) t->cb(t->context, PHOTON_TRAY_REGISTERED, 0);
    }
}

static void watcher_appeared(GDBusConnection *c, const gchar *name, const gchar *owner, gpointer data) {
    (void)name; (void)owner;
    photon_tray *t = data;
    // In a Flatpak sandbox the bus proxy does not let the app own org.kde.StatusNotifierItem-*; the item then registers
    // under its unique connection name, which the specification allows (watchers take the sender's object path
    // /StatusNotifierItem).
    const char *service = getenv("FLATPAK_ID") ? g_dbus_connection_get_unique_name(c) : t->bus_name;
    g_dbus_connection_call(c, WATCHER_NAME, WATCHER_PATH, WATCHER_NAME, "RegisterStatusNotifierItem",
                           g_variant_new("(s)", service), NULL, G_DBUS_CALL_FLAGS_NONE, 5000, NULL, registered_cb, t);
}

static void watcher_vanished(GDBusConnection *c, const gchar *name, gpointer data) {
    (void)c; (void)name;
    photon_tray *t = data;
    if (t->registered && t->cb) t->cb(t->context, PHOTON_TRAY_REGISTERED, 0);
    t->registered = 0;
}

static GVariant *load_pixmap(const char *png) {
    if (!png || !*png) return NULL;
    GVariantBuilder arr;
    g_variant_builder_init(&arr, G_VARIANT_TYPE("a(iiay)"));
    int sizes[] = { 22, 32, 48, 64 }, added = 0;
    for (int k = 0; k < 4; k++) {
        GdkPixbuf *pb = gdk_pixbuf_new_from_file_at_size(png, sizes[k], sizes[k], NULL);
        if (!pb) continue;
        if (!gdk_pixbuf_get_has_alpha(pb)) { GdkPixbuf *a = gdk_pixbuf_add_alpha(pb, FALSE, 0, 0, 0); g_object_unref(pb); pb = a; }
        int w = gdk_pixbuf_get_width(pb), h = gdk_pixbuf_get_height(pb), stride = gdk_pixbuf_get_rowstride(pb);
        const guchar *px = gdk_pixbuf_read_pixels(pb);
        guchar *argb = g_malloc((gsize)w * h * 4);
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                const guchar *s = px + y * stride + x * 4;
                guchar *d = argb + (y * w + x) * 4;
                d[0] = s[3]; d[1] = s[0]; d[2] = s[1]; d[3] = s[2]; // ARGB32, network byte order
            }
        GVariant *bytes = g_variant_new_from_data(G_VARIANT_TYPE("ay"), argb, (gsize)w * h * 4, TRUE, g_free, argb);
        g_variant_builder_add(&arr, "(ii@ay)", w, h, bytes);
        g_object_unref(pb);
        added++;
    }
    GVariant *v = g_variant_builder_end(&arr);
    if (!added) { g_variant_unref(g_variant_ref_sink(v)); return NULL; }
    return g_variant_ref_sink(v);
}

photon_tray *photon_tray_new(const char *id, const char *title, const char *icon_name, const char *icon_png, photon_tray_cb cb,
                             void *context) {
    GError *err = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &err);
    if (!bus) {
        fprintf(stderr, "photon: no session bus for the status icon: %s\n", err ? err->message : "?");
        if (err) g_error_free(err);
        return NULL;
    }
    photon_tray *t = g_new0(photon_tray, 1);
    t->cb = cb;
    t->context = context;
    t->id = g_strdup(id);
    t->title = g_strdup(title);
    t->icon_name = g_strdup(icon_name);
    t->status = g_strdup("Active");
    t->pixmap = load_pixmap(icon_png);
    t->bus = bus;
    t->revision = 1;
    snprintf(t->bus_name, sizeof t->bus_name, "org.kde.StatusNotifierItem-%d-%d", (int)getpid(), ++instance_counter);
    t->sni_info = g_dbus_node_info_new_for_xml(sni_xml, NULL);
    t->menu_info = g_dbus_node_info_new_for_xml(menu_xml, NULL);
    t->sni_reg = g_dbus_connection_register_object(bus, SNI_PATH, t->sni_info->interfaces[0], &sni_vtable, t, NULL, &err);
    if (!t->sni_reg) { fprintf(stderr, "photon: cannot export %s: %s\n", SNI_PATH, err ? err->message : "?"); g_clear_error(&err); }
    t->menu_reg = g_dbus_connection_register_object(bus, MENU_PATH, t->menu_info->interfaces[0], &menu_vtable, t, NULL, &err);
    if (!t->menu_reg) { fprintf(stderr, "photon: cannot export %s: %s\n", MENU_PATH, err ? err->message : "?"); g_clear_error(&err); }
    if (!getenv("FLATPAK_ID"))
        t->own_id = g_bus_own_name_on_connection(bus, t->bus_name, G_BUS_NAME_OWNER_FLAGS_NONE, NULL, NULL, NULL, NULL);
    t->watch_id = g_bus_watch_name_on_connection(bus, WATCHER_NAME, G_BUS_NAME_WATCHER_FLAGS_NONE, watcher_appeared, watcher_vanished, t,
                                                 NULL);
    return t;
}

void photon_tray_set_menu(photon_tray *t, const photon_tray_item *items, int count) {
    if (!t) return;
    for (int i = 0; i < t->n_entries; i++) g_free(t->entries[i].label);
    g_free(t->entries);
    t->entries = g_new0(tray_entry, count > 0 ? count : 1);
    t->n_entries = count;
    for (int i = 0; i < count; i++) {
        t->entries[i] = (tray_entry){ items[i].id, items[i].parent, items[i].separator, items[i].enabled, items[i].toggle,
                                      items[i].checked, g_strdup(items[i].label ? items[i].label : "") };
    }
    t->revision++;
    emit(t, MENU_PATH, "com.canonical.dbusmenu", "LayoutUpdated", g_variant_new("(ui)", t->revision, 0));
}

void photon_tray_set_tooltip(photon_tray *t, const char *title, const char *text) {
    if (!t) return;
    g_free(t->tip_title);
    g_free(t->tip_text);
    t->tip_title = g_strdup(title);
    t->tip_text = g_strdup(text);
    emit(t, SNI_PATH, "org.kde.StatusNotifierItem", "NewToolTip", NULL);
}

void photon_tray_set_status(photon_tray *t, const char *status) {
    if (!t || !status || strcmp(status, t->status) == 0) return;
    g_free(t->status);
    t->status = g_strdup(status);
    emit(t, SNI_PATH, "org.kde.StatusNotifierItem", "NewStatus", g_variant_new("(s)", status));
}

int photon_tray_registered(photon_tray *t) { return t ? t->registered : 0; }
const char *photon_tray_bus_name(photon_tray *t) { return t ? t->bus_name : ""; }

void photon_tray_free(photon_tray *t) {
    if (!t) return;
    if (t->watch_id) g_bus_unwatch_name(t->watch_id);
    if (t->own_id) g_bus_unown_name(t->own_id);
    if (t->sni_reg) g_dbus_connection_unregister_object(t->bus, t->sni_reg);
    if (t->menu_reg) g_dbus_connection_unregister_object(t->bus, t->menu_reg);
    if (t->sni_info) g_dbus_node_info_unref(t->sni_info);
    if (t->menu_info) g_dbus_node_info_unref(t->menu_info);
    for (int i = 0; i < t->n_entries; i++) g_free(t->entries[i].label);
    g_free(t->entries);
    if (t->pixmap) g_variant_unref(t->pixmap);
    g_free(t->id); g_free(t->title); g_free(t->icon_name); g_free(t->status); g_free(t->tip_title); g_free(t->tip_text);
    g_object_unref(t->bus);
    g_free(t);
}

// MARK: - Background portal

int photon_portal_request_background(int autostart, const char *const *argv, const char *reason) {
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    if (!bus) return 0;
    GVariantBuilder opts;
    g_variant_builder_init(&opts, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&opts, "{sv}", "reason", g_variant_new_string(reason ? reason : ""));
    g_variant_builder_add(&opts, "{sv}", "autostart", g_variant_new_boolean(autostart != 0));
    if (argv) g_variant_builder_add(&opts, "{sv}", "commandline", g_variant_new_strv(argv, -1));
    GError *err = NULL;
    GVariant *r = g_dbus_connection_call_sync(bus, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
                                              "org.freedesktop.portal.Background", "RequestBackground",
                                              g_variant_new("(sa{sv})", "", &opts), G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE,
                                              5000, NULL, &err);
    g_object_unref(bus);
    if (!r) {
        fprintf(stderr, "photon: background portal: %s\n", err ? err->message : "?");
        if (err) g_error_free(err);
        return 0;
    }
    g_variant_unref(r);
    return 1;
}

// MARK: - GTK helpers

int photon_widget_snapshot_png(GtkWidget *widget, const char *path) {
    if (!widget || !gtk_widget_get_realized(widget)) return 0;
    // Finish pending size allocation and drawing first (gtk_widget_draw needs an up-to-date allocation).
    for (int i = 0; i < 200 && gtk_events_pending(); i++) gtk_main_iteration_do(FALSE);
    int w = gtk_widget_get_allocated_width(widget), h = gtk_widget_get_allocated_height(widget);
    if (w <= 0 || h <= 0) return 0;
    cairo_surface_t *s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    cairo_t *cr = cairo_create(s);
    // The window background first (a toplevel draws it in its own draw handler, but CSD/transparent visuals may not).
    GtkStyleContext *sc = gtk_widget_get_style_context(widget);
    gtk_render_background(sc, cr, 0, 0, w, h);
    gtk_widget_draw(widget, cr);
    cairo_destroy(cr);
    int ok = cairo_surface_write_to_png(s, path) == CAIRO_STATUS_SUCCESS;
    cairo_surface_destroy(s);
    return ok;
}

void photon_css_apply(const char *css) {
    GtkCssProvider *p = gtk_css_provider_new();
    gtk_css_provider_load_from_data(p, css, -1, NULL);
    GdkScreen *screen = gdk_screen_get_default();
    if (screen) gtk_style_context_add_provider_for_screen(screen, GTK_STYLE_PROVIDER(p), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(p);
}

GtkWidget *photon_dialog_new(GtkWindow *parent, const char *title, const char *ok_label) {
    GtkWidget *d = gtk_dialog_new();
    gtk_window_set_title(GTK_WINDOW(d), title);
    if (parent) gtk_window_set_transient_for(GTK_WINDOW(d), parent);
    gtk_window_set_modal(GTK_WINDOW(d), TRUE);
    gtk_dialog_add_button(GTK_DIALOG(d), "Cancel", 0);
    gtk_dialog_add_button(GTK_DIALOG(d), ok_label ? ok_label : "OK", 1);
    gtk_dialog_set_default_response(GTK_DIALOG(d), 1);
    return d;
}

void photon_widget_activate_default(GtkWidget *widget) {
    GtkWidget *top = gtk_widget_get_toplevel(widget);
    if (GTK_IS_WINDOW(top)) gtk_window_activate_default(GTK_WINDOW(top));
}
