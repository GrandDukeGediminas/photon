// photon2 Live Wallpaper: the GNOME side of photon-linux's GNOME host (docs/linux-port.md §5.2).
//
// Mutter has no layer-shell, so photon-linux (`desktop --backend gnome`) draws each output into a plain xdg_toplevel
// with app_id io.github.photon2.Photon.Background and the title "photon2 background <connector>", or for a split
// region of the monitor (docs/re/09 §8.3) "photon2 background <connector> <x>,<y>,<w>,<h>" (logical pixels from the
// monitor's top-left; one window per region, each a wallpaper of its own). This extension:
//
// - finds those windows, keeps them minimized (no input, no focus, not painted where they are), on every workspace and
//   out of the overview, the window switcher and the dash;
// - puts a Clutter.Clone of the window's actor inside every background actor of its monitor (the desktop, the
//   overview's workspaces, the lock screen), above GNOME's own picture, over the whole actor or the region's part of
//   it, so each frame photon presents (Vulkan swapchain or wl_shm) is drawn by the compositor without another copy;
// - exports io.github.photon2.Shell (/io/github/photon2/Shell, io.github.photon2.Shell1) on the session bus: GetState
//   and StateChanged give Mutter's windows as JSON (focus, maximized, fullscreen, minimized, monitor, workspace, pid,
//   app id) for photon's playback rules; PointerChanged gives the cursor and the left button on the desktop.
//
// When the extension is disabled the host loses the bus name and exits; GNOME's own background shows again.
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Background from 'resource:///org/gnome/shell/ui/background.js';
import * as Workspace from 'resource:///org/gnome/shell/ui/workspace.js';
import * as WorkspaceThumbnail from 'resource:///org/gnome/shell/ui/workspaceThumbnail.js';

const APP_ID = 'io.github.photon2.Photon.Background';
const TITLE_PREFIX = 'photon2 background ';
const BUS_NAME = 'io.github.photon2.Shell';
const OBJECT_PATH = '/io/github/photon2/Shell';
const STATE_VERSION = 1;
const IFACE = `<node>
  <interface name="io.github.photon2.Shell1">
    <method name="GetState"><arg type="s" name="json" direction="out"/></method>
    <signal name="StateChanged"><arg type="s" name="json"/></signal>
    <signal name="PointerChanged">
      <arg type="d" name="x"/><arg type="d" name="y"/><arg type="b" name="desktop"/><arg type="b" name="pressed"/>
    </signal>
    <property name="Version" type="u" access="read"/>
  </interface>
</node>`;

export function isRenderer(window) {
    if (!window)
        return false;
    return window.get_wm_class?.() === APP_ID && (window.get_title?.() ?? '').startsWith(TITLE_PREFIX);
}

/// "photon2 background DP-1" → {connector: "DP-1", region: null}; "… DP-1 0,0,960,1080" → region {x, y, width, height}.
export function parseTitle(title) {
    const rest = title.slice(TITLE_PREFIX.length);
    const m = rest.match(/^(.*) (\d+),(\d+),(\d+),(\d+)$/);
    if (!m)
        return {connector: rest, region: null};
    const [x, y, width, height] = m.slice(2).map(Number);
    return {connector: m[1], region: width > 0 && height > 0 ? {x, y, width, height} : null};
}

function isMaximized(window) {
    if (typeof window.is_maximized === 'function')
        return window.is_maximized(); // GNOME 49
    return window.get_maximized() === Meta.MaximizeFlags.BOTH;
}

export default class Photon2Extension extends Extension {
    enable() {
        this._renderers = new Map();     // MetaWindow → {monitor, connector, region}
        this._connectors = new Map();    // monitor index → connector named by a renderer's title
        this._clones = new Set();        // {actor, monitor, clones: Map(MetaWindow → Clutter.Clone)}
        this._windowSignals = new Map(); // MetaWindow → [signal ids]
        this._signals = [];
        this._patches = [];
        this._lastState = '';
        this._stateIdle = 0;
        this._pointer = {x: NaN, y: NaN, desktop: false, pressed: false};

        this._patchShell();

        const display = global.display;
        this._connect(display, 'window-created', (_d, w) => this._watchWindow(w));
        for (const s of ['notify::focus-window', 'restacked', 'window-entered-monitor', 'window-left-monitor', 'in-fullscreen-changed'])
            this._connect(display, s, () => this._queueState());
        this._connect(global.workspace_manager, 'active-workspace-changed', () => this._queueState());
        this._connect(Main.layoutManager, 'monitors-changed', () => this._monitorsChanged());
        this._connect(global.stage, 'captured-event', (_s, event) => this._capturedEvent(event));
        for (const w of display.list_all_windows())
            this._watchWindow(w);

        this._service = {
            GetState: () => this._state(),
            get Version() {
                return STATE_VERSION;
            },
        };
        this._dbus = Gio.DBusExportedObject.wrapJSObject(IFACE, this._service);
        this._dbus.export(Gio.DBus.session, OBJECT_PATH);
        this._nameId = Gio.bus_own_name_on_connection(Gio.DBus.session, BUS_NAME, Gio.BusNameOwnerFlags.NONE, null, null);

        // Window states can change without a signal this extension follows (e.g. a client resizing itself).
        this._timer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1000, () => {
            this._queueState();
            return GLib.SOURCE_CONTINUE;
        });
        this._pointerTimer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 33, () => {
            this._pollPointer();
            return GLib.SOURCE_CONTINUE;
        });

        // Rebuild the desktop backgrounds so they get their clones.
        Main.layoutManager._updateBackgrounds();
    }

    disable() {
        GLib.source_remove(this._timer);
        GLib.source_remove(this._pointerTimer);
        if (this._stateIdle)
            GLib.source_remove(this._stateIdle);
        Gio.bus_unown_name(this._nameId);
        this._dbus.unexport();
        this._dbus = null;
        this._service = null;
        for (const [obj, id] of this._signals)
            obj.disconnect(id);
        this._signals = [];
        for (const [w, ids] of this._windowSignals)
            ids.forEach(id => w.disconnect(id));
        this._windowSignals.clear();
        for (const [obj, name, original] of this._patches.reverse())
            obj[name] = original;
        this._patches = [];
        for (const entry of [...this._clones]) {
            for (const clone of entry.clones.values())
                clone.destroy();
            entry.clones.clear();
        }
        this._clones.clear();
        this._renderers.clear();
        this._connectors.clear();
        Main.layoutManager._updateBackgrounds();
    }

    _connect(obj, signal, fn) {
        this._signals.push([obj, obj.connect(signal, fn)]);
    }

    _patch(obj, name, make) {
        const original = obj[name];
        this._patches.push([obj, name, original]);
        obj[name] = make(original);
    }

    /// The background windows stay out of the overview, the thumbnails, the window switcher and the dash; every
    /// background actor (desktop, overview workspaces, lock screen) gets a clone child.
    _patchShell() {
        const ext = this;
        this._patch(Background.BackgroundManager.prototype, '_createBackgroundActor', original => function () {
            const actor = original.call(this);
            ext._addClone(actor, this._monitorIndex);
            return actor;
        });
        this._patch(Workspace.Workspace.prototype, '_isOverviewWindow', original => function (window) {
            return !isRenderer(window) && original.call(this, window);
        });
        this._patch(WorkspaceThumbnail.WorkspaceThumbnail.prototype, '_isOverviewWindow', original => function (actor) {
            return !isRenderer(actor.get_meta_window?.()) && original.call(this, actor);
        });
        this._patch(Meta.Display.prototype, 'get_tab_list', original => function (...args) {
            return original.apply(this, args).filter(w => !isRenderer(w));
        });
        this._patch(Shell.App.prototype, 'get_windows', original => function () {
            return original.call(this).filter(w => !isRenderer(w));
        });
        this._patch(Shell.AppSystem.prototype, 'get_running', original => function () {
            return original.call(this).filter(app => app.get_windows().length > 0);
        });
    }

    // MARK: Background windows

    _watchWindow(window) {
        if (this._windowSignals.has(window))
            return;
        const queue = () => this._queueState();
        const ids = ['notify::minimized', 'notify::maximized-horizontally', 'notify::maximized-vertically', 'notify::fullscreen',
            'position-changed', 'size-changed', 'workspace-changed'].map(s => window.connect(s, queue));
        // app_id and title can arrive after the window exists.
        ids.push(window.connect('notify::title', () => this._checkRenderer(window)));
        ids.push(window.connect('notify::wm-class', () => this._checkRenderer(window)));
        ids.push(window.connect('notify::minimized', () => {
            if (isRenderer(window) && !window.minimized)
                window.minimize();
        }));
        ids.push(window.connect('unmanaged', () => this._unwatchWindow(window)));
        this._windowSignals.set(window, ids);
        this._checkRenderer(window);
        this._queueState();
    }

    _unwatchWindow(window) {
        this._windowSignals.get(window)?.forEach(id => window.disconnect(id));
        this._windowSignals.delete(window);
        const info = this._renderers.get(window);
        if (info) {
            this._renderers.delete(window);
            this._updateClones(info.monitor);
        }
        this._queueState();
    }

    _checkRenderer(window) {
        if (!isRenderer(window) || this._renderers.has(window))
            return;
        const {connector, region} = parseTitle(window.get_title());
        let monitor = global.backend.get_monitor_manager().get_monitor_for_connector(connector);
        if (monitor < 0)
            monitor = window.get_monitor();
        this._connectors.set(monitor, connector);
        // On its monitor (its scale is that monitor's), on every workspace, below everything, minimized: the window
        // itself takes no input and is not drawn; the clones show its frames.
        if (window.get_monitor() !== monitor)
            window.move_to_monitor(monitor);
        window.stick();
        window.make_below?.();
        if (!window.minimized)
            window.minimize();
        // A whole-monitor renderer replaces the monitor's earlier ones; regions sit side by side.
        if (!region) {
            for (const [w, info] of this._renderers) {
                if (info.monitor === monitor && !info.region)
                    this._renderers.delete(w);
            }
        }
        this._renderers.set(window, {monitor, connector, region});
        this._updateClones(monitor);
        // The actor may only exist after the first frame.
        GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
            this._updateClones(monitor);
            return GLib.SOURCE_REMOVE;
        });
        this._queueState();
    }

    _monitorsChanged() {
        // Monitor indices changed: map the renderers again from their connectors.
        const windows = [...this._renderers.keys()];
        this._renderers.clear();
        this._connectors.clear();
        windows.forEach(w => this._checkRenderer(w));
        this._queueState();
    }

    _addClone(actor, monitor) {
        const entry = {actor, monitor, clones: new Map()};
        this._clones.add(entry);
        actor.connect('destroy', () => {
            entry.clones.clear();
            this._clones.delete(entry);
        });
        // Region clones follow the background actor's size (the overview scales its workspaces' backgrounds).
        actor.connect('notify::size', () => this._updateClone(entry));
        this._updateClone(entry);
    }

    /// One clone per renderer of the entry's monitor: over the whole background actor, or at its region's part of it.
    _updateClone(entry) {
        const mine = [...this._renderers].filter(([, info]) => info.monitor === entry.monitor);
        for (const [w, clone] of entry.clones) {
            if (!mine.some(([m]) => m === w)) {
                clone.destroy();
                entry.clones.delete(w);
            }
        }
        const g = global.display.get_monitor_geometry(entry.monitor);
        for (const [w, info] of mine) {
            let clone = entry.clones.get(w);
            if (!clone) {
                clone = new Clutter.Clone({reactive: false});
                if (!info.region)
                    clone.add_constraint(new Clutter.BindConstraint({source: entry.actor, coordinate: Clutter.BindCoordinate.SIZE}));
                entry.actor.add_child(clone);
                entry.clones.set(w, clone);
            }
            if (info.region && g.width > 0 && g.height > 0) {
                const kx = entry.actor.width / g.width, ky = entry.actor.height / g.height;
                clone.set_position(info.region.x * kx, info.region.y * ky);
                clone.set_size(info.region.width * kx, info.region.height * ky);
            }
            const source = w.get_compositor_private() ?? null;
            if (clone.source !== source)
                clone.source = source;
            clone.visible = source !== null;
        }
    }

    _updateClones(monitor) {
        for (const entry of this._clones) {
            if (entry.monitor === monitor)
                this._updateClone(entry);
        }
    }

    // MARK: State for the playback rules

    _queueState() {
        if (this._stateIdle || !this._dbus)
            return;
        this._stateIdle = GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
            this._stateIdle = 0;
            const json = this._state();
            if (json !== this._lastState) {
                this._lastState = json;
                this._dbus?.emit_signal('StateChanged', new GLib.Variant('(s)', [json]));
            }
            return GLib.SOURCE_REMOVE;
        });
    }

    _state() {
        const display = global.display;
        const workspace = global.workspace_manager.get_active_workspace();
        const focus = display.focus_window;
        const monitors = [];
        for (let i = 0; i < display.get_n_monitors(); i++) {
            const g = display.get_monitor_geometry(i);
            monitors.push({index: i, connector: this._connectors.get(i) ?? '', x: g.x, y: g.y, width: g.width, height: g.height,
                scale: display.get_monitor_scale(i)});
        }
        const windows = [];
        for (const w of display.list_all_windows()) {
            if (isRenderer(w) || w.is_override_redirect())
                continue;
            const r = w.get_frame_rect();
            const type = w.get_window_type();
            windows.push({
                id: Number(w.get_id()), title: w.get_title() ?? '', appId: w.get_wm_class() ?? '',
                sandboxedAppId: w.get_sandboxed_app_id?.() ?? '', pid: w.get_pid(),
                x: r.x, y: r.y, width: r.width, height: r.height, monitor: w.get_monitor(),
                active: w === focus, minimized: w.minimized, maximized: isMaximized(w), fullscreen: w.is_fullscreen(),
                onWorkspace: w.is_on_all_workspaces() || w.located_on_workspace(workspace),
                desktop: type === Meta.WindowType.DESKTOP || type === Meta.WindowType.DOCK,
            });
        }
        const renderers = [...this._renderers].map(([w, info]) => ({monitor: info.monitor, connector: info.connector,
            region: info.region, title: w.get_title()}));
        return JSON.stringify({version: STATE_VERSION, monitors, windows, renderers});
    }

    // MARK: Pointer

    _isDesktopActor(actor) {
        if (!actor || Main.overview.visible)
            return false;
        if (actor === global.stage)
            return true;
        const group = Main.layoutManager._backgroundGroup;
        if (actor === group || group.contains(actor))
            return true;
        const window = actor.get_meta_window?.();
        return window?.get_window_type() === Meta.WindowType.DESKTOP;
    }

    _pollPointer() {
        if (this._renderers.size === 0)
            return;
        const [x, y] = global.get_pointer();
        if (x === this._pointer.x && y === this._pointer.y)
            return;
        this._pointer.x = x;
        this._pointer.y = y;
        this._pointer.desktop = this._isDesktopActor(global.stage.get_actor_at_pos(Clutter.PickMode.REACTIVE, x, y));
        this._emitPointer();
    }

    _capturedEvent(event) {
        const type = event.type();
        if (this._renderers.size > 0 && event.get_button?.() === 1) {
            if (type === Clutter.EventType.BUTTON_PRESS) {
                const actor = global.stage.get_event_actor ? global.stage.get_event_actor(event) : event.get_source();
                if (this._isDesktopActor(actor)) {
                    this._pointer.pressed = true;
                    this._emitPointer();
                }
            } else if (type === Clutter.EventType.BUTTON_RELEASE && this._pointer.pressed) {
                this._pointer.pressed = false;
                this._emitPointer();
            }
        }
        return Clutter.EVENT_PROPAGATE;
    }

    _emitPointer() {
        const p = this._pointer;
        this._dbus?.emit_signal('PointerChanged', new GLib.Variant('(ddbb)', [p.x, p.y, p.desktop, p.pressed]));
    }
}
