import AppKit
import PhotonApp
import PhotonRender
import SwiftUI

/// The engine's Settings → Performance tab, as far as photon implements it: the playback rules (docs/re/09 §1),
/// application rules, frame rate and post-processing.
struct SettingsView: View {
    @ObservedObject var state: AppState

    /// The engine's UI offers "pause all" and per-display "pause" only with several displays (`runtime.multimonitor`).
    private var multi: Bool { NSScreen.screens.count > 1 }

    var body: some View {
        Form {
            Section("Playback") {
                rulePicker(state.strings.label("ui_settings_playback_focused"), \.focus,
                           multi ? PlaybackSettings.focusOptions : [.run, .mute, .pause])
                rulePicker(state.strings.label("ui_settings_playback_maximized"), \.maximized,
                           multi ? PlaybackSettings.windowOptions : [.run, .mute, .pause, .stop])
                rulePicker(state.strings.label("ui_settings_playback_fullscreen"), \.fullscreen,
                           multi ? PlaybackSettings.windowOptions : [.run, .mute, .pause, .stop])
                rulePicker(state.strings.label("ui_settings_playback_playing_audio"), \.audio, PlaybackSettings.audioOptions)
                rulePicker(state.strings.label("ui_settings_playback_sleep"), \.sleep, PlaybackSettings.powerOptions)
                rulePicker(state.strings.label("ui_settings_playback_battery"), \.battery, PlaybackSettings.powerOptions)
                Toggle("Stop when video memory runs out", isOn: $state.playback.pauseOnVRAMExhaustion)
                Stepper("Check every \(state.playback.windowUpdateRate) ms", value: $state.playback.windowUpdateRate,
                        in: 50...5000, step: 50)
                if let status = status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            Section(label("ui_settings_playback_application_rules_header", "Application rules")) {
                ForEach($state.rules) { $rule in
                    HStack {
                        TextField("Application", text: $rule.application)
                            .frame(minWidth: 140)
                        Picker("", selection: $rule.condition) {
                            ForEach(AppRule.Condition.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        Picker("", selection: $rule.action) {
                            ForEach([PlaybackAction.mute, .pause, .pauseAll, .stop]) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        Button(role: .destructive) { state.rules.removeAll { $0.id == rule.id } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Menu("Add rule for…") {
                        ForEach(runningApps, id: \.self) { name in
                            Button(name) { state.rules.append(AppRule(application: name, condition: .focused, action: .pause)) }
                        }
                    }
                    .fixedSize()
                    Button("Add empty rule") { state.rules.append(AppRule(application: "", condition: .running, action: .pause)) }
                }
                Text("Applications match by name, bundle identifier or executable name.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Performance") {
                Stepper("Frame rate limit: \(state.fps == 0 ? "unlimited" : "\(state.fps) fps")", value: $state.fps, in: 0...240, step: 5)
                Picker("Post-processing", selection: $state.postProcessing) {
                    Text("Disabled").tag(SceneRenderer.PostProcessing.disabled)
                    Text("Enabled").tag(SceneRenderer.PostProcessing.enabled)
                    Text("Ultra (HDR)").tag(SceneRenderer.PostProcessing.ultra)
                    Text("Display HDR").tag(SceneRenderer.PostProcessing.displayhdr)
                }
                // `msaa` (Project_Prescan 0x14010ecb1): only scenes with 3D model objects are multisampled.
                Picker("Anti-aliasing (MSAA)", selection: $state.msaa) {
                    Text("None").tag("none")
                    Text("2×").tag("x2")
                    Text("4×").tag("x4")
                    Text("8×").tag("x8")
                }
                // `resolution` (Wallpaper_ApplySettings 0x1401155be): half or auto (half below 1969920 screen pixels)
                // drop the top texture mip and halve layer composites. Read at load: the shown wallpapers reload.
                Picker("Texture resolution", selection: $state.resolution) {
                    Text("Full").tag("full")
                    Text("Half").tag("half")
                    Text("Auto").tag("auto")
                }
            }
            EnergySection(state: state)
            Section(label("ui_settings_wallpaper_browser_transition", "Wallpaper switch")) {
                // General setting `browsetransition` (UI getTransitionOptions; values are the engine's FADEEFFECT numbers).
                Picker("Transition", selection: Binding(get: { state.browseTransition.mode },
                                                        set: { state.browseTransition.mode = $0 })) {
                    ForEach(Self.transitionOptions, id: \.1) { option in
                        Text(label(option.0, Self.transitionFallback(option.0))).tag(option.1)
                    }
                }
                if state.browseTransition.mode != -1 && state.browseTransition.mode != -2 {
                    // UI slider 0–3000 ms, step 50 (configureTransitionSlider).
                    Slider(value: Binding(get: { Double(state.browseTransition.timeMs) },
                                          set: { state.browseTransition.timeMs = Int($0) }), in: 0...3000, step: 50) {
                        Text("Duration \(state.browseTransition.timeMs) ms")
                    }
                }
            }
            WorkshopSettingsSection(state: state)
            Section("Displays") {
                // wallpaperconfig `layout` (ui `W.layouts`): per display, stretch (span), clone.
                Picker("Layout", selection: $state.layout) {
                    Text(label("ui_browse_monitors_layout_per_monitor", "Wallpaper per display")).tag(0)
                    Text(label("ui_browse_monitors_layout_fit", "Stretch single wallpaper")).tag(1)
                    Text(label("ui_browse_monitors_layout_clone_wallpaper", "Clone single wallpaper")).tag(2)
                }
                Text(state.layout == 0 ? "Stretch and clone groups join some displays under one wallpaper."
                     : "Stretch and clone show the main display's wallpaper on every display.")
                    .font(.caption).foregroundStyle(.secondary)
                if state.displays.count > 1 {
                    if state.layout == 2 { cloneControls(group: nil, members: state.displays.map(\.id)) }
                    if state.layout == 0 { groupControls }
                }
                if state.layout == 0 { splitControls }
                if let flipNote { Text(flipNote).font(.caption).foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 560)
    }

    // MARK: Displays (the browser's monitor panel: groups, clone source and flip; docs/re/09 §8.3)

    /// Displays picked for a new group.
    @State private var newGroup: Set<String> = []
    /// `ui_browse_monitors_clone_flip_limitation_message` after a flip the UI refuses.
    @State private var flipNote: String?

    private func displayName(_ key: String) -> String { state.displays.first { $0.id == key }?.name ?? key }

    /// The layout with the displays' real rectangles (the automatic clone source depends on them).
    private var plan: LayoutPlan { state.layoutPlan(LayoutCompositor.monitors()) }

    /// Clone source and per-display flip of layout 2 (`group` nil: the profile's own `source` / `monitorconfig`) or of a
    /// clone group.
    @ViewBuilder private func cloneControls(group: String?, members: [String]) -> some View {
        let locked = group.map { state.profile.groups[$0]?.source ?? "" } ?? state.profile.source
        let flips = group.map { state.profile.groups[$0]?.flip ?? [] } ?? state.profile.flip
        let auto = plan.instances.first { $0.key == (group ?? state.displays.first?.id ?? "") }?.host
        Picker(label("ui_browse_monitors_clone_set_source", "Clone source"), selection: Binding(
            get: { locked },
            set: { v in
                if let group { state.profile.setGroupSource(group, v.isEmpty ? nil : v) } else { state.profile.setSource(v.isEmpty ? nil : v) }
            })) {
            Text("Automatic" + (locked.isEmpty ? auto.map { " (\(displayName($0)))" } ?? "" : "")).tag("")
            ForEach(members, id: \.self) { Text(displayName($0)).tag($0) }
        }
        ForEach(members, id: \.self) { m in
            Toggle("\(label("ui_browse_monitors_clone_flip", "Flip")): \(displayName(m))", isOn: Binding(
                get: { flips.contains(m) },
                set: { _ in
                    let hit = group.map { state.profile.toggleGroupFlip($0, m) } ?? state.profile.toggleFlip(m, among: members)
                    flipNote = hit ? label("ui_browse_monitors_clone_flip_limitation_message", "At least one display of a clone must not be flipped.") : nil
                }))
        }
    }

    /// Stretch and clone groups of layout 0 (`groups`): each with its kind and members, clone source and flips, removal;
    /// and a new group from two or more displays (`callbackCreateGroup`).
    @ViewBuilder private var groupControls: some View {
        ForEach(state.profile.groups.keys.sorted(), id: \.self) { name in
            if let g = state.profile.groups[name] {
                HStack {
                    Text((g.isClone ? label("ui_browse_monitors_clone", "Clone") : label("ui_browse_monitors_stretch", "Stretch")) + ": "
                         + g.monitors.map(displayName).joined(separator: ", "))
                    Spacer()
                    Button(label("ui_browse_monitors_remove_group", "Remove group")) { state.profile.removeGroup(name) }
                }
                if g.isClone { cloneControls(group: name, members: g.monitors) }
            }
        }
        DisclosureGroup("New group") {
            ForEach(state.displays) { d in
                Toggle(d.name + (state.profile.group(containing: d.id) != nil ? " (in a group)" : ""), isOn: Binding(
                    get: { newGroup.contains(d.id) },
                    set: { on in if on { newGroup.insert(d.id) } else { newGroup.remove(d.id) } }))
            }
            HStack {
                Button(label("ui_browse_monitors_add_stretch_group", "Add stretch group")) { addGroup(1) }
                Button(label("ui_browse_monitors_add_clone_group", "Add clone group")) { addGroup(2) }
            }
            .disabled(newGroup.count < 2)
        }
    }

    // MARK: Splits (`splits`, scripts.js `callbackSplitSelectedMonitor`, `browseSplitMonitor`, `Rt`, `Tt`)

    /// Displays or split regions picked for a new split, and the dialog's direction and position (pixels).
    @State private var splitTarget = ""
    @State private var splitDirection = 0
    @State private var splitPixels: Double?

    /// A display or region key as the UI names it: the display, then the path of its regions.
    private func regionName(_ key: String) -> String {
        if let inst = plan.instance(key) { return inst.name }
        let root = MonitorProfile.splitRoot(key)
        return displayName(root) + key.dropFirst(root.count)
    }

    /// The pixel size the split dialog bounds the position with (the region's record).
    private func regionPixels(_ key: String) -> (w: Int, h: Int)? { plan.records.first { $0.key == key }?.pixelSize }

    /// What "Add split" is offered on (the UI's monitor menu): displays and split regions that are not a group and not in
    /// one.
    private var splittable: [String] {
        plan.instances.filter { ($0.kind == .display || $0.kind == .split) && state.profile.group(containing: $0.key) == nil }.map(\.key)
    }

    /// The splits that are applied (their parent is a region of the plan), parents before children.
    private var appliedSplits: [String] {
        state.profile.splits.keys.filter { k in plan.records.contains { $0.key == k + "/L" || $0.key == k + "/R" }
            || plan.records.contains { $0.key.hasPrefix(k + "/") } }.sorted()
    }

    private func directionLabel(_ d: Int) -> String {
        d == 1 ? label("ui_browse_monitors_horizontal", "Horizontal") : label("ui_browse_monitors_vertical", "Vertical")
    }

    @ViewBuilder private var splitControls: some View {
        ForEach(appliedSplits, id: \.self) { key in
            if let s = state.profile.splits[key], let px = regionPixels(key) {
                let size = s.direction == 1 ? px.h : px.w
                HStack {
                    Text("\(label("ui_browse_monitors_split", "Split")): \(regionName(key))")
                    Spacer()
                    Picker("", selection: Binding(get: { s.direction == 1 ? 1 : 0 }, set: { d in
                        let pixels = Double(MonitorProfile.splitPixels(s.position, size: size))
                        state.profile.editSplit(key, direction: d, position: MonitorProfile.splitFraction(pixels: pixels, size: d == 1 ? px.h : px.w))
                    })) {
                        Text(directionLabel(0)).tag(0)
                        Text(directionLabel(1)).tag(1)
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button(label("ui_browse_monitors_remove_split", "Remove split")) { state.profile.removeSplit(region: key + "/L") }
                }
                Slider(value: Binding(get: { Double(MonitorProfile.splitPixels(s.position, size: size)) }, set: { v in
                    state.profile.editSplit(key, direction: s.direction, position: MonitorProfile.splitFraction(pixels: v, size: size))
                }), in: 1...Double(max(size - 1, 2)), step: 1) {
                    Text("\(label("ui_browse_monitors_posititon", "Position")) \(MonitorProfile.splitPixels(s.position, size: size)) px")
                }
            }
        }
        DisclosureGroup(label("ui_browse_monitors_add_split", "Add split")) {
            Picker("Display or region", selection: $splitTarget) {
                ForEach(splittable, id: \.self) { Text(regionName($0)).tag($0) }
            }
            Picker(label("ui_browse_monitors_direction", "Direction"), selection: $splitDirection) {
                Text(directionLabel(0)).tag(0)
                Text(directionLabel(1)).tag(1)
            }
            if let px = regionPixels(splitTarget) {
                let size = splitDirection == 1 ? px.h : px.w
                TextField("\(label("ui_browse_monitors_posititon", "Position")) (px, 1–\(size - 1))", value: $splitPixels, format: .number)
                HStack {
                    Button(label("ui_browse_monitors_add_split", "Add split")) {
                        state.addSplit(splitTarget, direction: splitDirection,
                                       position: MonitorProfile.splitFraction(pixels: splitPixels, size: size))
                        splitPixels = nil
                    }
                    if MonitorProfile.splitParent(splitTarget) != nil {
                        Button(label("ui_browse_monitors_remove_all_splits", "Remove all splits")) {
                            state.profile.removeAllSplits(region: splitTarget)
                        }
                    }
                }
            }
        }
        .onAppear { if !splittable.contains(splitTarget) { splitTarget = splittable.first ?? "" } }
        .onChange(of: splittable) { _, keys in if !keys.contains(splitTarget) { splitTarget = keys.first ?? "" } }
    }

    private func addGroup(_ layout: Int) {
        state.profile.createGroup(state.displays.map(\.id).filter(newGroup.contains), layout: layout)
        newGroup = []
    }

    /// scripts.js `getTransitionOptions` (SettingsCatalog, PhotonApp).
    static let transitionOptions: [(String, Int)] = SettingsCatalog.transitionOptions

    /// The engine's UI string, or `fallback` when the install's strings are missing.
    private func label(_ key: String, _ fallback: String) -> String {
        let l = state.strings.label(key)
        return l.isEmpty || l == key ? fallback : l
    }

    /// "ui_browse_playlist_modal_settings_transition_fade_to_black" → "Fade to black".
    static func transitionFallback(_ key: String) -> String { SettingsCatalog.transitionFallback(key) }

    private func rulePicker(_ label: String, _ key: WritableKeyPath<PlaybackSettings, PlaybackAction>, _ options: [PlaybackAction]) -> some View {
        Picker(label.isEmpty || label.hasPrefix("ui_") ? Self.ruleFallback(key) : label, selection: Binding(get: { state.playback[keyPath: key] },
                                                              set: { state.playback[keyPath: key] = $0 })) {
            // Keep a saved value that this display setup doesn't offer selectable.
            ForEach(options.contains(state.playback[keyPath: key]) ? options : options + [state.playback[keyPath: key]]) {
                Text($0.label).tag($0)
            }
        }
    }

    static func ruleFallback(_ key: WritableKeyPath<PlaybackSettings, PlaybackAction>) -> String { SettingsCatalog.ruleFallback(key) }

    private var status: String? {
        let d = state.decision
        if d.stop { return "Now: stopped by a rule" }
        if state.hostFlags.contains(.asleep) { return "Now: paused, display asleep" }
        var parts: [String] = []
        if d.pauseMask != 0 { parts.append(d.pauseMask == UInt32.max ? "paused on all displays" : "paused on \(d.pauseMask.nonzeroBitCount) display(s)") }
        if d.mute { parts.append("muted") }
        return parts.isEmpty ? "Now: running" : "Now: " + parts.joined(separator: ", ")
    }

    private var runningApps: [String] {
        Array(Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName))).sorted()
    }
}

/// photon's energy controls (Energy.swift); none of these exist in Wallpaper Engine.
struct EnergySection: View {
    @ObservedObject var state: AppState

    var body: some View {
        Section("Energy") {
            LabeledContent("Now", value: state.energy.summary)
            Stepper(batteryLabel, value: $state.energySettings.batteryFPS, in: 0...240, step: 5)
            Toggle("Treat Low Power Mode as battery", isOn: $state.energySettings.followLowPower)
            Toggle("Slow down when the Mac is hot", isOn: $state.energySettings.thermalBackoff)
            Toggle("Limit web wallpapers to the frame rate", isOn: $state.energySettings.capWebPages)
            Text("Hot halves the frame rate; very hot pauses every wallpaper until the Mac cools. Wallpaper Engine runs web "
                 + "wallpapers at the display's refresh rate; the limit applies on battery and when hot either way.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var batteryLabel: String {
        let v = state.energySettings.batteryFPS
        return "Frame rate on battery: " + (v == 0 ? "same as limit" : "\(v) fps")
    }
}
