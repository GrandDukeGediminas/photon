import Foundation

/// The wallpaperconfig `profile` object (docs/re/09 §8.3): the multi-monitor arrangement the engine's `Layout_Compute`
/// (0x1400740d0) reads on every config load (0x14006a4f8: `profile` of `wallpaperconfig`, or of `wallpaperconfigvd<id>`
/// when that virtual-desktop config exists, 0x140045d75–0x140045f43). Monitors are named by their key (the engine's
/// monitor "location"; photon2's display key: the macOS display UUID, the Linux connector name).
///
/// - `source` (string): layout 2 ("Clone single wallpaper") clone source; a name that matches locks it.
/// - `monitorconfig.<monitor>.flip` (bool true; `Layout_ReadCloneFlip` 0x140061a10 needs an object and a JSON boolean)
///   mirrors that monitor's clone horizontally.
/// - `groups.<name>`: `monitors` (array of names; a non-array drops the group), `layout` (an int, else 1: 1 stretch,
///   2 clone; any other value spans like 1), `source`, `monitorconfig` (same flip rule) — `Layout_ApplyGroups` 0x140061b50.
/// - `splits.<key>`: `direction` (an int; 1 cuts top / bottom, anything else left / right), `position` (a number in
///   (0, 1), read as float); children are `<key>/L` and `<key>/R` and can be split again — `Layout_ApplySplit`
///   0x140061280.
///
/// Groups and splits are only read with layout 0 (0x140074ad0). The UI edits the profile with the rules of `scripts.js`
/// (`callbackCreateGroup`, `callbackRemoveGroup`, `Bt` clone flip, `clone_set_source`, `Tt` split removal), reproduced
/// below; it sends the whole object back with `updateProfile` (wallpaperui.exe), the engine recomputes the layout.
package struct MonitorProfile: Equatable {
    package struct Group: Equatable {
        package var monitors: [String]
        package var layout: Int
        package var source: String
        package var flip: Set<String>

        package init(monitors: [String], layout: Int = 1, source: String = "", flip: Set<String> = []) {
            self.monitors = monitors
            self.layout = layout
            self.source = source
            self.flip = flip
        }

        /// Clone group (layout 2); every other layout value spans.
        package var isClone: Bool { layout == 2 }
    }

    package struct Split: Equatable {
        /// 1: a horizontal cut (`/L` on top, `/R` below); anything else: a vertical cut (`/L` left, `/R` right).
        package var direction: Int
        /// Where the cut is, as a fraction of the parent's width or height, in (0, 1).
        package var position: Double

        package init(direction: Int, position: Double) {
            self.direction = direction
            self.position = position
        }
    }

    package var source: String
    package var flip: Set<String>
    package var groups: [String: Group]
    package var splits: [String: Split]

    package init(source: String = "", flip: Set<String> = [], groups: [String: Group] = [:], splits: [String: Split] = [:]) {
        self.source = source
        self.flip = flip
        self.groups = groups
        self.splits = splits
    }

    package var isEmpty: Bool { source.isEmpty && flip.isEmpty && groups.isEmpty && splits.isEmpty }

    // MARK: JSON (the engine's key names)

    /// Reads a profile object with the engine's type rules (jsoncpp: a boolean is not an int, `flip` must be a boolean).
    package init(json: Any?) {
        self.init()
        guard let o = json as? [String: Any] else { return }
        source = (o["source"] as? String) ?? ""
        flip = Self.flips(o["monitorconfig"])
        for (name, v) in (o["groups"] as? [String: Any]) ?? [:] {
            guard let g = v as? [String: Any], let monitors = g["monitors"] as? [Any] else { continue }
            groups[name] = Group(monitors: monitors.compactMap { $0 as? String }, layout: Self.int(g["layout"]) ?? 1,
                                 source: (g["source"] as? String) ?? "", flip: Self.flips(g["monitorconfig"]))
        }
        for (key, v) in (o["splits"] as? [String: Any]) ?? [:] {
            guard let s = v as? [String: Any], let d = Self.int(s["direction"]), let p = Self.number(s["position"]) else { continue }
            splits[key] = Split(direction: d, position: p)
        }
    }

    /// The profile object as the UI writes it.
    package var json: [String: Any] {
        var o: [String: Any] = [:]
        if !source.isEmpty { o["source"] = source }
        if !flip.isEmpty { o["monitorconfig"] = Self.monitorConfig(flip) }
        if !groups.isEmpty {
            o["groups"] = groups.mapValues { g -> [String: Any] in
                var j: [String: Any] = ["monitors": g.monitors, "layout": g.layout]
                if !g.source.isEmpty { j["source"] = g.source }
                if !g.flip.isEmpty { j["monitorconfig"] = Self.monitorConfig(g.flip) }
                return j
            }
        }
        if !splits.isEmpty { o["splits"] = splits.mapValues { ["direction": $0.direction, "position": $0.position] } }
        return o
    }

    private static func monitorConfig(_ flip: Set<String>) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: flip.map { ($0, ["flip": true] as [String: Any]) })
    }

    private static func flips(_ v: Any?) -> Set<String> {
        guard let mc = v as? [String: Any] else { return [] }
        return Set(mc.compactMap { k, v in
            guard let f = (v as? [String: Any])?["flip"], isBool(f), (f as? Bool) == true else { return nil }
            return k
        })
    }

    static func isBool(_ v: Any) -> Bool {
        #if canImport(Darwin)
        return CFGetTypeID(v as AnyObject) == CFBooleanGetTypeID()
        #else
        return type(of: v) == Bool.self
        #endif
    }

    /// jsoncpp `isInt` (0x1400886e0): an int, or a real that is integral and in the int range; not a boolean.
    static func int(_ v: Any?) -> Int? {
        guard let v, !isBool(v) else { return nil }
        if let i = v as? Int { return i }
        guard let d = (v as? NSNumber)?.doubleValue, d >= -2147483648, d <= 2147483647, d.rounded(.towardZero) == d else { return nil }
        return Int(d)
    }

    /// A JSON number (jsoncpp types 1–3), not a boolean.
    static func number(_ v: Any?) -> Double? {
        guard let v, !isBool(v) else { return nil }
        return (v as? NSNumber)?.doubleValue
    }

    // MARK: UI edits (scripts.js)

    /// "Lock as clone source" (`ui_browse_monitors_clone_set_source`): the monitor becomes the source and loses its flip.
    /// nil = "unlock" (`clone_remove_source`): the size / orientation rule picks again.
    package mutating func setSource(_ monitor: String?) {
        source = monitor ?? ""
        if let monitor { flip.remove(monitor) }
    }

    /// `ui_browse_monitors_clone_flip` (`Bt`): flipping the locked source unlocks it; when every monitor would be flipped
    /// the first other one is unflipped again (`clone_flip_limitation`: a clone needs an unflipped source). Returns
    /// whether that limitation applied.
    @discardableResult
    package mutating func toggleFlip(_ monitor: String, among monitors: [String]) -> Bool {
        var s = source, f = flip
        let hit = Self.toggle(monitor, source: &s, flip: &f, among: monitors)
        source = s; flip = f
        return hit
    }

    package mutating func setGroupSource(_ group: String, _ monitor: String?) {
        guard var g = groups[group] else { return }
        g.source = monitor ?? ""
        if let monitor { g.flip.remove(monitor) }
        groups[group] = g
    }

    @discardableResult
    package mutating func toggleGroupFlip(_ group: String, _ monitor: String) -> Bool {
        guard var g = groups[group] else { return false }
        let hit = Self.toggle(monitor, source: &g.source, flip: &g.flip, among: g.monitors)
        groups[group] = g
        return hit
    }

    private static func toggle(_ m: String, source: inout String, flip: inout Set<String>, among monitors: [String]) -> Bool {
        if m == source { source = "" }
        if flip.contains(m) { flip.remove(m) } else { flip.insert(m) }
        guard !monitors.isEmpty, monitors.allSatisfy({ flip.contains($0) }) else { return false }
        if let other = monitors.first(where: { $0 != m }) { flip.remove(other) }
        return true
    }

    /// The group a monitor belongs to (the UI's `At`: the last group listing it).
    package func group(containing monitor: String) -> String? {
        groups.keys.sorted().last { groups[$0]!.monitors.contains(monitor) }
    }

    /// "Add stretch group" / "Add clone group" (`callbackCreateGroup`): at least two selected entries (monitor keys or
    /// group names). A stretch group first removes the selected monitors' splits. When an entry is a group or in one,
    /// that group takes the new layout and the selection's monitors, and the other selected groups are removed;
    /// otherwise a new group `group_<hashCode of the concatenated keys>` (a random name on a clash). Returns the group.
    @discardableResult
    package mutating func createGroup(_ selection: [String], layout: Int) -> String? {
        guard selection.count >= 2 else { return nil }
        if layout != 2 { for e in selection where groups[e] == nil { removeSplits(rootedAt: e) } }
        let current = self
        let target = selection.lazy.compactMap { e -> String? in current.groups[e] != nil ? e : current.group(containing: e) }.first
        if let name = target, var g = groups[name] {
            g.layout = layout
            for e in selection {
                for m in groups[e]?.monitors ?? [e] where !g.monitors.contains(m) { g.monitors.append(m) }
            }
            groups[name] = g
            for e in selection where e != name && groups[e] != nil { groups[e] = nil }
            return name
        }
        var name = "group_\(Self.hashCode(selection.joined()))"
        while groups[name] != nil {
            name = "group_" + String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement()! })
        }
        groups[name] = Group(monitors: selection, layout: layout)
        return name
    }

    /// "Remove group" (`callbackRemoveGroup`): the group itself, or the group containing the monitor.
    package mutating func removeGroup(_ entry: String) {
        if groups[entry] != nil { groups[entry] = nil } else if let g = group(containing: entry) { groups[g] = nil }
    }

    /// `Tt`: removes the split of `key` and every split below it (`key` followed only by `/`, `L`, `R`).
    package mutating func removeSplits(rootedAt key: String) {
        for k in splits.keys where k.hasPrefix(key) && k.dropFirst(key.count).allSatisfy({ $0 == "/" || $0 == "L" || $0 == "R" }) {
            splits[k] = nil
        }
    }

    // MARK: split edits (scripts.js `callbackSplitSelectedMonitor`, `Rt`, `callbackSplitDblClick`, `callbackRemoveSplit`)

    /// `BrowseSplitMonitorModalCtrl.ok`: the dialog edits the position in pixels of the region's width (direction 0,
    /// "vertical": `/L` left) or height (1, "horizontal": `/L` on top); it is floored, clamped to [1, size − 1] and stored
    /// as a fraction of the size. A missing value is the middle (`floor(size / 2)`).
    package static func splitFraction(pixels: Double?, size: Int) -> Double {
        guard size > 1 else { return 0.5 }
        let half = Double(size / 2)
        let p = min(max(1, (pixels ?? half).rounded(.down)), Double(size - 1))
        return p / Double(size)
    }

    /// The pixel position the dialog shows for a split: `floor(position · size)`.
    package static func splitPixels(_ position: Double, size: Int) -> Int { Int((position * Double(size)).rounded(.down)) }

    /// "Add split" (`callbackSplitSelectedMonitor`, offered on a monitor or a split region that is not a group and not in
    /// one): `splits.<key>` = the dialog's `{direction, position}` (default `{0, 0.5}`). The region becomes `<key>/L` and
    /// `<key>/R`.
    package mutating func addSplit(_ key: String, direction: Int = 0, position: Double = 0.5) {
        splits[key] = Split(direction: direction, position: position)
    }

    /// Moving a divider (`Rt`): the split takes `position`; a split of its `/R` child with the same direction keeps its
    /// absolute position, a = p + (1 − p)·r, so r' = (a − new) / (1 − new). Returns false when `key` has no split.
    @discardableResult
    package mutating func moveSplit(_ key: String, to position: Double) -> Bool {
        guard let s = splits[key] else { return false }
        if var r = splits[key + "/R"], r.direction == s.direction {
            let a = s.position + (1 - s.position) * r.position
            r.position = (a - position) / (1 - position)
            splits[key + "/R"] = r
        }
        splits[key]?.position = position
        return true
    }

    /// "Edit split" (`callbackSplitDblClick`): the same direction moves the divider (`Rt`); another direction replaces
    /// the split's direction and position (`angular.merge`).
    package mutating func editSplit(_ key: String, direction: Int, position: Double) {
        guard let s = splits[key] else { return }
        if s.direction == direction { moveSplit(key, to: position) } else { splits[key] = Split(direction: direction, position: position) }
    }

    /// "Remove split" on a region (`callbackRemoveSplit`, `<key>/L` or `<key>/R`): the split of its parent and every split
    /// below it (`Tt`). Returns the parent.
    @discardableResult
    package mutating func removeSplit(region: String) -> String? {
        guard let parent = Self.splitParent(region) else { return nil }
        removeSplits(rootedAt: parent)
        return parent
    }

    /// "Remove all splits" on a region (`Tt(rootLocation)`): every split of its monitor.
    package mutating func removeAllSplits(region: String) { removeSplits(rootedAt: Self.splitRoot(region)) }

    /// `<key>/L` or `<key>/R` → `<key>`; nil for a monitor key.
    package static func splitParent(_ region: String) -> String? {
        guard region.hasSuffix("/L") || region.hasSuffix("/R") else { return nil }
        return String(region.dropLast(2))
    }

    /// The monitor a region lies on (the UI's `rootLocation`).
    package static func splitRoot(_ key: String) -> String {
        var k = key
        while let p = splitParent(k) { k = p }
        return k
    }

    /// `String.prototype.hashCode` of scripts.js: h = 31·h + UTF-16 unit, wrapped to int32.
    package static func hashCode(_ s: String) -> Int32 {
        var h: Int32 = 0
        for u in s.utf16 { h = h &* 31 &+ Int32(u) }
        return h
    }
}

/// The monitor records `Layout_Compute` (0x1400740d0) builds from the layout and the profile, and what each display
/// shows (docs/re/09 §8.3). Rectangles are in the platform's global layout coordinates (macOS points, X11 / Wayland
/// logical pixels); the size / orientation rule compares pixel sizes, as the engine's monitor rectangles are physical
/// pixels.
package struct LayoutPlan: Equatable {
    package struct Monitor: Equatable {
        package var key: String
        package var rect: CGRect
        /// Pixels per layout unit (the backing scale).
        package var scale: CGFloat

        package init(key: String, rect: CGRect, scale: CGFloat = 1) {
            self.key = key
            self.rect = rect
            self.scale = scale
        }
    }

    /// A monitor record (map 0x1404e5368): +0x50 group id (nil = 0xff), +0x51 monitor index, +0x52 split id, +0x53 flags
    /// (bit 0 skipped: no wallpaper of its own; bit 1 a group or split record; bit 2 flipped clone), +0x54 group layout,
    /// +0x58 rectangle.
    package struct Record: Equatable {
        package var key: String
        package var index: Int
        package var group: Int?
        package var splitID = 0
        package var skipped = false
        package var virtual = false
        package var flip = false
        package var groupLayout = 0
        package var rect: CGRect
        package var scale: CGFloat
        /// The physical monitor the record lies on (itself, or a split's monitor; nil for a group record).
        package var physical: String?

        package var pixelSize: (w: Int, h: Int) {
            (max(Int((rect.width * scale).rounded()), 0), max(Int((rect.height * scale).rounded()), 0))
        }
    }

    package enum Kind: String, Equatable {
        /// A monitor with its own wallpaper.
        case display
        /// A split region of a monitor.
        case split
        /// One wallpaper over several monitors (layout 1, or a stretch group): its window covers the union rectangle.
        case span
        /// One wallpaper shown on several monitors (layout 2, or a clone group): it renders on the source monitor, the
        /// others get a `CreateClone` of its window (cover fit, optional mirror; cloneextensions64 0x180007090).
        case clone
    }

    /// A wallpaper instance: a record that is not skipped (`App_LoadDesktopWallpaper` 0x140072a70 loads one per record,
    /// 0x14007344a). `key` is the config key of its wallpaper (`selectedwallpapers.<key>`): a monitor, a split
    /// (`<monitor>/L`…) or a group name; with layout 1 and 2 the first monitor's.
    package struct Instance: Equatable {
        package var key: String
        package var kind: Kind
        /// Where its window is (span: the union; clone: the source monitor's rectangle).
        package var rect: CGRect
        /// The physical monitor that renders it (clone: the source; span: the member with the lowest index).
        package var host: String
        /// Physical monitors showing it, in monitor order.
        package var members: [String]
        /// Render size in pixels (span: the union at the members' smallest scale; otherwise the host's region).
        package var pixelSize: CGSize
        package var name: String
    }

    /// What part of an instance a display shows where: `source` and `target` are UV rectangles (origin top-left) of the
    /// instance's frame and of the display. A clone target's source is the cover fit; `flip` mirrors it.
    package struct Tile: Equatable {
        package var display: String
        package var instance: String
        package var source: CGRect
        package var target: CGRect
        package var flip: Bool
        package var isClone: Bool
    }

    package var layout: Int
    package var records: [Record]
    package var instances: [Instance]
    package var tiles: [Tile]
    /// The physical monitors' rectangles by key (what tile targets are relative to).
    package var monitorRects: [String: CGRect] = [:]

    package func instance(_ key: String) -> Instance? { instances.first { $0.key == key } }
    package func tiles(for display: String) -> [Tile] { tiles.filter { $0.display == display } }

    private static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    // MARK: Layout_Compute

    package static func compute(layout: Int, profile: MonitorProfile, monitors: [Monitor], names: [String: String] = [:]) -> LayoutPlan {
        var records = monitors.enumerated().map { i, m in
            Record(key: m.key, index: i, rect: m.rect, scale: m.scale, physical: m.key)
        }
        var cloneSource: String?
        switch layout {
        case 1:
            // 0x140074257–0x14007434d: the record with index 0 gets the union of every rectangle, the others are skipped.
            if let first = records.first {
                let box = records.dropFirst().reduce(first.rect) { $0.union($1.rect) }
                for i in records.indices { if records[i].index == 0 { records[i].rect = box } else { records[i].skipped = true } }
            }
        case 2:
            if !records.isEmpty {
                let r = cloneAll(&records, profile: profile)
                cloneSource = r
            }
        default:
            applySplits(&records, profile: profile, monitors: monitors)
            applyGroups(&records, profile: profile)
        }
        var plan = LayoutPlan(layout: layout, records: records, instances: [], tiles: [])
        plan.monitorRects = Dictionary(monitors.map { ($0.key, $0.rect) }, uniquingKeysWith: { a, _ in a })
        plan.build(monitors: monitors, cloneSource: cloneSource, flips: profile.flip, names: names)
        return plan
    }

    /// Layout 2 (0x14007435b–0x140074a49): the source monitor, then monitor 0's record takes the source's rectangle
    /// (the wallpaper renders there, keyed by monitor 0) and the source's record takes monitor 0's rectangle as a clone
    /// target; flip bits are swapped with them, so every physical monitor keeps its own. Every record but monitor 0 is
    /// skipped. Returns the physical source.
    private static func cloneAll(_ records: inout [Record], profile: MonitorProfile) -> String {
        for i in records.indices { records[i].flip = profile.flip.contains(records[i].key) }
        let zero = records.firstIndex { $0.index == 0 }!
        var best = zero
        var landscape = isLandscape(records[zero])
        var bestFlipped = records[zero].flip
        var locked = false
        for i in records.indices {
            let r = records[i]
            let (w, h) = r.pixelSize
            let firstLandscape = !landscape && w >= h
            landscape = landscape || w >= h
            let cond = !landscape || w >= h
            if !profile.source.isEmpty, r.key == profile.source {
                best = i; bestFlipped = false; locked = true
                continue
            }
            if locked || r.flip { continue }
            if (cond && area(r) > area(records[best])) || firstLandscape || bestFlipped {
                best = i; bestFlipped = false
            }
        }
        let source = records[best].key
        for i in records.indices { records[i].skipped = records[i].index != 0 }
        if best != zero {
            let zeroRect = records[zero].rect, zeroScale = records[zero].scale, zeroFlip = records[zero].flip
            records[zero].rect = records[best].rect
            records[zero].scale = records[best].scale
            records[zero].flip = records[best].flip
            records[zero].physical = source
            records[best].rect = zeroRect
            records[best].scale = zeroScale
            records[best].flip = zeroFlip
            records[best].physical = records[zero].key
        }
        return source
    }

    /// `Layout_ApplySplit` (0x140061280), for each physical monitor with an object at `splits.<monitor>` whose record is
    /// not skipped (0x140074b50–0x140074c44): split ids count from 1 per monitor.
    private static func applySplits(_ records: inout [Record], profile: MonitorProfile, monitors: [Monitor]) {
        for m in monitors {
            guard let split = profile.splits[m.key], let i = records.firstIndex(where: { $0.key == m.key }), !records[i].skipped else { continue }
            var counter = 0
            split1(&records, key: m.key, split: split, parent: records[i], parentIndex: i, profile: profile, counter: &counter)
        }
    }

    /// One split: position must be in (0, 1) (read as float), d = int(position · size) of the parent's pixel width
    /// (direction ≠ 1) or height (1); `/L` keeps the first d, `/R` the rest. The parent is skipped; a child with its own
    /// `splits` entry is split again instead of being added (an invalid entry there drops that child).
    private static func split1(_ records: inout [Record], key: String, split: MonitorProfile.Split, parent: Record, parentIndex: Int?,
                               profile: MonitorProfile, counter: inout Int) {
        let p = Float(split.position)
        guard p > 0, p < 1 else { return }
        if let parentIndex { records[parentIndex].skipped = true }
        var l = parent, r = parent
        l.key = key + "/L"; r.key = key + "/R"
        l.splitID = counter + 1; r.splitID = counter + 2
        counter += 2
        l.virtual = true; r.virtual = true
        l.skipped = false; r.skipped = false
        let (pw, ph) = parent.pixelSize
        if split.direction == 1 {
            let d = CGFloat(Int(p * Float(ph))) / parent.scale
            l.rect.size.height = d
            r.rect.origin.y += d; r.rect.size.height -= d
        } else {
            let d = CGFloat(Int(p * Float(pw))) / parent.scale
            l.rect.size.width = d
            r.rect.origin.x += d; r.rect.size.width -= d
        }
        for child in [l, r] {
            if let s = profile.splits[child.key] {
                split1(&records, key: child.key, split: s, parent: child, parentIndex: nil, profile: profile, counter: &counter)
            } else if let j = records.firstIndex(where: { $0.key == child.key }) {
                records[j] = child
            } else {
                records.append(child)
            }
        }
    }

    /// `Layout_ApplyGroups` (0x140061b50): groups in key order (jsoncpp's sorted members). Members are looked up by key and
    /// must exist and not be skipped (a monitor in an earlier group, a split parent). A group with at least one member
    /// becomes a record keyed by its name: index = the lowest member index, layout 1 (or anything but 2) the union of
    /// the members, layout 2 the clone source's rectangle. Members are skipped, get the group id and their flip from
    /// the group's `monitorconfig`.
    private static func applyGroups(_ records: inout [Record], profile: MonitorProfile) {
        var gid = 0
        for name in profile.groups.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
            let g = profile.groups[name]!
            var members: [Int] = []
            var minIndex = 0xff
            var rect: CGRect?
            var scale: CGFloat = 1
            var landscape = false, locked = false
            var bestArea = 0
            for key in g.monitors {
                guard let i = records.firstIndex(where: { $0.key == key }), !records[i].skipped, !members.contains(i) else { continue }
                members.append(i)
                let r = records[i]
                minIndex = min(minIndex, r.index)
                if g.isClone {
                    let (w, h) = r.pixelSize
                    let firstLandscape = !landscape && w >= h
                    landscape = landscape || w >= h
                    let cond = !landscape || w >= h
                    func take() { rect = r.rect; scale = r.scale; bestArea = area(r) }
                    if !g.source.isEmpty, r.key == g.source { take(); locked = true; continue }
                    if locked || g.flip.contains(r.key) { continue }
                    let a = area(r)
                    if firstLandscape { take() } else if a > bestArea || (a == bestArea && r.index == minIndex) { if cond { take() } }
                } else {
                    rect = rect.map { $0.union(r.rect) } ?? r.rect
                    scale = members.count == 1 ? r.scale : min(scale, r.scale)
                }
            }
            guard !members.isEmpty else { continue }
            // Every member flipped and no `source` (the UI's `Bt` prevents it): the engine keeps its empty start rectangle
            // (0x1fffffff…, 0xe0000000…), so the group window is off-screen and every member a clone of nothing. photon2
            // uses the first member as the source instead.
            if rect == nil { rect = records[members[0]].rect; scale = records[members[0]].scale }
            for i in members {
                records[i].skipped = true
                records[i].group = gid
                records[i].flip = g.flip.contains(records[i].key)
            }
            records.append(Record(key: name, index: minIndex, group: gid, skipped: false, virtual: true, groupLayout: g.layout,
                                  rect: rect!, scale: scale, physical: nil))
            gid += 1
        }
    }

    private static func isLandscape(_ r: Record) -> Bool { let (w, h) = r.pixelSize; return w >= h }
    private static func area(_ r: Record) -> Int { let (w, h) = r.pixelSize; return w * h }

    // MARK: instances and tiles

    private mutating func build(monitors: [Monitor], cloneSource: String?, flips: Set<String>, names: [String: String]) {
        let order = Dictionary(monitors.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { a, _ in a })
        let physicalRect = Dictionary(monitors.map { ($0.key, $0.rect) }, uniquingKeysWith: { a, _ in a })
        func rel(_ r: CGRect, in box: CGRect) -> CGRect {
            guard box.width > 0, box.height > 0 else { return Self.unit }
            return CGRect(x: (r.minX - box.minX) / box.width, y: (r.minY - box.minY) / box.height,
                          width: r.width / box.width, height: r.height / box.height)
        }
        func name(_ key: String) -> String { names[key] ?? key }

        switch layout {
        case 1 where !monitors.isEmpty:
            let r = records.first { $0.index == 0 }!
            let minScale = monitors.map(\.scale).min() ?? 1
            instances = [Instance(key: r.key, kind: .span, rect: r.rect, host: monitors[0].key, members: monitors.map(\.key),
                                  pixelSize: Self.clampedSize(r.rect, minScale), name: name(r.key))]
            tiles = monitors.map { Tile(display: $0.key, instance: r.key, source: rel($0.rect, in: r.rect), target: Self.unit, flip: false, isClone: false) }
        case 2 where !monitors.isEmpty:
            let zero = records.first { $0.index == 0 }!
            let src = cloneSource ?? zero.key
            let srcMonitor = monitors.first { $0.key == src }!
            instances = [Instance(key: zero.key, kind: .clone, rect: srcMonitor.rect, host: src, members: monitors.map(\.key),
                                  pixelSize: Self.pixels(srcMonitor.rect, srcMonitor.scale), name: name(zero.key))]
            let aspect = Self.aspect(srcMonitor.rect)
            tiles = monitors.map { m in
                if m.key == src { return Tile(display: m.key, instance: zero.key, source: Self.unit, target: Self.unit, flip: false, isClone: false) }
                return Tile(display: m.key, instance: zero.key, source: LayoutGeometry.coverUV(source: aspect, target: Self.aspect(m.rect)),
                            target: Self.unit, flip: flips.contains(m.key), isClone: true)
            }
        default:
            for r in records where !r.skipped {
                if let phys = r.physical {
                    // A monitor or a split region.
                    instances.append(Instance(key: r.key, kind: r.virtual ? .split : .display, rect: r.rect, host: phys, members: [phys],
                                              pixelSize: Self.pixels(r.rect, r.scale),
                                              name: r.virtual ? "\(name(phys)) Split \(r.splitID)" : name(r.key)))
                    tiles.append(Tile(display: phys, instance: r.key, source: Self.unit, target: rel(r.rect, in: physicalRect[phys] ?? r.rect),
                                      flip: false, isClone: false))
                    continue
                }
                // A group record.
                let members = records.filter { $0.group == r.group && $0.skipped && $0.physical != nil }
                let physicals = Array(Set(members.compactMap(\.physical))).sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
                let clone = r.groupLayout == 2
                let host = clone ? (members.first { $0.rect == r.rect }?.physical ?? physicals.first ?? "")
                    : (members.min { $0.index < $1.index }?.physical ?? "")
                let minScale = members.map(\.scale).min() ?? 1
                let label = "Group (" + members.map { m in m.virtual ? name(m.physical!) + m.key.dropFirst(m.physical!.count) : name(m.key) }
                    .joined(separator: ", ") + ")"
                instances.append(Instance(key: r.key, kind: clone ? .clone : .span, rect: r.rect, host: host, members: physicals,
                                          pixelSize: clone ? Self.pixels(r.rect, r.scale) : Self.clampedSize(r.rect, minScale),
                                          name: names[r.key] ?? label))
                for m in members {
                    let target = rel(m.rect, in: physicalRect[m.physical!] ?? m.rect)
                    if !clone || m.rect == r.rect {
                        tiles.append(Tile(display: m.physical!, instance: r.key, source: clone ? Self.unit : rel(m.rect, in: r.rect),
                                          target: target, flip: false, isClone: false))
                    } else {
                        // Group clone targets: members whose rectangle differs from the group's (0x140075319–0x140075361).
                        tiles.append(Tile(display: m.physical!, instance: r.key,
                                          source: LayoutGeometry.coverUV(source: Self.aspect(r.rect), target: Self.aspect(m.rect)),
                                          target: target, flip: m.flip, isClone: true))
                    }
                }
            }
        }
        instances.sort { (order[$0.host] ?? 0, $0.key) < (order[$1.host] ?? 0, $1.key) }
    }

    private static func aspect(_ r: CGRect) -> CGFloat { r.height > 0 ? r.width / r.height : 1 }
    private static func pixels(_ r: CGRect, _ s: CGFloat) -> CGSize {
        CGSize(width: max((r.width * s).rounded(), 2), height: max((r.height * s).rounded(), 2))
    }
    /// The span frame: the union at the smallest backing scale, clamped to 16384 on its longer side.
    private static func clampedSize(_ r: CGRect, _ s: CGFloat) -> CGSize {
        var w = r.width * s, h = r.height * s
        if w > 16384 || h > 16384 { let k = 16384 / max(w, h); w *= k; h *= k }
        return CGSize(width: max(w.rounded(), 2), height: max(h.rounded(), 2))
    }

    // MARK: what the hosts do

    /// How one display is drawn by a renderer that has one window per display: its own wallpaper (`key`), a part of a
    /// shared instance frame that `host` renders, or several regions (`composite`: split regions, and split regions that
    /// are members of a group), each tile's instance in its target rectangle.
    package enum Role: Equatable {
        case own(key: String)
        case shared(instance: Instance, tile: Tile, isHost: Bool)
        case composite(tiles: [Tile])
    }

    package func role(_ display: String) -> Role {
        let mine = tiles(for: display)
        guard let t = mine.first else { return .own(key: display) }
        guard mine.count == 1, t.target == Self.unit, let inst = instance(t.instance) else { return .composite(tiles: mine) }
        switch inst.kind {
        case .display, .split: return .own(key: inst.key)
        case .span, .clone:
            if inst.members.count < 2 { return .own(key: inst.key) }
            return .shared(instance: inst, tile: t, isHost: inst.host == display)
        }
    }

    /// Whether a tile's instance is drawn once for several displays (a stretch or clone over two or more monitors).
    package func isShared(_ inst: Instance) -> Bool { (inst.kind == .span || inst.kind == .clone) && inst.members.count >= 2 }

    /// A tile's target in the display's layout units, relative to the display's origin (rounded).
    package func regionRect(_ t: Tile) -> CGRect {
        let m = monitorRects[t.display] ?? .zero
        let x0 = (t.target.minX * m.width).rounded(), y0 = (t.target.minY * m.height).rounded()
        let x1 = (t.target.maxX * m.width).rounded(), y1 = (t.target.maxY * m.height).rounded()
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// One desktop-host process per shared instance and per display or split region otherwise (Linux HostSupervisor): its
    /// outputs, its wallpaper key, `--layout`, `--clone-source`, `--clone-flip`, and `--region` for the outputs it covers
    /// only in part (a split region: the host's surface on that output is the region's rectangle).
    package struct HostGroup: Equatable {
        package var key: String
        package var outputs: [String]
        package var layout: Int
        package var cloneSource: String?
        package var flips: [String]
        /// Output → the region's rectangle relative to the output (layout units); absent: the whole output.
        package var regions: [String: CGRect] = [:]
    }

    package func hostGroups(displays: [String]) -> [HostGroup] {
        var out: [HostGroup] = []
        func join(_ inst: Instance, _ d: String, _ t: Tile, region: CGRect?) {
            if let i = out.firstIndex(where: { $0.key == inst.key && $0.layout != 0 }) {
                guard !out[i].outputs.contains(d) else { return }
                out[i].outputs.append(d)
                if t.flip { out[i].flips.append(d) }
                if let region { out[i].regions[d] = region }
            } else {
                out.append(HostGroup(key: inst.key, outputs: [d], layout: inst.kind == .span ? 1 : 2,
                                     cloneSource: inst.kind == .clone ? inst.host : nil, flips: t.flip ? [d] : [],
                                     regions: region.map { [d: $0] } ?? [:]))
            }
        }
        for d in displays {
            switch role(d) {
            case .own(let key):
                out.append(HostGroup(key: key, outputs: [d], layout: 0, cloneSource: nil, flips: []))
            case .shared(let inst, let t, _):
                join(inst, d, t, region: nil)
            case .composite(let tiles):
                for t in tiles {
                    guard let inst = instance(t.instance) else { continue }
                    if isShared(inst) {
                        join(inst, d, t, region: regionRect(t))
                    } else {
                        out.append(HostGroup(key: inst.key, outputs: [d], layout: 0, cloneSource: nil, flips: [], regions: [d: regionRect(t)]))
                    }
                }
            }
        }
        return out
    }
}
