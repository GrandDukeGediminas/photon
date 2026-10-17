import AppKit
import Foundation
import PhotonCore
import UniformTypeIdentifiers
import WebKit

/// Web wallpapers: a project whose `file` classifies as `.html` (or an http(s) URL) runs in the engine's separate
/// CEF host `bin/webwallpaper64.exe`, not in the scene renderer (docs/re/04 §1.2). This is the WebKit counterpart.
///
/// From `webwallpaper64.exe`:
/// - Before page scripts run it injects its runtime (`(function() { if (window.___STAHP) …`, at file offset 0x119ca1): the
///   `___wpxShared.onLoad` queue, `___wpxPause` / `___wpxUnpause` (CSS animations, media, timers, AudioContexts) and
///   `wallpaperMediaIntegration`. photon2 reads that script out of the user's installed binary, like the engine assets.
/// - User properties (0x1400199e2–0x140019a74): `if(window.wallpaperPropertyListener&&window.wallpaperPropertyListener
///   .applyUserProperties){window.wallpaperPropertyListener.applyUserProperties(<json>);}` with `{ name: {"value": v} }`.
/// - General properties (0x140020730–0x1400207c2): the same guard around `applyGeneralProperties({"language": …})`.
/// - Pause (0x1400201e4–0x1400202a6): `setPaused(true)` (guarded, and skipped while `___wpxAnimLocked`) then
///   `window.___wpxPause();`; resume: `window.___wpxUnpause();` then `setPaused(false)` under the same guard.
/// - `wallpaperRegisterAudioListener(cb)` (0x14001340f) and the media/utility functions are native bindings; here they
///   are JS functions that keep the callbacks. Audio frames are the analyzer's 128 floats (`SendAudioSample`).
public final class WebWallpaper: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    public enum Error: Swift.Error { case missingFile(URL) }

    public let webView: WKWebView
    /// Live instances (tests: a removed page must go away with its web view).
    public private(set) static var liveInstances = 0
    private let pageURL: URL
    private let properties: [String: Any]
    private var loaded = false
    private var schemeHandler: LocalSchemeHandler?
    /// `directory` user properties: folder, `mode` ("fetchall" lists every file after load, "ondemand" answers
    /// `wallpaperRequestRandomFileForProperty`) and `fileType` ("video" or images).
    private var userDirectories: [String: (url: URL, mode: String, fileType: String)] = [:]
    private var paused = false
    private var muted = false
    /// The frame-rate cap (`WebPageScripts.frameLimiter`), applied again after each load.
    private var frameRate = 0
    /// The page registered an audio listener (`AudioContextRegistered`, sent by the render process when
    /// `wallpaperRegisterAudioListener` stored a callback, 0x140014b91); the CEF wallpaper only streams audio after that.
    public private(set) var audioRequested = false
    /// Delivered to `applyGeneralProperties`: the host's general settings object (CEFWallpaper 0x140119a60 sends all of
    /// it as message 7; the web host maps `language` and drops `steamlanguage`, 0x140020540–0x1400206ad).
    public var generalSettings: [String: Any] = ["language": "en-us"]

    /// `directory` is the wallpaper folder, `file` its project `file`; `properties` are the current user values.
    /// `properties` maps each property name to its value, or to a full property object (`type`, `value`, …).
    /// `frameRate` caps the page's animation frames from the start (0 = every display frame; `setFrameRate` changes it).
    public init(directory: URL, file: String, properties: [String: Any], engineInstall: URL?, frame: CGRect, frameRate: Int = 0) throws {
        if file.hasPrefix("http://") || file.hasPrefix("https://"), let u = URL(string: file) {
            pageURL = u
        } else {
            pageURL = directory.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: pageURL.path) else { throw Error.missingFile(pageURL) }
        }
        self.properties = properties
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.mediaTypesRequiringUserActionForPlayback = []
        let content = WKUserContentController()
        // The engine's runtime, the bindings, the LED plugin and the console hook (WebPageScripts, shared with Linux).
        self.frameRate = max(frameRate, 0)
        for script in WebPageScripts.userScripts(engineInstall: engineInstall, fps: self.frameRate) {
            content.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        config.userContentController = content
        // Pages load from `photon-web://wallpaper/…` instead of file:// so they get a normal origin: WebKit blocks
        // `history.replaceState` and similar on file URLs, which CEF allows (Angular routers depend on it).
        // User `directory` properties (web host 0x140018bbe–0x1400190dc): the folders are served under
        // `photon-web://local/<absolute path>` so the page can load the files it is given.
        let dirs = WebPageScripts.userDirectories(properties)
        userDirectories = dirs
        if pageURL.isFileURL {
            let handler = LocalSchemeHandler(root: pageURL.deletingLastPathComponent())
            handler.extraRoots = dirs.values.map(\.url.standardizedFileURL)
            config.setURLSchemeHandler(handler, forURLScheme: LocalSchemeHandler.scheme)
            schemeHandler = handler
        }
        webView = WKWebView(frame: frame, configuration: config)
        super.init()
        Self.liveInstances += 1
        // WKUserContentController keeps its handlers strongly; through a weak proxy so the page (and its web content
        // process) goes away with this object instead of running on after removal.
        content.add(WeakScriptHandler(self), name: "photon")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
    }

    deinit {
        Self.liveInstances -= 1
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "photon")
    }

    private var media: WebMediaSource?

    private func startMedia() {
        if media == nil {
            let m = WebMediaSource()
            m.onEvent = { [weak self] kind, payload in
                self?.run(WebPageScripts.media(kind, payload))
            }
            media = m
            m.start()
        } else {
            media?.resend()
        }
    }

    private var appliedFilter: String?
    private var appliedFlip: Bool?

    /// The wallpaper's general colour options and flip, as the web host applies them with the user properties
    /// (web: 0x140019b82–0x14001a0df, 0x14001a1ea–0x14001a2a0): `wec_con`/50, `wec_brs`/50, `wec_sa`/50 and
    /// (`wec_hue`/50 − 1)·180 become `document.documentElement.style.filter = 'contrast(c) brightness(b) saturate(s)
    /// hue-rotate(h deg)'` while `wec_e` is on, else the filter is cleared (only when something changed);
    /// `alignmentfliph` sets `transform = 'scaleX(-1)'` with `overflow-y: hidden`, else clears the transform.
    public func applyWallpaperGeneral(_ v: [String: Any]) {
        let (filter, flip) = WebPageScripts.generalStyle(v)
        guard loaded else { return }
        if filter != appliedFilter { appliedFilter = filter; run(filter) }
        if flip != appliedFlip {
            appliedFlip = flip
            run(WebPageScripts.flipScript(flip))
        }
    }

    public func load() {
        if pageURL.isFileURL {
            let name = pageURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? pageURL.lastPathComponent
            webView.load(URLRequest(url: URL(string: "\(LocalSchemeHandler.scheme)://wallpaper/\(name)")!))
        } else {
            webView.load(URLRequest(url: pageURL))
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        run(WebPageScripts.setFrameRate(frameRate))
        run(WebPageScripts.applyGeneral(generalSettings))
        run(WebPageScripts.applyUser(properties))
        for (name, d) in userDirectories where d.mode.lowercased() == "fetchall" {
            run(WebPageScripts.directoryFiles(name, WebPageScripts.files(in: d.url, fileType: d.fileType)))
        }
        if paused { setPaused(true, force: true) }
        appliedFilter = nil
        appliedFlip = nil
    }

    public func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        if (message.body as? String) == "__audio" { audioRequested = true; return }
        if (message.body as? String) == "__media" { startMedia(); return }
        if let b = message.body as? String, b.hasPrefix("__random:") {
            // RequestRandomFile → RequestRandomFileResponse (0x1400117e7–0x140011901): the stored callback gets two
            // strings, the property name and a file. Inferred: one random file of the property's folder.
            let name = String(b.dropFirst("__random:".count))
            let file = userDirectories[name].flatMap { WebPageScripts.files(in: $0.url, fileType: $0.fileType).randomElement() }
            run(WebPageScripts.randomFile(name, file))
            return
        }
        if WebPageScripts.debug { NSLog("photon web: %@", "\(message.body)") }
    }

    /// Mutes the page's media (the tray mute and the mute rules apply to web wallpapers too). Uses WebKit's page
    /// mute state when available.
    public func setMuted(_ m: Bool) {
        guard m != muted else { return }
        muted = m
        let sel = NSSelectorFromString("_setPageMuted:")
        guard let method = class_getInstanceMethod(type(of: webView), sel) else { return }
        typealias SetMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
        // WKMediaMutedState: 1 = audio muted.
        unsafeBitCast(method_getImplementation(method), to: SetMuted.self)(webView, sel, m ? 1 : 0)
    }

    /// Caps how often the page's animation frames run (0 = every display frame).
    public func setFrameRate(_ fps: Int) {
        guard fps != frameRate else { return }
        frameRate = fps
        if loaded { run(WebPageScripts.setFrameRate(fps)) }
    }

    public func setPaused(_ p: Bool, force: Bool = false) {
        guard p != paused || force else { return }
        paused = p
        guard loaded else { return }
        run(WebPageScripts.setPaused(p))
    }

    /// One analyzer frame (128 floats) to every registered audio listener.
    public func sendAudio(_ samples: [Float]) {
        guard loaded, let js = WebPageScripts.audio(samples) else { return }
        run(js)
    }

    private func run(_ js: String) { webView.evaluateJavaScript(js, completionHandler: nil) }

    /// The properties as the CEF host delivers them (WebPageScripts.typedProperties).
    public static func typedProperties(project: [String: Any], preset: [String: Any] = [:], overrides: [String: Any]) -> [String: Any] {
        WebPageScripts.typedProperties(project: project, preset: preset, overrides: overrides)
    }

    /// Current property values of a project (WebPageScripts.properties).
    public static func properties(project: [String: Any], preset: [String: Any] = [:], overrides: [String: Any]) -> [String: Any] {
        WebPageScripts.properties(project: project, preset: preset, overrides: overrides)
    }
}


/// Serves a wallpaper folder to WebKit under `photon-web://wallpaper/`.
final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = WebPageScripts.scheme
    let root: URL
    /// Folders of `directory` properties, served as `photon-web://local/<absolute path>`.
    var extraRoots: [URL] = []
    init(root: URL) { self.root = root.standardizedFileURL }

    static func url(for file: URL) -> String { WebPageScripts.localURL(for: file) }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let rel = url.path.removingPercentEncoding ?? url.path
        var file = root.appendingPathComponent(rel).standardizedFileURL
        var allowed = file.path.hasPrefix(root.path)
        if url.host == "local" {
            file = URL(fileURLWithPath: rel).standardizedFileURL
            allowed = extraRoots.contains { file.path.hasPrefix($0.path + "/") }
        }
        guard allowed, let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type, "Content-Length": "\(data.count)",
                                                      "Access-Control-Allow-Origin": "*"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// Forwards script messages without retaining the receiver (WKUserContentController retains its handlers).
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}
