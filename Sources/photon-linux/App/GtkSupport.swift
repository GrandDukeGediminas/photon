#if os(Linux)
import CGtk3
import CPhotonApp
import Foundation

// Small Swift layer over GTK 3's C API for the app's windows (docs/linux-port.md §6.1): pointer casts in place of the
// GTK_WINDOW()-style macros, closures for GObject signals, main-thread hops, and the Foundation run loop pumped from the
// GLib main loop (AppState's debounced reloads and the playlist timer are Foundation timers and main-queue blocks).

typealias Widget = UnsafeMutablePointer<GtkWidget>

/// `GTK_WINDOW(w)` and friends: the same object seen as another GTK type.
@inline(__always) func G<T, U>(_ p: UnsafeMutablePointer<U>?) -> UnsafeMutablePointer<T>! {
    p.map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: T.self) }
}

/// The same for GTK interfaces and opaque types (GtkFileChooser, GtkColorChooser, GdkPixbuf, GdkDisplay), which Swift
/// imports as OpaquePointer.
@inline(__always) func G<U>(_ p: UnsafeMutablePointer<U>?) -> OpaquePointer! { p.map { OpaquePointer($0) } }

@inline(__always) func raw<U>(_ p: UnsafeMutablePointer<U>?) -> gpointer? { p.map { UnsafeMutableRawPointer($0) } }
@inline(__always) func raw(_ p: OpaquePointer?) -> gpointer? { p.map { UnsafeMutableRawPointer($0) } }

// MARK: - Signals

private final class Handler0 { let fn: () -> Void; init(_ f: @escaping () -> Void) { fn = f } }
private final class Handler1 { let fn: (gpointer?) -> Void; init(_ f: @escaping (gpointer?) -> Void) { fn = f } }
private final class HandlerBool { let fn: () -> Bool; init(_ f: @escaping () -> Bool) { fn = f } }

private let release0: GClosureNotify = { data, _ in if let data { Unmanaged<Handler0>.fromOpaque(data).release() } }
private let release1: GClosureNotify = { data, _ in if let data { Unmanaged<Handler1>.fromOpaque(data).release() } }
private let releaseBool: GClosureNotify = { data, _ in if let data { Unmanaged<HandlerBool>.fromOpaque(data).release() } }

private typealias Thunk2 = @convention(c) (gpointer?, gpointer?) -> Void
private typealias Thunk3 = @convention(c) (gpointer?, gpointer?, gpointer?) -> Void
private typealias Thunk3Bool = @convention(c) (gpointer?, gpointer?, gpointer?) -> gboolean

private let thunk2: Thunk2 = { _, data in Unmanaged<Handler0>.fromOpaque(data!).takeUnretainedValue().fn() }
private let thunk3: Thunk3 = { _, arg, data in Unmanaged<Handler1>.fromOpaque(data!).takeUnretainedValue().fn(arg) }
private let thunk3Bool: Thunk3Bool = { _, _, data in Unmanaged<HandlerBool>.fromOpaque(data!).takeUnretainedValue().fn() ? 1 : 0 }

/// A signal whose handler takes only the instance (`clicked`, `changed`, `value-changed`, `toggled`, …).
@discardableResult
func on<U>(_ object: UnsafeMutablePointer<U>?, _ signal: String, _ fn: @escaping () -> Void) -> gulong {
    let h = Unmanaged.passRetained(Handler0(fn)).toOpaque()
    return g_signal_connect_data(raw(object), signal, unsafeBitCast(thunk2, to: GCallback.self), h, release0, GConnectFlags(rawValue: 0))
}

/// A signal with one pointer-sized argument (`child-activated`, `response`, `notify::…`).
@discardableResult
func on1<U>(_ object: UnsafeMutablePointer<U>?, _ signal: String, _ fn: @escaping (gpointer?) -> Void) -> gulong {
    let h = Unmanaged.passRetained(Handler1(fn)).toOpaque()
    return g_signal_connect_data(raw(object), signal, unsafeBitCast(thunk3, to: GCallback.self), h, release1, GConnectFlags(rawValue: 0))
}

@discardableResult
func on1(_ object: OpaquePointer?, _ signal: String, _ fn: @escaping (gpointer?) -> Void) -> gulong {
    let h = Unmanaged.passRetained(Handler1(fn)).toOpaque()
    return g_signal_connect_data(raw(object), signal, unsafeBitCast(thunk3, to: GCallback.self), h, release1, GConnectFlags(rawValue: 0))
}

/// An event signal returning gboolean (`delete-event`, `button-press-event`): true stops further handling.
@discardableResult
func onEvent<U>(_ object: UnsafeMutablePointer<U>?, _ signal: String, _ fn: @escaping () -> Bool) -> gulong {
    let h = Unmanaged.passRetained(HandlerBool(fn)).toOpaque()
    return g_signal_connect_data(raw(object), signal, unsafeBitCast(thunk3Bool, to: GCallback.self), h, releaseBool, GConnectFlags(rawValue: 0))
}

/// Blocks a widget's handlers while the app sets its value (no feedback into the model).
func quietly<U>(_ object: UnsafeMutablePointer<U>?, _ ids: [gulong], _ body: () -> Void) {
    for id in ids { g_signal_handler_block(raw(object), id) }
    body()
    for id in ids { g_signal_handler_unblock(raw(object), id) }
}

// MARK: - Main loop

private final class IdleBox { let fn: () -> Void; init(_ f: @escaping () -> Void) { fn = f } }
private final class RepeatBox { let fn: () -> Bool; init(_ f: @escaping () -> Bool) { fn = f } }

/// Runs `fn` on the GTK main thread (from any thread).
func onMain(_ fn: @escaping () -> Void) {
    let box = Unmanaged.passRetained(IdleBox(fn)).toOpaque()
    g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, { data in
        let b = Unmanaged<IdleBox>.fromOpaque(data!).takeRetainedValue()
        b.fn()
        return 0
    }, box, nil)
}

/// Calls `fn` every `ms` milliseconds on the main thread while it returns true.
@discardableResult
func every(_ ms: UInt32, _ fn: @escaping () -> Bool) -> guint {
    let box = Unmanaged.passRetained(RepeatBox(fn)).toOpaque()
    return g_timeout_add_full(G_PRIORITY_DEFAULT, ms, { data in
        Unmanaged<RepeatBox>.fromOpaque(data!).takeUnretainedValue().fn() ? 1 : 0
    }, box, { data in Unmanaged<RepeatBox>.fromOpaque(data!).release() })
}

/// Once after `ms` milliseconds.
func after(_ ms: UInt32, _ fn: @escaping () -> Void) { every(ms) { fn(); return false } }

/// Coalesces bursts of model changes into one call on the next idle.
final class Debouncer {
    private var pending = false
    private let delay: UInt32
    private let fn: () -> Void
    init(ms: UInt32 = 0, _ fn: @escaping () -> Void) { delay = ms; self.fn = fn }
    func poke() {
        guard !pending else { return }
        pending = true
        let run = { [weak self] in
            guard let self else { return }
            self.pending = false
            self.fn()
        }
        if delay == 0 { onMain(run) } else { after(delay, run) }
    }
}

enum FoundationPump {
    /// Foundation's main run loop (timers, `DispatchQueue.main`) serviced from the GLib loop every 15 ms.
    static func start() {
        every(15) {
            // swift-corelibs' run loop can block in an unbounded ppoll on its wakeup and main-queue descriptors (seen
            // with a past limit date), which hung the app with its GLib loop. An empty main-queue block makes the
            // main-queue eventfd readable, so the pass returns after handling it (run(mode:before:) returns after a
            // handled source).
            DispatchQueue.main.async {}
            _ = RunLoop.main.run(mode: .default, before: Date())
            return true
        }
    }
}

// MARK: - Widget helpers

func label(_ text: String, css: String? = nil, wrap: Bool = false, xalign: Float = 0) -> Widget {
    let l = gtk_label_new(text)!
    gtk_label_set_xalign(G(l), xalign)
    if wrap {
        gtk_label_set_line_wrap(G(l), 1)
        gtk_label_set_max_width_chars(G(l), 60)
    }
    if let css { addClass(l, css) }
    return l
}

func addClass(_ w: Widget?, _ cls: String) { gtk_style_context_add_class(gtk_widget_get_style_context(w), cls) }
func removeClass(_ w: Widget?, _ cls: String) { gtk_style_context_remove_class(gtk_widget_get_style_context(w), cls) }

func box(_ vertical: Bool, spacing: Int32 = 6) -> Widget {
    gtk_box_new(vertical ? GTK_ORIENTATION_VERTICAL : GTK_ORIENTATION_HORIZONTAL, spacing)!
}

func pack(_ b: Widget?, _ child: Widget?, expand: Bool = false, fill: Bool = true, padding: UInt32 = 0) {
    gtk_box_pack_start(G(b), child, expand ? 1 : 0, fill ? 1 : 0, padding)
}

func packEnd(_ b: Widget?, _ child: Widget?, expand: Bool = false) { gtk_box_pack_end(G(b), child, expand ? 1 : 0, 1, 0) }

func button(_ text: String, _ fn: @escaping () -> Void) -> Widget {
    let b = gtk_button_new_with_label(text)!
    on(b, "clicked", fn)
    return b
}

func margins(_ w: Widget?, _ m: Int32) {
    gtk_widget_set_margin_start(w, m); gtk_widget_set_margin_end(w, m)
    gtk_widget_set_margin_top(w, m); gtk_widget_set_margin_bottom(w, m)
}

func scrolled(_ child: Widget?, h: Bool = false, v: Bool = true) -> Widget {
    let s = gtk_scrolled_window_new(nil, nil)!
    gtk_scrolled_window_set_policy(G(s), h ? GTK_POLICY_AUTOMATIC : GTK_POLICY_NEVER, v ? GTK_POLICY_AUTOMATIC : GTK_POLICY_NEVER)
    gtk_container_add(G(s), child)
    return s
}

func removeChildren(_ container: Widget?) {
    guard let list = gtk_container_get_children(G(container)) else { return }
    var node: UnsafeMutablePointer<GList>? = list
    while let n = node {
        gtk_widget_destroy(G(n.pointee.data?.assumingMemoryBound(to: GtkWidget.self)))
        node = n.pointee.next
    }
    g_list_free(list)
}

/// A text combo with (id, label) entries.
final class Combo {
    let widget: Widget
    private(set) var ids: [String]
    private var handler: gulong = 0

    init(_ entries: [(String, String)], selected: String?, onChange: @escaping (String) -> Void) {
        widget = gtk_combo_box_text_new()!
        ids = entries.map(\.0)
        for (id, text) in entries { gtk_combo_box_text_append(G(widget), id, text) }
        if let selected { _ = gtk_combo_box_set_active_id(G(widget), selected) }
        handler = on(widget, "changed") { [weak self] in
            guard let self, let c = gtk_combo_box_get_active_id(G(self.widget)) else { return }
            onChange(String(cString: c))
        }
    }

    var selected: String? { gtk_combo_box_get_active_id(G(widget)).map { String(cString: $0) } }

    func select(_ id: String) { quietly(widget, [handler]) { _ = gtk_combo_box_set_active_id(G(widget), id) } }

    func replace(_ entries: [(String, String)], selected: String?) {
        quietly(widget, [handler]) {
            gtk_combo_box_text_remove_all(G(widget))
            ids = entries.map(\.0)
            for (id, text) in entries { gtk_combo_box_text_append(G(widget), id, text) }
            if let selected { _ = gtk_combo_box_set_active_id(G(widget), selected) }
        }
    }
}

/// A GtkMenu built from (label, action) entries; nil action = separator, "-" prefix = disabled label.
func popupMenu(_ entries: [(String, (() -> Void)?)], at anchor: Widget?) {
    let menu = gtk_menu_new()!
    for (text, action) in entries {
        let item: Widget
        if text == "---" {
            item = gtk_separator_menu_item_new()
        } else {
            item = gtk_menu_item_new_with_label(text)
            if let action { on(item, "activate", action) } else { gtk_widget_set_sensitive(item, 0) }
        }
        gtk_menu_shell_append(G(menu), item)
    }
    gtk_widget_show_all(menu)
    if let anchor, gtk_widget_get_realized(anchor) != 0 {
        gtk_menu_popup_at_widget(G(menu), anchor, GDK_GRAVITY_SOUTH_WEST, GDK_GRAVITY_NORTH_WEST, nil)
    } else {
        gtk_menu_popup_at_pointer(G(menu), nil)
    }
}

/// Loads an image file scaled to fit `w`×`h` (aspect kept) or cropped to fill it.
enum Pixbufs {
    static func load(_ path: String, width w: Int32, height h: Int32, fill: Bool) -> OpaquePointer? {
        // Decode at about the size needed (preview GIFs and JPEGs are small; large PNGs decode at scale).
        guard let src = gdk_pixbuf_new_from_file_at_scale(path, fill ? w * 2 : w, fill ? h * 2 : h, 1, nil) else { return nil }
        let sw = gdk_pixbuf_get_width(src), sh = gdk_pixbuf_get_height(src)
        guard fill, sw > 0, sh > 0 else { return src }
        let scale = max(Double(w) / Double(sw), Double(h) / Double(sh))
        let tw = max(Int32((Double(sw) * scale).rounded()), w), th = max(Int32((Double(sh) * scale).rounded()), h)
        let scaledPB = gdk_pixbuf_scale_simple(src, tw, th, GDK_INTERP_BILINEAR)
        g_object_unref(raw(src))
        guard let scaledPB else { return nil }
        let out = gdk_pixbuf_new_subpixbuf(scaledPB, (tw - w) / 2, (th - h) / 2, w, h)
        let copy = gdk_pixbuf_copy(out)
        g_object_unref(raw(out))
        g_object_unref(raw(scaledPB))
        return copy
    }
}
#endif
