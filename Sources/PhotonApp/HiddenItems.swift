import Foundation

/// The content filter hook: workshop ids listed in a blocklist file never appear in the library, in playlists or in
/// Workshop results, and are never downloaded. The file is `~/Library/Application Support/photon2/hidden.json` on macOS
/// and `~/.config/photon2/hidden.json` (`$XDG_CONFIG_HOME/photon2`) on Linux.
///
/// Accepted forms: an array of ids (strings or numbers), `{"ids": [...]}` / `{"hidden": [...]}` / `{"items": [...]}`, an
/// array of objects with an `id` or `publishedfileid`, or an object keyed by id (`{"123": true, ...}`; a false value is
/// not hidden). Anything that isn't an id is ignored, and a missing or unreadable file hides nothing.
package enum HiddenItems {
    package static var defaultFile: URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/photon2/hidden.json")
        #else
        let env = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let base = env.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("photon2/hidden.json")
        #endif
    }

    package static func load(_ url: URL?) -> Set<String> {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return parse(data)
    }

    package static func parse(_ data: Data) -> Set<String> {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return [] }
        return ids(in: json)
    }

    private static func ids(in json: Any) -> Set<String> {
        if let list = json as? [Any] {
            var out = Set<String>()
            for entry in list {
                if let id = id(entry) {
                    out.insert(id)
                } else if let o = entry as? [String: Any], let id = (o["id"] ?? o["publishedfileid"]).flatMap(id) {
                    out.insert(id)
                }
            }
            return out
        }
        if let o = json as? [String: Any] {
            for key in ["ids", "hidden", "items"] { if let list = o[key] { return ids(in: list) } }
            return Set(o.compactMap { k, v -> String? in
                guard isID(k) else { return nil }
                if let b = v as? Bool { return b ? k : nil }
                return k
            })
        }
        return []
    }

    private static func id(_ v: Any) -> String? {
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespaces)
            return isID(t) ? t : nil
        }
        if let n = v as? NSNumber, !(v is Bool) {
            let i = n.int64Value
            return i > 0 ? String(i) : nil
        }
        return nil
    }

    private static func isID(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy(\.isASCII) && s.allSatisfy(\.isNumber) }
}

/// Where Wallpaper Engine workshop items live on this machine (app 431960).
package enum WorkshopPaths {
    package static let appID = "431960"

    /// steamcmd's own install root: `+workshop_download_item` puts items in `<root>/steamapps/workshop/content/431960`.
    /// On macOS that is `~/Library/Application Support/Steam`; on Linux it depends on how steamcmd was installed, so the
    /// candidates are tried (the download output names the real folder, which DownloadQueue then remembers).
    package static var steamcmdRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        return [home.appendingPathComponent("Library/Application Support/Steam")]
        #else
        return [".local/share/Steam", ".steam/steam", ".steam/steamcmd", "Steam", "steamcmd", ".steam/root",
                ".var/app/com.valvesoftware.Steam/.local/share/Steam"].map { home.appendingPathComponent($0) }
        #endif
    }

    package static func contentDirectory(steamRoot: URL) -> URL {
        steamRoot.appendingPathComponent("steamapps/workshop/content/\(appID)")
    }

    /// The default folder steamcmd downloads into (the first root).
    package static var steamcmdContent: URL { contentDirectory(steamRoot: steamcmdRoots[0]) }

    /// CrossOver's Steam bottle (macOS): items the Windows Steam client downloaded.
    package static var crossOverContent: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/\(appID)")
    }

    /// Workshop folders to scan, existing or not on macOS (steamcmd's first, so its copy wins a duplicate id), existing
    /// ones only on Linux; symlinked duplicates removed.
    package static var workshopLibraries: [URL] {
        // steamcmd that photon set up itself (SteamCmdInstaller) keeps its downloads in its own folder.
        let own = contentDirectory(steamRoot: SteamCmdInstaller.directory)
        let ownIfPresent = FileManager.default.fileExists(atPath: own.path) ? [own] : []
        #if os(macOS)
        return unique([steamcmdContent, crossOverContent] + ownIfPresent)
        #else
        return unique(steamcmdRoots.map(contentDirectory).filter { FileManager.default.fileExists(atPath: $0.path) } + ownIfPresent)
        #endif
    }

    /// The same folders without symlink aliases, order kept.
    package static func unique(_ dirs: [URL]) -> [URL] {
        var seen = Set<String>(), out: [URL] = []
        for d in dirs where seen.insert(d.resolvingSymlinksInPath().standardizedFileURL.path).inserted { out.append(d) }
        return out
    }

    /// `content/431960/<id>` → `downloads/431960/<id>`: where steamcmd stages an item while it downloads.
    package static func stagingDirectory(content: URL, id: String) -> URL {
        content.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("downloads/\(appID)/\(id)")
    }

    /// The install time Steam recorded for an item: `timeupdated` in `workshop/appworkshop_431960.acf` next to the content
    /// folder, else the item's project.json modification time.
    package static func installedTime(id: String, directory: URL) -> Int? {
        let acf = directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("appworkshop_\(appID).acf")
        if let text = try? String(contentsOf: acf, encoding: .utf8), let t = acfTimeUpdated(text, id: id) { return t }
        let attrs = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("project.json").path)
        return (attrs?[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970) }
    }

    /// `"WorkshopItemsInstalled" { "<id>" { "size" "…" "timeupdated" "…" } }` → timeupdated.
    package static func acfTimeUpdated(_ text: String, id: String) -> Int? {
        guard let installed = text.range(of: "\"WorkshopItemsInstalled\"") else { return nil }
        let rest = text[installed.upperBound...]
        guard let key = rest.range(of: "\"\(id)\"") else { return nil }
        let block = rest[key.upperBound...]
        guard let close = block.firstIndex(of: "}") else { return nil }
        let body = block[..<close]
        guard let t = body.range(of: "\"timeupdated\"") else { return nil }
        let value = body[t.upperBound...].split(separator: "\"", omittingEmptySubsequences: true)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return value.flatMap { Int($0) }
    }
}
