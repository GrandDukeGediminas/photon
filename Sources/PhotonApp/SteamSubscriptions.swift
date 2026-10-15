import Foundation

/// The Steam client's local record of the account's Workshop subscriptions: `userdata/<account>/ugc/<appid>_subscriptions.vdf`
/// under each Steam install (the Mac client, CrossOver's Windows client, the Linux client). `431960_subscriptions.vdf`
/// lists Wallpaper Engine items only; `0_subscriptions.vdf` lists subscriptions of every app without saying which, so
/// its ids are checked against `GetPublishedFileDetails` (`consumer_app_id`). The client rewrites these files when it
/// runs; nothing here logs in or reads login data.
package enum SteamSubscriptions {
    package struct Entry: Equatable {
        package let id: String
        package let timeSubscribed: Int
        /// The id came from `0_subscriptions.vdf` only, so its app is not known yet.
        package let mixed: Bool
    }

    package struct Snapshot: Equatable {
        /// Newest subscription first, one entry per id.
        package var entries: [Entry]
        /// The newest `time_last_updated` of the files read (0 when none had it).
        package var lastUpdated: Int
        package var files: [URL]

        package static let empty = Snapshot(entries: [], lastUpdated: 0, files: [])
    }

    /// Steam installs whose `userdata` may hold subscription lists.
    package static var steamRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        return [home.appendingPathComponent("Library/Application Support/Steam"),
                home.appendingPathComponent("Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam"),
                SteamCmdInstaller.directory]
        #else
        return WorkshopPaths.steamcmdRoots + [SteamCmdInstaller.directory]
        #endif
    }

    /// `<root>/userdata/<numeric account id>/ugc/{431960,0}_subscriptions.vdf` that exist, symlinked roots once.
    package static func files(roots: [URL] = steamRoots) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for root in WorkshopPaths.unique(roots) {
            let userdata = root.appendingPathComponent("userdata")
            guard let accounts = try? fm.contentsOfDirectory(atPath: userdata.path) else { continue }
            for account in accounts.sorted() where !account.isEmpty && account.allSatisfy(\.isNumber) && account != "0" {
                for name in ["\(WorkshopPaths.appID)_subscriptions.vdf", "0_subscriptions.vdf"] {
                    let f = userdata.appendingPathComponent("\(account)/ugc/\(name)")
                    if fm.fileExists(atPath: f.path) { out.append(f) }
                }
            }
        }
        return out
    }

    package static func load(files: [URL] = files()) -> Snapshot {
        var byID: [String: Entry] = [:]
        var lastUpdated = 0
        for f in files {
            guard let text = try? String(contentsOf: f, encoding: .utf8), let list = parse(text) else { continue }
            lastUpdated = max(lastUpdated, list.lastUpdated)
            let mixed = list.appID != WorkshopPaths.appID
            for (id, time) in list.items {
                let old = byID[id]
                byID[id] = Entry(id: id, timeSubscribed: max(time, old?.timeSubscribed ?? 0), mixed: mixed && (old?.mixed ?? true))
            }
        }
        let entries = byID.values.sorted { ($0.timeSubscribed, $0.id) > ($1.timeSubscribed, $1.id) }
        return Snapshot(entries: entries, lastUpdated: lastUpdated, files: files)
    }

    /// `"subscribedfiles" { "appid" "…" "time_last_updated" "…" "0" { "publishedfileid" "…" "time_subscribed" "…" } … }`.
    package static func parse(_ text: String) -> (appID: String, lastUpdated: Int, items: [(String, Int)])? {
        guard let root = KeyValues.parse(text), let body = root.first(where: { $0.key == "subscribedfiles" })?.value.children
        else { return nil }
        var appID = "", last = 0, items: [(String, Int)] = []
        for pair in body {
            switch pair.value {
            case .string(let s):
                if pair.key == "appid" { appID = s } else if pair.key == "time_last_updated" { last = Int(s) ?? 0 }
            case .object(let fields):
                guard let id = KeyValues.string(fields, "publishedfileid"), !id.isEmpty else { continue }
                let time: Int = KeyValues.string(fields, "time_subscribed").flatMap { Int($0) } ?? 0
                items.append((id, time))
            }
        }
        return (appID, last, items)
    }
}

/// Valve's text KeyValues (VDF): quoted keys and values, `{ }` blocks, `//` comments. Order is kept.
package enum KeyValues {
    package indirect enum Value: Equatable {
        case string(String)
        case object([Pair])

        package var string: String? { if case .string(let s) = self { return s } else { return nil } }
        package var children: [Pair]? { if case .object(let o) = self { return o } else { return nil } }
    }

    package struct Pair: Equatable {
        package let key: String
        package let value: Value
    }

    /// The string value of `key` in `pairs`.
    package static func string(_ pairs: [Pair], _ key: String) -> String? {
        pairs.first { $0.key == key }?.value.string
    }

    package static func parse(_ text: String) -> [Pair]? {
        var tokens: [String?] = [] // the string, nil for a brace
        var kinds: [Character] = [] // "s" string, "{", "}"
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\"" {
                var s = ""
                var j = text.index(after: i)
                while j < text.endIndex && text[j] != "\"" {
                    if text[j] == "\\", text.index(after: j) < text.endIndex {
                        j = text.index(after: j)
                        switch text[j] { case "n": s.append("\n"); case "t": s.append("\t"); default: s.append(text[j]) }
                    } else {
                        s.append(text[j])
                    }
                    j = text.index(after: j)
                }
                guard j < text.endIndex else { return nil }
                tokens.append(s); kinds.append("s")
                i = text.index(after: j)
            } else if c == "{" || c == "}" {
                tokens.append(nil); kinds.append(c)
                i = text.index(after: i)
            } else if c == "/", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "/" {
                i = text[i...].firstIndex(of: "\n") ?? text.endIndex
            } else {
                i = text.index(after: i)
            }
        }
        var pos = 0
        func block(top: Bool) -> [Pair]? {
            var out: [Pair] = []
            while pos < kinds.count {
                if kinds[pos] == "}" {
                    if top { return nil }
                    pos += 1
                    return out
                }
                guard kinds[pos] == "s", let key = tokens[pos] else { return nil }
                pos += 1
                guard pos < kinds.count else { return nil }
                if kinds[pos] == "s" {
                    out.append(Pair(key: key, value: .string(tokens[pos] ?? "")))
                    pos += 1
                } else if kinds[pos] == "{" {
                    pos += 1
                    guard let inner = block(top: false) else { return nil }
                    out.append(Pair(key: key, value: .object(inner)))
                } else {
                    return nil
                }
            }
            return top ? out : nil
        }
        return block(top: true)
    }
}
