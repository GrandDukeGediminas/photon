import Foundation

// photon's own energy controls. Wallpaper Engine has none of these: its only power input is the battery playback rule
// (run / pause / stop, docs/re/09 §1), and its `fps` setting does not reach web wallpapers (webwallpaper64 creates a
// windowed CEF browser with no frame-rate setting and ignores `fps`, docs/re/09 §6). The controls sit on top of the
// engine's `fps` setting and rules; with them off the engine's behaviour is unchanged.

/// The operating system's thermal pressure (macOS `ProcessInfo.ThermalState`).
package enum ThermalLevel: Int, Comparable, Codable {
    case nominal = 0, fair, serious, critical
    package static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// What the power probes saw.
package struct EnergyInputs: Equatable {
    /// Running on battery (macOS IOPS providing power source, Linux UPower OnBattery / sysfs).
    package var onBattery = false
    /// macOS Low Power Mode, or the Linux power-profiles-daemon "power-saver" profile.
    package var lowPower = false
    package var thermal = ThermalLevel.nominal

    package init(onBattery: Bool = false, lowPower: Bool = false, thermal: ThermalLevel = .nominal) {
        self.onBattery = onBattery; self.lowPower = lowPower; self.thermal = thermal
    }
}

/// The user's energy settings.
package struct EnergySettings: Equatable {
    /// The frame-rate cap while saving power (on battery, or Low Power Mode when `followLowPower`); 0 = keep `fps`.
    package var batteryFPS = 30
    /// Low Power Mode counts as being on battery: the battery frame rate and the engine's battery rule apply.
    package var followLowPower = true
    /// Serious thermal pressure halves the frame rate; critical pauses every wallpaper until it cools.
    package var thermalBackoff = true
    /// Web wallpapers follow the frame-rate limit too. Off, they run at the display's refresh rate as in the engine,
    /// except while saving power or hot.
    package var capWebPages = true

    package init(batteryFPS: Int = 30, followLowPower: Bool = true, thermalBackoff: Bool = true, capWebPages: Bool = true) {
        self.batteryFPS = batteryFPS; self.followLowPower = followLowPower; self.thermalBackoff = thermalBackoff
        self.capWebPages = capWebPages
    }

    /// The defaults keys (photon-only, so they never collide with the engine's config names).
    package static let batteryFPSKey = "photonbatteryfps"
    package static let followLowPowerKey = "photonlowpower"
    package static let thermalBackoffKey = "photonthermal"
    package static let capWebPagesKey = "photoncapweb"

    package init(defaults: UserDefaults) {
        self.init()
        if let v = defaults.object(forKey: Self.batteryFPSKey) as? Int { batteryFPS = max(v, 0) }
        if let v = defaults.object(forKey: Self.followLowPowerKey) as? Bool { followLowPower = v }
        if let v = defaults.object(forKey: Self.thermalBackoffKey) as? Bool { thermalBackoff = v }
        if let v = defaults.object(forKey: Self.capWebPagesKey) as? Bool { capWebPages = v }
    }

    package func save(to defaults: UserDefaults) {
        defaults.set(batteryFPS, forKey: Self.batteryFPSKey)
        defaults.set(followLowPower, forKey: Self.followLowPowerKey)
        defaults.set(thermalBackoff, forKey: Self.thermalBackoffKey)
        defaults.set(capWebPages, forKey: Self.capWebPagesKey)
    }
}

/// The result: the frame rate in use and why.
package struct EnergyState: Equatable {
    /// Frame-rate cap now in use (0 = unlimited).
    package var fps: Int
    /// The cap for web wallpapers (0 = the display's refresh rate).
    package var webFPS: Int
    /// The playback rules see the system as on battery (on battery, or Low Power Mode with `followLowPower`).
    package var saving: Bool
    /// Critical thermal pressure with `thermalBackoff`: every wallpaper pauses (host flag `.overheated`).
    package var overheated: Bool
    /// Why `fps` differs from the setting, in order ("on battery", "Low Power Mode", "Mac is hot").
    package var reasons: [String]

    package init(fps: Int, webFPS: Int? = nil, saving: Bool = false, overheated: Bool = false, reasons: [String] = []) {
        self.fps = fps; self.webFPS = webFPS ?? fps; self.saving = saving; self.overheated = overheated; self.reasons = reasons
    }

    /// One line for Settings: "60 fps", "30 fps: on battery", "Paused: the Mac is very hot".
    package var summary: String {
        if overheated { return "Paused: the computer is very hot" }
        let rate = fps == 0 ? "Unlimited frame rate" : "\(fps) fps"
        return reasons.isEmpty ? rate : "\(rate): \(reasons.joined(separator: ", "))"
    }
}

package enum EnergyPolicy {
    /// The frame rate used when serious heat halves an unlimited setting.
    package static let unlimitedBase = 60
    /// Heat never halves below this.
    package static let minimumFPS = 5

    package static func evaluate(fps setting: Int, settings: EnergySettings, inputs: EnergyInputs) -> EnergyState {
        var fps = max(setting, 0)
        var reasons: [String] = []
        let lowPower = settings.followLowPower && inputs.lowPower
        let saving = inputs.onBattery || lowPower
        if saving, settings.batteryFPS > 0, fps == 0 || settings.batteryFPS < fps {
            fps = settings.batteryFPS
            if inputs.onBattery { reasons.append("on battery") }
            if lowPower { reasons.append("Low Power Mode") }
        }
        var overheated = false
        if settings.thermalBackoff, inputs.thermal >= .serious {
            if inputs.thermal == .critical { overheated = true }
            fps = max((fps == 0 ? unlimitedBase : fps) / 2, minimumFPS)
            reasons.append("computer is hot")
        }
        // Web pages run at the refresh rate in the engine; with `capWebPages` off they still do unless something above
        // lowered the rate.
        let webFPS = settings.capWebPages || !reasons.isEmpty ? fps : 0
        return EnergyState(fps: fps, webFPS: webFPS, saving: saving, overheated: overheated, reasons: reasons)
    }
}
