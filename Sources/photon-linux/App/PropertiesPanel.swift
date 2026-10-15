#if os(Linux)
import CGtk3
import Foundation
import PhotonApp

/// Property rows for a wallpaper (macOS PropertiesView / GeneralPropertiesView / PropertyRow): bool, slider, color,
/// combo, textinput, file / directory, group and text, each shown when its `condition` (JavaScript over
/// `<name>.value`, ConditionEvaluator) holds for the current values.
final class PropertiesPanel {
    let widget: Widget
    let specs: [PropertySpec]
    private let values: () -> [String: Any]
    private let set: (String, Any) -> Void
    /// One row per spec: the row widget and a function that shows the stored value without sending it back.
    private var rows: [(spec: PropertySpec, row: Widget, update: ([String: Any]) -> Void)] = []
    /// The value controls by property id (self-test).
    private(set) var controls: [String: Widget] = [:]

    init(specs: [PropertySpec], values: @escaping () -> [String: Any], set: @escaping (String, Any) -> Void) {
        self.specs = specs
        self.values = values
        self.set = set
        widget = box(true, spacing: 10)
        for spec in specs {
            let (row, update) = makeRow(spec)
            pack(widget, row)
            rows.append((spec, row, update))
        }
        refresh()
    }

    func refresh() {
        let v = values()
        for r in rows { r.update(v) }
        updateVisibility(v)
    }

    func updateVisibility(_ v: [String: Any]? = nil) {
        let evaluator = ConditionEvaluator(values: v ?? values())
        for r in rows {
            let show = evaluator.isVisible(r.spec)
            if show { gtk_widget_show_all(r.row) } else { gtk_widget_hide(r.row) }
        }
    }

    private func change(_ id: String, _ value: Any) {
        set(id, value)
        updateVisibility()
    }

    /// A label whose engine string is missing (no Wallpaper Engine install, e.g. the CI test scenes): the key made
    /// readable, "ui_browse_properties_playback_rate" → "Playback rate". The macOS app shows the key itself then.
    static func readable(_ text: String) -> String {
        guard text.hasPrefix("ui_"), !text.contains(" ") else { return text }
        var t = text
        for prefix in ["ui_browse_properties_alignment_", "ui_browse_properties_", "ui_browse_lut_filter_", "ui_"] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count))
            break
        }
        t = t.replacingOccurrences(of: "_", with: " ")
        if t.hasSuffix("filter none") { return "None" }
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    private func makeRow(_ raw: PropertySpec) -> (Widget, ([String: Any]) -> Void) {
        let spec = PropertySpec(id: raw.id, type: raw.type, label: Self.readable(raw.label), order: raw.order, defaultValue: raw.defaultValue,
                                min: raw.min, max: raw.max, step: raw.step, fraction: raw.fraction, precision: raw.precision,
                                options: raw.options.map { .init(label: Self.readable($0.label), key: $0.key, value: $0.value) },
                                condition: raw.condition)
        let value = { (v: [String: Any]) -> Any in v[spec.id] ?? spec.defaultValue }
        switch spec.type {
        case "bool":
            let check = gtk_check_button_new_with_label(spec.label)!
            controls[spec.id] = check
            let h = on(check, "toggled") { [weak self] in self?.change(spec.id, gtk_toggle_button_get_active(G(check)) != 0) }
            return (check, { v in
                let b = (value(v) as? Bool) ?? ((value(v) as? NSNumber)?.boolValue ?? false)
                quietly(check, [h]) { gtk_toggle_button_set_active(G(check), b ? 1 : 0) }
            })
        case "slider":
            let row = box(true, spacing: 2)
            let top = box(false, spacing: 6)
            pack(top, label(spec.label), expand: true)
            let valueLabel = label("", css: "photon-dim", xalign: 1)
            pack(top, valueLabel)
            pack(row, top)
            let lo = min(spec.min, spec.max), hi = max(spec.min, spec.max)
            let step = spec.fraction ? (spec.step ?? 0) : max(spec.step ?? 1, 1)
            let format = { (x: Double) -> String in spec.fraction ? String(format: "%.\(min(spec.precision, 4))f", x) : "\(Int(x.rounded()))" }
            guard hi > lo else { return (row, { v in gtk_label_set_text(G(valueLabel), format((value(v) as? NSNumber)?.doubleValue ?? spec.min)) }) }
            let scale = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, lo, hi, step > 0 ? step : (hi - lo) / 1000)!
            gtk_scale_set_draw_value(G(scale), 0)
            controls[spec.id] = scale
            pack(row, scale)
            let h = on(scale, "value-changed") { [weak self] in
                let raw = gtk_range_get_value(G(scale))
                // Quantized as on macOS: steps from the minimum; integer sliders round.
                let q = step > 0 ? lo + ((raw - lo) / step).rounded() * step : raw
                let out = spec.fraction ? min(max(q, lo), hi) : q.rounded()
                gtk_label_set_text(G(valueLabel), format(out))
                self?.change(spec.id, out)
            }
            return (row, { v in
                let x = (value(v) as? NSNumber)?.doubleValue ?? (value(v) as? String).flatMap(Double.init) ?? spec.min
                quietly(scale, [h]) { gtk_range_set_value(G(scale), min(max(x, lo), hi)) }
                gtk_label_set_text(G(valueLabel), format(x))
            })
        case "color":
            let row = box(false, spacing: 6)
            pack(row, label(spec.label), expand: true)
            let color = gtk_color_button_new()!
            controls[spec.id] = color
            pack(row, color)
            let h = on(color, "color-set") { [weak self] in
                var rgba = GdkRGBA()
                gtk_color_chooser_get_rgba(G(color), &rgba)
                self?.change(spec.id, [rgba.red, rgba.green, rgba.blue].map { String(format: "%.5f", $0) }.joined(separator: " "))
            }
            return (row, { v in
                // Property colours are "r g b" in 0–1 (some wallpapers use 0–255).
                let parts = "\(value(v))".split(separator: " ").compactMap { Double($0) }
                var rgba = GdkRGBA(red: 1, green: 1, blue: 1, alpha: 1)
                if parts.count >= 3 {
                    let s = parts.prefix(3).contains { $0 > 1 } ? 255.0 : 1.0
                    rgba = GdkRGBA(red: parts[0] / s, green: parts[1] / s, blue: parts[2] / s, alpha: 1)
                }
                quietly(color, [h]) { gtk_color_chooser_set_rgba(G(color), &rgba) }
            })
        case "combo", "combolutfilters":
            let row = box(false, spacing: 6)
            pack(row, label(spec.label), expand: true)
            let combo = Combo(spec.options.map { ($0.key, $0.label) }, selected: nil) { [weak self] key in
                self?.change(spec.id, spec.options.first { $0.key == key }?.value.base ?? key)
            }
            controls[spec.id] = combo.widget
            objc_keep(row, combo)
            pack(row, combo.widget)
            return (row, { v in combo.select("\(value(v))") })
        case "textinput":
            let row = box(true, spacing: 4)
            pack(row, label(spec.label))
            let entry = gtk_entry_new()!
            controls[spec.id] = entry
            pack(row, entry)
            let h = on(entry, "changed") { [weak self] in self?.change(spec.id, String(cString: gtk_entry_get_text(G(entry)))) }
            return (row, { v in
                let s = (value(v) as? String) ?? "\(value(v))"
                if String(cString: gtk_entry_get_text(G(entry))) != s { quietly(entry, [h]) { gtk_entry_set_text(G(entry), s) } }
            })
        case "file", "directory":
            // User file / folder properties: web wallpapers get the path (and folder listings), scenes the file.
            let row = box(false, spacing: 6)
            pack(row, label(spec.label), expand: true)
            let chooser = gtk_file_chooser_button_new(spec.label, spec.type == "file" ? GTK_FILE_CHOOSER_ACTION_OPEN : GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER)!
            controls[spec.id] = chooser
            pack(row, chooser)
            let h = on(chooser, "file-set") { [weak self] in
                guard let f = gtk_file_chooser_get_filename(G(chooser)) else { return }
                self?.change(spec.id, String(cString: f))
                g_free(f)
            }
            return (row, { v in
                if let p = value(v) as? String, !p.isEmpty { quietly(chooser, [h]) { _ = gtk_file_chooser_set_filename(G(chooser), p) } }
            })
        case "group":
            let l = label(spec.label, css: "photon-section")
            return (l, { _ in })
        case "text", "":
            let l = label(spec.label, css: "photon-dim", wrap: true)
            return (l, { _ in })
        default:
            let row = box(false, spacing: 6)
            pack(row, label(spec.label), expand: true)
            pack(row, label("\(spec.type) not supported", css: "photon-dim"))
            return (row, { _ in })
        }
    }

    /// Whether a property's row is shown (its condition holds).
    func isShown(_ id: String) -> Bool {
        rows.first { $0.spec.id == id }.map { gtk_widget_get_visible($0.row) != 0 } ?? false
    }

    /// Sets a property through its control, as a user would (self-test): sliders and checks fire their handlers.
    func setThroughControl(_ id: String, _ value: Any) -> Bool {
        guard let w = controls[id], let spec = specs.first(where: { $0.id == id }) else { return false }
        switch spec.type {
        case "bool": gtk_toggle_button_set_active(G(w), (value as? Bool) == true ? 1 : 0)
        case "slider": gtk_range_set_value(G(w), (value as? NSNumber)?.doubleValue ?? 0)
        case "textinput": gtk_entry_set_text(G(w), "\(value)")
        case "combo", "combolutfilters": _ = gtk_combo_box_set_active_id(G(w), "\(value)")
        default: return false
        }
        return true
    }
}

/// Keeps a Swift helper alive as long as a widget (released with the widget's data).
func objc_keep(_ w: Widget, _ object: AnyObject) {
    let p = Unmanaged.passRetained(object).toOpaque()
    g_object_set_data_full(G(w), "photon-keep-\(UInt(bitPattern: p))", p) { data in
        if let data { Unmanaged<AnyObject>.fromOpaque(data).release() }
    }
}
#endif
