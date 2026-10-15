import Foundation
import JavaScriptCore
import PhotonCore

/// One wallpaper the app can show: a workshop item or one of the engine's default projects.
package struct WallpaperItem: Identifiable, Hashable {
    package let id: String
    package let directory: URL
    package let title: String
    package let type: String
    package let preview: URL?
    /// Presets name the workshop item they configure.
    package let dependency: String?
    package let tags: [String]

    /// Directory whose project.json declares the properties (the dependency for presets).
    package var baseDirectory: URL {
        guard let dependency else { return directory }
        return directory.deletingLastPathComponent().appendingPathComponent(dependency)
    }

    /// Why this item can't be shown, or nil when photon renders it.
    package var unsupportedReason: String? {
        if let dependency {
            return FileManager.default.fileExists(atPath: baseDirectory.appendingPathComponent("project.json").path)
                ? nil : "Preset for \(dependency), which isn't downloaded"
        }
        switch type {
        case "scene", "video", "web": return nil
        case "", "unknown": return "Unknown wallpaper type"
        default: return "\(type.capitalized) wallpapers aren't supported"
        }
    }

    package static func == (a: WallpaperItem, b: WallpaperItem) -> Bool { a.id == b.id }
    package func hash(into h: inout Hasher) { h.combine(id) }
}

/// A user property from project.json `general.properties`, as shown in the properties panel.
package struct PropertySpec: Identifiable {
    package struct Option: Hashable {
        package let label: String
        package let key: String
        package let value: AnyHashable

        package init(label: String, key: String, value: AnyHashable) {
            self.label = label
            self.key = key
            self.value = value
        }
    }

    package let id: String
    package let type: String
    package let label: String
    package let order: Int
    package let defaultValue: Any
    package let min: Double
    package let max: Double
    package let step: Double?
    package let fraction: Bool
    package let precision: Int
    package let options: [Option]
    package let condition: String?

    package init(id: String, type: String, label: String, order: Int, defaultValue: Any, min: Double, max: Double, step: Double?,
                 fraction: Bool, precision: Int, options: [Option], condition: String?) {
        self.id = id; self.type = type; self.label = label; self.order = order; self.defaultValue = defaultValue
        self.min = min; self.max = max; self.step = step; self.fraction = fraction; self.precision = precision
        self.options = options; self.condition = condition
    }

    package var isLabel: Bool { ["text", "group", ""].contains(type) }
}

package enum Library {
    /// The wallpapers in `directories`. An id found in several folders (the steamcmd and CrossOver workshop folders)
    /// is taken from the first folder that has it.
    package static func scan(directories: [URL]) -> [WallpaperItem] {
        var items: [WallpaperItem] = []
        var seen = Set<String>()
        for root in directories {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
            for name in names where !seen.contains(name) {
                let dir = root.appendingPathComponent(name)
                guard let project = readProject(dir) else { continue }
                seen.insert(name)
                let preview = (project["preview"] as? String).map { dir.appendingPathComponent($0) }
                items.append(WallpaperItem(
                    id: name,
                    directory: dir,
                    title: (project["title"] as? String) ?? name,
                    // The engine ignores `type` and classifies `file` (Project_ClassifyFile 0x14011e520).
                    type: project["file"] == nil ? "" : ProjectKind.classify(file: (project["file"] as? String) ?? "").typeName.lowercased(),
                    preview: preview.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil },
                    dependency: project["file"] == nil ? project["dependency"] as? String : nil,
                    tags: (project["tags"] as? [String]) ?? []))
            }
        }
        return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The general properties the engine injects into every wallpaper's property list (`UI_BuildGeneralProps`
    /// 0x140104b60, docs/re/09 §5): volume (slider 0–100, order 1), playback rate (10–200, order 2), mouse parallax,
    /// alignment (cover 0 / fill 1 / center 3 / stretch 2 / free 4) with position (0–100), horizontal/vertical (0–100),
    /// zoom (0–200) and flip, and audio processing for projects that support it. A property the project declares itself
    /// is left as declared.
    package static func generalProperties(for item: WallpaperItem, strings: LocalizedStrings) -> [PropertySpec] {
        let project = readProject(item.baseDirectory) ?? [:]
        let general = project["general"] as? [String: Any]
        let declared = (general?["properties"] as? [String: Any]) ?? [:]
        let visual = item.type == "scene" || item.type == "video" || item.type.isEmpty
        func slider(_ id: String, _ text: String, _ order: Int, _ lo: Double, _ hi: Double, _ v: Double, _ cond: String? = nil) -> PropertySpec {
            PropertySpec(id: id, type: "slider", label: strings.label(text), order: order, defaultValue: v, min: lo, max: hi,
                         step: 1, fraction: false, precision: 0, options: [], condition: cond)
        }
        func toggle(_ id: String, _ text: String, _ order: Int, _ v: Bool) -> PropertySpec {
            PropertySpec(id: id, type: "bool", label: strings.label(text), order: order, defaultValue: v, min: 0, max: 1,
                         step: nil, fraction: false, precision: 0, options: [], condition: nil)
        }
        var specs = [slider("volume", "ui_browse_properties_volume", 1, 0, 100, 50)]
        if item.type != "web" { specs.append(slider("rate", "ui_browse_properties_playback_rate", 2, 10, 200, 100)) }
        if item.type == "scene" || item.type.isEmpty {
            specs.append(toggle("cameraparallax", "ui_browse_properties_mouse_parallax", 3, true))
        }
        if visual {
            let options: [(String, Int)] = [("ui_browse_properties_alignment_cover", 0), ("ui_browse_properties_alignment_fill", 1),
                                            ("ui_browse_properties_alignment_center", 3), ("ui_browse_properties_alignment_stretch", 2),
                                            ("ui_browse_properties_alignment_free", 4)]
            specs.append(PropertySpec(id: "alignment", type: "combo", label: strings.label("ui_browse_properties_alignment"), order: 4,
                                      defaultValue: 0, min: 0, max: 4, step: nil, fraction: false, precision: 0,
                                      options: options.map { .init(label: strings.label($0.0), key: "\($0.1)", value: AnyHashable($0.1)) },
                                      condition: nil))
            specs.append(slider("alignmentposition", "ui_browse_properties_alignment_position", 5, 0, 100, 50,
                                "alignment.value<2&&checkPositionVisibility()"))
            specs.append(slider("alignmentx", "ui_browse_properties_alignment_horizontal", 5, 0, 100, 50,
                                "alignment.value==3||alignment.value==4"))
            specs.append(slider("alignmenty", "ui_browse_properties_alignment_vertical", 6, 0, 100, 50,
                                "alignment.value==3||alignment.value==4"))
            specs.append(slider("alignmentz", "ui_browse_properties_alignment_zoom", 7, 0, 200, 100, "alignment.value==4"))
            specs.append(toggle("alignmentfliph", "ui_browse_properties_alignment_flip_horizontally", 8, false))
            // Colour options (0x140107160–0x140108bd7, docs/re/09 §5.1): flag bit 0x80 adds the LUT filter `wcc_v`
            // (type "combolutfilters", options from the UI's `lutFilterOptionFiles`) and `wcc_amt` (0–100, shown when a
            // filter is set); bit 0x40 adds `wec_e` and the 0–100 sliders `wec_brs`, `wec_con`, `wec_sa`, `wec_hue`
            // (default 50, shown when `wec_e`). Scenes get both (0x14010eb45 `or edx, 0xd0`). The other builder call
            // (0x14010cfad–0x14010d05d, and 0x14010a5f0–0x14010a68e) switches on the wallpaper object's type (vt+0x20:
            // 1 scene 0x1404897d8, 2 web/CEF 0x140489c18, 3 application 0x14048a610, 4 video 0x140488990, 5 0x14048a718):
            // video (4) → 0xd5 (LUT and colour); web (2) → 0x170, or 0x43 when the file's extension is exactly ".webm"
            // (a .webm video played by the web host: colour options, no LUT).
            let webm = item.type == "video" && ((project["file"] as? String).map { ($0 as NSString).pathExtension == "webm" } ?? false)
            let lutOptions = [PropertySpec.Option(label: strings.label("ui_browse_properties_image_filter_none"), key: "", value: AnyHashable(""))]
                + lutFilterFiles.enumerated().map { i, f in
                    PropertySpec.Option(label: "\(i + 1) " + strings.label("ui_browse_lut_filter_" + f), key: f, value: AnyHashable(f))
                }
            if !webm {
                specs.append(PropertySpec(id: "wcc_v", type: "combo", label: strings.label("ui_browse_properties_image_filter"), order: 10,
                                          defaultValue: "", min: 0, max: 0, step: nil, fraction: false, precision: 0,
                                          options: lutOptions, condition: nil))
                specs.append(slider("wcc_amt", "ui_browse_properties_filter_strength", 11, 0, 100, 100, "wcc_v.value"))
            }
            specs.append(toggle("wec_e", "ui_browse_properties_show_color_options", 12, false))
            specs.append(slider("wec_brs", "ui_browse_properties_brightness", 13, 0, 100, 50, "wec_e.value"))
            specs.append(slider("wec_con", "ui_browse_properties_contrast", 14, 0, 100, 50, "wec_e.value"))
            specs.append(slider("wec_sa", "ui_browse_properties_saturation", 15, 0, 100, 50, "wec_e.value"))
            specs.append(slider("wec_hue", "ui_browse_properties_hue_shift", 16, 0, 100, 50, "wec_e.value"))
        }
        if item.type == "web" {
            // Web wallpapers (0x14010d058: flags 0x170) get the colour options without the LUT filter; the web host
            // applies them as a CSS filter (WebWallpaper.applyWallpaperGeneral).
            specs.append(toggle("wec_e", "ui_browse_properties_show_color_options", 12, false))
            specs.append(slider("wec_brs", "ui_browse_properties_brightness", 13, 0, 100, 50, "wec_e.value"))
            specs.append(slider("wec_con", "ui_browse_properties_contrast", 14, 0, 100, 50, "wec_e.value"))
            specs.append(slider("wec_sa", "ui_browse_properties_saturation", 15, 0, 100, 50, "wec_e.value"))
            specs.append(slider("wec_hue", "ui_browse_properties_hue_shift", 16, 0, 100, 50, "wec_e.value"))
            specs.append(toggle("alignmentfliph", "ui_browse_properties_alignment_flip_horizontally", 8, false))
        }
        if (general?["supportsaudioprocessing"] as? Bool) == true {
            specs.append(toggle("audioprocessing", "Audio processing", 9, true))
        }
        return specs.filter { declared[$0.id] == nil }
    }

    /// LUT filter names: the UI's `window.wpxGlobalData.lutFilterOptionFiles` (ui/dist/scripts/scripts.js), else the
    /// `.tex` files in `assets/materials/lut`. Set from the engine install by AppState.
    package static var lutFilterFiles: [String] = []
    package static func loadLUTFilters(install: URL) -> [String] {
        let js = install.appendingPathComponent("ui/dist/scripts/scripts.js")
        if let text = try? String(contentsOf: js, encoding: .utf8),
           let r = text.range(of: #"lutFilterOptionFiles=\[[^\]]*\]"#, options: .regularExpression) {
            let list = text[r].drop(while: { $0 != "[" })
            if let data = list.data(using: .utf8), let a = (try? JSONSerialization.jsonObject(with: data)) as? [String], !a.isEmpty { return a }
        }
        let dir = install.appendingPathComponent("assets/materials/lut")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".tex") }.map { String($0.dropLast(4)) }.sorted()
    }

    package static func readProject(_ dir: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("project.json")) else { return nil }
        return parseEngineJSON(data) as? [String: Any]
    }

    /// Properties for an item, with preset values as the defaults.
    package static func properties(for item: WallpaperItem, strings: LocalizedStrings) -> [PropertySpec] {
        guard let base = readProject(item.baseDirectory) else { return [] }
        let preset = item.dependency != nil ? ((readProject(item.directory)?["preset"] as? [String: Any]) ?? [:]) : [:]
        let props = ((base["general"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
        return props.compactMap { key, raw -> PropertySpec? in
            guard let p = raw as? [String: Any] else { return nil }
            let type = ((p["type"] as? String) ?? "").lowercased()
            let options = ((p["options"] as? [[String: Any]]) ?? []).map { o -> PropertySpec.Option in
                let v = o["value"] ?? ""
                return .init(label: strings.label(o["label"] as? String ?? "\(v)"), key: "\(v)", value: (v as? AnyHashable) ?? AnyHashable("\(v)"))
            }
            var value = p["value"] ?? NSNull()
            if let pv = preset[key], !(pv is NSNull) { value = pv }
            return PropertySpec(
                id: key, type: type, label: strings.label(p["text"] as? String ?? key),
                order: (p["order"] as? NSNumber)?.intValue ?? 0, defaultValue: value,
                min: (p["min"] as? NSNumber)?.doubleValue ?? 0, max: (p["max"] as? NSNumber)?.doubleValue ?? 1,
                step: (p["step"] as? NSNumber)?.doubleValue, fraction: (p["fraction"] as? Bool) ?? false,
                precision: (p["precision"] as? NSNumber)?.intValue ?? 2, options: options,
                condition: (p["condition"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        .sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }
}

/// The engine's UI strings (`locale/ui_en-us.json`), used for property labels such as
/// `ui_browse_properties_scheme_color`.
package struct LocalizedStrings {
    package let table: [String: String]

    package init(installDirectory: URL) {
        var t: [String: String] = [:]
        for file in ["core_en-us.json", "ui_en-us.json"] {
            let url = installDirectory.appendingPathComponent("locale").appendingPathComponent(file)
            if let data = try? Data(contentsOf: url), let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] {
                t.merge(d) { _, b in b }
            }
        }
        table = t
    }

    /// Translates a `ui_` key and reduces the label's HTML to plain text.
    package func label(_ s: String) -> String {
        var text = table[s] ?? s
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        for (entity, char) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Evaluates property `condition` expressions (JavaScript over `<name>.value`) to decide what to show.
package final class ConditionEvaluator {
    private let context = JSContext()!

    package init(values: [String: Any]) {
        // UI helper used by the injected `alignmentposition` condition; photon always shows the slider.
        context.evaluateScript("function checkPositionVisibility() { return true; }")
        for (k, v) in values {
            context.setObject(["value": v], forKeyedSubscript: k as NSString)
        }
    }

    package func isVisible(_ spec: PropertySpec) -> Bool {
        guard let condition = spec.condition else { return true }
        context.exception = nil
        let r = context.evaluateScript("!!(\(condition))")
        if context.exception != nil { return true }
        return r?.toBool() ?? true
    }
}
