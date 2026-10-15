#if os(Linux)
import CGtk3
import CPhotonApp
import Foundation
import PhotonApp
import PhotonRender

/// `photon-linux app --self-test OUTDIR`: drives the app the way a user would, through its widgets and the status-icon
/// menu, and checks the model, the persisted settings and the desktop hosts after each step: browse → apply →
/// properties → presets → playlist → settings → tray. Window snapshots (gtk_widget_draw, any backend) and screen captures
/// (`import -window root` on X11, `grim` on Wayland) go to OUTDIR, with `results.txt` (one PASS/FAIL line per check).
/// The settings live in OUTDIR/config, never in the user's ~/.config/photon2.
final class AppSelfTest {
    let app: LinuxApp
    let outDir: URL
    private var steps: [(String, UInt32, () -> Void)] = []
    private var lines: [String] = []
    private var failures = 0
    private var item: WallpaperItem?
    private var second: WallpaperItem?

    init(app: LinuxApp, outDir: URL) {
        self.app = app
        self.outDir = outDir
    }

    var state: AppState { app.state }

    private func check(_ ok: Bool, _ what: String) {
        let line = (ok ? "PASS: " : "FAIL: ") + what
        if !ok { failures += 1 }
        lines.append(line)
        print("self-test: " + line)
    }

    private func snapshot(_ w: Widget?, _ name: String) {
        let path = outDir.appendingPathComponent(name).path
        let ok = w.map { photon_widget_snapshot_png($0, path) != 0 } ?? false
        check(ok, "window snapshot \(name)")
    }

    /// The whole screen: the desktop host's wallpaper under the app's windows.
    private func screen(_ name: String) {
        let path = outDir.appendingPathComponent(name).path
        let env = ProcessInfo.processInfo.environment
        let status = env["WAYLAND_DISPLAY"].map { !$0.isEmpty } == true
            ? StaticBackground.spawn(["grim", path]) : StaticBackground.spawn(["import", "-window", "root", path])
        check(status == 0 && FileManager.default.fileExists(atPath: path), "screen capture \(name)")
    }

    /// The persisted settings file (what a restart reads).
    private var persisted: [String: Any] {
        guard let url = (app.defaults as? XDGDefaults)?.fileURL, let d = try? Data(contentsOf: url) else { return [:] }
        return (try? PropertyListSerialization.propertyList(from: d, options: [], format: nil)) as? [String: Any] ?? [:]
    }

    private func step(_ name: String, wait ms: UInt32 = 500, _ body: @escaping () -> Void) { steps.append((name, ms, body)) }

    func run(done: @escaping (Int) -> Void) {
        let usable = state.items.filter { $0.unsupportedReason == nil }
        let preferred = ProcessInfo.processInfo.environment["PHOTON_SELFTEST_ITEMS"]?.split(separator: ",").map(String.init) ?? []
        item = preferred.first.flatMap { state.item($0) } ?? usable.first { $0.type == "scene" } ?? usable.first
        second = (preferred.count > 1 ? state.item(preferred[1]) : nil) ?? usable.first { $0.id != item?.id }
        if ProcessInfo.processInfo.environment["PHOTON_SELFTEST_LAYOUT"] == "1" {
            layoutSteps()
            next(0, done: done)
            return
        }

        step("start", wait: 1500) { [self] in
            check(!state.items.isEmpty, "library has \(state.items.count) wallpapers")
            check(!state.displays.isEmpty, "displays from the hosts: \(state.displays.map(\.id).joined(separator: ", "))")
            check(item != nil && second != nil, "two supported wallpapers to test with (\(item?.id ?? "-"), \(second?.id ?? "-"))")
            app.showBrowser()
        }
        step("browse", wait: 1500) { [self] in
            guard let b = app.browser, let item else { return check(false, "browser window") }
            check(gtk_widget_get_visible(b.window) != 0, "browser window shown")
            check(b.filtered.count <= state.items.count && !b.filtered.isEmpty, "grid lists \(b.filtered.count) supported wallpapers")
            b.select(item.id)
            check(b.selection == item.id && b.detail?.item.id == item.id, "selecting \(item.id) shows its details")
            snapshot(b.window, "01-browser.png")
        }
        step("apply", wait: ProcessInfo.processInfo.environment["PHOTON_SELFTEST_HOST_WAIT"].flatMap(UInt32.init) ?? 12000) { [self] in
            guard let b = app.browser, let item, let tile = b.tile(item.id) else { return check(false, "tile for \(String(describing: self.item?.id))") }
            gtk_widget_activate(tile) // a double-click activates the flow box child
            check(state.wallpaper(forDisplay: AppState.allDisplays) == item.id, "double-click applies \(item.id) to all displays")
            check((persisted["assignments"] as? [String: String])?[AppState.allDisplays] == item.id, "assignment persisted in \(outDir.lastPathComponent)/config")
        }
        step("applied") { [self] in
            guard let item else { return }
            let running = app.supervisor.hosts.values.filter { $0.spec.id == item.id }
            check(!app.supervisor.enabled || !running.isEmpty, "a desktop host runs \(item.id) (\(running.count) host(s))")
            check(state.errors[item.id] == nil, "no load error for \(item.id) (\(state.errors[item.id] ?? "ok"))")
            screen("02-screen-applied.png")
            if let b = app.browser { snapshot(b.window, "02-browser-applied.png") }
            // The desktop alone: the browser hides (as when closed), the hosts' wallpaper is the screen.
            app.browser.map { gtk_widget_hide($0.window) }
        }
        step("desktop", wait: 1000) { [self] in
            screen("02-desktop-applied.png")
            app.showBrowser()
        }
        step("per-display apply") { [self] in
            guard let second, let first = state.displays.first, let b = app.browser else { return }
            b.select(second.id)
            b.detail?.chooseDisplay(first.id)
            b.apply(second.id, display: first.id)
            check(state.wallpaper(forDisplay: first.id) == second.id, "Apply on display \(first.id) shows \(second.id) there")
            // Back to one wallpaper everywhere for the next steps.
            if let item { b.select(item.id); b.apply(item.id, display: nil) }
        }
        step("properties", wait: 1500) { [self] in
            guard let b = app.browser, let item, let d = b.detail else { return check(false, "detail pane") }
            // General properties: the wallpaper volume slider and the horizontal flip.
            let generalPanel = d.general
            if let g = generalPanel {
                check(g.setThroughControl("volume", 30), "volume slider exists")
                check((state.overrides[item.id]?["volume"] as? NSNumber)?.intValue == 30, "volume 30 stored as a general override")
                if g.specs.contains(where: { $0.id == "alignmentfliph" }) {
                    _ = g.setThroughControl("alignmentfliph", true)
                    check(state.generalValues(of: item.id)["alignmentfliph"] as? Bool == true, "flip stored")
                }
            } else {
                check(false, "general properties panel")
            }
            // The project's own properties through their controls: the test scene `images` declares color, bool, a slider shown
            // only while the bool is on (condition), combo, textinput, group and text.
            if let p = d.properties {
                let types = Set(p.specs.map(\.type))
                lines.append("NOTE: \(item.id) property types: \(types.sorted().joined(separator: ", "))")
                if let cond = p.specs.first(where: { $0.condition != nil && $0.type == "slider" }),
                   let gate = p.specs.first(where: { $0.type == "bool" && cond.condition?.contains($0.id) == true }) {
                    check(!p.isShown(cond.id), "\(cond.id) hidden while its condition \(cond.condition ?? "") is false")
                    _ = p.setThroughControl(gate.id, true)
                    check(p.isShown(cond.id), "\(cond.id) shown once \(gate.id) is on")
                    let v = cond.fraction ? cond.min + (cond.max - cond.min) * 0.75 : ((cond.min + cond.max) / 2).rounded()
                    _ = p.setThroughControl(cond.id, v)
                    check((state.overrides[item.id]?[cond.id] as? NSNumber)?.doubleValue == v, "slider \(cond.id) = \(v) stored")
                }
                for spec in p.specs {
                    switch spec.type {
                    case "combo":
                        guard let last = spec.options.last else { continue }
                        _ = p.setThroughControl(spec.id, last.key)
                        check("\(state.overrides[item.id]?[spec.id] ?? "")" == "\(last.value)", "combo \(spec.id) = \(last.key) stored as the option value")
                    case "textinput":
                        _ = p.setThroughControl(spec.id, "photon self-test")
                        check(state.overrides[item.id]?[spec.id] as? String == "photon self-test", "text \(spec.id) stored")
                    default: break
                    }
                }
                let stored = (persisted["overrides"] as? Data).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: [String: Any]]
                check(stored?[item.id]?.isEmpty == false, "overrides persisted (overrides key, JSON data)")
                d.savePreset(specs: p.specs, existing: [], name: "self-test")
            } else {
                d.savePreset(specs: [], existing: [], name: "self-test")
                lines.append("NOTE: \(item.id) has no project properties")
            }
            check(state.presets(of: item.id).map(\.name).contains("self-test"), "preset self-test saved (wpresets)")
            snapshot(b.window, "03-properties.png")
            snapshot(d.content, "03-properties-pane.png")
        }
        step("playlist", wait: 800) { [self] in
            guard let b = app.browser, let item, let second, let panel = b.playlist else { return }
            panel.setTarget(AppState.allDisplays)
            b.select(item.id); panel.addSelection()
            b.select(second.id); panel.addSelection()
            check(state.playlists.assigned[AppState.allDisplays]?.items.map(\.file) == [item.id, second.id], "playlist of two wallpapers on all displays")
            panel.configure()
        }
        step("playlist settings", wait: 800) { [self] in
            guard let item, let second else { return }
            if let d = PlaylistSettingsDialog.current?.dialog { snapshot(d, "04-playlist-settings.png") }
            check(PlaylistSettingsDialog.confirm(["mode": "timer", "delay": 1, "order": "sorted"]), "playlist settings dialog confirmed")
            let p = state.playlists.assigned[AppState.allDisplays]
            check(p?.mode == .timer && p?.delay == 1 && p?.sorted == true, "timer 1 min, sorted order applied")
            app.browser?.playlist.saveDialog(name: "self-test list")
            check(state.playlists.saved.contains { $0.name == "self-test list" }, "playlist saved (playlists key)")
            // Two Nexts over a sorted two-item playlist show both wallpapers (the first may re-pick the shown one: the
            // sorted index need not follow the wallpaper that was applied by hand).
            let key = state.displays.first?.id ?? AppState.allDisplays
            var seen = [state.wallpaper(forDisplay: key) ?? "-"]
            for _ in 0..<2 { state.playlists.next(); seen.append(state.wallpaper(forDisplay: key) ?? "-") }
            check(Set(seen.dropFirst()) == [item.id, second.id],
                  "Next Wallpaper steps through the playlist (\(seen.joined(separator: " → ")))")
            check(persisted["selectedplaylists"] is Data, "selected playlists persisted")
            if let b = app.browser { snapshot(b.window, "04-playlist.png") }
        }
        step("settings", wait: 1500) { [self] in
            app.showSettings()
            guard let s = app.settings else { return check(false, "settings window") }
            if let fps = s.controls["fps"] { gtk_spin_button_set_value(G(fps), 30) }
            check(state.fps == 30, "frame rate 30 through the spin button")
            if let msaa = s.controls["msaa"] { _ = gtk_combo_box_set_active_id(G(msaa), "x4") }
            check(state.msaa == "x4", "MSAA x4 through its combo")
            if let focus = s.controls["ui_settings_playback_focused"] { _ = gtk_combo_box_set_active_id(G(focus), "pause") }
            check(state.playback.focus == .pause, "focus rule pause")
            let p = persisted
            check((p["fps"] as? NSNumber)?.intValue == 30 && p["msaa"] as? String == "x4" && p["playbackfocus"] as? String == "pause",
                  "fps, msaa, playbackfocus persisted with the macOS keys")
        }
        step("settings shown", wait: 6000) { [self] in
            if let s = app.settings {
                snapshot(s.window, "05-settings.png")
                snapshot(s.content, "05-settings-page.png")
            }
            // The settings change restarted the hosts with the new arguments.
            let args = app.supervisor.hosts.values.first?.process.arguments ?? []
            check(!app.supervisor.enabled || (args.contains("--msaa") && args[(args.firstIndex(of: "--msaa") ?? 0) + 1] == "x4"),
                  "hosts restarted with --msaa x4")
        }
        // The Workshop window's Subscribed mode, over a subscription list written to OUTDIR (Steam's own files are
        // never read here). Resolving the ids needs Steam's API: offline the summary shows the error instead.
        step("workshop subscribed", wait: 3000) { [self] in
            let ugc = outDir.appendingPathComponent("steam/userdata/12345/ugc")
            try? FileManager.default.createDirectory(at: ugc, withIntermediateDirectories: true)
            let vdf = "\"subscribedfiles\"\n{\n\t\"appid\"\t\"431960\"\n\t\"time_last_updated\"\t\"1757631788\"\n"
                + "\t\"0\"\n\t{\n\t\t\"publishedfileid\"\t\"764162681\"\n\t\t\"time_subscribed\"\t\"1757279420\"\n\t}\n"
                + "\t\"1\"\n\t{\n\t\t\"publishedfileid\"\t\"1\"\n\t\t\"time_subscribed\"\t\"1757279419\"\n\t}\n}\n"
            try? vdf.write(to: ugc.appendingPathComponent("431960_subscriptions.vdf"), atomically: true, encoding: .utf8)
            let root = outDir.appendingPathComponent("steam")
            state.workshop.subscriptionSource = { SteamSubscriptions.load(files: SteamSubscriptions.files(roots: [root])) }
            state.workshop.subscribedCacheFile = outDir.appendingPathComponent("subscribed.json")
            app.showWorkshop()
            guard let w = app.workshopWindow else { return check(false, "workshop window") }
            w.setMode(subscribed: true)
            check(state.workshop.subscriptionSnapshot?.entries.map(\.id) == ["764162681", "1"],
                  "Subscribed reads the subscription list, newest first")
        }
        step("workshop subscribed shown", wait: 500) { [self] in
            guard let w = app.workshopWindow else { return }
            let ws: WorkshopController = state.workshop
            check(!ws.subscribedLoading, "subscriptions resolved or failed (\(ws.subscribedError ?? "\(ws.subscribed.count) item(s), \(ws.subscribedUnavailable) unavailable"))")
            snapshot(w.window, "05-workshop-subscribed.png")
            w.setMode(subscribed: false)
            gtk_widget_hide(w.window)
        }
        // Steam sign-in inside the app (SteamSignInWindow) with the fake steamcmd: password, then an emailed Steam Guard
        // code (a wrong one first). Nothing reaches Steam.
        let fake = "/src/Tests/fixtures/workshop/fake-steamcmd.sh"
        var savedUser = "", savedPath = ""
        step("sign-in password", wait: 1500) { [self] in
            let w: WorkshopController = state.workshop
            savedUser = w.username; savedPath = w.steamcmdPath
            w.steamcmdPath = fake
            w.username = "email"
            app.showSignIn()
            w.signIn.start(username: "email")
        }
        step("sign-in code", wait: 1500) { [self] in
            let w: WorkshopController = state.workshop
            check(w.signIn.state == .needsPassword, "sign-in asks for the password (\(w.signIn.state))")
            if let win = app.signInWindow { snapshot(win.window, "05-signin-password.png") }
            w.signIn.submitPassword("right")
        }
        step("sign-in wrong code", wait: 1500) { [self] in
            let w: WorkshopController = state.workshop
            check(w.signIn.state == .needsCode(.email, retry: false), "sign-in asks for the emailed Steam Guard code (\(w.signIn.state))")
            w.signIn.submitCode("BAD")
        }
        step("sign-in good code", wait: 1500) { [self] in
            let w: WorkshopController = state.workshop
            check(w.signIn.state == .needsCode(.email, retry: true), "a refused code is asked for again (\(w.signIn.state))")
            if let win = app.signInWindow { snapshot(win.window, "05-signin-code.png") }
            w.signIn.submitCode("GOOD1")
        }
        step("signed in", wait: 500) { [self] in
            let w: WorkshopController = state.workshop
            check(w.signIn.state == .signedIn, "signed in (\(w.signIn.state))")
            w.username = savedUser; w.steamcmdPath = savedPath
            if let win = app.signInWindow { gtk_widget_hide(win.window) }
        }
        step("tray", wait: 2500) { [self] in
            guard let tray = app.tray else { return check(false, "status icon") }
            let labels = tray.entries.map(\.label)
            check(labels.contains("Browse Wallpapers…") && labels.contains("Settings…") && labels.contains("Quit photon"), "tray menu: \(labels.joined(separator: " | "))")
            check(labels.contains(app.label("core_tray_next_wallpaper", "Next Wallpaper")), "tray offers Next Wallpaper while the playlist runs")
            let menu = tray.entries.map { "\($0.id)\t\($0.parent)\t\($0.enabled ? "enabled" : "disabled")\t\($0.checked ? "checked" : "-")\t\($0.label)" }
            try? (menu.joined(separator: "\n") + "\n").write(to: outDir.appendingPathComponent("06-tray-menu.txt"), atomically: true, encoding: .utf8)
            tray.click(3) // Pause
            check(state.paused, "tray Pause pauses")
            tray.click(4) // Mute
            check(state.muted, "tray Mute mutes")
            try? tray.busName.write(to: outDir.appendingPathComponent("tray-bus-name.txt"), atomically: true, encoding: .utf8)
        }
        step("paused") { [self] in
            let host = app.supervisor.hosts.values.first
            check(!app.supervisor.enabled || host?.lastLines.contains { $0.contains("control: pause true") } == true
                  || host?.live?.paused == true, "the host received pause")
            app.browser.map { gtk_widget_hide($0.window) }
            app.settings.map { gtk_widget_hide($0.window) }
        }
        step("paused desktop", wait: 800) { [self] in
            screen("07-desktop-paused.png")
            app.tray?.click(3)
            app.tray?.click(4)
            check(!state.paused && !state.muted, "tray Resume and unmute")
            app.browser.map { gtk_widget_hide($0.window) }
            app.settings.map { gtk_widget_hide($0.window) }
        }
        // Wallpaper switches (docs/linux-port.md §6.1): in the running host between scenes, by handover to and from a web
        // page, and the playlist's "change when a video ends".
        let web = state.items.first { $0.type == "web" && $0.unsupportedReason == nil }
        // PHOTON_SELFTEST_VIDEO: a short video wallpaper (app-check.sh generates a 2 s one), else the first video.
        let video = ProcessInfo.processInfo.environment["PHOTON_SELFTEST_VIDEO"].flatMap { state.item($0) }
            ?? state.items.first { $0.type == "video" && $0.unsupportedReason == nil }
        // The overlay shaders are the engine's (assets/shaders/HLSL/dx11playlisttransition.*); the CC0 stand-in assets of
        // hosted CI have none, and the hosts then switch without an overlay, as the macOS app does when a transition
        // cannot be made.
        let effects = FileManager.default.fileExists(atPath: state.engineAssets.appendingPathComponent("shaders/HLSL/dx11playlisttransition.frag").path)
        if !effects { lines.append("NOTE: no dx11playlisttransition shaders in \(state.engineAssets.path): switches without the overlay") }
        let drew = { (l: [String]) -> Bool in
            effects ? l.contains { $0.contains("started") || ($0.hasPrefix("switch:") && $0.contains("shown")) }
                    : l.contains { $0.contains("failed") || $0.contains("cut shown") }
        }
        var hostLines: [String] = []
        let lines0 = { [self] in app.supervisor.switchLog.count }
        var switchMark = 0
        step("switch in place", wait: 4000) { [self] in
            guard let item, let second, let b = app.browser else { return }
            b.apply(item.id, display: nil)
            state.browseTransition = TransitionSettings(mode: 0, timeMs: 1000)
            switchMark = lines0()
            after(1500) { b.apply(second.id, display: nil) }
        }
        step("switch in place done", wait: 200) { [self] in
            guard let second, app.supervisor.enabled else { return }
            let log = app.supervisor.switchLog.dropFirst(switchMark).joined(separator: " | ")
            check(log.contains("→ \(second.id) in host") && log.contains("effect 0 1000 ms"), "browse switch to \(second.id) loads in the running host with the fade: \(log)")
            let h = app.supervisor.hosts.values.first { $0.spec.id == second.id }
            hostLines = h?.lastLines ?? []
            check(drew(h?.switchLines ?? []), "the host drew the switch (\(h?.switchLines.joined(separator: "; ") ?? "no host"))")
            screen("08-desktop-after-switch.png")
        }
        if let web {
            step("handover to web", wait: 9000) { [self] in
                switchMark = lines0()
                state.browseTransition = TransitionSettings(mode: 0, timeMs: 1500)
                app.browser?.apply(web.id, display: nil)
                after(3500) { [self] in screen("09-desktop-switching-to-web.png") }
            }
            step("handover to web done", wait: 200) { [self] in
                guard app.supervisor.enabled else { return }
                let log = app.supervisor.switchLog.dropFirst(switchMark).joined(separator: " | ")
                check(log.contains("→ \(web.id) by handover (effect 0 1500 ms, type change)"), "switch to the web page hands over between hosts: \(log)")
                let h = app.supervisor.hosts.values.first { $0.spec.id == web.id }
                check(h?.process.arguments.contains("--switch-snapshot") == true, "the web host starts with the scene host's frames")
                check(effects ? h?.switchLines.contains { $0.contains("shown") } == true : h?.switchLines.contains { $0.contains("failed") } == true,
                      "the web host showed the overlay over the page (\(h?.switchLines.joined(separator: "; ") ?? "no host"))")
                check(app.supervisor.retiring.isEmpty && app.supervisor.hosts.count == 1, "the scene host ended after the handover")
            }
            step("handover from web", wait: 9000) { [self] in
                guard let item else { return }
                switchMark = lines0()
                state.browseTransition = TransitionSettings(mode: -2, timeMs: 0)
                app.browser?.apply(item.id, display: nil)
            }
            step("handover from web done", wait: 200) { [self] in
                guard let item, app.supervisor.enabled else { return }
                let log = app.supervisor.switchLog.dropFirst(switchMark).joined(separator: " | ")
                check(log.contains("→ \(item.id) by handover (none (no flicker)"), "switch back to \(item.id) with the −2 hold: \(log)")
                let h = app.supervisor.hosts.values.first { $0.spec.id == item.id }
                check(h?.switchLines.contains { $0.contains("hold shown") } == true,
                      "the scene host held the web page's frame until its scene drew (\(h?.switchLines.joined(separator: "; ") ?? "no host"))")
            }
        } else {
            lines.append("NOTE: no web wallpaper in the library: handover checks skipped")
        }
        if let video, let item {
            step("video playlist", wait: 9000) { [self] in
                state.browseTransition = .browseDefault
                app.browser?.apply(video.id, display: nil)
                switchMark = lines0()
                // Timer mode with videosequence: the video's end selects the next item (`Playlist_OnVideoEnded`).
                state.playlists.assign(["name": "video sequence", "items": [item.id, video.id],
                                        "settings": ["mode": "timer", "delay": 60, "order": "sorted", "videosequence": true, "beginfirst": true,
                                                     "transition": "1", "transitiontime": 800]], to: AppState.allDisplays)
            }
            step("video playlist done", wait: 200) { [self] in
                guard app.supervisor.enabled else { return }
                let key = state.displays.first?.id ?? AppState.allDisplays
                let log = app.supervisor.switchLog.dropFirst(switchMark).joined(separator: " | ")
                check(state.wallpaper(forDisplay: key) == item.id, "the playlist moved on when the video ended (now \(state.wallpaper(forDisplay: key) ?? "-"))")
                check(log.contains("\(video.id) → \(item.id) in host") && log.contains("effect 1 800 ms"), "with the playlist's transition: \(log)")
                let h = app.supervisor.hosts.values.first { $0.spec.id == item.id }
                check(h?.allLines.contains { $0.hasPrefix("video: ended") } == true, "the host reported the video's end")
                state.playlists.clear(AppState.allDisplays)
            }
        } else {
            lines.append("NOTE: no video wallpaper in the library: video-end check skipped")
        }
        step("rules to hosts", wait: 3000) { [self] in
            state.rules = [AppRule(application: "photon-selftest-nothing", condition: .running, action: .pause)]
            var pb = state.playback
            pb.pauseOnVRAMExhaustion = true
            state.playback = pb
        }
        step("rules to hosts done", wait: 500) { [self] in
            let args = app.supervisor.hosts.values.first?.process.arguments ?? []
            check(!app.supervisor.enabled || (args.contains("--app-rules") && args.contains("--pause-vram")),
                  "application rules and pausevram reach the hosts (--app-rules, --pause-vram)")
            _ = hostLines
            state.rules = []
            var pb = state.playback
            pb.pauseOnVRAMExhaustion = false
            state.playback = pb
        }
        step("persisted") { [self] in
            // A second AppState over the same settings file sees what the first saved (restart).
            if let url = (app.defaults as? XDGDefaults)?.fileURL, let again = XDGDefaults(directory: url.deletingLastPathComponent()) {
                check(again.integer(forKey: "fps") == 30 && again.string(forKey: "msaa") == "x4", "settings read back from \(url.path)")
            }
            try? (lines.joined(separator: "\n") + "\n").write(to: outDir.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
            print("self-test: \(failures == 0 ? "all checks passed" : "\(failures) failure(s)") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed)")
        }
        next(0, done: done)
    }

    // MARK: Displays: clone groups and splits (PHOTON_SELFTEST_LAYOUT=1, two or more outputs; docs/re/09 §8.3)

    /// The running hosts' command lines.
    private var hostArgs: [[String]] { app.supervisor.hosts.values.map(\.process.arguments) }

    private func arg(_ a: [String], _ name: String) -> [String] {
        a.indices.filter { a[$0] == name && $0 + 1 < a.count }.map { a[$0 + 1] }
    }

    private func toggle(_ key: String, _ on: Bool = true) -> Bool {
        guard let w = app.settings?.controls[key] else { return false }
        gtk_toggle_button_set_active(G(w), on ? 1 : 0)
        return true
    }

    private func click(_ key: String) -> Bool {
        guard let w = app.settings?.controls[key] else { return false }
        gtk_button_clicked(G(w))
        return true
    }

    private func combo(_ key: String, _ id: String) -> Bool {
        guard let w = app.settings?.controls[key] else { return false }
        return gtk_combo_box_set_active_id(G(w), id) != 0
    }

    private func spin(_ key: String, _ v: Double) -> Bool {
        guard let w = app.settings?.controls[key] else { return false }
        gtk_spin_button_set_value(G(w), v)
        return true
    }

    /// Through the Settings → Displays controls: a clone group of the first two outputs (its host, a locked source, a
    /// flip, removal); a split of the first output (one host per region with `--region`, a wallpaper per region through
    /// the browser, sound for the first host of a wallpaper only), a nested split, moving a divider, removal.
    private func layoutSteps() {
        let hostWait = ProcessInfo.processInfo.environment["PHOTON_SELFTEST_HOST_WAIT"].flatMap(UInt32.init) ?? 9000
        var a = "", b = ""
        var group = ""
        step("layout start", wait: hostWait) { [self] in
            check(state.displays.count >= 2, "two or more outputs: \(state.displays.map(\.id).joined(separator: ", "))")
            guard state.displays.count >= 2, let item else { return }
            a = state.displays[0].id; b = state.displays[1].id
            state.layout = 0
            state.profile = MonitorProfile()
            app.showBrowser()
            app.browser?.apply(item.id, display: nil)
            app.showSettings()
            // The controls stay usable with the windows hidden; the screen captures show the desktop alone.
            app.browser.map { gtk_widget_hide($0.window) }
            app.settings.map { gtk_widget_hide($0.window) }
        }
        step("clone group", wait: hostWait) { [self] in
            guard !a.isEmpty else { return }
            check(toggle("newgroup:" + a) && toggle("newgroup:" + b) && click("addclonegroup"), "new group: both outputs ticked, Add clone group")
            group = state.profile.groups.keys.first ?? ""
            check(state.profile.groups[group] == MonitorProfile.Group(monitors: [a, b], layout: 2),
                  "the profile has clone group \(group) of \(a), \(b) (group_<hashCode>: \(group == "group_\(MonitorProfile.hashCode(a + b))"))")
            check(state.wallpaperTargets.map(\.id) == [group], "the group is the only wallpaper target: \(state.wallpaperTargets.map(\.id))")
            if let item { state.apply(item.id, display: group) }
        }
        step("clone group host", wait: 300) { [self] in
            guard !group.isEmpty else { return }
            let args = hostArgs
            check(args.count == 1 && arg(args.first ?? [], "--layout") == ["clone"] && arg(args.first ?? [], "--output") == ["\(a),\(b)"],
                  "one host clones the group over both outputs: \(args.map { $0.suffix(14).joined(separator: " ") })")
            screen("20-clone-group.png")
            check(combo("clonesource:" + group, b), "lock \(b) as the group's clone source")
            check(state.profile.groups[group]?.source == b, "group source stored")
        }
        step("clone group source", wait: hostWait) { [self] in
            check(toggle("cloneflip:\(group):\(a)"), "flip \(a)")
            check(state.profile.groups[group]?.flip == [a], "group flip stored")
        }
        step("clone group flip", wait: hostWait) { [self] in
            guard !group.isEmpty else { return }
            let h = hostArgs.first ?? []
            check(hostArgs.count == 1 && arg(h, "--clone-source") == [b] && arg(h, "--clone-flip") == [a],
                  "the host runs with --clone-source \(b) --clone-flip \(a): \(h.suffix(10).joined(separator: " "))")
            screen("21-clone-group-flipped.png")
            check(click("removegroup:" + group), "Remove group")
            check(state.profile.groups.isEmpty, "group removed")
        }
        // The target and direction combos rebuild the page (the position's range follows them): pick them first.
        step("split target", wait: 300) { [self] in
            guard !a.isEmpty else { return }
            check(combo("splittarget", a) && combo("newsplitdirection", "0"), "split \(a) vertically")
        }
        step("split", wait: hostWait) { [self] in
            guard !a.isEmpty, let item, let second else { return }
            let w = HostSupervisor.geometry[a]?.2 ?? 0
            check(spin("newsplitposition", Double(w / 2)) && click("addsplit"), "Add split on \(a): vertical at \(w / 2) px")
            check(state.profile.splits[a] == MonitorProfile.Split(direction: 0, position: Double(w / 2) / Double(w)),
                  "splits.\(a) = {direction 0, position \(Double(w / 2) / Double(w))}")
            check(Set(state.wallpaperTargets.map(\.id)) == [a + "/L", a + "/R", b], "targets \(state.wallpaperTargets.map(\.id))")
            app.browser?.apply(item.id, display: nil)
            app.browser?.apply(second.id, display: a + "/R")
            check(state.wallpaper(forDisplay: a + "/R") == second.id, "\(second.id) applied to \(a)/R through the browser")
        }
        step("split hosts", wait: 300) { [self] in
            guard !a.isEmpty, let item, let second else { return }
            let w = HostSupervisor.geometry[a]?.2 ?? 0, h = HostSupervisor.geometry[a]?.3 ?? 0
            let regions = hostArgs.filter { !arg($0, "--region").isEmpty }
            let rs = Set(regions.flatMap { arg($0, "--region") })
            check(regions.count == 2 && rs == ["\(a)=0,0,\(w / 2),\(h)", "\(a)=\(w / 2),0,\(w - w / 2),\(h)"],
                  "a host per region of \(a): \(rs.sorted())")
            let right = regions.first { arg($0, "--region") == ["\(a)=\(w / 2),0,\(w - w / 2),\(h)"] }
            check(right?.contains(second.directory.path) == true, "the right region's host runs \(second.id)")
            let ofItem = hostArgs.filter { $0.contains(item.directory.path) }
            check(ofItem.count == 2 && ofItem.filter { $0.contains("--no-sound") }.count == 1,
                  "\(item.id) runs on \(a)/L and \(b): one host plays its sound, the other has --no-sound")
            check(app.supervisor.hosts.values.allSatisfy { $0.ready }, "every host drew (host: ready)")
            screen("22-split.png")
            // Nested: /R cut top / bottom.
            check(combo("splittarget", a + "/R") && combo("newsplitdirection", "1"), "split \(a)/R horizontally")
        }
        step("nested split add", wait: hostWait) { [self] in
            guard !a.isEmpty else { return }
            let h = HostSupervisor.geometry[a]?.3 ?? 0
            check(spin("newsplitposition", Double(h / 2)) && click("addsplit"), "Add split on \(a)/R: horizontal at \(h / 2) px")
            check(state.profile.splits[a + "/R"] == MonitorProfile.Split(direction: 1, position: 0.5), "splits.\(a)/R = {direction 1, position 0.5}")
        }
        step("nested split", wait: 300) { [self] in
            guard !a.isEmpty, let second else { return }
            check(Set(state.wallpaperTargets.map(\.id)) == [a + "/L", a + "/R/L", a + "/R/R", b], "targets \(state.wallpaperTargets.map(\.id))")
            check(state.wallpaper(forDisplay: a + "/R/L") == second.id, "\(a)/R/L took \(a)/R's wallpaper")
            let w = HostSupervisor.geometry[a]?.2 ?? 0, h = HostSupervisor.geometry[a]?.3 ?? 0
            let rs = Set(hostArgs.flatMap { arg($0, "--region") })
            check(rs == ["\(a)=0,0,\(w / 2),\(h)", "\(a)=\(w / 2),0,\(w - w / 2),\(h / 2)", "\(a)=\(w / 2),\(h / 2),\(w - w / 2),\(h - h / 2)"],
                  "three region hosts: \(rs.sorted())")
        }
        step("nested split hosts", wait: 300) { [self] in
            guard !a.isEmpty else { return }
            screen("23-split-nested.png")
            let w = HostSupervisor.geometry[a]?.2 ?? 0
            check(spin("splitposition:" + a, Double(w / 4)), "move \(a)'s divider to \(w / 4) px")
            check(state.profile.splits[a]?.position == Double(w / 4) / Double(w), "position \(state.profile.splits[a]?.position ?? -1)")
        }
        step("moved split", wait: hostWait) { [self] in
            guard !a.isEmpty else { return }
            let w = HostSupervisor.geometry[a]?.2 ?? 0, h = HostSupervisor.geometry[a]?.3 ?? 0
            let rs = Set(hostArgs.flatMap { arg($0, "--region") })
            check(rs.contains("\(a)=0,0,\(w / 4),\(h)"), "the left region's host follows the divider: \(rs.sorted())")
            screen("24-split-moved.png")
            check(click("removesplit:" + a), "Remove split")
            check(state.profile.splits.isEmpty, "every split of \(a) removed")
        }
        step("split removed", wait: hostWait) { [self] in
            check(hostArgs.allSatisfy { arg($0, "--region").isEmpty }, "no region hosts left (\(hostArgs.count) host(s))")
            check(Set(state.wallpaperTargets.map(\.id)) == Set(state.displays.map(\.id)), "targets are the displays again")
            screen("25-split-removed.png")
            app.showSettings()
            if let s = app.settings { snapshot(s.window, "26-settings-displays.png") }
            try? (lines.joined(separator: "\n") + "\n").write(to: outDir.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
            print("self-test: \(failures == 0 ? "all checks passed" : "\(failures) failure(s)") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed)")
        }
    }

    private func next(_ i: Int, done: @escaping (Int) -> Void) {
        guard i < steps.count else { done(failures); return }
        let (name, wait, body) = steps[i]
        print("self-test: step \(name)")
        body()
        after(wait) { [self] in next(i + 1, done: done) }
    }
}
#endif
