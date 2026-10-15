#if os(Linux)
import CPhotonSystem
import Foundation
import PhotonCore

/// Media integration for web wallpapers on Linux (docs/re/09 §6.1, docs/linux-port.md §5.3): the payloads of
/// WebMedia.swift's macOS source, fed from MPRIS (LinuxMedia.swift's poll) instead of MediaRemote.
///
/// - status `{enabled}`: true while the session bus answers (media integration is on whether or not a player exists,
///   as wallpaper64's replay 0x1400c76a0 reports it), false once when there is no session bus.
/// - playback `{state}`: PlaybackStatus (Playing 1, Paused 2, Stopped 0).
/// - properties: `title`, `artist`, `albumTitle` (xesam:album), `albumArtist`, `genres`; `subTitle` and `contentType`
///   have no MPRIS field and stay "".
/// - thumbnail: mpris:artUrl's image re-encoded as `data:image/png;base64,…` (wallpaper64 sends PNG data) and the five
///   colours from `MediaColors.palette`, as `#RRGGBB`.
/// - timeline `{position, duration}` in seconds (doubles widened from floats): sent when the length or the state
///   changes or the position moved more than 1 s from where the last report and the rate put it (MPRIS players do not
///   signal position changes).
/// Events are queued for the host loop (`drain`), which runs them on its own thread; the source polls once a second on
/// its own queue. A newly registered page gets the current state (`resend`): the first poll after it starts from
/// wallpaper64's "nothing cached" baseline, so only fields that are set follow `{enabled: true}`.
public final class WebMediaSourceLinux {
    private let queue = DispatchQueue(label: "photon.webmedia")
    private let lock = NSLock()
    private var pending: [(String, [String: Any])] = []
    private var timer: DispatchSourceTimer?
    private static let emptyProps = ["title": "", "subTitle": "", "albumArtist": "", "albumTitle": "", "artist": "", "genres": "",
                                     "contentType": ""]
    private typealias State = (enabled: Bool?, state: Int, props: [String: String], art: String, position: Double, at: Date, dur: Double)
    private static let baseline: State = (nil, 0, emptyProps, "", 0, .distantPast, 0)
    private var last: State = WebMediaSourceLinux.baseline
    /// PNG encoder for thumbnails (RGBA8 rows, width, height); photon-linux passes PhotonProto's PNGWriter.
    private let encodePNG: ([UInt8], Int, Int) -> Data

    public init(encodePNG: @escaping ([UInt8], Int, Int) -> Data) { self.encodePNG = encodePNG }

    deinit { timer?.cancel() }

    public func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    public func resend() { queue.async { self.last = Self.baseline } }

    /// Events since the last call, oldest first: (kind, payload).
    public func drain() -> [(String, [String: Any])] {
        lock.lock(); defer { lock.unlock() }
        let p = pending
        pending.removeAll()
        return p
    }

    static func hex(_ c: UInt32) -> String { String(format: "#%02X%02X%02X", c & 0xff, (c >> 8) & 0xff, (c >> 16) & 0xff) }

    private func poll() {
        var i = photon_mpris_info()
        let reachable = photon_mpris_poll(&i) != 0
        defer { photon_mpris_info_free(&i) }
        var out: [(String, [String: Any])] = []
        guard reachable else {
            if last.enabled != false { out.append(("status", ["enabled": false])); last.enabled = false }
            emit(out)
            return
        }
        if last.enabled != true { out.append(("status", ["enabled": true])) }
        let info = i.found != 0 ? MprisSnapshot(i) : nil
        let now = Date()
        let state = info?.state ?? 0
        if state != last.state { out.append(("playback", ["state": state])) }
        var props = Self.emptyProps
        if let info {
            props["title"] = info.title
            props["artist"] = info.artist
            props["albumTitle"] = info.album
            props["albumArtist"] = info.albumArtist
            props["genres"] = info.genres
        }
        if props != last.props { out.append(("properties", props)) }
        let art = info?.artURL ?? ""
        if art != last.art {
            var t: [String: Any] = ["thumbnail": ""]
            var colors: [UInt32] = [0, 0, 0, 0, 0]
            if let data = MprisSnapshot.artwork(art), let img = TexFile.decodeStraightRGBA(data) {
                t["thumbnail"] = "data:image/png;base64," + encodePNG([UInt8](img.pixels), img.width, img.height).base64EncodedString()
                let px = MediaColors.premultipliedWords(img.pixels, width: img.width, height: img.height)
                colors = MediaColors.palette(px.data, width: px.width, height: px.height)
            }
            for (k, key) in ["primaryColor", "secondaryColor", "tertiaryColor", "textColor", "highContrastColor"].enumerated() {
                t[key] = Self.hex(k < colors.count ? colors[k] : 0)
            }
            out.append(("thumbnail", t))
        }
        let dur = Double(info?.lengthMicros ?? 0) / 1e6
        let position = Double(info?.positionMicros ?? 0) / 1e6
        let predicted = last.position + (last.state == 1 ? now.timeIntervalSince(last.at) * (info?.rate ?? 1) : 0)
        if info != nil, dur != last.dur || state != last.state || abs(position - predicted) > 1 {
            out.append(("timeline", ["position": Double(Float(position)), "duration": Double(Float(dur))]))
        }
        last = (true, state, props, art, position, now, dur)
        emit(out)
    }

    private func emit(_ events: [(String, [String: Any])]) {
        guard !events.isEmpty else { return }
        lock.lock(); pending += events; lock.unlock()
    }
}

extension MprisSnapshot {
    init(_ i: photon_mpris_info) {
        func s(_ p: UnsafeMutablePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "" }
        self.init(busName: s(i.bus_name), identity: s(i.identity), desktopEntry: s(i.desktop_entry), status: s(i.status),
                  title: s(i.title), artist: s(i.artist), album: s(i.album), albumArtist: s(i.album_artist), genres: s(i.genres),
                  artURL: s(i.art_url), lengthMicros: i.length_us, positionMicros: i.position_us, rate: i.rate)
    }
}
#endif
