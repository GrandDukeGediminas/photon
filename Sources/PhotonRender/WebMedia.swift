import AppKit
import Foundation

/// Media integration for web wallpapers (docs/re/09 §6.1).
///
/// webwallpaper64.exe: the five `wallpaperRegisterMedia*Listener(cb)` bindings (native handler web: 0x140014bea–0x14001511e)
/// accept exactly one function argument, keep one callback each and send `MediaIntegrationContextRegistered`
/// (web: 0x140014def), which makes wallpaper64 start forwarding media events. Each event reaches the page as one
/// object (the CefDictionaryValue converted to V8, web: 0x140010e37–0x140010f55):
/// - properties (`SendMediaPropertyUpdate`, web: 0x14001a628): strings `title`, `subTitle`, `albumArtist`, `albumTitle`,
///   `artist`, `genres`, `contentType` (SetString vt+0xc8);
/// - thumbnail (`SendMediaThumbnailUpdate`, web: 0x14001b5b8): `thumbnail` (wallpaper64 builds it as
///   `"data:image/png;base64," + …`, 0x14011c6ca) and `primaryColor`, `secondaryColor`, `tertiaryColor`, `textColor`,
///   `highContrastColor` as `"#RRGGBB"` from the packed 0x00BBGGRR value (web: 0x14000b100, "%02X" of bytes 0, 1, 2);
/// - playback (`SendMediaPlaybackUpdate`, web: 0x14001c3ac): int `state` (wallpaperMediaIntegration.PLAYBACK_STOPPED 0,
///   PLAYING 1, PAUSED 2);
/// - timeline (`SendMediaTimelineUpdate`, web: 0x140020f3c): doubles `position`, `duration` (seconds, from floats);
/// - status (`SendMediaStatusUpdate`, web: 0x14001c80c): bool `enabled`.
///
/// macOS source: Now Playing through MediaRemote (as SceneScript's `NowPlayingPoller`), polled once a second; events
/// are sent only for fields that changed. WinRT-only fields (`subTitle`, `albumArtist`, `contentType`) stay "".
final class WebMediaSource {
    private typealias GetInfo = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private let getInfo: GetInfo?
    private let queue = DispatchQueue(label: "photon.webmedia")
    private var timer: DispatchSourceTimer?
    private var last: (enabled: Bool?, state: Int?, props: [String: String]?, art: Int?, elapsed: Double, stamp: Double, dur: Double)
        = WebMediaSource.replayBaseline
    /// wallpaper64's registration replay (0x1400c76a0, run when a page registers a listener): media integration
    /// unavailable (Windows < 10.0.17763, or the setting off: provider +0xb60 bit 0) → one `{enabled: false}` status;
    /// available but the `winrtutil64 -mediainterface` child not started → it is started (0x1400c8b60) and nothing is sent
    /// yet; running → `{enabled: true}` (the event ctor 0x1400c1390 defaults +0x174 to 1, status flag 0x10 always set),
    /// plus properties only when the cached title is not empty (+0x530), thumbnail only with image bytes (+0x600),
    /// playback only when the state (+0x658) ≠ 0, timeline only when the duration (+0x660) ≠ 0. So `enabled` means
    /// "media integration is on", not "a session exists"; with no session a page gets `{enabled: true}` alone.
    /// Starting from the baseline "nothing cached" reproduces that filter on the first poll.
    private static let replayBaseline: (enabled: Bool?, state: Int?, props: [String: String]?, art: Int?, elapsed: Double, stamp: Double, dur: Double)
        = (nil, 0, emptyProps, 0, 0, 0, 0)
    private static let emptyProps = ["title": "", "subTitle": "", "albumArtist": "", "albumTitle": "", "artist": "", "genres": "", "contentType": ""]
    /// Called on the main queue with (event kind, payload). Kinds: "properties", "thumbnail", "playback", "timeline",
    /// "status".
    var onEvent: ((String, [String: Any]) -> Void)?

    init() {
        let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
        getInfo = h.flatMap { dlsym($0, "MRMediaRemoteGetNowPlayingInfo") }.map { unsafeBitCast($0, to: GetInfo.self) }
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    /// Re-sends everything on the next poll (a newly registered listener gets the current state).
    func resend() { queue.async { self.last = Self.replayBaseline } }

    deinit { timer?.cancel() }

    private func poll() {
        guard let getInfo else {
            if last.enabled == nil { emit([("status", ["enabled": false])]); last.enabled = false }
            return
        }
        getInfo(queue) { [weak self] info in self?.update(info as? [String: Any]) }
    }

    private func emit(_ events: [(String, [String: Any])]) {
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in events.forEach { self?.onEvent?($0.0, $0.1) } }
    }

    static func hex(_ c: UInt32) -> String { String(format: "#%02X%02X%02X", c & 0xff, (c >> 8) & 0xff, (c >> 16) & 0xff) }

    private func update(_ info: [String: Any]?) {
        var out: [(String, [String: Any])] = []
        // MediaRemote is reachable: integration is on (`enabled` true) whether or not something is playing.
        if last.enabled != true { out.append(("status", ["enabled": true])) }
        let hadSession = last.state != 0 || last.props.map { $0 != Self.emptyProps } ?? false
        guard info != nil else {
            // No session. What winrtutil64's session-changed handler sends when the current session goes away was not
            // traced; photon2 clears playback and properties once (Inferred).
            if hadSession { out.append(("playback", ["state": 0])); out.append(("properties", Self.emptyProps)) }
            last = (true, 0, Self.emptyProps, last.art, last.elapsed, last.stamp, last.dur)
            emit(out)
            return
        }
        let enabled = true
        let rate = (info?["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
        let state = rate > 0 ? 1 : 2
        if state != last.state { out.append(("playback", ["state": state])) }
        var props = ["title": "", "subTitle": "", "albumArtist": "", "albumTitle": "", "artist": "", "genres": "", "contentType": ""]
        if let info {
            props["title"] = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
            props["artist"] = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            props["albumTitle"] = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
            props["genres"] = info["kMRMediaRemoteNowPlayingInfoGenre"] as? String ?? ""
        }
        if props != last.props { out.append(("properties", props)) }
        let art = info?["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
        let artHash = art?.hashValue ?? 0
        if artHash != last.art {
            var t: [String: Any] = ["thumbnail": ""]
            var colors: [UInt32] = [0, 0, 0, 0, 0]
            if let art, let img = NSImage(data: art) {
                if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    t["thumbnail"] = "data:image/png;base64," + png.base64EncodedString()
                }
                if let px = MediaColors.rgba(img) { colors = MediaColors.palette(px.data, width: px.width, height: px.height) }
            }
            for (i, k) in ["primaryColor", "secondaryColor", "tertiaryColor", "textColor", "highContrastColor"].enumerated() {
                t[k] = Self.hex(i < colors.count ? colors[i] : 0)
            }
            out.append(("thumbnail", t))
        }
        let dur = (info?["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0
        let elapsed = (info?["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0
        let stamp = (info?["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        if dur != last.dur || elapsed != last.elapsed || stamp != last.stamp {
            let pos = elapsed + (rate > 0 && stamp > 0 ? (Date().timeIntervalSinceReferenceDate - stamp) * rate : 0)
            // The web host widens floats to doubles (cvtss2sd, web: 0x140020ff6).
            out.append(("timeline", ["position": Double(Float(pos)), "duration": Double(Float(dur))]))
        }
        last = (enabled, state, props, artHash, elapsed, stamp, dur)
        emit(out)
    }
}
