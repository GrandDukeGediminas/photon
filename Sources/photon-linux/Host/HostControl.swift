#if os(Linux)
import Foundation

/// `photon-linux desktop … --control`: the app (`photon-linux app`, App/HostSupervisor.swift) drives a running host
/// through its stdin, one command per line, so tray pause, mute, master volume and the live general properties
/// (alignment, colour options, rate, volume: the engine applies them without reloading) need no restart:
///
///     pause 0|1          the tray pause (wallpaper64 host flag 0x1): every output pauses, with the pause fade
///     mute 0|1           the tray mute (host flag 0x40): the volume fades to 0
///     volume P           wallpaper volume × master volume, percent
///     rate P             the wallpaper's `rate` general property, percent
///     general {json}     the wallpaper's general properties (`applyGeneralProperties`; web pages get the CSS filter)
///     load {json}        switch to another scene / video wallpaper on the same outputs, with the switch transition
///                        (`dir`, `properties`, `general`, `volume`, `rate`, `transition`; SceneHost.swift)
///     snapshot DIR       write the frame of every output to DIR for the host that takes over (`snapshot: written`),
///                        then stop drawing
///     quit               end the host
///
/// End of input (the app went away) ends the host too. Lines are read without blocking from the host's own loop.
final class HostControl {
    enum Command {
        case pause(Bool), mute(Bool), volume(Float), rate(Float), general([String: Any]), load([String: Any]), snapshot(String), quit
    }

    private var buffer = [UInt8]()
    private(set) var closed = false

    init() {
        let flags = fcntl(0, F_GETFL)
        _ = fcntl(0, F_SETFL, flags | O_NONBLOCK)
    }

    /// Commands that arrived since the last call.
    func poll() -> [Command] {
        guard !closed else { return [] }
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(0, &chunk, chunk.count)
            if n > 0 { buffer += chunk[0..<n]; continue }
            if n == 0 { closed = true }
            break // EAGAIN: nothing more for now
        }
        var out: [Command] = []
        while let nl = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[..<nl], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            buffer.removeSubrange(...nl)
            if let c = Self.parse(line) { out.append(c) }
        }
        if closed { out.append(.quit) }
        return out
    }

    static func parse(_ line: String) -> Command? {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = parts.first else { return nil }
        let arg = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "pause": return .pause(arg == "1" || arg == "true")
        case "mute": return .mute(arg == "1" || arg == "true")
        case "volume": return Float(arg).map { .volume($0) }
        case "rate": return Float(arg).map { .rate($0) }
        case "general":
            guard let d = arg.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
            return .general(o)
        case "load":
            guard let d = arg.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
            return .load(o)
        case "snapshot": return arg.isEmpty ? nil : .snapshot(arg)
        case "quit": return .quit
        default: return nil
        }
    }
}

/// `--output NAME[,NAME…]`: the outputs a host covers (connector names as `--list-outputs` prints them, or indices).
enum OutputFilter {
    static func matches(_ filter: [String]?, name: String, index: Int) -> Bool {
        guard let filter, !filter.isEmpty else { return true }
        return filter.contains(name) || filter.contains(String(index))
    }
}
#endif
