import Foundation

/// A wallpaper playlist as wallpaper64.exe holds it (docs/re/09 §9). The JSON form is the engine's: the per-display
/// `selectedwallpapers[monitor].playlist` and the saved `general.playlists[]` entries the UI writes (scripts.js `qe`):
/// `{"name", "settings": {delay, order, mode, transition, transitiontime, transitionpool, videosequence,
/// updateonpause, beginfirst, playintro}, "items": ["file" | {"file", "daytimeend", "preset"}]}`. photon2 stores the
/// library id where the engine stores the path of `project.json`.
///
/// This file is Foundation only, so the scheduler can be compiled and tested on its own (scratchpad `playlist-test`).
package struct EnginePlaylist {
    package struct Item: Equatable {
        package var file: String
        /// Item +0x20: end of the item's slot, a fraction of the day (daytime) or a day count (day of week); 0 = unset.
        package var daytimeEnd: Float = 0
        /// Item +0x28: name of a saved property preset (UI "Choose preset"). Applied on selection through
        /// `Preset_Find` 0x140063f00 (PropertyPresets.swift, `AppState.displayPresets`).
        package var preset: String = ""
        /// `0x140076fd0`: items compare by file + preset.
        package var key: String { file + preset }
    }

    package enum Mode: Int { case logon = 0, timer = 1, daytime = 2, dayOfWeek = 3, never = 4 }

    package struct Flags: OptionSet {
        package let rawValue: Int
        package init(rawValue: Int) { self.rawValue = rawValue }
        package static let videoSequence = Flags(rawValue: 1)   // "videosequence": change when a video ends
        package static let updateOnPause = Flags(rawValue: 2)   // "updateonpause": the timer runs while paused
        package static let beginFirst = Flags(rawValue: 8)      // "beginfirst": start with the first wallpaper (timer only)
        package static let playIntro = Flags(rawValue: 0x10)    // "playintro": first wallpaper at startup only (needs beginFirst)
    }

    package var name = ""
    /// +0x00: every item; +0x18: the random-order pool still to be drawn (a shuffle bag).
    package var items: [Item] = []
    package var pool: [Item] = []
    /// The item entries as read (string or object), one per element of `items`. `json` writes these back rather than
    /// the parsed items, so the ends the parse fills in (daytime gaps, day-of-week shares) stay unset in the stored
    /// playlist, as in the UI's own copy.
    package var rawItems: [Any] = []
    /// +0x30: minutes between changes (ctor 0x140060510: 60).
    package var delay: Float = 60
    /// +0x34: "sorted" = 1, anything else 0 (random).
    package var sorted = false
    /// +0x38. The ctor leaves it unset; it is only read after a parse of a settings object (timer by default).
    package var mode: Mode = .timer
    package var flags: Flags = []
    /// +0x40: next index for sorted order (and the start index picked by the parse).
    package var index = 0
    /// +0x48: the `transition`/`transitiontime`/`transitionpool` members of the settings object, for
    /// `TransitionSettings.parse` (`Transition_ParseSettings` 0x140075790, frame-graph §T1).
    package var transitionSettings: Any?
    /// The settings object as read, written back unchanged by `json` (nil: the playlist had none, which keeps the ctor's
    /// delay 60 and transition −2, so it must not come back as an empty object).
    package var settingsObject: [String: Any]?
    package var settingsJSON: [String: Any] { settingsObject ?? [:] }

    /// `Playlist_Parse` 0x140075a90.
    package static func parse(_ json: [String: Any], random: inout PlaylistRandom) -> EnginePlaylist {
        var p = EnginePlaylist()
        p.name = json["name"] as? String ?? ""
        if let s = json["settings"] as? [String: Any] {
            p.settingsObject = s
            // "delay": any number → float minutes; any other type (absent included) → 0 (0x140075b50–0x140075b85).
            p.delay = Self.number(s["delay"]).map(Float.init) ?? 0
            p.sorted = (s["order"] as? String) == "sorted"
            p.mode = .timer
            if let m = s["mode"] as? String {
                switch m {
                case "logon": p.mode = .logon                         // keeps the delay
                case "daytime": p.mode = .daytime; p.delay = 0
                case "dayofweek": p.mode = .dayOfWeek; p.delay = 0
                case "never": p.mode = .never; p.delay = 0
                default: break
                }
            }
            if Self.bool(s["videosequence"]) == true { p.flags.insert(.videoSequence) }
            if Self.bool(s["updateonpause"]) == true { p.flags.insert(.updateOnPause) }
            if p.mode == .timer, Self.bool(s["beginfirst"]) == true { p.flags.insert(.beginFirst) }
            if p.flags.contains(.beginFirst), Self.bool(s["playintro"]) == true { p.flags.insert(.playIntro) }
            p.transitionSettings = s
        }
        // Items: a string is a file; an object reads file, daytimeend (any number) and preset. Both vectors get every
        // item with a non-empty file (0x140075f0c–0x1400764f6).
        for raw in json["items"] as? [Any] ?? [] {
            var item: Item?
            if let f = raw as? String {
                item = Item(file: f)
            } else if let o = raw as? [String: Any], let f = o["file"] as? String {
                item = Item(file: f, daytimeEnd: Self.number(o["daytimeend"]).map(Float.init) ?? 0, preset: o["preset"] as? String ?? "")
            }
            guard let item, !item.file.isEmpty else { continue }
            p.items.append(item)
            p.pool.append(item)
            p.rawItems.append(raw)
        }
        // The intro wallpaper never enters the random pool (0x1400765d0).
        if p.flags.contains(.playIntro), !p.pool.isEmpty { p.pool.removeFirst() }
        switch p.mode {
        case .dayOfWeek: p.assignDays()
        case .daytime: p.fillDaytimeEnds()
        default: break
        }
        // Fewer than two items is no playlist (0x1400769c6).
        if p.items.count < 2 {
            p.items.removeAll()
            p.rawItems.removeAll()
        } else {
            // Start index: uniform over the items (mt19937, 0x140076a30–0x140076b40), 0 with "beginfirst".
            p.index = p.flags.contains(.beginFirst) ? 0 : random.uniform(p.items.count)
        }
        return p
    }

    /// Day of week (0x140076713–0x1400767d8): the 7 days are split over min(n, 7) items, earlier items rounding down;
    /// each item's end is the running total of the shares.
    package mutating func assignDays() {
        var total = 0
        for i in items.indices {
            let slots = max(min(items.count, 7), 1)
            var remaining = 7, share = 1, k = 0
            while k < slots {
                share = k >= slots - 1 ? remaining : remaining / (slots - k)
                if k == i { break }
                remaining -= share
                k += 1
            }
            total += share
            items[i].daytimeEnd = Float(total)
        }
    }

    /// Time of day (0x1400767dd–0x1400769ab): the last item ends at 1; items without an end share the gap before the
    /// next item that has one evenly.
    package mutating func fillDaytimeEnds() {
        var start: Float = 0, first = 0
        for i in items.indices {
            let end: Float = i == items.count - 1 ? 1 : items[i].daytimeEnd
            guard end > 0 else { continue }
            let count = i - first + 1
            if count > 0, first <= i {
                let step = (end - start) / Float(count)
                for k in first...i { items[k].daytimeEnd = start + Float(k - first + 1) * step }
            }
            first = i + 1
            start = end
        }
    }

    /// Back to the engine's JSON (the UI's `qe`): the settings object and the item entries as read; items built in code
    /// (no raw entries) as strings unless they carry an end or a preset.
    package var json: [String: Any] {
        var o: [String: Any] = ["name": name]
        if let settingsObject { o["settings"] = settingsObject }
        o["items"] = rawItems.count == items.count ? rawItems : items.map { item -> Any in
            if item.daytimeEnd == 0 && item.preset.isEmpty { return item.file }
            var o: [String: Any] = ["file": item.file]
            if item.daytimeEnd != 0 { o["daytimeend"] = Double(item.daytimeEnd) }
            if !item.preset.isEmpty { o["preset"] = item.preset }
            return o
        }
        return o
    }

    package static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, !isBoolean(v, n) else { return nil }
        return n.doubleValue
    }

    package static func bool(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, isBoolean(v, n) else { return nil }
        return n.boolValue
    }

    /// JSON `true`/`false` as opposed to a number. Darwin: the CFBoolean type. swift-corelibs-foundation has no public
    /// CFGetTypeID; a Swift `Bool` or an NSNumber made from one (objCType "c": JSONSerialization's booleans) is a boolean.
    package static func isBoolean(_ v: Any?, _ n: NSNumber) -> Bool {
        #if canImport(Darwin)
        return CFGetTypeID(n) == CFBooleanGetTypeID()
        #else
        if let v, type(of: v) == Bool.self { return true }
        return String(cString: n.objCType) == "c"
        #endif
    }
}

/// The CRT `rand()` the scheduler draws with (0x1402c97a0: x = x·214013 + 2531011, (x >> 16) & 0x7fff) and the start
/// index draw. Seedable so tests are repeatable.
package struct PlaylistRandom {
    package var state: UInt32
    package init(seed: UInt32 = UInt32(truncatingIfNeeded: UInt64(Date().timeIntervalSince1970 * 1000))) { state = seed }
    package mutating func rand() -> Int {
        state = state &* 214013 &+ 2531011
        return Int((state >> 16) & 0x7fff)
    }
    /// Uniform 0..<n (the parse's `uniform_int_distribution`; the engine's generator is mt19937 seeded from the clock).
    package mutating func uniform(_ n: Int) -> Int {
        guard n > 1 else { return 0 }
        return Int(UInt32(rand()) << 15 | UInt32(rand())) % n
    }
}

/// What a display shows from its playlist (`selectedwallpapers` monitor node, map at 0x1404e5328): the playlist at
/// node +0x38, the timer +0x7c, the resume item +0xa0/+0xc0 and the flags +0xe0..+0xe2.
package struct PlaylistRunner {
    package var playlist: EnginePlaylist
    /// +0x7c: seconds since the last change.
    package var elapsed: Float = 0
    /// +0xa0/+0xc0: the item shown before the restart, restored from the saved state (`bin/playliststate.bin`).
    package var resume: EnginePlaylist.Item?
    /// +0xe0: the playlist changes on login (set at startup for mode logon), so the resume item is not kept.
    package var logonPending = false
    /// +0xe1: "beginfirst" at startup: the next pick starts from item 0.
    package var beginFirstPending = false
    /// +0xe2: the intro (first) wallpaper is showing.
    package var introPlaying = false
    /// The wallpaper object on the display (node +0x30): what it shows and whether it is a video (type 4).
    package var current: EnginePlaylist.Item?
    package var currentIsVideo = false

    package init(playlist: EnginePlaylist) { self.playlist = playlist }

    package struct Context {
        /// `0x1400647b0`: a URL or an existing file.
        package var isValid: (EnginePlaylist.Item) -> Bool = { _ in true }
        /// Local time for daytime / day of week.
        package var now: Date = Date()
        package var calendar: Calendar = .current
        /// `0x14003dcf0`: LOCALE_IFIRSTDAYOFWEEK, 0 = Monday … 6 = Sunday.
        package var firstDayOfWeek: Int = PlaylistRunner.localeFirstDayOfWeek()
    }

    /// `Playlist_Select` 0x140067a00: the item the display should show now, or nil to leave it alone. `force` is the
    /// "next wallpaper" command and a newly selected playlist; the timer passes false.
    package mutating func select(force: Bool, context: Context, random: inout PlaylistRandom) -> EnginePlaylist.Item? {
        var pick: EnginePlaylist.Item?
        let items = playlist.items
        switch playlist.mode {
        case .daytime:
            // First item whose end is past the current minute of the day (time + localtime, 0x140067ae5–0x140067bc2).
            let c = context.calendar.dateComponents([.hour, .minute], from: context.now)
            let frac = Float((c.hour ?? 0) * 60 + (c.minute ?? 0)) / 1440
            pick = items.first { $0.daytimeEnd > frac }
            if pick == nil { pick = items.last }
        case .dayOfWeek:
            // GetLocalTime().wDayOfWeek (0 = Sunday) shifted to the locale's first day (0x140067bc7–0x140067c6b).
            let weekday = context.calendar.component(.weekday, from: context.now) - 1 // 0 = Sunday
            let day = (weekday - context.firstDayOfWeek + 6) % 7
            pick = items.first { $0.daytimeEnd > Float(day) }
            if pick == nil { pick = items.last }
        case .logon, .timer, .never:
            guard !items.isEmpty else { return nil }
            if !force {
                if playlist.mode == .logon, current != nil { return nil }
                if playlist.mode == .never { return nil }
            }
            pick = selectSequence(force: force, context: context, random: &random)
        }
        guard let pick else { return nil }
        // The same file and preset as the running wallpaper: nothing to do (0x1400683b4–0x140068449).
        if let current, current.file == pick.file, current.preset == pick.preset { return nil }
        // Switch: the timer restarts (+0x7c = 0, 0x1400684ea).
        elapsed = 0
        current = pick
        return pick
    }

    private mutating func selectSequence(force: Bool, context: Context, random: inout PlaylistRandom) -> EnginePlaylist.Item? {
        // Pool entries that are no longer items are dropped (0x140067ce5–0x140067d76).
        let keys = Set(playlist.items.map(\.key))
        playlist.pool.removeAll { !keys.contains($0.key) }
        let intro = playlist.flags.contains(.playIntro)
        var resumed: EnginePlaylist.Item?
        // The item from before the restart, if it is still in the playlist and valid (0x140067d97–0x140067eb6).
        if let r = resume, !force {
            if let match = playlist.items.first(where: { $0.key == r.key }), context.isValid(match) { resumed = match }
        }
        resume = nil
        let n = playlist.items.count
        if beginFirstPending {
            // "beginfirst" at startup: item 0, or the next valid one (0x140067eb9–0x140067fc7).
            beginFirstPending = false
            introPlaying = intro
            playlist.index = 0
            var pick = playlist.items[0]
            playlist.index = 1
            var tries = n
            while !context.isValid(pick), tries > 0 {
                tries -= 1
                playlist.index %= n
                pick = playlist.items[playlist.index]
                playlist.index += 1
            }
            return pick
        }
        if let resumed, !logonPending { return resumed }
        introPlaying = false
        logonPending = false
        if !playlist.sorted {
            // Random: draw from the pool and remove the draw; refill from the items (without the intro) when empty,
            // and leave out the running wallpaper on a refill when there is more than one candidate
            // (0x140068010–0x14006826a).
            if playlist.pool.isEmpty {
                refillPool(skipIntro: intro)
                let candidates = playlist.items.count - (intro ? 1 : 0)
                if candidates > 1, let current, let i = playlist.pool.firstIndex(where: { $0.key == current.key }) {
                    playlist.pool.remove(at: i)
                }
            }
            guard !playlist.pool.isEmpty else { return nil }
            var pick = drawFromPool(random: &random)
            var refilled = false
            while !context.isValid(pick) {
                if playlist.pool.isEmpty {
                    if refilled { return pick }
                    refilled = true
                    refillPool(skipIntro: false)
                }
                pick = drawFromPool(random: &random)
            }
            return pick
        }
        // Sorted: the next index, skipping the intro when the order wraps to 0 (0x14006826f–0x140068394).
        playlist.index %= n
        if intro, playlist.index == 0, n > 1 { playlist.index = 1 }
        var pick = playlist.items[playlist.index]
        playlist.index += 1
        var tries = n
        while !context.isValid(pick), tries > 0 {
            tries -= 1
            playlist.index %= n
            pick = playlist.items[playlist.index]
            playlist.index += 1
        }
        return pick
    }

    /// `0x140077240`: the items (from the second with "playintro") appended to the pool.
    private mutating func refillPool(skipIntro: Bool) {
        playlist.pool.append(contentsOf: playlist.items.dropFirst(skipIntro ? 1 : 0))
    }

    /// `idx = min(n − 1, (int)(rand() / 32767 · n))`, clamped ≥ 0, then erased from the pool.
    private mutating func drawFromPool(random: inout PlaylistRandom) -> EnginePlaylist.Item {
        let n = playlist.pool.count
        let r = Float(random.rand()) / 32767
        let i = max(min(n - 1, Int(r * Float(n) + 0)), 0)
        return playlist.pool.remove(at: i)
    }

    /// `Playlist_Tick` 0x140076be0, run from the playback evaluator on every `windowupdaterate` tick with
    /// dt = min(time since the last tick, 5 s). Returns true when the display should be re-selected
    /// (`select(force: false)`). `paused`: tray pause (host flags & 1) or the display's bit in the rule pause mask.
    /// `uiOpen`: the engine re-evaluates daytime / day-of-week only while its browser UI is not connected (the tick's
    /// third argument is `ui pipe == -1`, 0x14006dd9a).
    package mutating func tick(dt: Float, paused: Bool, uiOpen: Bool) -> Bool {
        guard !playlist.items.isEmpty else { return false }
        if paused && !playlist.flags.contains(.updateOnPause) { return false }
        switch playlist.mode {
        case .daytime, .dayOfWeek:
            return !uiOpen
        case .logon, .timer, .never:
            let delay = playlist.delay
            guard delay >= 0.01 else { return false }
            elapsed += min(dt, 5)
            guard elapsed / 60 >= delay else { return false }
            // A video changes when it ends instead ("videosequence"), and the intro video plays to its end.
            if current != nil, currentIsVideo {
                if playlist.flags.contains(.videoSequence) || introPlaying { return false }
            }
            return true
        }
    }

    /// `Playlist_OnVideoEnded` 0x140067720: the display's video ended. True when the playlist should move on
    /// (`select(force: false)`): timer mode with "videosequence", or the intro video.
    package func videoEndedShouldAdvance() -> Bool {
        guard !playlist.items.isEmpty else { return false }
        return (playlist.mode == .timer && playlist.flags.contains(.videoSequence))
            || (playlist.flags.contains(.playIntro) && introPlaying)
    }

    /// Whether the tray shows "Next Wallpaper" for this display (0x14002168e–0x1400216b2).
    package var offersNext: Bool { !playlist.items.isEmpty && playlist.mode != .daytime && playlist.mode != .dayOfWeek }

    // MARK: persistence (`bin/playliststate.bin`, `bin/playliststatetime.bin`)

    /// The saved state: the shown item, the sorted index, the random pool and the timer with the wall-clock time it was
    /// saved at (0x14006eef0, 0x140070690).
    package struct Saved: Codable {
        package var file: String, preset: String
        package var index: Int
        package var pool: [[String]]
        package var elapsed: Float
        package var savedAt: Double
    }

    package var saved: Saved {
        Saved(file: current?.file ?? "", preset: current?.preset ?? "", index: playlist.index,
              pool: playlist.pool.map { [$0.file, $0.preset] }, elapsed: elapsed, savedAt: Date().timeIntervalSince1970)
    }

    /// Startup restore (0x14006b2d2–0x14006b5a8, 0x14006bd0f–0x14006be2f): the timer gains the time the app was not
    /// running; the shown item is resumed unless the timer has run out meanwhile; logon mode always changes;
    /// "beginfirst" starts over at item 0.
    package mutating func restore(_ s: Saved?, now: Double = Date().timeIntervalSince1970) {
        if let s {
            elapsed = s.elapsed + Float(max(now - s.savedAt, 0))
            playlist.index = s.index
            resume = s.file.isEmpty ? nil : EnginePlaylist.Item(file: s.file, preset: s.preset)
            if playlist.mode == .timer, elapsed / 60 > playlist.delay { resume = nil }
            let keys = Set(playlist.items.map(\.key))
            playlist.pool = s.pool.compactMap { $0.count == 2 ? EnginePlaylist.Item(file: $0[0], preset: $0[1]) : nil }
                .filter { keys.contains($0.key) }
        }
        logonPending = playlist.mode == .logon
        if playlist.flags.contains(.beginFirst) {
            resume = nil
            logonPending = false
            beginFirstPending = playlist.items.count > 1
        }
    }

    package static func localeFirstDayOfWeek() -> Int {
        // Calendar.firstWeekday: 1 = Sunday … 7 = Saturday → 0 = Monday … 6 = Sunday.
        (Calendar.current.firstWeekday + 5) % 7
    }
}
