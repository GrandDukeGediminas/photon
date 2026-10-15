import Foundation

// The platform-independent half of the system-audio capture (docs/re/06 §5): the packet queue between a capture
// callback and the analysis thread, and `AudioSystem`, the engine's `Audio_Thread` loop around `AudioAnalyzer`. The
// capture backends are per platform: AudioCapture.swift (macOS: Core Audio process tap, ScreenCaptureKit) and
// Linux/AudioCaptureLinux.swift (PipeWire, PulseAudio).

/// Packets handed from a capture callback to the analysis thread.
final class AudioPacketQueue {
    private let lock = NSLock()
    private var packets: [AudioPacket] = []
    private var frames = 0
    /// Drop the oldest packets past ~2 s at 48 kHz if the analysis thread stalls.
    private let maxFrames = 96_000

    func push(_ p: AudioPacket) {
        lock.lock(); defer { lock.unlock() }
        packets.append(p)
        frames += p.frames
        while frames > maxFrames, !packets.isEmpty { frames -= packets.removeFirst().frames }
    }

    func drain() -> [AudioPacket] {
        lock.lock(); defer { lock.unlock() }
        let out = packets
        packets.removeAll(keepingCapacity: true)
        frames = 0
        return out
    }
}

/// A running system-output capture.
protocol AudioCaptureBackend: AnyObject {
    var name: String { get }
    var sampleRate: Double { get }
    func stop()
}

func makePacket(interleaved: UnsafePointer<Float>, frames: Int, channels: Int) -> AudioPacket {
    let s = Array(UnsafeBufferPointer(start: interleaved, count: frames * channels))
    return AudioPacket(samples: s, channels: channels, silent: !s.contains { $0 != 0 })
}

// MARK: - Shared capture + analysis

/// Process-wide system-audio capture feeding one `AudioAnalyzer` on its own thread
/// (the engine's `Audio_Thread`). Renderers read `latestSpectrum()` once per frame.
public final class AudioSystem {
    public static let shared = AudioSystem()
    /// Set by uniform packing when a compiled program has a g_AudioSpectrum* member.
    public static var shaderDemand = false

    /// Thread poll period in ms: clamp(floor(1000/fps)·0.5, 6, 100) (docs/re/06 §5.1). 60 fps → 8.
    public var pollPeriodMs = AudioSystem.pollPeriod(fps: 15)

    /// The settings reader's formula (0x14006c6c3–0x14006c733): `floorf(1000 / fps)` (0x14041a5c0, `roundss` mode 9),
    /// times 0.5, clamped to [6, 100] (a NaN or infinity from fps 0 takes 100), truncated. The default fps 15 gives 33 ms.
    public static func pollPeriod(fps: Int) -> Int {
        let x = floorf(1000 / Float(fps)) * 0.5
        guard 100 > x else { return 100 }
        return Int(6 > x ? 6 : x)
    }
    /// `audioinputvolume × 0.02`; default volume 50 → 1.0.
    public var gain: Float = 1
    /// `audioinputthreshold × 0.001`; default 0.
    public var threshold: Float = 0

    public private(set) var backendName: String?
    let packets = AudioPacketQueue()
    private var backend: AudioCaptureBackend?
    private var thread: Thread?
    private let lock = NSLock()
    private var spectrum = [Float](repeating: 0, count: 128)
    private var running = false
    private var sampleRate: Double = 48000
    private var sawAudio = false
    private var startedAt = Date()

    private static var logged = Set<String>()
    private static let logLock = NSLock()
    static func logOnce(_ msg: String) {
        logLock.lock(); defer { logLock.unlock() }
        if logged.insert(msg).inserted { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!) }
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    /// The capture backend's sample rate (the analyzer's N and fill depend on it).
    public var captureRate: Double { lock.lock(); defer { lock.unlock() }; return sampleRate }

    /// Starts capture (idempotent): `startPlatformBackend` (AudioCapture.swift on macOS: the process tap, then
    /// ScreenCaptureKit; Linux/AudioCaptureLinux.swift: PipeWire, then PulseAudio). On failure the spectrum stays zero
    /// and one line is logged.
    public func start() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()

        startPlatformBackend()
    }

    func attach(_ b: AudioCaptureBackend) {
        lock.lock()
        backend = b
        backendName = b.name
        sampleRate = b.sampleRate
        startedAt = Date()
        lock.unlock()
        Self.logOnce("photon: audio capture via \(b.name) at \(Int(b.sampleRate)) Hz")
        let t = Thread { [weak self] in self?.run() }
        t.name = "photon.audio.analysis"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    public func stop() {
        lock.lock()
        running = false
        let b = backend
        backend = nil
        spectrum = [Float](repeating: 0, count: 128)
        lock.unlock()
        b?.stop()
        thread = nil
    }

    /// The latest 128-float spectrum (zeros when stopped, silent or denied).
    public func latestSpectrum() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return spectrum
    }

    private func run() {
        let analyzer = AudioAnalyzer(sampleRate: sampleRate, gain: gain, threshold: threshold)
        while isRunning {
            let period = min(max(pollPeriodMs, 6), 100)
            usleep(useconds_t(period * 1000))
            let batch = packets.drain()
            if !sawAudio {
                if batch.contains(where: { !$0.silent }) {
                    sawAudio = true
                } else if Date().timeIntervalSince(startedAt) > 5 {
                    Self.logOnce(Self.silenceHint)
                }
            }
            analyzer.gain = gain
            analyzer.threshold = threshold
            if let out = analyzer.poll(batch, periodMs: period) {
                lock.lock(); spectrum = out; lock.unlock()
            }
        }
    }
}
