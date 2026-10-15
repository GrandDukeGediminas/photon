import Combine
import Foundation

/// Saved property presets (docs/re/09 §9.6).
///
/// The engine keeps them in the config under `general.wpresets[<wallpaper file>].presets`, an array of
/// `{"name", "properties": {<property>: <value>}}` (UI `saveWallpaperPresets` → 0x140044c40: `presets` must be an array; the
/// file's entry is created when missing). `Preset_Find` 0x140063f00 looks a preset up by wallpaper file and name: an empty
/// name finds nothing; `general.wpresets[file]` must be an object with a `presets` array; the first element whose `name`
/// is a string equal to the name decides, and its `properties` must be an object (else nothing). Callers:
/// `Playlist_Select` (item preset, 0x1400684e1), the windowed-wallpaper command (`preset`, 0x1400713c7) and
/// 0x140065d61. The found object goes to `0x140073d00`, which builds the load JSON: for every key of the preset,
/// `wproperties[key].value = preset[key]` (the stored user property object is created when missing). The preset only
/// changes the values of that load; the stored user properties stay as they are. `wproperties` also holds the UI-injected
/// general properties (rate, volume, alignment, `wec_*`, …), so a preset saved from the UI (`Xt` of every property of
/// the selected monitor) carries them too.
///
/// photon2 stores the same JSON under the `wpresets` key of its defaults domain, keyed by the wallpaper id (photon2's
/// `file`). The running preset of each display is `AppState.displayPresets`.
extension AppState {
    package static let presetsKey = "wpresets"

    /// `general.wpresets`: wallpaper id → `{"presets": [...]}`.
    package var savedPresets: [String: [String: Any]] {
        get {
            defaults.data(forKey: Self.presetsKey)
                .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: [String: Any]] } ?? [:]
        }
        set {
            if let d = try? JSONSerialization.data(withJSONObject: newValue) { defaults.set(d, forKey: Self.presetsKey) }
            objectWillChange.send()
        }
    }

    /// The presets of a wallpaper, in stored order.
    package func presets(of id: String) -> [(name: String, properties: [String: Any])] {
        (savedPresets[id]?["presets"] as? [Any] ?? []).compactMap { e in
            guard let o = e as? [String: Any], let n = o["name"] as? String else { return nil }
            return (n, o["properties"] as? [String: Any] ?? [:])
        }
    }

    /// `Preset_Find` 0x140063f00.
    package func presetProperties(file: String, name: String) -> [String: Any]? {
        guard !name.isEmpty, let entry = savedPresets[file], let list = entry["presets"] as? [Any] else { return nil }
        for e in list {
            guard let o = e as? [String: Any], let n = o["name"] as? String, n == name else { continue }
            return o["properties"] as? [String: Any]
        }
        return nil
    }

    /// The UI's Save (`callbackSaveWallpaperProperties`): the current value of every property (`Xt`), merged into a
    /// preset of the same name (`angular.merge`) or appended as a new one; then `saveWallpaperPresets`.
    package func savePreset(named name: String, of id: String, values: [String: Any]) {
        guard !name.isEmpty else { return }
        var all = savedPresets
        var entry = all[id] ?? [:]
        var list = entry["presets"] as? [Any] ?? []
        if let i = list.firstIndex(where: { ($0 as? [String: Any])?["name"] as? String == name }), var o = list[i] as? [String: Any] {
            var props = o["properties"] as? [String: Any] ?? [:]
            for (k, v) in values { props[k] = v }
            o["properties"] = props
            list[i] = o
        } else {
            list.append(["name": name, "properties": values])
        }
        entry["presets"] = list
        all[id] = entry
        savedPresets = all
    }

    package func deletePreset(named name: String, of id: String) {
        var all = savedPresets
        guard var entry = all[id], var list = entry["presets"] as? [Any] else { return }
        list.removeAll { ($0 as? [String: Any])?["name"] as? String == name }
        entry["presets"] = list
        all[id] = entry
        savedPresets = all
    }

    /// The UI's Load (`Jt`, `applySingleProperty`): the preset's values become the wallpaper's stored values.
    package func loadPreset(named name: String, of id: String) {
        guard let props = presetProperties(file: id, name: name) else { return }
        for (k, v) in props {
            if Self.generalKeys.contains(k) { setGeneral(k, to: v, of: id) } else { setProperty(k, to: v, of: id) }
        }
    }

    /// Property values for loading `id` on `display`: the stored overrides with the display's running preset on top
    /// (0x140073d00 sets `wproperties[key].value` from the preset).
    package func effectiveOverrides(_ id: String, display: String?) -> [String: Any] {
        var o = overrides[id] ?? [:]
        if let display, let name = displayPresets[display], let props = presetProperties(file: id, name: name) {
            for (k, v) in props { o[k] = v }
        }
        return o
    }

    /// `generalValues(of:)` with the display's running preset applied to the general keys.
    package func generalValues(of id: String, display: String?) -> [String: Any] {
        var v = generalValues(of: id)
        if let display, let name = displayPresets[display], let props = presetProperties(file: id, name: name) {
            for k in Self.generalKeys { if let p = props[k] { v[k] = p } }
        }
        return v
    }
}
