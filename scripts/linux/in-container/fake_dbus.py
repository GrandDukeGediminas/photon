#!/usr/bin/env python3
"""Fake D-Bus services for the phase-4 checks (docs/linux-port.md §7): an MPRIS player on the session bus, and UPower,
logind and a screensaver following a fixed timeline. Run in the container with python3-gi.

    fake_dbus.py mpris <seconds> <art.png>    org.mpris.MediaPlayer2.photontest: Playing "First Song" by "Artist A" (art),
                                              at 2 s "Second Song" by "B1", "B2" (no art change), at 3 s Paused,
                                              at 4 s a seek (Position jumps to 100 s)
    fake_dbus.py system <seconds>             system bus: UPower OnBattery false → true at 1 s → false at 7 s;
                                              logind session Lock at 2 s / Unlock at 3 s, PrepareForSleep(true) at 4 s /
                                              (false) at 5 s; session bus: org.freedesktop.ScreenSaver ActiveChanged
                                              true at 6 s / false at 6.5 s
"""
import sys
import time

from gi.repository import Gio, GLib

MPRIS_XML = """
<node>
  <interface name="org.mpris.MediaPlayer2">
    <property name="Identity" type="s" access="read"/>
    <property name="DesktopEntry" type="s" access="read"/>
  </interface>
  <interface name="org.mpris.MediaPlayer2.Player">
    <property name="PlaybackStatus" type="s" access="read"/>
    <property name="Metadata" type="a{sv}" access="read"/>
    <property name="Position" type="x" access="read"/>
    <property name="Rate" type="d" access="read"/>
  </interface>
</node>"""

SYSTEM_XML = """
<node>
  <interface name="org.freedesktop.UPower"><property name="OnBattery" type="b" access="read"/></interface>
  <interface name="org.freedesktop.login1.Manager">
    <method name="GetSessionByPID"><arg type="u" direction="in"/><arg type="o" direction="out"/></method>
    <method name="GetSession"><arg type="s" direction="in"/><arg type="o" direction="out"/></method>
    <signal name="PrepareForSleep"><arg type="b"/></signal>
  </interface>
  <interface name="org.freedesktop.login1.Session">
    <property name="LockedHint" type="b" access="read"/>
    <signal name="Lock"/><signal name="Unlock"/>
  </interface>
  <interface name="org.freedesktop.ScreenSaver">
    <method name="GetActive"><arg type="b" direction="out"/></method>
    <signal name="ActiveChanged"><arg type="b"/></signal>
  </interface>
</node>"""

SESSION_PATH = "/org/freedesktop/login1/session/_31"


def node(xml, name):
    return Gio.DBusNodeInfo.new_for_xml(xml).lookup_interface(name)


def mpris(seconds, art):
    state = {
        "status": "Playing",
        "meta": {"xesam:title": GLib.Variant("s", "First Song"), "xesam:artist": GLib.Variant("as", ["Artist A"]),
                 "xesam:album": GLib.Variant("s", "Album X"), "xesam:albumArtist": GLib.Variant("as", ["Album Artist"]),
                 "xesam:genre": GLib.Variant("as", ["Rock", "Pop"]), "mpris:length": GLib.Variant("x", 200_000_000),
                 "mpris:artUrl": GLib.Variant("s", "file://" + art)},
        "pos0": 10.0, "t0": time.monotonic(),
    }

    def position():
        p = state["pos0"] + (time.monotonic() - state["t0"] if state["status"] == "Playing" else 0)
        return int(p * 1e6)

    def get_property(conn, sender, path, iface, prop):
        if iface == "org.mpris.MediaPlayer2":
            return GLib.Variant("s", {"Identity": "Photon Test Player", "DesktopEntry": "photontest"}[prop])
        if prop == "PlaybackStatus":
            return GLib.Variant("s", state["status"])
        if prop == "Metadata":
            return GLib.Variant("a{sv}", state["meta"])
        if prop == "Position":
            return GLib.Variant("x", position())
        if prop == "Rate":
            return GLib.Variant("d", 1.0)
        return None

    def on_bus(conn, name):
        for iface in ("org.mpris.MediaPlayer2", "org.mpris.MediaPlayer2.Player"):
            conn.register_object("/org/mpris/MediaPlayer2", node(MPRIS_XML, iface), None, get_property, None)

    Gio.bus_own_name(Gio.BusType.SESSION, "org.mpris.MediaPlayer2.photontest", Gio.BusNameOwnerFlags.NONE, on_bus, None, None)
    loop = GLib.MainLoop()

    def at(t, f):
        GLib.timeout_add(int(t * 1000), lambda: (f(), False)[1])

    def second():
        state["meta"] = dict(state["meta"], **{"xesam:title": GLib.Variant("s", "Second Song"),
                                               "xesam:artist": GLib.Variant("as", ["B1", "B2"])})

    def pause():
        state["pos0"] = position() / 1e6
        state["status"] = "Paused"

    def seek():
        state["pos0"] = 100.0
        state["t0"] = time.monotonic()

    at(2, second)
    at(3, pause)
    at(4, seek)
    at(seconds, loop.quit)
    loop.run()


def system(seconds):
    state = {"battery": False, "locked": False, "saver": False}
    conns = {}

    def get_property(conn, sender, path, iface, prop):
        if prop == "OnBattery":
            return GLib.Variant("b", state["battery"])
        if prop == "LockedHint":
            return GLib.Variant("b", state["locked"])
        return None

    def call(conn, sender, path, iface, method, params, inv):
        if method in ("GetSessionByPID", "GetSession"):
            inv.return_value(GLib.Variant("(o)", (SESSION_PATH,)))
        elif method == "GetActive":
            inv.return_value(GLib.Variant("(b)", (state["saver"],)))

    def on_system(conn, name):
        conns["system"] = conn
        conn.register_object("/org/freedesktop/UPower", node(SYSTEM_XML, "org.freedesktop.UPower"), None, get_property, None)
        conn.register_object("/org/freedesktop/login1", node(SYSTEM_XML, "org.freedesktop.login1.Manager"), call, None, None)
        conn.register_object(SESSION_PATH, node(SYSTEM_XML, "org.freedesktop.login1.Session"), None, get_property, None)

    def on_session(conn, name):
        conns["session"] = conn
        conn.register_object("/org/freedesktop/ScreenSaver", node(SYSTEM_XML, "org.freedesktop.ScreenSaver"), call, None, None)

    sysbus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    sesbus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    Gio.bus_own_name_on_connection(sysbus, "org.freedesktop.UPower", Gio.BusNameOwnerFlags.NONE, None, None)
    Gio.bus_own_name_on_connection(sysbus, "org.freedesktop.login1", Gio.BusNameOwnerFlags.NONE, None, None)
    Gio.bus_own_name_on_connection(sesbus, "org.freedesktop.ScreenSaver", Gio.BusNameOwnerFlags.NONE, None, None)
    on_system(sysbus, None)
    on_session(sesbus, None)

    def changed(conn, path, iface, prop, value):
        conn.emit_signal(None, path, "org.freedesktop.DBus.Properties", "PropertiesChanged",
                         GLib.Variant("(sa{sv}as)", (iface, {prop: GLib.Variant("b", value)}, [])))

    def battery(v):
        state["battery"] = v
        changed(sysbus, "/org/freedesktop/UPower", "org.freedesktop.UPower", "OnBattery", v)

    def lock(v):
        state["locked"] = v
        sysbus.emit_signal(None, SESSION_PATH, "org.freedesktop.login1.Session", "Lock" if v else "Unlock", None)
        changed(sysbus, SESSION_PATH, "org.freedesktop.login1.Session", "LockedHint", v)

    def sleep(v):
        sysbus.emit_signal(None, "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "PrepareForSleep",
                           GLib.Variant("(b)", (v,)))

    def saver(v):
        state["saver"] = v
        sesbus.emit_signal(None, "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver", "ActiveChanged",
                           GLib.Variant("(b)", (v,)))

    loop = GLib.MainLoop()

    def at(t, f, *a):
        GLib.timeout_add(int(t * 1000), lambda: (f(*a), False)[1])

    at(1, battery, True)
    at(2, lock, True)
    at(3, lock, False)
    at(4, sleep, True)
    at(5, sleep, False)
    at(6, saver, True)
    at(6.5, saver, False)
    at(7, battery, False)
    at(seconds, loop.quit)
    loop.run()


if __name__ == "__main__":
    if sys.argv[1] == "mpris":
        mpris(float(sys.argv[2]), sys.argv[3])
    else:
        system(float(sys.argv[2]))
