import Foundation
import PhotonApp

/// The energy controls' host arguments (Energy.swift), shared by the scene and web hosts. The app passes `--fps 240`
/// for an unlimited frame rate (a loop needs a period), which is the setting 0 here.
enum EnergyOptions {
    static let unlimitedLoopRate: Double = 240

    static func parse(_ flag: String, _ value: String?, into e: inout EnergySettings) {
        switch flag {
        case "--battery-fps": e.batteryFPS = value.flatMap(Int.init).map { max($0, 0) } ?? e.batteryFPS
        case "--low-power": e.followLowPower = value != "ignore"
        case "--cap-web": e.capWebPages = value != "off"
        default: break
        }
    }

    static func arguments(_ e: EnergySettings) -> [String] {
        ["--battery-fps", String(e.batteryFPS), "--low-power", e.followLowPower ? "follow" : "ignore",
         "--cap-web", e.capWebPages ? "on" : "off"]
    }

    /// The `fps` setting from `--fps` (240 or more = unlimited = 0).
    static func baseFPS(_ fps: Double) -> Int { fps >= unlimitedLoopRate ? 0 : max(Int(fps.rounded()), 1) }

    static func loopRate(_ fps: Int) -> Double { fps == 0 ? unlimitedLoopRate : Double(fps) }
}
