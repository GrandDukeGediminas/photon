#if os(Linux)
import CGtk3
import Combine
import CPhotonApp
import Foundation
import PhotonApp
import PhotonRender

/// `photon-linux app`: the Linux counterpart of the macOS menu-bar app (Sources/photon/main.swift; docs/linux-port.md
/// §6.1). The model is PhotonApp's AppState (settings in `~/.config/photon2/photon2.plist`, the keys of the macOS
/// defaults domain), the windows are GTK 3, the status icon is a StatusNotifierItem, and the wallpapers run in desktop
/// host processes (HostSupervisor).
///
///     photon-linux app [--background] [--no-hosts] [--self-test OUTDIR] [workshop id | wallpaper directory]
///       --background   start with no window (login autostart, the systemd user unit); the status icon opens them
///       --no-hosts     the UI and the model only (nothing is drawn on the desktop)
///       --self-test    drive browse → apply → properties → playlist → settings → tray, screenshot each step into OUTDIR
///                      and check the persisted settings (exit status 0 when every check passed)
final class LinuxApp {
    let state: AppState
    let defaults: UserDefaults
    let supervisor: HostSupervisor
    let executable: String
    private(set) var tray: Tray?
    private(set) var browser: BrowserWindow?
    private(set) var settings: SettingsWindow?
    private(set) var workshopWindow: WorkshopWindow?
    private var subscriptions: Set<AnyCancellable> = []
    private lazy var trayRefresh = Debouncer(ms: 100) { [weak self] in self?.tray?.rebuild() }
    nonisolated(unsafe) static var current: LinuxApp?

    init(defaults: UserDefaults, executable: String, hosts: Bool) {
        self.defaults = defaults
        self.executable = executable
        let workshop = LibraryPaths.workshop(defaults)
        let assets = LibraryPaths.engineAssets(defaults)
        // Displays: the outputs the desktop hosts cover, by connector name.
        let outputs = HostSupervisor.listOutputs(executable: executable)
        DisplayInfo.provider = { outputs }
        state = AppState(engineAssets: assets, libraryDirectories: LibraryPaths.libraryDirectories(workshop: workshop, engineAssets: assets),
                         defaults: defaults)
        supervisor = HostSupervisor(state: state, executable: executable)
        supervisor.enabled = hosts
        print("photon: \(state.items.count) wallpapers (workshop \(workshop.path), engine assets \(assets.path)), "
              + "displays: \(state.displays.map(\.id).joined(separator: ", ")); settings \((defaults as? XDGDefaults)?.fileURL.path ?? "defaults")")
    }

    /// Wallpaper Engine ownership (`OwnershipCheck`): nothing starts until the Steam account passed it.
    lazy var ownership = OwnershipCheck(workshop: state.workshop, defaults: defaults)
    private var ownershipWindow: OwnershipWindow?
    private(set) var started = false

    /// `start` once the account owns Wallpaper Engine: at once after a recent success (re-checked in the background when
    /// a week old; only a definite "not owned" then quits), else after the ownership window's check passes.
    func startWhenOwned(showBrowser: Bool) {
        LinuxApp.current = self
        if ownership.mayStart {
            start(showBrowser: showBrowser)
            if ownership.dueForRecheck {
                ownership.check { [weak self] status in
                    guard status == .notOwned else { return }
                    print("photon: this Steam account doesn't own Wallpaper Engine; quitting")
                    self?.quit()
                }
            }
        } else {
            ownershipWindow = OwnershipWindow(app: self) { [weak self] in
                self?.ownershipWindow = nil
                self?.start(showBrowser: showBrowser)
            }
        }
    }

    func start(showBrowser: Bool) {
        guard !started else { return }
        started = true
        LinuxApp.current = self
        AudioSystem.shared.pollPeriodMs = AudioSystem.pollPeriod(fps: state.fps)
        photon_css_apply(Self.css)
        tray = Tray(app: self)
        state.objectWillChange.sink { [weak self] in self?.trayRefresh.poke() }.store(in: &subscriptions)
        state.playlists.objectWillChange.sink { [weak self] in self?.trayRefresh.poke() }.store(in: &subscriptions)
        supervisor.onStatus = { [weak self] in self?.trayRefresh.poke(); self?.settings?.refreshStatus() }
        // Monitor hotplug: re-read the hosts' outputs.
        if let display = gdk_display_get_default() {
            let refresh = { [weak self] in
                guard let self else { return }
                after(500) {
                    let outputs = HostSupervisor.listOutputs(executable: self.executable)
                    DisplayInfo.provider = { outputs }
                    self.state.refreshDisplays()
                }
            }
            on1(display, "monitor-added") { _ in refresh() }
            on1(display, "monitor-removed") { _ in refresh() }
        }
        state.playlists.start()
        supervisor.reconcile()
        if showBrowser || (state.activeIDs.isEmpty && !(tray?.visible ?? false)) { self.showBrowser() }
        // Without a StatusNotifierWatcher (GNOME without the AppIndicator extension) the browser is the only way in.
        after(3000) { [weak self] in
            guard let self, let tray = self.tray, !tray.visible, self.browser == nil else { return }
            print("photon: no status icon host (StatusNotifierWatcher) on the session bus; showing the browser")
            self.showBrowser()
        }
    }

    func showBrowser(startupID: String? = nil) {
        if browser == nil { browser = BrowserWindow(app: self) }
        state.playlists.uiOpen = true
        browser?.present(startupID: startupID)
    }

    /// A second `photon-linux app` launch (single instance, D-Bus `Activate`): apply the wallpaper it names, and raise
    /// the browser unless it was a `--background` start (login autostart while the app already runs).
    func activated(by args: [String], token: String) {
        guard started else { return }
        let background = args.contains("--background")
        print("photon: activated by another launch (\(args.isEmpty ? "no arguments" : args.joined(separator: " ")))")
        if let target = args.first(where: { !$0.hasPrefix("-") }) {
            let id = target.allSatisfy(\.isNumber) ? target : URL(fileURLWithPath: target).lastPathComponent
            if state.item(id) != nil { state.apply(id, display: nil) } else { print("photon: \(target) is not in the library") }
        }
        if !background { showBrowser(startupID: token) }
    }

    /// The bus name of the running instance (the Flatpak's application id).
    static let instanceName = "io.github.photon2.Photon"
    static let instancePath = "/io/github/photon2/Photon"
    nonisolated(unsafe) static var pendingActivations: [([String], String)] = []

    func browserClosed() { state.playlists.uiOpen = false }

    private(set) var signInWindow: SteamSignInWindow?

    /// steamcmd setup and Steam sign-in (SteamSignInWindow).
    func showSignIn() {
        if signInWindow == nil { signInWindow = SteamSignInWindow(workshop: state.workshop) }
        signInWindow?.present()
    }

    /// The Steam Workshop browser (WorkshopWindow).
    func showWorkshop() {
        if workshopWindow == nil { workshopWindow = WorkshopWindow(app: self) }
        workshopWindow?.present()
    }

    func showSettings() {
        if settings == nil { settings = SettingsWindow(app: self) }
        settings?.present()
    }

    func quit() {
        state.playlists.saveState()
        supervisor.stopAll()
        // Let the hosts read `quit` before the pipes close with the process.
        after(200) { gtk_main_quit() }
    }

    /// What the playback rules are doing (macOS `autoStateDescription`), from the hosts' last report.
    var autoStateDescription: String? {
        if state.paused { return nil }
        let s = supervisor.status
        if s.isEmpty || s.hasSuffix("resumed") || s.hasPrefix("resume") || s == "unmute" { return nil }
        return "Automatically: " + s
    }

    func label(_ key: String, _ fallback: String) -> String {
        let l = state.strings.label(key)
        return l.isEmpty || l == key ? fallback : l.replacingOccurrences(of: "&&", with: "&")
    }

    /// The executable path (`/proc/self/exe`), for the host processes and autostart entries.
    static var selfPath: String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = readlink("/proc/self/exe", &buf, buf.count - 1)
        return n > 0 ? String(cString: buf) : CommandLine.arguments[0]
    }

    static let css = """
    .photon-tile { padding: 6px; border-radius: 8px; border: 2px solid transparent; }
    flowboxchild:selected .photon-tile { border-color: @theme_selected_bg_color; }
    flowboxchild:selected { background: transparent; }
    flowboxchild:selected label { color: @theme_fg_color; }
    .photon-active-badge { color: white; background: @theme_selected_bg_color; border-radius: 9px; padding: 0 5px; font-weight: bold; }
    .photon-failed-badge { color: black; background: #f5c211; border-radius: 9px; padding: 0 5px; }
    .photon-caption { font-size: smaller; }
    .photon-dim { opacity: 0.65; }
    .photon-title { font-weight: bold; font-size: larger; }
    .photon-section { font-weight: bold; margin-top: 8px; }
    .photon-warning { color: #c64600; }
    .photon-error { color: #c01c28; }
    .photon-playlist-item { padding: 2px; }
    """

    // MARK: - Command

    static func main(_ args: [String]) -> Int32 {
        var rest = Array(args.dropFirst()) // "app"
        var background = false, hosts = true
        var selfTest: String?
        var target: String?
        while !rest.isEmpty {
            let a = rest.removeFirst()
            switch a {
            case "--background": background = true
            case "--no-hosts": hosts = false
            case "--self-test": selfTest = rest.isEmpty ? "/tmp/photon-app-selftest" : rest.removeFirst()
            case "-h", "--help":
                print("usage: photon-linux app [--background] [--no-hosts] [--self-test OUTDIR] [workshop id | wallpaper directory]")
                return 0
            default: target = a
            }
        }
        setlinebuf(stdout)
        var argc: Int32 = 0
        guard gtk_init_check(&argc, nil) != 0 else {
            FileHandle.standardError.write(Data("photon: cannot open a display (DISPLAY / WAYLAND_DISPLAY)\n".utf8))
            return 1
        }
        // Single instance: the first `photon-linux app` owns io.github.photon2.Photon on the session bus; a second launch
        // hands it its arguments and activation token and exits (the self-test and PHOTON_SINGLE_INSTANCE=0 skip this).
        if selfTest == nil, ProcessInfo.processInfo.environment["PHOTON_SINGLE_INSTANCE"] != "0" {
            let claimed = photon_instance_claim(instanceName, instancePath, { _, argv, n, token in
                let args = (0..<Int(n)).compactMap { argv?[$0].map { String(cString: $0) } }
                let t = token.map { String(cString: $0) } ?? ""
                if let app = LinuxApp.current { app.activated(by: args, token: t) } else { LinuxApp.pendingActivations.append((args, t)) }
            }, nil)
            if claimed == 0 {
                let env = ProcessInfo.processInfo.environment
                let token = env["XDG_ACTIVATION_TOKEN"] ?? env["DESKTOP_STARTUP_ID"] ?? ""
                let forwarded = Array(args.dropFirst())
                var cArgs = forwarded.map { strdup($0) } + [nil]
                defer { cArgs.forEach { free($0) } }
                let ok = cArgs.withUnsafeMutableBufferPointer { buf in
                    buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) {
                        photon_instance_activate(instanceName, instancePath, $0, Int32(forwarded.count), token)
                    }
                }
                print(ok != 0 ? "photon: already running; activated the running instance" : "photon: another instance owns \(instanceName) but did not answer")
                return ok != 0 ? 0 : 1
            }
            if claimed < 0 { print("photon: no session bus; not checking for a running instance") }
        }
        g_set_prgname("photon2")
        g_set_application_name("photon")
        gtk_window_set_default_icon_name("photon2")
        FoundationPump.start()
        let defaults: UserDefaults
        if let dir = selfTest {
            // The self-test never touches the user's settings: its own config folder under OUTDIR.
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defaults = XDGDefaults(directory: URL(fileURLWithPath: dir).appendingPathComponent("config"))!
        } else {
            defaults = XDGDefaults()!
        }
        let app = LinuxApp(defaults: defaults, executable: selfPath, hosts: hosts)
        if let target {
            let id = target.allSatisfy(\.isNumber) ? target : URL(fileURLWithPath: target).lastPathComponent
            if app.state.item(id) == nil {
                print("photon: \(target) is not in the library")
                return 1
            }
            app.state.apply(id, display: nil)
        }
        // The self-test runs on stand-in assets without a Steam account (its settings live in OUTDIR and it quits when done).
        if selfTest != nil { app.start(showBrowser: false) } else { app.startWhenOwned(showBrowser: !background) }
        for (a, t) in pendingActivations { app.activated(by: a, token: t) }
        pendingActivations = []
        var status: Int32 = 0
        if let dir = selfTest {
            let test = AppSelfTest(app: app, outDir: URL(fileURLWithPath: dir))
            test.run { failures in
                status = failures == 0 ? 0 : 1
                app.quit()
            }
        }
        // SIGTERM / SIGINT (systemd stop, Ctrl-C): stop the hosts and leave the main loop.
        for sig in [SIGTERM, SIGINT] {
            g_unix_signal_add_full(G_PRIORITY_DEFAULT, sig, { _ in
                LinuxApp.current?.quit()
                return 0
            }, nil, nil)
        }
        gtk_main()
        app.state.playlists.saveState()
        return status
    }
}
#endif
