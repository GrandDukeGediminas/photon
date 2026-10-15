#ifndef PHOTON_APP_H
#define PHOTON_APP_H
// The Linux app's C side (docs/linux-port.md §6.1): the status icon as a StatusNotifierItem (org.kde.StatusNotifierItem
// on the session bus, registered with org.kde.StatusNotifierWatcher) with its menu exported over com.canonical.dbusmenu,
// and a few GTK helpers Swift cannot express (macros, variadic calls, widget snapshots).
//
// Everything runs on the GLib main loop of the thread that called gtk_init (the app's main thread).

#include <gtk/gtk.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Status icon

typedef struct photon_tray photon_tray;

enum {
    PHOTON_TRAY_ACTIVATE = 0,          // primary click on the icon (SNI Activate)
    PHOTON_TRAY_SECONDARY = 1,         // middle click (SecondaryActivate)
    PHOTON_TRAY_MENU_ITEM = 2,         // a menu item was clicked (item = its id)
    PHOTON_TRAY_MENU_OPENING = 3,      // the host is about to show the menu (AboutToShow on the root)
    PHOTON_TRAY_REGISTERED = 4,        // the watcher accepted the item (item = 1) or no watcher is running (item = 0)
    PHOTON_TRAY_CONTEXT_MENU = 5,      // ContextMenu(x, y): hosts without dbusmenu support (item = x << 16 | y)
};

typedef void (*photon_tray_cb)(void *context, int event, int item);

/// One menu entry. `parent` 0 is the root; an entry with children is a submenu.
typedef struct {
    int id;              // > 0, unique
    int parent;          // 0 or the id of a submenu entry
    const char *label;   // mnemonic underscores are literal ("__" for "_")
    int separator;       // 1: a separator (label ignored)
    int enabled;
    int toggle;          // 0 none, 1 checkmark
    int checked;
} photon_tray_item;

/// Owns `org.kde.StatusNotifierItem-<pid>-<n>`, exports /StatusNotifierItem and /MenuBar, and registers with the watcher
/// (again whenever a watcher appears). `icon_name` is a theme icon; `icon_png` (may be NULL) a file whose pixels are
/// also sent as IconPixmap for hosts that cannot see the theme (Flatpak, missing icon).
photon_tray *photon_tray_new(const char *id, const char *title, const char *icon_name, const char *icon_png, photon_tray_cb cb,
                             void *context);
/// Replaces the menu (LayoutUpdated is emitted with a new revision).
void photon_tray_set_menu(photon_tray *t, const photon_tray_item *items, int count);
void photon_tray_set_tooltip(photon_tray *t, const char *title, const char *text);
/// "Active", "Passive" or "NeedsAttention".
void photon_tray_set_status(photon_tray *t, const char *status);
/// 1 when a watcher accepted the item.
int photon_tray_registered(photon_tray *t);
/// The bus name the item owns (for tests).
const char *photon_tray_bus_name(photon_tray *t);
void photon_tray_free(photon_tray *t);

// MARK: - Portals

/// org.freedesktop.portal.Background.RequestBackground: asks to run in the background and, with `autostart`, to be
/// started at login with `argv` (NULL-terminated). The Flatpak build's "Start at login". 1 when the request was sent.
int photon_portal_request_background(int autostart, const char *const *argv, const char *reason);

// MARK: - Single instance

/// Called on the main loop when a second launch activates this instance: its arguments (after `app`) and its
/// XDG_ACTIVATION_TOKEN / DESKTOP_STARTUP_ID ("" when none).
typedef void (*photon_activate_cb)(void *context, const char *const *args, int n, const char *token);

/// Asks the session bus for `name` (RequestName, DO_NOT_QUEUE). 1: this is the first instance, `path` now exports
/// io.github.photon2.Photon.Activate(as, s); 0: another process owns the name; -1: no session bus (no guard).
int photon_instance_claim(const char *name, const char *path, photon_activate_cb cb, void *context);
/// Calls Activate on the instance that owns `name`. 1 when it answered.
int photon_instance_activate(const char *name, const char *path, const char *const *args, int n, const char *token);

// MARK: - GTK helpers

/// Renders a widget (a window's content) into a PNG through gtk_widget_draw, on any GDK backend. 0 on failure.
int photon_widget_snapshot_png(GtkWidget *widget, const char *path);
/// A CSS provider for the whole screen (the app's small stylesheet).
void photon_css_apply(const char *css);
/// gtk_dialog_new_with_buttons without the variadic call: a modal dialog with OK/Cancel (response 1 / 0).
GtkWidget *photon_dialog_new(GtkWindow *parent, const char *title, const char *ok_label);
/// Sends a key press + release to a widget's window (self-test driving).
void photon_widget_activate_default(GtkWidget *widget);

#ifdef __cplusplus
}
#endif
#endif
