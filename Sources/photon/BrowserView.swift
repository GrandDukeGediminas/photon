import AppKit
import PhotonRender
import SwiftUI

/// The wallpaper browser: a grid of the library on the left, the selected wallpaper's details and
/// properties on the right, playback controls along the bottom.
struct BrowserView: View {
    @ObservedObject var state: AppState
    @State private var selection: String?
    @State private var search = ""
    @State private var showUnsupported = false
    @State private var mode: Mode = .library
    @State private var workshopSelection: WorkshopItem?

    enum Mode: String { case library = "Library", workshop = "Workshop", subscribed = "Subscribed" }

    private var filtered: [WallpaperItem] {
        state.items.filter { item in
            (showUnsupported || item.unsupportedReason == nil)
                && (search.isEmpty || item.title.localizedCaseInsensitiveContains(search)
                    || item.tags.contains { $0.localizedCaseInsensitiveContains(search) } || item.id == search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    Picker("", selection: $mode) {
                        Text("Library").tag(Mode.library)
                        Text("Workshop").tag(Mode.workshop)
                        Text("Subscribed").tag(Mode.subscribed)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .padding(.top, 8)
                    switch mode {
                    case .library: library
                    case .workshop: WorkshopBrowser(state: state, selection: $workshopSelection)
                    case .subscribed: SubscribedBrowser(state: state, selection: $workshopSelection)
                    }
                }
                .frame(minWidth: 480, idealWidth: 760)
                Group {
                    if mode != .library {
                        if let item = workshopSelection {
                            WorkshopDetail(state: state, item: item) { id in selection = id; mode = .library }
                                .id(item.id)
                        } else {
                            Text("Select a Workshop item")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else if let id = selection, let item = state.item(id) {
                        DetailView(state: state, item: item)
                            .id(item.id)
                    } else {
                        Text("Select a wallpaper")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 480)
            }
            Divider()
            PlaylistPanel(state: state, selection: selection)
            Divider()
            PlaybackBar(state: state)
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear {
            if selection == nil { selection = state.wallpaper(forDisplay: AppState.allDisplays) ?? state.activeIDs.first }
        }
        // A finished download: select it in the library (and show it there when it is the Workshop item on view).
        .onReceive(state.workshop.$lastInstalled.compactMap { $0 }) { id in
            selection = id
            if mode != .library && workshopSelection?.id == id { mode = .library }
        }
    }

    private var library: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search title, tag or id", text: $search)
                    .textFieldStyle(.plain)
                Toggle("Show unsupported", isOn: $showUnsupported)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 12)], spacing: 12) {
                    ForEach(filtered) { item in
                        Tile(item: item, selected: selection == item.id, active: state.activeIDs.contains(item.id),
                             failed: state.errors[item.id] != nil)
                            // The double tap goes first: attached after the single tap it is never recognised.
                            .onTapGesture(count: 2) { selection = item.id; state.apply(item.id, display: nil) }
                            .onTapGesture { selection = item.id }
                    }
                }
                .padding(12)
            }
            Divider()
            Text("\(filtered.count) of \(state.items.count) wallpapers · double-click to apply to all displays")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
        }
    }
}

private struct Tile: View {
    let item: WallpaperItem
    let selected: Bool
    let active: Bool
    let failed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Thumbnail(url: item.preview)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topTrailing) {
                    if active {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .font(.title3)
                            .padding(5)
                    } else if failed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .padding(5)
                    }
                }
                .opacity(item.unsupportedReason == nil ? 1 : 0.4)
            Text(item.title)
                .font(.caption)
                .lineLimit(2, reservesSpace: true)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.25) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .help(item.unsupportedReason ?? item.title)
    }
}

struct Thumbnail: View {
    let url: URL?
    var maxPixels = 480
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.15))
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .clipped()
        .onAppear {
            guard image == nil, let url else { return }
            ThumbnailCache.shared.image(url, maxPixels: maxPixels) { image = $0 }
        }
    }
}

private struct DetailView: View {
    @ObservedObject var state: AppState
    let item: WallpaperItem
    @State private var target = AppState.allDisplays
    @State private var specs: [PropertySpec] = []
    @State private var generalSpecs: [PropertySpec] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Thumbnail(url: item.preview, maxPixels: 900)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(item.title).font(.headline).textSelection(.enabled)
                Text("\(item.type.isEmpty ? "preset" : item.type) · \(item.id)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)

                if let reason = item.unsupportedReason {
                    Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    HStack {
                        Picker("Show on", selection: $target) {
                            Text("All displays").tag(AppState.allDisplays)
                            // Every record with a wallpaper of its own: displays, groups (docs/re/09 §8.3).
                            ForEach(state.wallpaperTargets) { d in
                                Text(d.name).tag(d.id)
                            }
                        }
                        .labelsHidden()
                        Button("Apply") { state.apply(item.id, display: target == AppState.allDisplays ? nil : target) }
                            .keyboardShortcut(.defaultAction)
                    }
                    let showing = state.wallpaperTargets.filter { state.wallpaper(forDisplay: $0.id) == item.id }
                    if !showing.isEmpty {
                        Text("Showing on " + showing.map(\.name).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = state.errors[item.id] {
                    Label("Failed to load: \(error)", systemImage: "xmark.octagon").foregroundStyle(.red).font(.caption)
                }

                if !generalSpecs.isEmpty && item.unsupportedReason == nil {
                    Divider()
                    Text("Wallpaper").font(.headline)
                    GeneralPropertiesView(state: state, id: item.id, specs: generalSpecs)
                }

                if !specs.isEmpty {
                    Divider()
                    HStack {
                        Text("Properties").font(.headline)
                        Spacer()
                        // Saved property presets (`general.wpresets`, PropertyPresets.swift, docs/re/09 §9.6).
                        Menu("Presets") {
                            let names = state.presets(of: item.id).map(\.name)
                            ForEach(names, id: \.self) { n in Button(n) { state.loadPreset(named: n, of: item.id) } }
                            if !names.isEmpty { Divider() }
                            Button("Save Current…") {
                                if let n = AppState.promptPresetName(existing: names) {
                                    let v = state.values(specs, of: item.id).merging(state.generalValues(of: item.id)) { a, _ in a }
                                    state.savePreset(named: n, of: item.id, values: v)
                                }
                            }
                            if !names.isEmpty {
                                Menu("Delete") { ForEach(names, id: \.self) { n in Button(n) { state.deletePreset(named: n, of: item.id) } } }
                            }
                        }
                        .fixedSize()
                        Button("Reset") { state.resetProperties(of: item.id) }
                            .disabled(state.overrides[item.id] == nil)
                    }
                    PropertiesView(state: state, id: item.id, specs: specs)
                }
            }
            .padding(14)
        }
        .onAppear {
            specs = Library.properties(for: item, strings: state.strings)
            generalSpecs = Library.generalProperties(for: item, strings: state.strings)
        }
    }
}

private struct PropertiesView: View {
    @ObservedObject var state: AppState
    let id: String
    let specs: [PropertySpec]

    var body: some View {
        let evaluator = ConditionEvaluator(values: state.values(specs, of: id))
        VStack(alignment: .leading, spacing: 10) {
            ForEach(specs.filter(evaluator.isVisible)) { spec in
                PropertyRow(spec: spec, value: binding(spec))
            }
        }
    }

    private func binding(_ spec: PropertySpec) -> Binding<Any> {
        Binding(get: { state.value(spec, of: id) }, set: { state.setProperty(spec.id, to: $0, of: id) })
    }
}

/// The engine's injected general properties (volume, rate, parallax, alignment): applied live, no scene reload.
private struct GeneralPropertiesView: View {
    @ObservedObject var state: AppState
    let id: String
    let specs: [PropertySpec]

    var body: some View {
        let values = state.generalValues(of: id)
        let evaluator = ConditionEvaluator(values: values)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(specs.filter(evaluator.isVisible)) { spec in
                PropertyRow(spec: spec, value: Binding(get: { state.generalValues(of: id)[spec.id] ?? spec.defaultValue },
                                                       set: { state.setGeneral(spec.id, to: $0, of: id) }))
            }
        }
    }
}

private struct PropertyRow: View {
    let spec: PropertySpec
    @Binding var value: Any

    var body: some View {
        switch spec.type {
        case "bool":
            Toggle(spec.label, isOn: Binding(get: { (value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? false) },
                                             set: { value = $0 }))
        case "slider":
            sliderRow
        case "color":
            ColorPicker(spec.label, selection: Binding(get: { Self.color(value) }, set: { value = Self.string($0) }),
                        supportsOpacity: false)
        case "combo":
            Picker(spec.label, selection: Binding(get: { "\(value)" }, set: { key in
                value = spec.options.first { $0.key == key }?.value ?? key
            })) {
                ForEach(spec.options, id: \.self) { Text($0.label).tag($0.key) }
            }
        case "textinput":
            VStack(alignment: .leading, spacing: 4) {
                Text(spec.label).font(.callout)
                TextField("", text: Binding(get: { value as? String ?? "\(value)" }, set: { value = $0 }))
            }
        case "file", "directory":
            // User file / folder properties: web wallpapers get the path (and folder listings), scenes the file.
            LabeledContent(spec.label) {
                HStack {
                    Text((value as? String).flatMap { $0.isEmpty ? nil : ($0 as NSString).lastPathComponent } ?? "None")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = spec.type == "file"
                        panel.canChooseDirectories = spec.type == "directory"
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url { value = url.path }
                    }
                }
            }
        case "group":
            Text(spec.label).font(.subheadline.bold()).padding(.top, 6)
        case "text", "":
            if !spec.label.isEmpty { Text(spec.label).font(.caption).foregroundStyle(.secondary) }
        default:
            LabeledContent(spec.label) {
                Text("\(spec.type) not supported").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var sliderRow: some View {
        let v = (value as? NSNumber)?.doubleValue ?? (value as? Double) ?? spec.min
        let step = spec.fraction ? (spec.step ?? 0) : max(spec.step ?? 1, 1)
        let lo = min(spec.min, spec.max), hi = max(spec.min, spec.max)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(spec.label).font(.callout)
                Spacer()
                Text(spec.fraction ? String(format: "%.\(min(spec.precision, 4))f", v) : "\(Int(v.rounded()))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if hi > lo {
                // Quantize here: Slider(step:) draws a tick mark per step, which hangs on fine steps over wide ranges.
                Slider(value: Binding(get: { min(max(v, lo), hi) }, set: {
                    let q = step > 0 ? lo + (($0 - lo) / step).rounded() * step : $0
                    value = spec.fraction ? min(max(q, lo), hi) : q.rounded()
                }), in: lo...hi)
            }
        }
    }

    /// Property colours are "r g b" in 0–1 (some wallpapers use 0–255).
    static func color(_ value: Any) -> Color {
        let parts = "\(value)".split(separator: " ").compactMap { Double($0) }
        guard parts.count >= 3 else { return .white }
        let scale = parts.prefix(3).contains { $0 > 1 } ? 255.0 : 1.0
        return Color(.sRGB, red: parts[0] / scale, green: parts[1] / scale, blue: parts[2] / scale)
    }

    static func string(_ color: Color) -> String {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return [c.redComponent, c.greenComponent, c.blueComponent].map { String(format: "%.5f", $0) }.joined(separator: " ")
    }
}

private struct PlaybackBar: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 14) {
            Button { state.paused.toggle() } label: {
                Label(state.paused ? "Play" : "Pause", systemImage: state.paused ? "play.fill" : "pause.fill")
            }
            Button { state.muted.toggle() } label: {
                Image(systemName: state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .help(state.muted ? "Unmute" : "Mute")
            Slider(value: $state.volume, in: 0...1)
                .frame(width: 140)
                .disabled(state.muted)
                .help("Master volume, on top of each wallpaper's own volume")
            Spacer()
            Picker("Post-processing", selection: $state.postProcessing) {
                Text("Disabled").tag(SceneRenderer.PostProcessing.disabled)
                Text("Enabled").tag(SceneRenderer.PostProcessing.enabled)
                Text("Ultra (HDR)").tag(SceneRenderer.PostProcessing.ultra)
                Text("Display HDR").tag(SceneRenderer.PostProcessing.displayhdr)
            }
            .fixedSize()
            .help("Wallpaper Engine's post-processing quality. Ultra runs the HDR bloom path on HDR scenes.")
            Button("Reload library") { state.reloadLibrary() }
            Button("Settings…") { NSApp.sendAction(Selector(("showSettings")), to: nil, from: nil) }
        }
        .padding(10)
    }
}
