import AppKit
import Combine
import Metal
import PhotonCore
import PhotonHost
import PhotonRender
import SwiftUI

/// photon: Wallpaper Engine scenes on every display, controlled from a menu-bar icon.
/// `photon [workshop id | wallpaper directory]` also applies a wallpaper to all displays on launch; `photon --version`
/// prints the version, which the menu also shows.
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let state: AppState
    let host: DesktopHost
    let renderer: WallpaperRenderer
    private var statusItem: NSStatusItem!
    private var browser: NSWindow?
    private var settingsWindow: NSWindow?
    private var monitor: PlaybackMonitor?
    private var subscriptions: Set<AnyCancellable> = []
    /// Wallpaper Engine ownership (`OwnershipCheck`): nothing starts until the Steam account passed it.
    lazy var ownership = OwnershipCheck(workshop: state.workshop, defaults: state.defaults)
    private var gate: NSWindow?
    private var started = false

    init(state: AppState, device: MTLDevice) {
        self.state = state
        host = DesktopHost(device: device)
        renderer = WallpaperRenderer(device: device, state: state)
        super.init()
        host.renderer = renderer
        // The frame cap is the `fps` setting after the energy controls (`state.energy`).
        host.framesPerSecond = state.energy.fps
        // Wallpaper-switch transitions run at display rate (the engine's overlay thread is not capped by `fps`).
        renderer.fullRateChanged = { [weak self] full in
            guard let self else { return }
            self.host.framesPerSecond = full ? 0 : self.state.energy.fps
        }
        AudioSystem.shared.pollPeriodMs = AudioSystem.pollPeriod(fps: state.energy.fps)
        state.$energy.map(\.fps).removeDuplicates().dropFirst().sink { [weak self] fps in
            guard let self else { return }
            self.host.framesPerSecond = self.renderer.fullRate ? 0 : fps
            AudioSystem.shared.pollPeriodMs = AudioSystem.pollPeriod(fps: fps)
        }.store(in: &subscriptions)
        state.$energy.map(\.webFPS).removeDuplicates().dropFirst().sink { [weak self] fps in
            self?.renderer.frameRateChanged(fps)
        }.store(in: &subscriptions)
        // A stop rule hides the desktop windows and frees the wallpapers; they come back when it ends.
        state.$decision.map(\.stop).removeDuplicates().sink { [weak self] stop in
            guard let self else { return }
            if stop { self.renderer.releaseAll() }
            self.host.hidden = stop
        }.store(in: &subscriptions)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ownership.mayStart {
            start()
            if ownership.dueForRecheck { recheckOwnership() }
        } else {
            showOwnershipGate()
        }
    }

    /// The window shown until the account passes the ownership check.
    private func showOwnershipGate() {
        let view = OwnershipGateView(ownership: ownership, workshop: state.workshop) { [weak self] in
            guard let self else { return }
            self.gate?.close()
            self.gate = nil
            self.start()
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "photon"
        w.contentView = NSHostingView(rootView: view)
        w.isReleasedWhenClosed = false
        w.center()
        gate = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            guard let self, !self.started else { return }
            NSApp.terminate(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// The weekly re-check while running: only a definite "not owned" stops photon; no connection or no saved login keeps
    /// the last success until its grace period ends.
    private func recheckOwnership() {
        ownership.check { [weak self] status in
            guard let self, status == .notOwned else { return }
            let alert = NSAlert()
            alert.messageText = "Wallpaper Engine isn't owned by this Steam account"
            alert.informativeText = "photon runs only for a Steam account that owns Wallpaper Engine. photon will quit."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    private func start() {
        guard !started else { return }
        started = true
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "photon")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        NSApp.mainMenu = Self.mainMenu()
        host.show()
        monitor = PlaybackMonitor(state: state)
        // Playlists: restore the saved state and run the startup selection (docs/re/09 §9).
        state.playlists.start()
        state.$playback.map(\.windowUpdateRate).removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.monitor?.restartTimer()
        }.store(in: &subscriptions)
        state.$playback.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.monitor?.evaluate() }
        }.store(in: &subscriptions)
        state.$energySettings.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.monitor?.evaluate() }
        }.store(in: &subscriptions)
        if let s = ProcessInfo.processInfo.environment["PHOTON_CYCLE"], let seconds = Double(s) {
            startCycling(every: seconds)
        } else if state.activeIDs.isEmpty {
            showBrowser()
        }
    }

    /// Testing: step through every supported wallpaper (`PHOTON_CYCLE=<seconds>`).
    private func startCycling(every seconds: Double) {
        let ids = state.items.filter { $0.unsupportedReason == nil }.map(\.id)
        var i = 0
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [state] timer in
            guard i < ids.count else { NSLog("photon: cycle done"); timer.invalidate(); return }
            NSLog("photon: cycle %d/%d %@", i + 1, ids.count, ids[i])
            state.apply(ids[i], display: nil)
            i += 1
        }
    }

    /// Accessory apps have no menu bar, but text fields still need the standard edit key equivalents.
    static func mainMenu() -> NSMenu {
        let main = NSMenu(), appItem = NSMenuItem(), editItem = NSMenuItem()
        main.addItem(appItem)
        main.addItem(editItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit photon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        return main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for id in state.activeIDs.sorted() {
            let title = state.item(id)?.title ?? id
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if !state.activeIDs.isEmpty { menu.addItem(.separator()) }
        // Tray "Next Wallpaper" (core_tray_next_wallpaper, shown while a display runs a playlist that is not daytime /
        // day of week, 0x14002168e) and "Saved Playlists" (core_tray_saved_playlists). "Previous" is photon2's own.
        if state.playlists.offersNext {
            menu.addItem(item(label("core_tray_next_wallpaper", "Next Wallpaper"), #selector(nextWallpaper), key: "n"))
        }
        if state.playlists.offersPrevious {
            menu.addItem(item("Previous Wallpaper", #selector(previousWallpaper), key: ""))
        }
        if !state.playlists.saved.isEmpty {
            let sub = NSMenu()
            for p in state.playlists.saved {
                let i = NSMenuItem(title: p.name, action: #selector(loadSavedPlaylist(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = p.name
                sub.addItem(i)
            }
            let parent = NSMenuItem(title: label("core_tray_saved_playlists", "Saved Playlists"), action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }
        if state.playlists.offersNext || state.playlists.offersPrevious || !state.playlists.saved.isEmpty { menu.addItem(.separator()) }
        menu.addItem(item("Browse Wallpapers…", #selector(showBrowser), key: "b"))
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(.separator())
        let pause = item(state.paused ? "Resume" : "Pause", #selector(togglePause), key: "p")
        menu.addItem(pause)
        let mute = item("Mute", #selector(toggleMute), key: "m")
        mute.state = state.muted ? .on : .off
        menu.addItem(mute)
        if let reason = autoStateDescription {
            let info = NSMenuItem(title: reason, action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        menu.addItem(.separator())
        let version = NSMenuItem(title: "photon \(PhotonVersion.string)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(item("Quit photon", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func item(_ title: String, _ action: Selector, key: String, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = target ?? self
        return i
    }

    @objc func showBrowser() {
        if browser == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "photon"
            let hosting = NSHostingController(rootView: BrowserView(state: state))
            hosting.sizingOptions = [.minSize]
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 1180, height: 760))
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("photon.browser")
            if !window.setFrameUsingName("photon.browser") { window.center() }
            browser = window
            // The engine re-evaluates daytime / day-of-week playlists only while its UI is closed.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.state.playlists.uiOpen = false
            }
        }
        state.playlists.uiOpen = true
        NSApp.activate(ignoringOtherApps: true)
        browser?.makeKeyAndOrderFront(nil)
    }

    /// What the playback rules are doing right now, for the menu.
    private var autoStateDescription: String? {
        let d = state.decision
        if d.stop { return "Stopped by a playback rule" }
        if state.hostFlags.contains(.asleep) { return "Paused: display asleep" }
        var parts: [String] = []
        if d.pauseMask != 0 {
            parts.append(d.pauseMask == UInt32.max ? "paused (all displays)" : "paused on \(d.pauseMask.nonzeroBitCount) display(s)")
        }
        if d.mute { parts.append("muted") }
        return parts.isEmpty ? nil : "Automatically " + parts.joined(separator: ", ")
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "photon Settings"
            window.contentViewController = NSHostingController(rootView: SettingsView(state: state))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func togglePause() { state.paused.toggle() }
    @objc func nextWallpaper() { state.playlists.next() }
    @objc func previousWallpaper() { state.playlists.previous() }
    /// Tray "Saved Playlists": the playlist goes on every display.
    @objc func loadSavedPlaylist(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let p = state.playlists.saved.first(where: { $0.name == name }) else { return }
        state.playlists.assign(p.json, to: AppState.allDisplays)
    }

    private func label(_ key: String, _ fallback: String) -> String {
        let l = state.strings.label(key)
        return l.isEmpty ? fallback : l.replacingOccurrences(of: "&&", with: "&")
    }

    func applicationWillTerminate(_ notification: Notification) { state.playlists.saveState() }
    @objc func toggleMute() { state.muted.toggle() }
}

if CommandLine.arguments.dropFirst().first == "--version" {
    print("photon \(PhotonVersion.string)")
    exit(0)
}

let home = FileManager.default.homeDirectoryForCurrentUser
// steamcmd's workshop folder (where the Workshop tab downloads to), then CrossOver Steam's; a duplicate id comes from
// the first.
let workshop = WorkshopPaths.steamcmdContent
let engineAssets = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PHOTON_WE_ASSETS"]
    ?? home.appendingPathComponent("Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/common/wallpaper_engine/assets").path)
let install = engineAssets.deletingLastPathComponent()

let state = AppState(engineAssets: engineAssets, libraryDirectories: WorkshopPaths.workshopLibraries + [
    install.appendingPathComponent("projects/defaultprojects"),
    install.appendingPathComponent("projects/myprojects"),
])

if let arg = CommandLine.arguments.dropFirst().first {
    let id = arg.allSatisfy(\.isNumber) ? arg : URL(fileURLWithPath: arg).lastPathComponent
    if state.item(id) == nil {
        print("photon: \(arg) is not in the library (\(workshop.path))")
        exit(1)
    }
    state.apply(id, display: nil)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController(state: state, device: MTLCreateSystemDefaultDevice()!)
app.delegate = controller
app.run()
