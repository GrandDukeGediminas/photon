#if !os(Linux)
import AVFoundation
import CoreAudio
#endif
import Foundation

/// OpenAL Soft 1.21.1 HRTF rendering as `mediaextensions64.dll` does it on a headphone output (docs/re/06 §4.1,
/// evidence/session8-leftovers MI5).
///
/// When it is used (dll):
/// * The engine opens the default device with `alcOpenDevice(NULL)` and `alcCreateContext(dev, NULL)` (0x18000ef96 /
///   0x18000efb0, again at 0x18000f0ea / 0x18000f104): no ALC_HRTF_SOFT attribute, so the app request is "default".
///   Without an alsoft.ini the user request is "default" too.
/// * WASAPI (0x18018693e–0x1801869a8): the endpoint's PKEY_AudioEndpoint_FormFactor (VT_UI4; 10 when unreadable)
///   sets `IsHeadphones` (device +0x16) = stereo output (+0x14 == 1) && form factor ∈ {Headphones 3, Headset 5}.
/// * `aluInitRenderer` (0x18019950b–0x18019986e): `stereo-mode` (absent → auto) keeps that flag; with both requests at
///   default, headphones → HRTF (status ALC_HRTF_HEADPHONES_DETECTED_SOFT = 4 at +0x7048), else the pair-wise panning
///   of `SoundSpatial.ambiGains`. The first loadable entry of the HRTF list is used: with no `.mhr` files in the
///   search paths that is "Built-In HRTF" (0x18018b3dc, the MinPHR03 blob at dll 0x1802b9390). `hrtf-size` absent →
///   the store's IR size. `InitHrtfPanning` 0x180197df0: `hrtf-mode` absent → render mode 2 (full HRTF, +0x54).
///
/// Per source (`CalcPanningAndFilters`, render mode 2 at 0x180192983):
/// * positional (`SoundSpatial.toSource` distance > max(FLT_EPSILON, AL_REFERENCE_DISTANCE/1024)): ev =
///   asin(clamp(y, −1, 1)), az = atan2(x, −z) of the normalised direction, `GetHrtfCoeffs`(ev, az, distance, spread)
///   once, gain = DryGain (no ambisonic decode, no 0.5 speaker matrix);
/// * otherwise (distance 0 or a non-spatialised buffer, 0x180192c92): every channel but LFE gets `GetHrtfCoeffs`(its
///   elevation, its angle, +inf, spread) at DryGain: mono 0°, stereo −30° / +30° (0x18019239b–0x18019241d).
/// Spread is 0 (AL radius 0).
///
/// Store (`GetLoadedHrtf` 0x18018b0d0, `LoadHrtf03` 0x18018d920): see `HrtfStore`. Mixer: `HrtfVoiceFilter`.
public final class HrtfStore {
    /// HrirLength: 128 taps (coefficient rows of 0x400 bytes).
    public static let hrirLength = 128
    /// HrtfHistoryLength (0x40 in MixHrtf / 0x41 in MixHrtfBlend, 0x1801a39f6 / 0x1801a3bc1).
    static let historyLength = 64
    /// MaxHrirDelay (0x1802cce9c = 63.0).
    static let maxHrirDelay: Float = 63
    /// 2 fractional delay bits (×0.25 at 0x18018ae85, ×4 at 0x18018baed).
    static let delayFracOne: Float = 4

    public struct Field { public var distance: Float; public var evCount: Int }
    public struct Elevation { public var azCount: Int; public var irOffset: Int }

    public private(set) var sampleRate: Int
    public private(set) var irSize: Int
    public let fields: [Field]
    public let elevations: [Elevation]
    /// irCount × 128 × (left, right).
    public private(set) var coeffs: [Float]
    /// irCount × (left, right), in quarter samples.
    public private(set) var delays: [UInt8]
    public var irCount: Int { delays.count / 2 }

    init(sampleRate: Int, irSize: Int, fields: [Field], elevations: [Elevation], coeffs: [Float], delays: [UInt8]) {
        self.sampleRate = sampleRate; self.irSize = irSize; self.fields = fields; self.elevations = elevations
        self.coeffs = coeffs; self.delays = delays
    }

    /// `LoadHrtf03` 0x18018d920 for the MinPHR03 bytes after the 8-byte magic. Header: rate u32, channel type u8
    /// (0 left only, 1 left+right; > 1 rejected), IR size u8 (8…128), field count u8 (1…16). Per field: distance u16 mm
    /// (50…2500, stored /1000 as metres; each field must not be farther than the previous one, 0x18018dae6), elevation
    /// count u8 (5…181), then that many azimuth counts u8 (1…255). IR offsets accumulate over all elevations
    /// (0x18018dc06–0x18018dc5b). Coefficients: per IR, per tap, int24 per channel → (v ^ 0x800000) − 0x800000, × 2⁻²³
    /// (0x18018de36–0x18018de4d). Delays: per IR u8 per channel, each ≤ 252 (63 << 2, 0x18018dec3). A left-only set is
    /// mirrored (0x18018e1f0): IR (offset + (azCount − a) mod azCount) gets IR a's left taps and delay as its right ear.
    public static func parse03(_ d: Data) -> HrtfStore? {
        let b = [UInt8](d)
        var p = 0
        func u8() -> Int? { guard p < b.count else { return nil }; defer { p += 1 }; return Int(b[p]) }
        func u16() -> Int? { guard let lo = u8(), let hi = u8() else { return nil }; return lo | hi << 8 }
        guard b.count >= 8, String(bytes: b[0..<8], encoding: .ascii) == "MinPHR03" else { return nil }
        p = 8
        guard let r0 = u16(), let r1 = u16(), let chanType = u8(), let irSize = u8(), let fdCount = u8(),
              chanType <= 1, (8...128).contains(irSize), (1...16).contains(fdCount) else { return nil }
        let rate = r0 | r1 << 16
        var fields: [Field] = [], elevs: [Elevation] = []
        var irCount = 0
        for f in 0..<fdCount {
            guard let mm = u16(), let evc = u8(), (50...2500).contains(mm), (5...181).contains(evc) else { return nil }
            let dist = Float(mm) / 1000
            if f > 0, dist > fields[f - 1].distance { return nil }
            fields.append(Field(distance: dist, evCount: evc))
            for _ in 0..<evc {
                guard let az = u8(), (1...255).contains(az) else { return nil }
                elevs.append(Elevation(azCount: az, irOffset: irCount))
                irCount += az
            }
        }
        let nch = chanType == 1 ? 2 : 1
        guard b.count >= p + irCount * irSize * nch * 3 + irCount * nch else { return nil }
        var coeffs = [Float](repeating: 0, count: irCount * hrirLength * 2)
        for i in 0..<irCount {
            for k in 0..<irSize {
                for c in 0..<nch {
                    let v = Int32(b[p]) | Int32(b[p + 1]) << 8 | Int32(b[p + 2]) << 16
                    p += 3
                    coeffs[(i * hrirLength + k) * 2 + c] = Float((v ^ 0x800000) - 0x800000) * Float(bitPattern: 0x3400_0000)
                }
            }
        }
        var delays = [UInt8](repeating: 0, count: irCount * 2)
        for i in 0..<irCount {
            for c in 0..<nch {
                let v = b[p]; p += 1
                guard v <= 252 else { return nil }
                delays[i * 2 + c] = v
            }
        }
        if nch == 1 {
            for e in elevs {
                for a in 0..<e.azCount {
                    let l = e.irOffset + a, r = e.irOffset + (e.azCount - a) % e.azCount
                    for k in 0..<hrirLength { coeffs[(r * hrirLength + k) * 2 + 1] = coeffs[(l * hrirLength + k) * 2] }
                    delays[r * 2 + 1] = delays[l * 2]
                }
            }
        }
        return HrtfStore(sampleRate: rate, irSize: irSize, fields: fields, elevations: elevs, coeffs: coeffs, delays: delays)
    }

    /// The "Built-In HRTF" of OpenAL Soft as linked into the engine: the MinPHR03 blob in `mediaextensions64.dll`
    /// (found by its magic; the strings table holds the bare magics, which fail to parse).
    public static func builtIn(dll: URL) -> HrtfStore? {
        guard let data = try? Data(contentsOf: dll, options: .alwaysMapped) else { return nil }
        let magic = Data("MinPHR03".utf8)
        var from = data.startIndex
        while let r = data.range(of: magic, in: from..<data.endIndex) {
            if let s = parse03(data.subdata(in: r.lowerBound..<min(data.endIndex, r.lowerBound + 0x40000))) { return s }
            from = r.upperBound
        }
        return nil
    }

    /// `GetLoadedHrtf` 0x18018b5b5–0x18018bb80 when the device rate differs from the store's: every IR's 128 taps per ear
    /// go through `PPhaseResampler` (double, `rs.process(128, in, 128, out)`, then to float); delays become
    /// roundf(d · rate/srcRate) / 4, scaled down by 63 / max when the largest exceeds 63 samples, stored as
    /// (int)(v · 4 · scale + 0.5); irSize = (uint)min(128, roundf(irSize · rate/srcRate)).
    public func resampled(to rate: Int) -> HrtfStore {
        guard rate != sampleRate, rate > 0 else { return self }
        let rs = PPhaseResampler(srcRate: sampleRate, dstRate: rate)
        var c = coeffs
        var inp = [Double](repeating: 0, count: Self.hrirLength), out = inp
        for i in 0..<irCount {
            for j in 0..<2 {
                for k in 0..<Self.hrirLength { inp[k] = Double(coeffs[(i * Self.hrirLength + k) * 2 + j]) }
                rs.process(inp, &out)
                for k in 0..<Self.hrirLength { c[(i * Self.hrirLength + k) * 2 + j] = Float(out[k]) }
            }
        }
        let scale = Float(rate) / Float(sampleRate)
        var newDelays = [Float](repeating: 0, count: delays.count)
        var maxDelay: Float = 0
        for i in 0..<delays.count {
            let v = (Float(delays[i]) * scale).rounded() / Self.delayFracOne
            maxDelay = max(maxDelay, v)
            newDelays[i] = v
        }
        var delayScale = Self.delayFracOne
        if maxDelay > Self.maxHrirDelay { delayScale = Self.maxHrirDelay / maxDelay * Self.delayFracOne }
        let d = newDelays.map { UInt8(truncatingIfNeeded: Int32(($0 * delayScale + 0.5).rounded(.towardZero))) }
        let ir = Int(min(Float(Self.hrirLength), (Float(irSize) * scale).rounded()))
        return HrtfStore(sampleRate: rate, irSize: ir, fields: fields, elevations: elevations, coeffs: c, delays: d)
    }

    /// One HRTF filter: taps (left, right interleaved, 128 pairs) and integer sample delays.
    public struct Filter {
        public var coeffs = [Float](repeating: 0, count: HrtfStore.hrirLength * 2)
        public var delay: (UInt32, UInt32) = (0, 0)
    }

    /// `GetHrtfCoeffs` 0x18018abc0, operation for operation (float32).
    public func filter(elevation: Float, azimuth: Float, distance: Float, spread: Float) -> Filter {
        let tau = Float(bitPattern: 0x40c9_0fdb), halfPi = Float(bitPattern: 0x3fc9_0fdb), pi = Float(bitPattern: 0x4049_0fdb)
        let dirfact = 1 - spread / tau
        // Field: walk to nearer fields while the current one is farther than the source (0x18018ac4d–0x18018ac6d).
        var f = 0, ebase = 0
        while fields[f].distance > distance && f != fields.count - 1 { ebase += fields[f].evCount; f += 1 }
        let evCount = fields[f].evCount
        // CalcEvIndex: (ev + π/2)·(n − 1)/π, truncated, index clamped to n − 1, blend from the unclamped index.
        let ev = (elevation + halfPi) * Float(evCount - 1) / pi
        let evi = Self.cvtt(ev)
        let ev0 = min(UInt32(bitPattern: evi), UInt32(evCount - 1))
        let evBlend = ev - Float(UInt32(bitPattern: evi))
        let ev1 = min(ev0 + 1, UInt32(evCount - 1))
        let e0 = elevations[ebase + Int(ev0)], e1 = elevations[ebase + Int(ev1)]
        // CalcAzIndex: (az + τ)·n/τ, truncated; index mod n, blend from the truncated value.
        func azIndex(_ n: Int) -> (Int, Float) {
            let a = Float(n) * (azimuth + tau) / tau
            let t = UInt32(bitPattern: Self.cvtt(a))
            return (Int(t % UInt32(n)), a - Float(t))
        }
        let (a0, b0) = azIndex(e0.azCount), (a1, b1) = azIndex(e1.azCount)
        let idx = [e0.irOffset + a0, e0.irOffset + (a0 + 1) % e0.azCount,
                   e1.irOffset + a1, e1.irOffset + (a1 + 1) % e1.azCount]
        let w = [(1 - b0) * (1 - evBlend) * dirfact, b0 * (1 - evBlend) * dirfact,
                 (1 - b1) * evBlend * dirfact, b1 * evBlend * dirfact]
        var out = Filter()
        for ear in 0..<2 {
            var d = Float(delays[idx[0] * 2 + ear]) * w[0]
            d += Float(delays[idx[1] * 2 + ear]) * w[1]
            d += Float(delays[idx[2] * 2 + ear]) * w[2]
            d += Float(delays[idx[3] * 2 + ear]) * w[3]
            let v = UInt32(bitPattern: Self.cvt(d * 0.25))
            if ear == 0 { out.delay.0 = v } else { out.delay.1 = v }
        }
        let pass = (1 - dirfact) * Float(bitPattern: 0x3f35_04f3)
        out.coeffs[0] = pass; out.coeffs[1] = pass
        coeffs.withUnsafeBufferPointer { src in
            out.coeffs.withUnsafeMutableBufferPointer { dst in
                for c in 0..<4 {
                    let base = idx[c] * Self.hrirLength * 2, m = w[c]
                    for k in 0..<(Self.hrirLength * 2) { dst[k] = src[base + k] * m + dst[k] }
                }
            }
        }
        return out
    }

    /// cvttss2si (truncation; 0x80000000 when out of range).
    static func cvtt(_ x: Float) -> Int32 { x.isFinite && abs(x) < 2_147_483_648 ? Int32(x.rounded(.towardZero)) : Int32.min }
    /// cvtss2si (round to nearest even under the default MXCSR).
    static func cvt(_ x: Float) -> Int32 { x.isFinite && abs(x) < 2_147_483_648 ? Int32(x.rounded(.toNearestOrEven)) : Int32.min }
}

/// OpenAL Soft's polyphase Kaiser-windowed sinc resampler (dll `PPhaseResampler::init` 0x1801c03d0,
/// `process` 0x1801c0670; 180 dB stop band, transition 0.05, cutoff 0.475, both over max(p, q)).
struct PPhaseResampler {
    let p: Int, q: Int, m: Int, l: Int
    let f: [Double]

    init(srcRate: Int, dstRate: Int) {
        func gcd(_ a: Int, _ b: Int) -> Int { var a = a, b = b; while b != 0 { (a, b) = (b, a % b) }; return a }
        let g = gcd(srcRate, dstRate)
        p = dstRate / g; q = srcRate / g
        let big = Double(max(p, q))
        let cutoff = 0.475 / big, width = 0.05 / big
        // CalcKaiserOrder(180, width): ceil((180 − 7.95) / (2.285 · 2π · width)); CalcKaiserBeta(180) = 0.1102 · 171.3.
        let order = Int(ceil(172.05 / (width * 6.283185307179586 * 2.285)))
        let half = (order + 1) / 2
        l = half; m = half * 2 + 1
        let beta = 18.877260000000003
        func besselI0(_ x: Double) -> Double {
            var term = 1.0, sum = 1.0, k = 1.0, last = 0.0
            let x2 = x / 2
            repeat { let y = x2 / k; k += 1; last = sum; term *= y * y; sum += term } while sum != last
            return sum
        }
        let i0b = besselI0(beta)
        var taps = [Double](repeating: 0, count: m)
        for i in 0..<m {
            let x = Double(i) - Double(half)
            let kk = x / Double(half)
            let kaiser = (kk >= -1 && kk <= 1) ? besselI0(beta * (1 - kk * kk).squareRoot()) / i0b : 0
            let y = (cutoff + cutoff) * x
            let sinc = abs(y) < 1e-9 ? 1.0 : sin(y * Double.pi) / (y * Double.pi)
            taps[i] = kaiser * 2 * Double(p) * cutoff * sinc
        }
        f = taps
    }

    func process(_ input: [Double], _ out: inout [Double]) {
        let inN = input.count
        for i in 0..<out.count {
            var jf = (l + q * i) % p, js = (l + q * i) / p
            var r = 0.0
            if jf < m {
                var filtLen = (m - jf + p - 1) / p
                if js + 1 > inN {
                    let skip = min(js + 1 - inN, filtLen)
                    jf += p * skip; js -= skip; filtLen -= skip
                }
                var todo = min(js + 1, filtLen)
                while todo > 0 { r += f[jf] * input[js]; jf += p; js -= 1; todo -= 1 }
            }
            out[i] = r
        }
    }
}

#if !os(Linux) // Linux: OpenAL Soft makes this choice itself (Linux/SoundOpenAL.swift)
/// Which renderer OpenAL Soft would pick for the current output (dll 0x18018693e, 0x18019950b), and the shared HRTF
/// store at the output rate.
public enum SoundOutput {
    /// Set by the host / renderer from `AssetFileSystem.workingDirectory`: the folder holding `bin/mediaextensions64.dll`.
    public static var engineDirectory: URL?

    private static var cached: (key: String, store: HrtfStore?)?
    private static let lock = NSLock()

    /// The HRTF store for new voices at `rate`, or nil for the speaker (pair-wise) path. `PHOTON_HRTF=1` forces HRTF
    /// (alsoft.ini `hrtf = true`), `PHOTON_HRTF=0` disables it (`hrtf = false`).
    public static func hrtf(rate: Double) -> HrtfStore? {
        let env = ProcessInfo.processInfo.environment["PHOTON_HRTF"]
        let on: Bool
        switch env {
        case "1"?: on = true
        case "0"?: on = false
        default: on = outputIsHeadphones()
        }
        guard on, let dir = engineDirectory else { return nil }
        let key = "\(dir.path)|\(Int(rate))"
        lock.lock(); defer { lock.unlock() }
        if let c = cached, c.key == key { return c.store }
        let dll = [dir.appendingPathComponent("bin/mediaextensions64.dll"),
                   dir.deletingLastPathComponent().appendingPathComponent("bin/mediaextensions64.dll")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
        let store = dll.flatMap { HrtfStore.builtIn(dll: $0) }?.resampled(to: Int(rate))
        cached = (key, store)
        return store
    }

    /// macOS stand-in for the WASAPI form-factor test: the default output must have two channels (the device's mix
    /// format is stereo) and be headphones: the built-in jack's data source 'hdpn', or a Bluetooth / Bluetooth LE
    /// device (Windows reports A2DP headphones as Headphones / Headset; that every Bluetooth output is headphones is
    /// Inferred, a Bluetooth speaker would get HRTF here and not on Windows).
    public static func outputIsHeadphones() -> Bool {
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr, dev != 0 else { return false }
        // Channel count of the output streams.
        addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput,
                                          mElement: kAudioObjectPropertyElementMain)
        var channels = 0
        if AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 {
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
            defer { raw.deallocate() }
            if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr {
                let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
                channels = abl.reduce(0) { $0 + Int($1.mNumberChannels) }
            }
        }
        guard channels == 2 else { return false }
        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &transport) == noErr,
           transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE { return true }
        var source = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioDevicePropertyScopeOutput,
                                          mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &source) == noErr, source == 0x6864_706e /* 'hdpn' */ { return true }
        return false
    }
}

#endif

/// The device's HRTF accumulator (`HrtfAccumData`, (left, right) pairs): every HRTF voice adds its convolution into it at
/// `HrtfDirectDelay` (256) samples past the mix position (`DoHrtfMix` writes at device +0x4a30 = +0x4230 + 256 float
/// pairs, 0x180173ec5; alc/voice.cpp, to line the source mix up with the ambisonic HRTF decode). After the mix the first
/// n pairs are output and HrirLength + HrtfDirectDelay pairs carry over to the next mix (core/mixer/hrtfbase.h). So
/// every HRTF voice is heard 256 samples (5.3 ms at 48 kHz) after its input, and a stopped voice's tail keeps playing.
public final class HrtfAccumulator {
    /// HrtfDirectDelay (core/mixer/hrtfdefs.h; the +0x800-byte offset at 0x180173ec5).
    public static let directDelay = 256
    /// Pairs the accumulator still holds after a mix: HrirLength + HrtfDirectDelay.
    public static let tailLength = HrtfStore.hrirLength + directDelay
    var buffer: [Float] = []   // (left, right) pairs: n + tailLength
    private var tail = [Float](repeating: 0, count: HrtfAccumulator.tailLength * 2)
    private var n = 0

    public init() {}

    /// Start of a mix of `n` samples: the carried pairs, then silence.
    public func begin(_ n: Int) {
        let carry = Self.tailLength * 2
        if buffer.count < n * 2 + carry { buffer = [Float](repeating: 0, count: n * 2 + carry) }
        for i in 0..<carry { buffer[i] = tail[i] }
        for i in carry..<(n * 2 + carry) { buffer[i] = 0 }
        self.n = n
    }

    /// End of the mix: adds the first n pairs to `left` / `right` and keeps the rest for the next mix.
    public func finish(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        for i in 0..<n { left[i] += buffer[i * 2]; right[i] += buffer[i * 2 + 1] }
        for i in 0..<(Self.tailLength * 2) { tail[i] = buffer[n * 2 + i] }
    }

    public func clear() { for i in tail.indices { tail[i] = 0 } }
}

/// Per-channel HRTF state of a voice (`DirectParams::Hrtf`: Old, Target, History) and `DoHrtfMix` 0x180173e70 with
/// `MixHrtfBlendSamples` and `MixHrtfSamples` (SSE 0x1801a6010 / 0x1801a5ea0, picked at 0x180174b4d; C 0x1801a3960 /
/// 0x1801a3780). The input of one pass is the 64-sample history followed by the new samples (the last 64 become the next
/// history). Each ear convolves the input delayed by its integer delay with `irSize` taps into the accumulator.
///
/// `DoHrtfMix(samples, n, Counter, OutPos, TargetGain)` (alc/voice.cpp):
/// * Counter > 0 and OutPos 0 (a fading voice's first pass): fademix = min(n, Counter); gain = TargetGain, or
///   lerp(Old.Gain, TargetGain, fademix / Counter) when Counter > fademix. Blend over fademix samples: Old (gain Old.Gain
///   → 0, stepping down from fademix) out, Target (0 → gain, from the second sample with a one-sample later read) in;
///   then Old = Target with that gain.
/// * The rest (n − fademix samples, all of them when Counter is 0): Target from Old.Gain toward TargetGain (lerped
///   when Counter > n), step (gain − Old.Gain)/todo.
/// Counter is SamplesToDo once the voice is fading (flag 0x10, every mix after its first, 0x180174d19–0x180174d2e), at
/// most 64 for a voice stopping without a buffer, else 0; with Counter 0 `Voice::mix` first copies Target into Old (gain
/// included). A stopping voice mixes toward TargetGain 0 (0x1801754c8). Parts below 1e-5 (GainSilenceThreshold
/// 0x1802ce0f0) are skipped.
public final class HrtfVoiceFilter {
    public static let directDelay = HrtfAccumulator.directDelay
    public static let tailLength = HrtfAccumulator.tailLength
    public let irSize: Int
    public var old = HrtfStore.Filter(), target = HrtfStore.Filter()
    /// Old.Gain / Target.Gain (the dry gain, set with the target filter).
    var oldGain: Float = 0
    public var targetGain: Float = 0
    private var history = [Float](repeating: 0, count: HrtfStore.historyLength)
    private var work: [Float] = []
    /// Accumulator of the stand-alone `mix` / `drain` (the emulator replay of `photon-tool hrtf-dump`).
    private let own = HrtfAccumulator()

    public init(irSize: Int) { self.irSize = irSize }

    /// A fresh voice (InitVoice: `DirectParams{}`): clears the history and the filter state.
    public func resetHistory() {
        for i in history.indices { history[i] = 0 }
        old = HrtfStore.Filter(); oldGain = 0
    }

    /// Clears the history and the stand-alone accumulator.
    public func reset() {
        resetHistory()
        own.clear()
    }

    /// Counter 0 (`Voice::mix`, not fading): Old = Target, gain included.
    func copyTargetToOld() { old = target; oldGain = targetGain }

    /// One stand-alone mix while this voice is not mixed: only the accumulator advances.
    public func drain(_ n: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        own.begin(n)
        own.finish(left: left, right: right)
    }

    /// One stand-alone mix of `n` samples into the filter's own accumulator, added to `left` / `right`: Counter n when
    /// `fading`, else 0; `gain` is the target's gain (DryGain); `stopping` mixes toward 0.
    public func mix(_ input: UnsafePointer<Float>, _ n: Int, fading: Bool, gain: Float, stopping: Bool = false,
                    left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        targetGain = gain
        if !fading { copyTargetToOld() }
        own.begin(n)
        mix(input, n, into: own, outPos: 0, counter: fading ? n : 0, targetGain: stopping ? 0 : gain)
        own.finish(left: left, right: right)
    }

    /// `DoHrtfMix`: `n` samples at `outPos` of the current mix into `acc`.
    func mix(_ samples: UnsafePointer<Float>, _ n: Int, into acc: HrtfAccumulator, outPos startPos: Int, counter: Int,
             targetGain: Float) {
        let hist = HrtfStore.historyLength
        let delay = Self.directDelay
        if work.count < hist + n { work = [Float](repeating: 0, count: hist + n) }
        for i in 0..<hist { work[i] = history[i] }
        for i in 0..<n { work[hist + i] = samples[i] }
        for i in 0..<hist { history[i] = work[n + i] }
        let silence: Float = 0.00001
        // The SSE / NEON ApplyCoeffs work on two taps per step, so an odd IR size (e.g. 35 at 48 kHz) applies one more
        // tap: (irSize + 1) & ~1 (hrtf_mix.py replay).
        let taps = (irSize + 1) & ~1
        var outPos = startPos
        work.withUnsafeBufferPointer { w in
            acc.buffer.withUnsafeMutableBufferPointer { a in
                func apply(_ coeffs: [Float], _ at: Int, _ l: Float, _ r: Float) {
                    coeffs.withUnsafeBufferPointer { c in
                        for k in 0..<taps {
                            a[(delay + at + k) * 2] += c[k * 2] * l
                            a[(delay + at + k) * 2 + 1] += c[k * 2 + 1] * r
                        }
                    }
                }
                func lerp(_ v1: Float, _ v2: Float, _ mu: Float) -> Float { v1 + (v2 - v1) * mu }
                var fademix = 0
                if counter > 0 && outPos == 0 {
                    fademix = min(n, counter)
                    var gain = targetGain
                    if counter > fademix { gain = lerp(oldGain, targetGain, Float(fademix) / Float(counter)) }
                    // MixHrtfBlendSamples over fademix samples.
                    if oldGain > silence {
                        let oldStep = oldGain / Float(fademix)
                        var ld = hist - Int(old.delay.0), rd = hist - Int(old.delay.1)
                        var sc = Float(fademix)
                        for i in 0..<fademix {
                            let g = oldStep * sc
                            apply(old.coeffs, outPos + i, w[ld] * g, w[rd] * g)
                            ld += 1; rd += 1; sc -= 1
                        }
                    }
                    let newStep = gain / Float(fademix)
                    if newStep * Float(fademix) > silence {
                        var ld = hist + 1 - Int(target.delay.0), rd = hist + 1 - Int(target.delay.1)
                        var sc: Float = 1
                        var i = 1
                        while i < fademix {
                            let g = newStep * sc
                            apply(target.coeffs, outPos + i, w[ld] * g, w[rd] * g)
                            ld += 1; rd += 1; sc += 1; i += 1
                        }
                    }
                    old = target; oldGain = gain
                    outPos += fademix
                }
                if fademix < n {
                    let todo = n - fademix
                    var gain = targetGain
                    if counter > n { gain = lerp(oldGain, targetGain, Float(todo) / Float(counter - fademix)) }
                    // MixHrtfSamples from HrtfSamples + fademix with the target filter.
                    let step = (gain - oldGain) / Float(todo)
                    var ld = fademix + hist - Int(target.delay.0), rd = fademix + hist - Int(target.delay.1)
                    var sc: Float = 0
                    for i in 0..<todo {
                        let g = oldGain + step * sc
                        apply(target.coeffs, outPos + i, w[ld] * g, w[rd] * g)
                        ld += 1; rd += 1; sc += 1
                    }
                    oldGain = gain
                }
            }
        }
    }
}
