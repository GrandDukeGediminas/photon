#if os(Linux)
import Foundation
import PhotonApp

/// Where the Linux app finds wallpapers (docs/linux-port.md §6.1). Steam runs Wallpaper Engine through Proton; its
/// Workshop items for app 431960 land in `<steam>/steamapps/workshop/content/431960` and the install (with `assets`,
/// `projects/defaultprojects` and the locale strings) in `<steam>/steamapps/common/wallpaper_engine`. Steam's root is
/// `~/.local/share/Steam` (native), `~/.steam/steam` (a symlink most distributions create, or the Debian package's
/// root), or `~/.var/app/com.valvesoftware.Steam/.local/share/Steam` (Flatpak). The install directory can be set by
/// hand for a standalone copy or one in another library folder (the `weinstalldir` / `workshopdir` settings, Linux only).
enum LibraryPaths {
    static let workshopKey = "workshopdir"
    static let installKey = "weinstalldir"

    /// Steam roots in preference order, existing ones only.
    static var steamRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [".local/share/Steam", ".steam/steam", ".steam/root", ".var/app/com.valvesoftware.Steam/.local/share/Steam",
                          ".var/app/com.valvesoftware.Steam/data/Steam"].map { home.appendingPathComponent($0) }
        var seen = Set<String>(), out: [URL] = []
        for c in candidates {
            let r = c.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: r.appendingPathComponent("steamapps").path), seen.insert(r.path).inserted else { continue }
            out.append(r)
        }
        return out
    }

    /// Library folders of a Steam root (`steamapps/libraryfolders.vdf` "path" entries), the root first.
    static func libraryFolders(_ root: URL) -> [URL] {
        var out = [root]
        if let text = try? String(contentsOf: root.appendingPathComponent("steamapps/libraryfolders.vdf"), encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "\"").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if parts.count >= 2, parts[0] == "path" {
                    let u = URL(fileURLWithPath: parts[1])
                    if !out.contains(where: { $0.standardizedFileURL == u.standardizedFileURL }) { out.append(u) }
                }
            }
        }
        return out
    }

    static func detectWorkshop() -> URL? {
        for root in steamRoots {
            for lib in libraryFolders(root) {
                let d = lib.appendingPathComponent("steamapps/workshop/content/431960")
                if FileManager.default.fileExists(atPath: d.path) { return d }
            }
        }
        return nil
    }

    static func detectInstall() -> URL? {
        for root in steamRoots {
            for lib in libraryFolders(root) {
                let d = lib.appendingPathComponent("steamapps/common/wallpaper_engine")
                if FileManager.default.fileExists(atPath: d.appendingPathComponent("assets").path) { return d }
            }
        }
        return nil
    }

    /// The workshop folder: PHOTON_WORKSHOP, the saved setting, Steam's, or `~/.local/share/Steam/…` (shown as missing).
    static func workshop(_ defaults: UserDefaults) -> URL {
        if let p = ProcessInfo.processInfo.environment["PHOTON_WORKSHOP"], !p.isEmpty { return URL(fileURLWithPath: p) }
        if let p = defaults.string(forKey: workshopKey), !p.isEmpty { return URL(fileURLWithPath: p) }
        return detectWorkshop() ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/Steam/steamapps/workshop/content/431960")
    }

    /// The engine's `assets` folder: PHOTON_WE_ASSETS, `<saved install>/assets`, Steam's, or photon's own copy (downloaded
    /// at setup, EngineFiles).
    static func engineAssets(_ defaults: UserDefaults) -> URL {
        if let p = ProcessInfo.processInfo.environment["PHOTON_WE_ASSETS"], !p.isEmpty { return URL(fileURLWithPath: p) }
        if let p = defaults.string(forKey: installKey), !p.isEmpty { return URL(fileURLWithPath: p).appendingPathComponent("assets") }
        return (detectInstall() ?? EngineFiles.installDirectory).appendingPathComponent("assets")
    }

    /// The library folders AppState scans: the workshop, then the install's default and own projects (as on macOS), and
    /// PHOTON_LIBRARY (colon-separated extra folders, e.g. the redistributable test scenes).
    static func libraryDirectories(workshop: URL, engineAssets: URL) -> [URL] {
        let install = engineAssets.deletingLastPathComponent()
        // The chosen workshop folder first, then steamcmd's and other Steam roots' (a duplicate id comes from the first).
        var dirs = WorkshopPaths.unique([workshop] + WorkshopPaths.workshopLibraries)
            + [install.appendingPathComponent("projects/defaultprojects"), install.appendingPathComponent("projects/myprojects")]
        if let extra = ProcessInfo.processInfo.environment["PHOTON_LIBRARY"] {
            dirs += extra.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        return dirs
    }
}
#endif
