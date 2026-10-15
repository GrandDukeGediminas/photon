import AppKit
import Foundation
import PhotonCore

/// Media integration for SceneScript (docs/re/08 §7, docs/re/script-api.md "Media").
///
/// In Wallpaper Engine the data comes from `winrtutil64.exe -mediainterface` (WinRT
/// GlobalSystemMediaTransportControlsSession, `RunMediaInterface` 0x140031fb0) through `mediaextensions64.dll`
/// into a per-scene session (binding manager +0x140), created when a script exports any media hook (mask bits
/// 14–18, `0x140177cf0`). Events are queued with flags 0x10 status, 0x4 playback, 0x1 properties, 0x2 thumbnail,
/// 0x8 timeline and drained at the start of `Bindings_Tick` 0x140171440.
///
/// Thumbnail colours are computed by winrtutil (0x140046c20): three dominant colours from an HSV histogram
/// (0x140065590, `MediaColors.dominant`), then `highContrastColor` = black if the WCAG contrast of the primary
/// colour against black is >= 2.5, else white; `textColor` = secondary if its contrast with the primary is >= 2.5
/// and higher than the tertiary's, else tertiary if that is >= 2.5, else highContrastColor (contrast 0x14002db80).
///
/// Sources here: `PHOTON_MEDIA=<file.json>` replays a scripted list of events on the scene clock (synthetic
/// tests); otherwise macOS Now Playing (private MediaRemote framework) is polled once a second. Recent macOS
/// releases only answer MediaRemote for entitled processes; then no session is reported (status stays disabled),
/// which is what WE shows with media integration turned off.
final class ScriptMedia {
    struct Event {
        var flags = 0
        var enabled = false
        var state = 0
        var props: [String: String] = [:]
        var thumb = false
        var colors: [UInt32] = [0, 0, 0, 0, 0]
        var position: Float = 0
        var duration: Float = 0
        /// The thumbnail as the session stores it (+0x108: straight RGBA, width, height), after the Spotify rule.
        var image: (pixels: Data, width: Int, height: Int)?

        var js: [String: Any] {
            ["flags": flags, "enabled": enabled, "state": state, "props": props, "thumb": thumb,
             "colors": colors.map { NSNumber(value: $0) }, "position": Double(position), "duration": Double(duration)]
        }
    }

    /// `$mediaThumbnail` user-property value of the current thumbnail ("mediaThumbnail_<n>.system"), and the
    /// previous one (session +0x8 / serial +0x4, Bindings_Tick 0x14017174f–0x140171aa1).
    private(set) var thumbnailName = ""
    private(set) var previousThumbnailName = ""
    private var serial = 0
    /// Session +0x108 / +0x160: the current and previous thumbnail images (Bindings_Tick 0x140171681–0x1401716aa moves
    /// the current one to +0x160 before storing the new one).
    private(set) var image: (pixels: Data, width: Int, height: Int)?
    private(set) var previousImage: (pixels: Data, width: Int, height: Int)?

    /// UserTexture ctor `system` branch (0x1400ebbfc–0x1400ebc37): a name equal to the current texture name gets the
    /// current image, any other name the previous one; an empty image or a zero size fails.
    func systemImage(_ name: String) -> (pixels: Data, width: Int, height: Int)? {
        let img = name == thumbnailName ? image : previousImage
        guard let img, !img.pixels.isEmpty, img.width > 0, img.height > 0 else { return nil }
        return img
    }

    private var scripted: [(time: Float, event: Event)] = []
    private var scriptedIndex = 0
    private let live: NowPlayingPoller?

    init() {
        let env = ProcessInfo.processInfo.environment["PHOTON_MEDIA"]
        if let path = env, path != "off", path != "live" {
            live = nil
            scripted = Self.loadScript(path)
        } else if env == "off" || (env == nil && SceneScriptEngine.simulatedClock) {
            // Offline renders (photon-tool) stay deterministic unless PHOTON_MEDIA=live.
            live = nil
        } else {
            live = NowPlayingPoller()
        }
    }

    /// Events due at scene time `time`; thumbnail events also advance the `$mediaThumbnail` names.
    func poll(time: Float) -> [Event] {
        var out: [Event] = []
        while scriptedIndex < scripted.count, scripted[scriptedIndex].time <= time {
            out.append(scripted[scriptedIndex].event)
            scriptedIndex += 1
        }
        if let live { out.append(contentsOf: live.drain()) }
        for e in out where e.flags & 2 != 0 {
            previousImage = image
            image = e.image
            previousThumbnailName = thumbnailName
            thumbnailName = "mediaThumbnail_\(serial).system"
            serial += 1
        }
        return out
    }

    /// User-property entries the session adds (`{"value": name}` only, no `type`).
    var userProperties: [String: Any] {
        var d: [String: Any] = [:]
        if !thumbnailName.isEmpty { d["$mediaThumbnail"] = ["value": thumbnailName] }
        if !previousThumbnailName.isEmpty { d["$mediaPreviousThumbnail"] = ["value": previousThumbnailName] }
        return d
    }

    /// winrtutil64.exe thumbnail handler 0x140046c20: decode, the Spotify rule (0x140047de1–0x140048235) for an app id
    /// whose lower-cased form starts with "spotify", then the colours from the processed pixels; the processed image is
    /// what the session stores (re-encoded as PNG, `image/png`, then decoded by the exe).
    static func thumbnail(_ data: Data, app: String, into e: inout Event) {
        #if os(Linux)
        // LinuxCompat's NSImage(data:) does not decode; the colour pass gets what MediaColors.rgba draws on macOS:
        // premultiplied RGBA as 0xAABBGGRR words, from the same straight pixels.
        guard let straight = TexFile.decodeStraightRGBA(data) else { return }
        var px = MediaColors.premultipliedWords(straight.pixels, width: straight.width, height: straight.height)
        #else
        guard let img = NSImage(data: data), var px = MediaColors.rgba(img),
              let straight = TexFile.decodeStraightRGBA(data) else { return }
        #endif
        var bytes = [UInt8](straight.pixels)
        var w = straight.width, h = straight.height
        if app.lowercased().hasPrefix("spotify") {
            var pm = px.data.withUnsafeBytes { [UInt8]($0) }
            var pw = px.width, ph = px.height
            spotifyRule(&pm, &pw, &ph)
            spotifyRule(&bytes, &w, &h)
            px = (pm.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }, pw, ph)
        }
        e.thumb = true
        e.colors = MediaColors.palette(px.data, width: px.width, height: px.height)
        e.image = (Data(bytes), w, h)
    }

    /// The Spotify rule on RGBA8 rows (alpha at byte 3). Probe dx = (int)(w·0.06), row = (int)(h·0.4). When the pixels
    /// (row, dx) and (row, w − dx) are both transparent, scan from (row, dx) rightwards for at most w/2 pixels to the first
    /// non-transparent one at x0; if found with 0 ≤ x0 < 0.4·w and 0 ≤ cut = 2·x0 − w + h < 0.4·h, keep the top-left
    /// aligned (w − 2·x0) × (h − cut) block starting at column x0 (a square: the cover without its transparent frame).
    /// Otherwise, when pixel (0, w/2) is transparent, every pixel with alpha < 255 in rows 77…226, columns 44…255
    /// becomes (a, a, a, 255). The engine indexes those rows/columns without a bounds check; smaller images are left
    /// unchanged here.
    static func spotifyRule(_ px: inout [UInt8], _ w: inout Int, _ h: inout Int) {
        guard w > 0, h > 0, px.count >= w * h * 4 else { return }
        func alpha(_ i: Int) -> UInt8 { px[i * 4 + 3] }
        let dx = Int(Float(w) * 0.06), row = Int(Float(h) * 0.4), half = w >> 1
        if alpha(row * w + dx) == 0 && alpha((row + 1) * w - dx) == 0 {
            var n = half, i = row * w + dx
            while alpha(i) == 0 && n > 0 { i += 1; n -= 1 }
            guard n != 0 else { return }
            let x0 = dx - n + half
            guard x0 >= 0, Float(x0) < Float(w) * 0.4 else { return }
            let cut = 2 * x0 - w + h
            guard cut >= 0, Float(cut) < Float(h) * 0.4 else { return }
            let nw = w - 2 * x0, nh = h - cut
            var out = [UInt8](repeating: 0, count: nw * nh * 4)
            for y in 0..<nh {
                let src = (y * w + x0) * 4
                out.replaceSubrange(y * nw * 4..<(y + 1) * nw * 4, with: px[src..<src + nw * 4])
            }
            px = out; w = nw; h = nh
            return
        }
        guard alpha(half) == 0, h >= 227, w >= 256 else { return }
        for y in 77..<227 {
            for x in 44..<256 {
                let o = (y * w + x) * 4, a = px[o + 3]
                if a < 255 { px[o] = a; px[o + 1] = a; px[o + 2] = a; px[o + 3] = 255 }
            }
        }
    }

    /// `PHOTON_MEDIA` file: `[{"time": s, "status": bool, "playback": int, "properties": {title, artist, …},
    /// "thumbnail": {"file": path} | {"colors": [u32 × 5], "has": bool}, "timeline": {"position", "duration"}}]`.
    static func loadScript(_ path: String) -> [(time: Float, event: Event)] {
        guard let d = FileManager.default.contents(atPath: path),
              let list = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else {
            NSLog("photon: PHOTON_MEDIA %@ unreadable", path)
            return []
        }
        var out: [(Float, Event)] = []
        for item in list {
            var e = Event()
            if let s = item["status"] as? Bool { e.flags |= 0x10; e.enabled = s }
            if let p = item["playback"] as? NSNumber { e.flags |= 0x4; e.state = p.intValue }
            if let p = item["properties"] as? [String: Any] {
                e.flags |= 0x1
                for (k, v) in p { e.props[k] = "\(v)" }
            }
            if let t = item["thumbnail"] as? [String: Any] {
                e.flags |= 0x2
                if let f = t["file"] as? String, let data = FileManager.default.contents(atPath: f) {
                    Self.thumbnail(data, app: t["app"] as? String ?? "", into: &e)
                } else {
                    e.thumb = (t["has"] as? Bool) ?? false
                    e.colors = ((t["colors"] as? [NSNumber]) ?? []).map { $0.uint32Value }
                    while e.colors.count < 5 { e.colors.append(0) }
                }
            }
            if let t = item["timeline"] as? [String: Any] {
                e.flags |= 0x8
                e.position = (t["position"] as? NSNumber)?.floatValue ?? 0
                e.duration = (t["duration"] as? NSNumber)?.floatValue ?? 0
            }
            out.append(((item["time"] as? NSNumber)?.floatValue ?? 0, e))
        }
        return out.sorted { $0.0 < $1.0 }
    }
}

#if !os(Linux) // Linux: NowPlayingPoller in Linux/LinuxMedia.swift (MPRIS, docs/linux-port.md §5.1)
/// macOS Now Playing through MediaRemote (private framework, resolved at runtime). Mapping to the WinRT session:
/// status = a now-playing client exists; playback = rate > 0 ? playing (1) : paused (2), no info → stopped (0);
/// properties: Title → title, Artist → artist, Album → albumTitle, Genre → genres (WinRT-only fields stay "");
/// thumbnail = ArtworkData; timeline = ElapsedTime / Duration.
final class NowPlayingPoller {
    private typealias GetInfo = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private let getInfo: GetInfo?
    private typealias GetPID = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
    private let getPID: GetPID?
    private var pid: Int32 = 0
    private let queue = DispatchQueue(label: "photon.nowplaying")
    private let lock = NSLock()
    private var pending: [ScriptMedia.Event] = []
    private var last: (enabled: Bool, state: Int, props: [String: String], art: Int, elapsed: Double, stamp: Double, dur: Float)
        = (false, 0, [:], 0, 0, 0, 0)
    private var timer: DispatchSourceTimer?

    init() {
        let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
        getInfo = h.flatMap { dlsym($0, "MRMediaRemoteGetNowPlayingInfo") }.map { unsafeBitCast($0, to: GetInfo.self) }
        getPID = h.flatMap { dlsym($0, "MRMediaRemoteGetNowPlayingApplicationPID") }.map { unsafeBitCast($0, to: GetPID.self) }
        guard getInfo != nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    deinit { timer?.cancel() }

    func drain() -> [ScriptMedia.Event] {
        lock.lock(); defer { lock.unlock() }
        let p = pending
        pending.removeAll()
        return p
    }

    private func poll() {
        getPID?(queue) { [weak self] p in self?.pid = p }
        getInfo?(queue) { [weak self] info in self?.update(info as? [String: Any]) }
    }

    /// The now-playing app's executable name, the closest macOS counterpart of the WinRT session's AppUserModelId
    /// ("Spotify.exe" / "SpotifyAB.SpotifyMusic_…" on Windows; "Spotify" here), for the Spotify thumbnail rule.
    private func appName() -> String {
        guard pid > 0, let app = NSRunningApplication(processIdentifier: pid) else { return "" }
        return app.executableURL?.lastPathComponent ?? app.localizedName ?? ""
    }

    private func update(_ info: [String: Any]?) {
        var e = ScriptMedia.Event()
        let enabled = info != nil
        if enabled != last.enabled { e.flags |= 0x10; e.enabled = enabled }
        let rate = (info?["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
        let state = info == nil ? 0 : (rate > 0 ? 1 : 2)
        if state != last.state { e.flags |= 0x4; e.state = state }
        var props: [String: String] = [:]
        if let info {
            props["title"] = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
            props["artist"] = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            props["albumTitle"] = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
            props["genres"] = info["kMRMediaRemoteNowPlayingInfoGenre"] as? String ?? ""
        }
        if props != last.props { e.flags |= 0x1; e.props = props }
        let art = info?["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
        let artHash = art?.hashValue ?? 0
        if artHash != last.art {
            e.flags |= 0x2
            if let art { ScriptMedia.thumbnail(art, app: appName(), into: &e) }
        }
        // Timeline events only when the source reports new values (elapsed/timestamp/duration), as SMTC does.
        let dur = Float((info?["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0)
        let elapsed = (info?["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0
        let stamp = (info?["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        if dur != last.dur || elapsed != last.elapsed || stamp != last.stamp {
            e.flags |= 0x8
            e.position = Float(elapsed + (rate > 0 && stamp > 0 ? (Date().timeIntervalSinceReferenceDate - stamp) * rate : 0))
            e.duration = dur
        }
        last = (enabled, state, props, artHash, elapsed, stamp, dur)
        guard e.flags != 0 else { return }
        lock.lock(); pending.append(e); lock.unlock()
    }
}
#endif
