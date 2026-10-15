#if os(Linux)
import CPhotonSystem
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One MPRIS poll (photon_mpris_poll), as Swift values.
public struct MprisSnapshot: Equatable {
    public var busName = "", identity = "", desktopEntry = "", status = ""
    public var title = "", artist = "", album = "", albumArtist = "", genres = "", artURL = ""
    public var lengthMicros: Int64 = 0, positionMicros: Int64 = 0
    public var rate: Double = 1

    /// nil when the session bus is unreachable or no player is on it.
    public static func poll() -> MprisSnapshot? {
        var i = photon_mpris_info()
        let ok = photon_mpris_poll(&i)
        defer { photon_mpris_info_free(&i) }
        guard ok != 0, i.found != 0 else { return nil }
        func s(_ p: UnsafeMutablePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "" }
        return MprisSnapshot(busName: s(i.bus_name), identity: s(i.identity), desktopEntry: s(i.desktop_entry), status: s(i.status),
                             title: s(i.title), artist: s(i.artist), album: s(i.album), albumArtist: s(i.album_artist),
                             genres: s(i.genres), artURL: s(i.art_url), lengthMicros: i.length_us, positionMicros: i.position_us,
                             rate: i.rate)
    }

    /// WinRT playback status: PLAYING 1, PAUSED 2, STOPPED 0.
    public var state: Int { status == "Playing" ? 1 : status == "Paused" ? 2 : 0 }

    /// The player's application name, for the Spotify thumbnail rule (the WinRT session's AppUserModelId there):
    /// the desktop entry, else the bus name's suffix (org.mpris.MediaPlayer2.spotify → "spotify").
    public var app: String {
        if !desktopEntry.isEmpty { return desktopEntry }
        return busName.hasPrefix("org.mpris.MediaPlayer2.") ? String(busName.dropFirst("org.mpris.MediaPlayer2.".count)) : identity
    }

    /// mpris:artUrl's bytes: file://, data: (base64) or http(s) (5 s timeout).
    public static func artwork(_ url: String) -> Data? {
        guard !url.isEmpty else { return nil }
        if url.hasPrefix("data:") {
            guard let comma = url.firstIndex(of: ","), url[..<comma].hasSuffix(";base64") else { return nil }
            return Data(base64Encoded: String(url[url.index(after: comma)...]))
        }
        guard let u = URL(string: url) else { return nil }
        if u.isFileURL { return try? Data(contentsOf: u) }
        guard u.scheme == "http" || u.scheme == "https" else { return nil }
        var result: Data?
        let done = DispatchSemaphore(value: 0)
        var req = URLRequest(url: u)
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req) { d, r, _ in
            if (r as? HTTPURLResponse)?.statusCode == 200 { result = d }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return result
    }
}

/// SceneScript media integration from MPRIS (the macOS NowPlayingPoller reads MediaRemote; docs/re/08 §7, 09 §6.1).
/// Polled once a second like the macOS source. Mapping to the WinRT session winrtutil64 reads:
/// status = a player is on the bus; playback = PlaybackStatus (Playing 1, Paused 2, Stopped 0);
/// properties: xesam:title → title, xesam:artist → artist, xesam:album → albumTitle, xesam:albumArtist → albumArtist,
/// xesam:genre → genres (lists joined with ", "; subTitle and contentType have no MPRIS field and stay unset);
/// thumbnail = mpris:artUrl's image; timeline = Position / mpris:length in seconds. MPRIS players do not signal
/// Position changes (the property is computed on read), so a timeline event is sent when the length or state
/// changes or the position differs by more than 1 s from where the last report and the rate put it (a seek), which
/// is when SMTC players report timeline updates.
final class NowPlayingPoller {
    private let queue = DispatchQueue(label: "photon.nowplaying")
    private let lock = NSLock()
    private var pending: [ScriptMedia.Event] = []
    private var last: (enabled: Bool, state: Int, props: [String: String], art: String, position: Double, at: Date, dur: Float)
        = (false, 0, [:], "", 0, .distantPast, 0)
    private var timer: DispatchSourceTimer?

    init() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0)
        t.setEventHandler { [weak self] in self?.update(MprisSnapshot.poll()) }
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

    static func properties(_ m: MprisSnapshot) -> [String: String] {
        ["title": m.title, "artist": m.artist, "albumTitle": m.album, "albumArtist": m.albumArtist, "genres": m.genres]
    }

    private func update(_ info: MprisSnapshot?) {
        var e = ScriptMedia.Event()
        let now = Date()
        let enabled = info != nil
        if enabled != last.enabled { e.flags |= 0x10; e.enabled = enabled }
        let state = info?.state ?? 0
        if state != last.state { e.flags |= 0x4; e.state = state }
        let props = info.map(Self.properties) ?? [:]
        if props != last.props { e.flags |= 0x1; e.props = props }
        let art = info?.artURL ?? ""
        if art != last.art {
            e.flags |= 0x2
            if let data = MprisSnapshot.artwork(art) { ScriptMedia.thumbnail(data, app: info?.app ?? "", into: &e) }
        }
        let dur = Float(Double(info?.lengthMicros ?? 0) / 1e6)
        let position = Double(info?.positionMicros ?? 0) / 1e6
        let predicted = last.position + (last.state == 1 ? now.timeIntervalSince(last.at) * (info?.rate ?? 1) : 0)
        if dur != last.dur || state != last.state || abs(position - predicted) > 1 {
            e.flags |= 0x8
            e.position = Float(position)
            e.duration = dur
        }
        last = (enabled, state, props, art, position, now, dur)
        guard e.flags != 0 else { return }
        lock.lock(); pending.append(e); lock.unlock()
    }
}
/// `photon-linux media-check`: ScriptMedia fed live from MPRIS, as the scene's SceneScript media hooks receive it.
public enum ScriptMediaCheck {
    /// Polls for `seconds` on a 0.25 s scene clock; one JSON line per event (thumbnail events add the `$mediaThumbnail`
    /// name and the stored image size).
    public static func run(seconds: Double) -> [String] {
        setenv("PHOTON_MEDIA", "live", 1)
        let media = ScriptMedia()
        var lines: [String] = []
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            let t = Float(Date().timeIntervalSince(start))
            for e in media.poll(time: t) {
                var js = e.js
                js["t"] = Double(t)
                if e.flags & 2 != 0 {
                    js["thumbnailName"] = media.thumbnailName
                    if let img = media.image { js["image"] = [img.width, img.height] }
                }
                if let d = try? JSONSerialization.data(withJSONObject: js, options: [.sortedKeys]) {
                    let line = String(decoding: d, as: UTF8.self)
                    print(line)
                    lines.append(line)
                }
            }
            usleep(250_000)
        }
        return lines
    }
}
#endif
