#if os(Linux)
import CPhotonSystem
import Foundation
import PhotonApp

/// Processes as the application rules see them (docs/re/09 §1.5, docs/linux-port.md §5). The engine matches a rule's
/// `executable` against the executable file name of each window's process (rules+0x138) and of every running process
/// (rules+0xf8); on Linux the process comes from /proc: `exe` (its file name), `comm`, and for windows the X11
/// `WM_CLASS` or the Wayland app_id. `AppRule.matches` (shared with macOS) compares the rule, case-insensitively, with
/// `name`, `bundleID` and `executable`.
enum LinuxProcesses {
    /// /proc/<pid>/exe's file name ("" when unreadable: another user's process, or gone).
    static func exe(_ pid: Int32) -> String {
        exePath(pid).map { ($0 as NSString).lastPathComponent } ?? ""
    }

    static func exePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = readlink("/proc/\(pid)/exe", &buf, buf.count - 1)
        guard n > 0 else { return nil }
        var path = String(cString: buf)
        if path.hasSuffix(" (deleted)") { path.removeLast(" (deleted)".count) }
        return path
    }

    static func comm(_ pid: Int32) -> String {
        ((try? String(contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parent(_ pid: Int32) -> Int32? {
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8), let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        return fields.count > 1 ? Int32(fields[1]) : nil
    }

    /// A window's process: `name` = comm, `bundleID` = the window class (X11 `WM_CLASS` class), `executable` = the
    /// executable's file name.
    static func identity(pid: Int32, windowClass: String = "") -> AppIdentity {
        AppIdentity(pid: pid, name: comm(pid), bundleID: windowClass, executable: exe(pid))
    }

    /// A Wayland toplevel (no pid): `bundleID` = the app_id ("org.mozilla.firefox"), `name` = its last dotted part
    /// ("firefox"), so a rule naming the program matches either way.
    static func identity(appID: String) -> AppIdentity {
        let last = appID.split(separator: ".").last.map(String.init) ?? appID
        return AppIdentity(pid: 0, name: last, bundleID: appID, executable: last)
    }

    /// A window that has both (KWin's org_kde_plasma_window, the GNOME Shell extension's state): `executable` from
    /// /proc, `bundleID` the app_id, `name` the app_id's last dotted part (else `comm`), so a rule naming the program,
    /// the executable or the app_id matches. Without a pid, `identity(appID:)`; nil without either.
    static func identity(pid: Int32, appID: String) -> AppIdentity? {
        guard pid > 0 else { return appID.isEmpty ? nil : identity(appID: appID) }
        let last = appID.split(separator: ".").last.map(String.init) ?? ""
        return AppIdentity(pid: pid, name: last.isEmpty ? comm(pid) : last, bundleID: appID, executable: exe(pid))
    }

    /// The user's processes (condition-0 rules: "while the application runs").
    static func running() -> [AppIdentity] {
        let uid = getuid()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return [] }
        var out: [AppIdentity] = []
        var st = stat()
        for n in names {
            guard let pid = Int32(n), pid != getpid(), stat("/proc/\(n)", &st) == 0, st.st_uid == uid else { continue }
            let e = exe(pid)
            guard !e.isEmpty else { continue } // kernel threads have no exe
            out.append(AppIdentity(pid: pid, name: comm(pid), executable: e))
        }
        return out
    }

    /// The photon executable (`/proc/self/exe`).
    static let selfExe = exePath(getpid()) ?? ""

    /// photon's own processes: this one, the app and the other hosts (the same executable) and what they started
    /// (WebKit's web processes, a web host's audio). The engine excludes its own process from the audio sessions.
    static func isPhoton(_ pid: Int32) -> Bool {
        var p: Int32? = pid
        for _ in 0..<6 {
            guard let q = p, q > 1 else { return false }
            if q == getpid() || (!selfExe.isEmpty && exePath(q) == selfExe) { return true }
            p = parent(q)
        }
        return false
    }

    /// The audio inputs: whether a process other than photon has a playing stream (the "playing audio" rule,
    /// 0x140138b80), and those processes for "playingaudio" application rules. `PHOTON_AUDIO_STREAMS_LOG=1` prints the
    /// streams seen.
    static func audio(wantApps: Bool) -> (other: Bool, apps: [AppIdentity]) {
        var buf = [photon_audio_stream](repeating: photon_audio_stream(), count: 64)
        let n = Int(photon_audio_streams(&buf, Int32(buf.count)))
        guard n > 0 else { return (false, []) }
        var other = false
        var apps: [AppIdentity] = []
        let log = ProcessInfo.processInfo.environment["PHOTON_AUDIO_STREAMS_LOG"] == "1"
        for s in buf.prefix(n) {
            let bin = withUnsafeBytes(of: s.binary) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let own = s.pid > 0 && isPhoton(s.pid)
            if log {
                let name = withUnsafeBytes(of: s.application) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                print("audio stream \(s.index): pid \(s.pid) \(bin) \"\(name)\" \(s.corked != 0 ? "corked" : "playing")\(own ? " (photon)" : "")")
            }
            guard s.corked == 0, !own else { continue }
            other = true
            if wantApps {
                apps.append(s.pid > 0 ? identity(pid: s.pid) : AppIdentity(pid: 0, name: bin, executable: bin))
            }
        }
        return (other, apps)
    }

    /// Everything the evaluator needs besides the windows, read only when a rule can use it.
    static func appInputs(settings: PlaybackSettings, rules: [AppRule]) -> DesktopAppInputs {
        var a = DesktopAppInputs()
        if rules.contains(where: { $0.condition == .running }) { a.running = running() }
        let wantApps = rules.contains { $0.condition == .playingAudio }
        if settings.audio != .run || wantApps {
            let r = audio(wantApps: wantApps)
            a.otherAudio = r.other
            a.audioApps = r.apps
        }
        return a
    }
}
#endif
