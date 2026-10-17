import Foundation
import PhotonCore

/// The page side of a web wallpaper host, shared by the macOS WKWebView host (WebWallpaper.swift) and the Linux
/// WebKitGTK host (photon-linux, docs/linux-port.md §5.3): the injected bindings, the plugin stubs, and the JavaScript
/// each host event becomes (docs/re/09 §6). Foundation only; the strings are what WebWallpaper sent before they moved here.
public enum WebPageScripts {
    /// The URL scheme pages load from: `photon-web://wallpaper/<file>` (the wallpaper folder) and
    /// `photon-web://local/<absolute path>` (folders of `directory` user properties).
    public static let scheme = "photon-web"

    /// The installed `distribution/bin/webwallpaper64.exe` runtime script (0x119ca1 in this build), found by its first
    /// line so other builds work too.
    public static func engineRuntime(_ install: URL) -> String? {
        let exe = install.appendingPathComponent("distribution/bin/webwallpaper64.exe")
        guard let data = try? Data(contentsOf: exe, options: .alwaysMapped),
              let start = data.range(of: Data("(function() {\n\tif (window.___STAHP)".utf8)) else { return nil }
        guard let end = data[start.lowerBound...].firstIndex(of: 0) else { return nil }
        return String(data: data[start.lowerBound..<end], encoding: .utf8)
    }

    /// Native bindings of the CEF host, as plain JS. `wallpaperRegisterAudioListener` (0x140014a9f) needs exactly one
    /// function argument and keeps only that one callback (a second registration replaces it, 0x140014b6c); frames call it
    /// with a 128-element Array of numbers (0x140010c0f–0x140010cbe). Messages go to the host through
    /// `window.webkit.messageHandlers.photon` (WKScriptMessageHandler on macOS, WebKitGTK's script message handler on
    /// Linux).
    public static let bindings = """
    (function() {
      window.__photonAudioListener = null;
      window.wallpaperRegisterAudioListener = function(cb) {
        if (arguments.length !== 1 || typeof cb !== 'function') return;
        window.__photonAudioListener = cb;
        try { window.webkit.messageHandlers.photon.postMessage('__audio'); } catch (e) {}
      };
      // Media listeners (web: 0x140014bea–0x14001511e): exactly one function argument, one callback per kind; the
      // first registration starts the media source (MediaIntegrationContextRegistered). WebMedia.swift.
      window.__photonMedia = {};
      ['Properties', 'Thumbnail', 'Playback', 'Timeline', 'Status'].forEach(function(k) {
        window['wallpaperRegisterMedia' + k + 'Listener'] = function(cb) {
          if (arguments.length !== 1 || typeof cb !== 'function') return;
          window.__photonMedia[k.toLowerCase()] = cb;
          try { window.webkit.messageHandlers.photon.postMessage('__media'); } catch (e) {}
        };
      });
      // wallpaperGetUtilities (web: 0x140015376–0x1400156d9): {isScreensaver, isWallpaper} booleans.
      window.wallpaperGetUtilities = function() { return {isScreensaver: false, isWallpaper: true}; };
      window.__photonRandomFile = {};
      window.wallpaperRequestRandomFileForProperty = function(name, cb) {
        if (typeof name !== 'string' || typeof cb !== 'function') return;
        window.__photonRandomFile[name] = cb;
        try { window.webkit.messageHandlers.photon.postMessage('__random:' + name); } catch (e) {}
      };
      window.wallpaperOnVideoEnded = function() {};
      window.wallpaperRequestTakeScreenshotResponse = function() {};
    })();
    """

    /// The LED plugin (`distribution/plugins/led/ledextensions64.dll`, loaded by wallpaper64 0x1400549da when
    /// `GetWPExtPluginVersion()` is "pluginAlphaDev0007"). Its export manifest (string in the DLL) declares a global
    /// `cue` with getProtocolDetails() → object, getDeviceCount() → int, getDeviceInfo(int) → object,
    /// getLedPositionsByDeviceIndex(int) → array, setLedsColorsAsync(array), setAllLedsColorsAsync(int, object),
    /// setLedColorsByImageData(int, imageData, int, int), and a plugin `led` (window.wpPlugins.led) with
    /// setAllDevicesByImageData(imageData, int, int). The web host's function wrapper (web: 0x140039c51–0x14003aaa5)
    /// requires exactly the declared parameters plus, when the function returns something, a trailing callback that
    /// receives the result (`ReturnPluginFunction`). Registration runs
    /// `onPluginLoaded('<name>', '<version>')` after load, and for `led` also `onPluginLoaded('cue', …)` (web:
    /// 0x14001f56d–0x14001f633; both calls pass the same version). The version wallpaper64 sends is the plugin object's
    /// vt+0x40 (`RegisterWallpaperPlugin` JSON built at 0x14011bb06–0x14011bb68; name = vt+0x30): ledextensions64.dll's
    /// object (vtable 0x18014e6a0, `CreateWPExtPlugin` 0x18000b664) returns "led" (0x18000bf88) and "1.2.0" (0x18000bf98).
    /// Neither macOS nor Linux has iCUE, so the functions report no devices and drop colour writes.
    /// The objects are installed when the registration "arrives", right before `onPluginLoaded`, not at document start:
    /// def_corsair_o_tron declares `var cue = null;` in its main script (which would overwrite an earlier `window.cue`)
    /// and takes `cue = window.cue` in `onPluginLoaded('cue')`, so in CEF the export exists only after the page's
    /// scripts ran (Inferred from that page; installing at document start made its onPluginLoaded throw).
    public static let ledPlugin = """
    (function() {
      function fn(params, ret, result) {
        return function() {
          if (arguments.length !== params + (ret ? 1 : 0)) return;
          if (ret) { var cb = arguments[arguments.length - 1]; if (typeof cb !== 'function') return;
                     Promise.resolve().then(function() { cb(result()); }); }
        };
      }
      var cue = {
        getProtocolDetails: fn(0, true, function() { return {sdkVersion: '', serverVersion: '', sdkProtocolVersion: 0,
                                                              serverProtocolVersion: 0, breakingChanges: false}; }),
        getDeviceCount: fn(0, true, function() { return 0; }),
        getDeviceInfo: fn(1, true, function() { return {}; }),
        getLedPositionsByDeviceIndex: fn(1, true, function() { return []; }),
        setLedsColorsAsync: fn(1, false),
        setAllLedsColorsAsync: fn(2, false),
        setLedColorsByImageData: fn(4, false)
      };
      var led = { setAllDevicesByImageData: fn(3, false) };
      // RegisterWallpaperPlugin: the exports appear when the registration arrives, after the page's scripts ran.
      var register = function() {
        window.cue = cue;
        window.wpPlugins = window.wpPlugins || {};
        window.wpPlugins.led = led;
      };
      var notify = function() {
        window.___wpxShared.onLoad(function(){register();window.wallpaperPluginListener && window.wallpaperPluginListener.onPluginLoaded('led', '1.2.0');});
        window.___wpxShared.onLoad(function(){window.wallpaperPluginListener && window.wallpaperPluginListener.onPluginLoaded('cue', '1.2.0');});
      };
      if (window.___wpxShared) { notify(); } else { window.addEventListener('load', function() { register();
        window.wallpaperPluginListener && window.wallpaperPluginListener.onPluginLoaded('led', '1.2.0');
        window.wallpaperPluginListener && window.wallpaperPluginListener.onPluginLoaded('cue', '1.2.0'); }); }
    })();
    """
    /// `PHOTON_WEBPLUGINS=0` leaves the LED plugin out (as an install without `distribution/plugins/led`).
    public static let pluginsEnabled = ProcessInfo.processInfo.environment["PHOTON_WEBPLUGINS"] != "0"

    public static let debug = ProcessInfo.processInfo.environment["PHOTON_WEBDEBUG"] == "1"
    /// `PHOTON_WEBDEBUG=1`: page console output and errors go to the log.
    public static let consoleHook = """
    (function() {
      ['log','warn','error','info'].forEach(function(k) {
        var o = console[k];
        console[k] = function() { try { window.webkit.messageHandlers.photon.postMessage(k + ': ' + Array.prototype.map.call(arguments, String).join(' ')); } catch (e) {} o.apply(console, arguments); };
      });
      window.addEventListener('error', function(e) { try { window.webkit.messageHandlers.photon.postMessage('uncaught: ' + e.message + ' @' + e.filename + ':' + e.lineno); } catch (x) {} });
    })();
    """

    /// photon's frame-rate cap for web pages (an energy control; the engine has none: webwallpaper64 creates a windowed
    /// CEF browser without `windowless_frame_rate` and ignores the `fps` setting, docs/re/09 §6). `requestAnimationFrame`
    /// callbacks are batched and released at most `fps` times a second (0 = every display frame), with the wait between
    /// batches spent in a timer, so a capped page does not wake on every display refresh.
    /// It is installed before the engine's runtime, which keeps the `requestAnimationFrame` it finds (`var RAF`) for
    /// its pause queue. `setFrameRate` changes the cap of a loaded page.
    public static let frameLimiter = """
    (function() {
      if (window.___photonFrameLimit) return;
      var raf = window.requestAnimationFrame.bind(window), timeout = window.setTimeout.bind(window);
      var limit = window.___photonFrameLimit = { fps: 0 };
      var callbacks = new Map(), nextID = 0, scheduled = false, last = -1;
      function flush(t) {
        scheduled = false;
        var interval = limit.fps > 0 ? 1000 / limit.fps : 0;
        if (interval > 0 && last >= 0) {
          var wait = last + interval - t;
          if (wait > 1) { schedule(wait); return; }
          // Keep the cadence (60 fps on a 120 Hz display is every other frame) unless a frame was missed.
          last = t - last < 2 * interval ? last + interval : t;
        } else {
          last = t;
        }
        var run = callbacks;
        callbacks = new Map();
        run.forEach(function(fn) { try { fn(t); } catch (e) { timeout(function() { throw e; }, 0); } });
      }
      function schedule(wait) {
        scheduled = true;
        // Sleep until shortly before the frame is due, then wait for the display frame.
        if (wait > 6) { timeout(function() { raf(flush); }, wait - 6); } else { raf(flush); }
      }
      window.requestAnimationFrame = function(fn) {
        var id = ++nextID;
        callbacks.set(id, fn);
        if (!scheduled) schedule(0);
        return id;
      };
      window.cancelAnimationFrame = function(id) { callbacks.delete(id); };
      if (window.webkitRequestAnimationFrame) {
        window.webkitRequestAnimationFrame = window.requestAnimationFrame;
        window.webkitCancelAnimationFrame = window.cancelAnimationFrame;
      }
    })();
    """

    /// Changes the frame-rate cap of a loaded page (0 = unlimited).
    public static func setFrameRate(_ fps: Int) -> String {
        "if(window.___photonFrameLimit){window.___photonFrameLimit.fps=\(max(fps, 0));}"
    }

    /// The scripts injected at document start in the main frame, in order: the frame limiter (capped at `fps` from the
    /// start), the engine's runtime
    /// (when the install has it), the bindings, the LED plugin, the console hook (`PHOTON_WEBDEBUG=1`).
    public static func userScripts(engineInstall: URL?, fps: Int = 0) -> [String] {
        var s: [String] = [frameLimiter + setFrameRate(fps)]
        if let runtime = engineInstall.flatMap(engineRuntime) { s.append(runtime) }
        s.append(bindings)
        if pluginsEnabled { s.append(ledPlugin) }
        if debug { s.append(consoleHook) }
        return s
    }

    // MARK: Host events as JavaScript

    /// General properties (0x140020730–0x1400207c2): `applyGeneralProperties(<settings>)` under the listener guard.
    public static func applyGeneral(_ general: [String: Any]) -> String {
        "if(window.wallpaperPropertyListener&&window.wallpaperPropertyListener.applyGeneralProperties){"
            + "window.wallpaperPropertyListener.applyGeneralProperties(\(json(general)));}"
    }

    /// User properties (0x1400199e2–0x140019a74): `applyUserProperties({ name: {"value": v, …} })`; a property given as
    /// a full object (`type`, `value`, …) keeps its fields.
    public static func applyUser(_ properties: [String: Any]) -> String {
        var user: [String: Any] = [:]
        for (k, v) in properties { user[k] = (v as? [String: Any]).map { $0["value"] != nil ? $0 : ["value": v] } ?? ["value": v] }
        return "if(window.wallpaperPropertyListener&&window.wallpaperPropertyListener.applyUserProperties){"
            + "window.wallpaperPropertyListener.applyUserProperties(\(json(user)));}"
    }

    /// `directory` user properties: name → (folder, `mode`, `fileType`) (web host 0x140018bbe–0x1400190dc).
    public static func userDirectories(_ properties: [String: Any]) -> [String: (url: URL, mode: String, fileType: String)] {
        var dirs: [String: (url: URL, mode: String, fileType: String)] = [:]
        for (k, v) in properties {
            guard let o = v as? [String: Any], (o["type"] as? String)?.lowercased() == "directory",
                  let path = o["value"] as? String, !path.isEmpty else { continue }
            dirs[k] = (URL(fileURLWithPath: path), (o["mode"] as? String) ?? "", (o["fileType"] as? String) ?? "")
        }
        return dirs
    }

    /// fetchall directories: `userDirectoryFilesAddedOrChanged('name',["file",…])` (0x140009c9a–0x140009d1d).
    public static func directoryFiles(_ name: String, _ files: [URL]) -> String {
        let list = files.map { json(localURL(for: $0)) }.joined(separator: ",")
        return "if(window.wallpaperPropertyListener&&window.wallpaperPropertyListener.userDirectoryFilesAddedOrChanged){"
            + "window.wallpaperPropertyListener.userDirectoryFilesAddedOrChanged(\(json(name)),[\(list)]);}"
    }

    /// RequestRandomFileResponse (0x1400117e7–0x140011901): the stored callback gets the property name and a file.
    public static func randomFile(_ name: String, _ file: URL?) -> String {
        "(function(){var cb=window.__photonRandomFile[\(json(name))];if(cb){cb(\(json(name)),\(json(file.map(localURL(for:)) ?? "")));}})();"
    }

    /// Pause (0x1400201e4–0x1400202a6): `setPaused(true)` (guarded, skipped while `___wpxAnimLocked`) then
    /// `window.___wpxPause();`; resume: `window.___wpxUnpause();` then `setPaused(false)` under the same guard.
    public static func setPaused(_ p: Bool) -> String {
        let guarded = "if(window.wallpaperPropertyListener&&window.wallpaperPropertyListener.setPaused&&!window.___wpxAnimLocked){"
            + "window.wallpaperPropertyListener.setPaused(\(p ? "true" : "false"));}"
        return p ? guarded + "window.___wpxPause&&window.___wpxPause();" : "window.___wpxUnpause&&window.___wpxUnpause();" + guarded
    }

    /// One analyzer frame (128 floats) to the registered audio listener; nil for a frame of another size.
    public static func audio(_ samples: [Float]) -> String? {
        guard samples.count == 128 else { return nil }
        let list = samples.map { String(format: "%.6g", $0) }.joined(separator: ",")
        return "(function(){var cb=window.__photonAudioListener;if(cb){cb([\(list)]);}})();"
    }

    /// A media event (`properties`, `thumbnail`, `playback`, `timeline`, `status`) to its listener (docs/re/09 §6.1).
    public static func media(_ kind: String, _ payload: [String: Any]) -> String {
        "(function(){var cb=window.__photonMedia&&window.__photonMedia[\(json(kind))];if(cb){cb(\(json(payload)));}})();"
    }

    /// The wallpaper's general colour options and flip, as the web host applies them with the user properties
    /// (web: 0x140019b82–0x14001a0df, 0x14001a1ea–0x14001a2a0): `wec_con`/50, `wec_brs`/50, `wec_sa`/50 and
    /// (`wec_hue`/50 − 1)·180 become `document.documentElement.style.filter = 'contrast(c) brightness(b) saturate(s)
    /// hue-rotate(h deg)'` while `wec_e` is on, else the filter is cleared; `alignmentfliph` sets
    /// `transform = 'scaleX(-1)'` with `overflow-y: hidden`, else clears the transform. Hosts run each script only when
    /// it differs from the last one they ran.
    public static func generalStyle(_ v: [String: Any]) -> (filter: String, flip: Bool) {
        func num(_ k: String, _ d: Float) -> Float { (v[k] as? NSNumber)?.floatValue ?? (v[k] as? String).flatMap(Float.init) ?? d }
        func flag(_ k: String) -> Bool { (v[k] as? Bool) ?? ((v[k] as? NSNumber)?.boolValue ?? false) }
        func f(_ x: Float) -> String { String(format: "%g", x) } // ostream << float (6 significant digits)
        let filter: String
        if flag("wec_e") {
            filter = "document.documentElement.style.filter = 'contrast(\(f(num("wec_con", 50) / 50))) brightness(\(f(num("wec_brs", 50) / 50)))"
                + " saturate(\(f(num("wec_sa", 50) / 50))) hue-rotate(\(f((num("wec_hue", 50) / 50 - 1) * 180))deg)';"
        } else {
            filter = "document.documentElement.style.filter = '';"
        }
        return (filter, flag("alignmentfliph"))
    }

    public static func flipScript(_ flip: Bool) -> String {
        flip ? "var e=document.documentElement.style;e.transform = 'scaleX(-1)';e['overflow-y'] = 'hidden';"
             : "document.documentElement.style.transform = '';"
    }

    // MARK: Files and values

    /// `photon-web://local/<absolute path>` for a file in a `directory` property's folder.
    public static func localURL(for file: URL) -> String {
        "\(scheme)://local" + (file.standardizedFileURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path)
    }

    /// Files of a user directory (recursive), filtered by the property's `fileType` (Inferred filter: "video" → video
    /// files, anything else → images).
    public static func files(in dir: URL, fileType: String) -> [URL] {
        let video = ["mp4", "webm", "ogv", "mov", "m4v"], image = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg"]
        let exts = fileType.lowercased() == "video" ? video : image
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        var out: [URL] = []
        while let u = e?.nextObject() as? URL { if exts.contains(u.pathExtension.lowercased()) { out.append(u) } }
        return out.sorted { $0.path < $1.path }
    }

    /// jsoncpp writes object members in key order (its object is a std::map), so pages see the properties sorted;
    /// some iterate `Object.keys` and depend on that order (corsair_collection applies `effect` before `scene`).
    public static func json(_ v: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// The properties as the CEF host delivers them: objects with the current `value` plus the declaration's `type`
    /// (and `mode`/`fileType`), which the web host reads for `directory`/`file` handling (0x140018be4–0x1400190dc).
    public static func typedProperties(project: [String: Any], preset: [String: Any] = [:], overrides: [String: Any]) -> [String: Any] {
        let values = properties(project: project, preset: preset, overrides: overrides)
        let declared = ((project["general"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
        var props: [String: Any] = [:]
        for (k, v) in values {
            var o: [String: Any] = ["value": v]
            if let d = declared[k] as? [String: Any] {
                for f in ["type", "mode", "fileType"] { if let x = d[f] { o[f] = x } }
            }
            props[k] = o
        }
        return props
    }

    /// Current property values of a project (`general.properties[*].value`), with a preset and overrides on top.
    public static func properties(project: [String: Any], preset: [String: Any] = [:], overrides: [String: Any]) -> [String: Any] {
        UserProperties.load(project: project)
            .merging(preset.filter { !($0.value is NSNull) }) { _, b in b }
            .merging(overrides) { _, b in b }
    }
}
