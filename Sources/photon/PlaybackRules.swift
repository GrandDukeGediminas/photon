import AppKit
import CoreAudio
import Foundation
import IOKit.ps
import Metal

// Wallpaper Engine's automatic playback rules (docs/re/09-host.md §1), ported from wallpaper64.exe:
// settings reader 0x14006c280, mode parser 0x140141880, window-state probe 0x14003d050 / EnumWindows callback 0x14003bba0,
// evaluator 0x14006cea0 (WM_TIMER 0x68, every `windowupdaterate` ms clamped to 50…5000, default 1000), app rules
// 0x140134b70 / 0x1401359c0, sleep 0x14006ed90, pause/mute apply 0x1400739a0, stop apply 0x140073ac0.

extension AppIdentity {
    init(pid: pid_t) {
        let app = NSRunningApplication(processIdentifier: pid)
        self.init(pid: pid, name: app?.localizedName ?? "", bundleID: app?.bundleIdentifier ?? "",
                  executable: app?.executableURL?.lastPathComponent ?? "")
    }
}

/// Watches the system and re-evaluates the rules on the `windowupdaterate` timer, like the engine's WM_TIMER 0x68.
/// Also handles the event-driven states: display sleep, power source, screen lock and screensaver.
final class PlaybackMonitor {
    private weak var state: AppState?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var distributed: [NSObjectProtocol] = []
    private var vram = VRAMRule()
    /// The lock handler paused playback (wallpaper64 `0x1404df540 & 0x40`), so unlock resumes it.
    private var pausedByLock = false

    init(state: AppState) {
        self.state = state
        let ws = NSWorkspace.shared.notificationCenter
        // GUID_MONITOR_POWER_ON / GUID_SESSION_DISPLAY_STATUS (0x140023dc4): display off → sleep(true), on → sleep(false).
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setAsleep(true)
        })
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setAsleep(false)
        })
        // Re-evaluate right away when the foreground application changes (the engine also has a WinEvent hook).
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.evaluate()
        })
        let dc = DistributedNotificationCenter.default()
        // WM_WTSSESSION_CHANGE (0x140023b09): WTS_SESSION_LOCK pauses (unless already paused) and remembers it; unlock resumes.
        distributed.append(dc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self, let state = self.state else { return }
            if !state.paused {
                self.pausedByLock = true
                state.paused = true
            }
        })
        distributed.append(dc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self, let state = self.state, self.pausedByLock else { return }
            self.pausedByLock = false
            state.paused = false
        })
        // The engine's screensaver sends WM_COPYDATA 1014 (flag 0x400000, pause all); it is cleared on the next tick
        // once SPI_GETSCREENSAVERRUNNING says it stopped (0x140023ee7).
        distributed.append(dc.addObserver(forName: Notification.Name("com.apple.screensaver.didstart"), object: nil, queue: .main) { [weak self] _ in
            self?.state?.hostFlags.insert(.screensaver); self?.evaluate()
        })
        distributed.append(dc.addObserver(forName: Notification.Name("com.apple.screensaver.didstop"), object: nil, queue: .main) { [weak self] _ in
            self?.state?.hostFlags.remove(.screensaver); self?.evaluate()
        })
        // Energy controls (Energy.swift): react to Low Power Mode and heat right away, not only on the next tick.
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.evaluate()
        })
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.evaluate()
        })
        restartTimer()
        evaluate()
    }

    deinit {
        timer?.invalidate()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        distributed.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    }

    func restartTimer() {
        timer?.invalidate()
        let ms = min(max(state?.playback.windowUpdateRate ?? 1000, 50), 5000)
        timer = Timer.scheduledTimer(withTimeInterval: Double(ms) / 1000, repeats: true) { [weak self] _ in self?.evaluate() }
    }

    /// `0x14006ed90`: sleep with "pause" sets flag 0x20 (everything pauses), "stop" sets it and stops; "run" ignores it.
    private func setAsleep(_ asleep: Bool) {
        guard let state else { return }
        if asleep {
            guard state.playback.sleep != .run else { return }
            state.hostFlags.insert(.asleep)
            if state.playback.sleep == .stop { state.decision.stop = true }
        } else {
            state.hostFlags.remove(.asleep)
        }
        evaluate()
    }

    func evaluate() {
        guard let state else { return }
        var flags = state.hostFlags
        state.energyInputs = Self.energyInputs
        // The battery rule also covers Low Power Mode when the energy settings say so; heat can pause everything.
        if state.energy.saving { flags.insert(.onBattery) } else { flags.remove(.onBattery) }
        if state.energy.overheated { flags.insert(.overheated) } else { flags.remove(.overheated) }
        if state.playback.pauseOnVRAMExhaustion { updateVRAM(&flags) } else { flags.remove(.vramExhausted) }
        if flags != state.hostFlags { state.hostFlags = flags }
        // While asleep the engine skips the pause update (0x14006d45b); a stop decided by sleep stays.
        if flags.contains(.asleep) { return }
        let snap = Self.snapshot(rules: state.rules)
        var d = PlaybackEvaluator.evaluate(snap, settings: state.playback, rules: state.rules, flags: flags, layout: state.layout)
        if d.stop { d.pauseMask = state.decision.pauseMask }
        if d != state.decision { state.decision = d }
    }

    /// `pausevram` (0x14006d2e5–0x14006d3f5): usage ≥ 80 % of the budget stops everything (flag 0x400); it is released when
    /// usage drops below 75 % after more than 15 s, or below 35 %. Metal's working-set size stands in for the DXGI budget.
    private func updateVRAM(_ flags: inout HostFlags) {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let budget = Double(device.recommendedMaxWorkingSetSize), used = Double(device.currentAllocatedSize)
        if let line = vram.update(used: used, budget: budget, flags: &flags) { NSLog("photon: %@", line) }
    }

    static var energyInputs: EnergyInputs {
        let thermal: ThermalLevel
        switch ProcessInfo.processInfo.thermalState {
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        default: thermal = .nominal
        }
        return EnergyInputs(onBattery: onBattery, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: thermal)
    }

    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }

    // MARK: - Window probe (0x14003d050 / 0x14003bba0)

    /// The foreground window's display gets the focus bit; it also gets the fullscreen bit when the window covers the whole
    /// display (GetWindowRect ≥ monitor rect, 0x14003bfa9). Every visible, non-minimised window of another application that
    /// fills its display's work area counts as maximized (WS_MAXIMIZE on Windows). The desktop (Finder's desktop window,
    /// the engine's Progman/WorkerW) and photon's own windows (the engine's WPEUI) never count. An application with a rule
    /// for that state is left out of the global mask (0x14003be61), its rule decides instead.
    static func snapshot(rules: [AppRule]) -> SystemSnapshot {
        var snap = SystemSnapshot()
        let screens = NSScreen.screens
        let frames = screens.map { CGDisplayBounds($0.displayID) }
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let work = screens.map { s -> CGRect in
            let v = s.visibleFrame
            return CGRect(x: v.minX, y: mainHeight - v.maxY, width: v.width, height: v.height)
        }
        for i in 0..<min(screens.count, 32) { snap.allMask |= 1 << UInt32(i) }
        let own = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var identities: [pid_t: AppIdentity] = [:]
        func identity(_ pid: pid_t) -> AppIdentity {
            if let i = identities[pid] { return i }
            let i = AppIdentity(pid: pid); identities[pid] = i; return i
        }
        func hasRule(_ pid: pid_t, _ c: AppRule.Condition) -> Bool { rules.contains { $0.condition == c && $0.matches(identity(pid)) } }
        func display(of r: CGRect) -> Int? {
            var best: Int?, area: CGFloat = 0
            for (i, f) in frames.enumerated() {
                let x = f.intersection(r)
                if !x.isNull, x.width * x.height > area { area = x.width * x.height; best = i }
            }
            return best
        }
        var foregroundSeen = false
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != own,
                  (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.width > 1, r.height > 1,
                  let d = display(of: r), d < 32 else { continue }
            let bit = UInt32(1) << UInt32(d)
            let tol: CGFloat = 2
            let coversWork = r.minX <= work[d].minX + tol && r.minY <= work[d].minY + tol
                && r.maxX >= work[d].maxX - tol && r.maxY >= work[d].maxY - tol
            let coversScreen = r.width >= frames[d].width && r.height >= frames[d].height
            let isForeground = pid == front && !foregroundSeen
            // A foreground window that covers the whole display is the fullscreen case, not a maximized one.
            if coversWork && !(isForeground && coversScreen) {
                if hasRule(pid, .maximized) { snap.windows.append((identity(pid), d, .maximized)) } else { snap.maximizedMask |= bit }
            }
            if isForeground {
                foregroundSeen = true
                if hasRule(pid, .focused) { snap.windows.append((identity(pid), d, .focused)) } else { snap.focusMask = bit }
                if coversScreen {
                    if hasRule(pid, .fullscreen) { snap.windows.append((identity(pid), d, .fullscreen)) } else { snap.fullscreenMask |= bit }
                }
            }
        }
        if !rules.isEmpty {
            snap.running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map { identity($0.processIdentifier) }
        }
        let audioPIDs = Self.audioPIDs().subtracting([own])
        snap.otherAudio = !audioPIDs.isEmpty
        if rules.contains(where: { $0.condition == .playingAudio }) { snap.audioApps = audioPIDs.map(identity) }
        return snap
    }

    /// Processes with running audio output (Core Audio process objects, macOS 14.2+); the engine watches WASAPI audio
    /// sessions of other processes (AudioEventHandler, 0x140138b80).
    static func audioPIDs() -> Set<pid_t> {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        var result = Set<pid_t>()
        for id in ids {
            var running: UInt32 = 0, rs = UInt32(MemoryLayout<UInt32>.size)
            var ra = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &ra, 0, nil, &rs, &running) == noErr, running != 0 else { continue }
            var pid: pid_t = 0, ps = UInt32(MemoryLayout<pid_t>.size)
            var pa = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(id, &pa, 0, nil, &ps, &pid) == noErr, pid > 0 { result.insert(pid) }
        }
        return result
    }
}
