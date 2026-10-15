#!/usr/bin/env python3
"""A StatusNotifierWatcher + host for the app check (docs/linux-port.md §6.1), standing in for a panel's tray.

    fake_sni_watcher.py <out.json> [seconds]

Owns org.kde.StatusNotifierWatcher on the session bus. When an item registers it reads the item the way a tray host
does: the org.kde.StatusNotifierItem properties (Id, Title, Status, IconName, IconPixmap sizes, ToolTip, Menu) and the
menu through com.canonical.dbusmenu (Version, GetLayout of the whole tree, AboutToShow). Then it clicks the item whose
label is "Pause" (Event "clicked"), reads Status again (the app reports Passive while paused), clicks the same id again
(now "Resume") and reads Status once more. Everything it saw goes to <out.json>.
"""
import json
import sys
import time

from gi.repository import Gio, GLib

WATCHER_XML = """
<node>
  <interface name="org.kde.StatusNotifierWatcher">
    <method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
    <method name="RegisterStatusNotifierHost"><arg type="s" direction="in"/></method>
    <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
    <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
    <property name="ProtocolVersion" type="i" access="read"/>
    <signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
  </interface>
</node>"""

out_path = sys.argv[1]
seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 120
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
items = []
report = {"registered": [], "checks": []}
loop = GLib.MainLoop()


def save():
    with open(out_path, "w") as f:
        json.dump(report, f, indent=1, ensure_ascii=False)


def prop(name, iface, path, key):
    r = bus.call_sync(name, path, "org.freedesktop.DBus.Properties", "Get", GLib.Variant("(ss)", (iface, key)),
                      GLib.VariantType("(v)"), Gio.DBusCallFlags.NONE, 3000, None)
    return r.unpack()[0]


def layout_labels(node, depth=0, acc=None):
    acc = [] if acc is None else acc
    ident, props, children = node
    if ident != 0:
        acc.append({"id": ident, "depth": depth, "label": props.get("label", ""), "type": props.get("type", "standard"),
                    "enabled": props.get("enabled", True), "toggle": props.get("toggle-type", ""),
                    "state": props.get("toggle-state", -1), "submenu": props.get("children-display", "")})
    for c in children:
        layout_labels(c, depth + 1, acc)
    return acc


def inspect(service):
    name, path = (service.split("/", 1)[0], "/" + service.split("/", 1)[1]) if "/" in service else (service, "/StatusNotifierItem")
    sni = "org.kde.StatusNotifierItem"
    info = {"service": service}
    for key in ["Id", "Title", "Status", "Category", "IconName", "ItemIsMenu", "Menu"]:
        info[key] = prop(name, sni, path, key)
    pix = prop(name, sni, path, "IconPixmap")
    info["IconPixmap"] = [[w, h, len(data)] for (w, h, data) in pix]
    tip = prop(name, sni, path, "ToolTip")
    info["ToolTip"] = {"title": tip[2], "text": tip[3]}
    menu = info["Menu"]
    dm = "com.canonical.dbusmenu"
    info["MenuVersion"] = prop(name, dm, menu, "Version")
    bus.call_sync(name, menu, dm, "AboutToShow", GLib.Variant("(i)", (0,)), None, Gio.DBusCallFlags.NONE, 3000, None)
    rev, layout = bus.call_sync(name, menu, dm, "GetLayout", GLib.Variant("(iias)", (0, -1, [])), None,
                                Gio.DBusCallFlags.NONE, 3000, None).unpack()
    info["revision"] = rev
    info["menu"] = layout_labels(layout)
    pause = next((e for e in info["menu"] if e["label"] in ("Pause", "Resume")), None)
    if pause:
        def click():
            bus.call_sync(name, menu, dm, "Event", GLib.Variant("(isvu)", (pause["id"], "clicked", GLib.Variant("i", 0), 0)),
                          None, Gio.DBusCallFlags.NONE, 3000, None)
        click()
        time.sleep(0.6)
        ctx = GLib.MainContext.default()
        while ctx.pending():
            ctx.iteration(False)
        info["status_after_pause_click"] = prop(name, sni, path, "Status")
        _, layout2 = bus.call_sync(name, menu, dm, "GetLayout", GLib.Variant("(iias)", (0, -1, [])), None,
                                   Gio.DBusCallFlags.NONE, 3000, None).unpack()
        info["label_after_pause_click"] = next((e["label"] for e in layout_labels(layout2) if e["id"] == pause["id"]), None)
        click()
        time.sleep(0.6)
        info["status_after_second_click"] = prop(name, sni, path, "Status")
    report["registered"].append(info)
    save()
    print("fake watcher: inspected", service, flush=True)
    return False


def call(conn, sender, path, iface, method, params, invocation):
    if method == "RegisterStatusNotifierItem":
        service = params.unpack()[0]
        if not service.startswith(":") and "/" not in service:
            service = service  # a well-known name, as photon registers
        items.append(service)
        invocation.return_value(None)
        conn.emit_signal(None, "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher", "StatusNotifierItemRegistered",
                         GLib.Variant("(s)", (service,)))
        print("fake watcher: registered", service, flush=True)
        GLib.timeout_add(1500, lambda: inspect(service))
    else:
        invocation.return_value(None)


def get(conn, sender, path, iface, prop_name):
    if prop_name == "RegisteredStatusNotifierItems":
        return GLib.Variant("as", items)
    if prop_name == "IsStatusNotifierHostRegistered":
        return GLib.Variant("b", True)
    if prop_name == "ProtocolVersion":
        return GLib.Variant("i", 0)
    return None


node = Gio.DBusNodeInfo.new_for_xml(WATCHER_XML)
bus.register_object("/StatusNotifierWatcher", node.interfaces[0], call, get, None)
Gio.bus_own_name_on_connection(bus, "org.kde.StatusNotifierWatcher", Gio.BusNameOwnerFlags.NONE, None, None)
save()
GLib.timeout_add(int(seconds * 1000), loop.quit)
loop.run()
