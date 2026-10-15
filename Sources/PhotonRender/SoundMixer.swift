import Foundation
import simd

/// One OpenAL Soft 1.21.1 source with a buffer (`mediaextensions64.dll` links 1.21.1; al/source.cpp, alc/voice.cpp,
/// alc/alu.cpp), mixed at the device rate, one `render` per device update. `PCMVoice` renders through it on macOS and
/// `SoundReference` uses it for the cross-platform check against OpenAL Soft itself (docs/linux-port.md §3.6).
///
/// How the engine drives a source (docs/re/06 §4.2): each track of a sound object owns an SFML 2.5 `sf::SoundStream`
/// in the dll (vtable 0x180208838; media-object slots 0x58 play 0x18000da10, 0x60 pause 0x18000d9c0, 0x68 stop
/// 0x18000dbe0, 0x70 volume). Its streaming thread (0x18000dc30) queues three 16-bit buffers at the track's own rate and
/// calls `alSourcePlay` / `alSourcePause`; `stop()` ends the thread, which calls `alSourceStop`. A one-shot track ends
/// when the queue runs out. No source sets `AL_SOURCE_RESAMPLER_SOFT` and `ResamplerDefault` (dll 0x180311528) is 1, so
/// every source resamples with the linear resampler. The queue is continuous (SFML refills it, and loops it seamlessly
/// with `onLoop`), so a static buffer with AL_LOOPING gives the same samples.
///
/// The voice (`Voice::mix`):
/// * Stepping: increment = round(Pitch · 4096) (`fastf2u`, cvtss2si), Pitch = (float)rate / (float)deviceRate, at most
///   10 · 4096 (MaxPitch); position = integer part + 12-bit fraction (MixerFracBits).
/// * Source samples: 24 held samples (MaxResamplerPadding / 2) before the position, then the buffer from the position
///   (wrapping when looping); past the end of a one-shot buffer, the last loaded sample repeated. After each pass the 48
///   samples around the new position are kept (`mPrevSamples`).
/// * Resampling: a plain copy when the increment is 4096 and the fraction 0, else `Resample_<LerpTag>` (SSE2 / SSE4.1 /
///   NEON compute the same values): out = a + mu·(b − a), mu = frac · (1/4096).
/// * Fading (`VoiceIsFading`, flag 0x10): clear for a new voice, so its first mix copies the targets into the current
///   gains and mixes at constant gain; set after every mix, so later mixes ramp to the targets over the whole mix
///   (Counter = SamplesToDo), or over at most 64 samples for a voice stopping without a buffer.
/// * Speaker path: three ambisonic gains (W, Y, X, `SoundSpatial.ambiGains`), each mixed with `Mix_` into the device's
///   dry buffer and decoded to left/right with `SoundSpatial.decoder` after every voice is mixed.
/// * HRTF path: one `HrtfVoiceFilter` per channel into the device's `HrtfAccumulator`; output 256 samples late.
/// * `pause()` (`alSourcePause` → voice Stopping): the next mix reads the next samples as usual, mixes them toward gain 0
///   and does not store the position, so a resume (`alSourcePlay` on a paused source, `VChangeState::Play` only) replays
///   them, ramping from gain 0 with the voice's history.
/// * `stop()` (`alSourceStop` → `VChangeState::Stop`): the voice loses its buffer and its source; a playing voice mixes
///   once more (Stopping) from its held samples: the next ones up to, not including, the first with the smallest
///   magnitude, then the last of those (or the last played sample) repeated, faded to 0 over min(n, 64) samples. A paused
///   voice is already silent and stays so.
/// * End of a one-shot buffer: the mix that reaches the end fills the rest with the last sample at full gain; the voice
///   then leaves its source (the source reads AL_STOPPED) and its next mix is the same held-sample fade as a stop.
/// * `play()` on a stopped source starts a new voice (`InitVoice`: position 0, flags clear, `mPrevSamples` and
///   `DirectParams` zeroed) while an old stopping voice still mixes its fade.
/// * Source properties reach the voice at the start of the next mix, and only while the voice has its source
///   (`ProcessParamUpdates`: voice changes, then `CalcSourceParams` for voices with a source ID).
final class VoiceMixer {
    static let fracBits = 12
    static let fracOne = 1 << fracBits
    static let fracMask = fracOne - 1
    /// MaxResamplerPadding.
    static let padding = 48
    static let bufferLineSize = 1024

    let channels: [[Float]]
    let loops: Bool
    let sourceRate: Int, deviceRate: Int
    let hrtf: HrtfStore?
    /// mStep.
    let increment: Int

    /// The voice the source owns (playing or paused), and voices without a source still to be mixed (stopping).
    private var voice: Voice?
    private var retired: [Voice] = []
    private var sourcePaused = false
    // Source properties: Gains.Target of the (W, Y, X) dry channels, or the HRTF filters and dry gain.
    private var targets = [Float](repeating: 0, count: 3)
    private var hrtfFilters: [HrtfStore.Filter]?
    private var hrtfGain: Float = 0
    // Device buffers.
    private var ambi: [[Float]] = []
    private let accum: HrtfAccumulator?

    /// `rate` is the buffer's sample rate, `deviceRate` the output's (default: the same).
    init(channels: [[Float]], loops: Bool, hrtf: HrtfStore?, rate: Int? = nil, deviceRate: Int? = nil) {
        self.channels = channels; self.loops = loops; self.hrtf = hrtf
        let dev = deviceRate ?? hrtf?.sampleRate ?? rate ?? 48000
        self.deviceRate = dev
        sourceRate = rate ?? dev
        increment = Self.increment(sourceRate: sourceRate, deviceRate: dev)
        accum = hrtf != nil ? HrtfAccumulator() : nil
    }

    /// `CalcAttnSourceParams` / `CalcNonAttnSourceParams`: Pitch 1 (no Doppler: both velocities are 0) times
    /// (float)frequency / (float)deviceFrequency; MaxPitch 10; `fastf2u` rounds to nearest (cvtss2si).
    static func increment(sourceRate: Int, deviceRate: Int) -> Int {
        var pitch: Float = 1
        pitch *= Float(sourceRate) / Float(deviceRate)
        if pitch > 10 { return 10 << fracBits }
        return max(Int((pitch * Float(fracOne)).rounded(.toNearestOrEven)), 1)
    }

    /// Source state AL_PLAYING.
    var isPlaying: Bool { voice != nil && !sourcePaused }
    /// Anything left to hear: a voice still mixing or an HRTF tail.
    var isActive: Bool { voice != nil || !retired.isEmpty || tailSamples > 0 }
    private var tailSamples = 0

    /// Speaker path targets (`SoundSpatial.ambiGains`).
    func setTargets(_ g: SIMD3<Float>) { targets = [g.x, g.y, g.z] }

    /// HRTF path targets: one filter per channel and the dry gain.
    func setHrtf(_ f: [HrtfStore.Filter], gain: Float) { hrtfFilters = f; hrtfGain = gain }

    /// `alSourcePlay`: a paused source resumes; otherwise a new voice starts from the beginning.
    func play() {
        if let v = voice {
            if sourcePaused {
                sourcePaused = false
                v.state = .playing
                return
            }
            // AL_PLAYING: restarted from the beginning, the old voice stops (cross-fade).
            detach(v)
        }
        let v = Voice(channels: channels.count, loops: loops, hrtf: hrtf)
        voice = v
        sourcePaused = false
    }

    /// `alSourcePause`.
    func pause() {
        guard let v = voice, !sourcePaused else { return }
        sourcePaused = true
        if v.state == .playing { v.state = .stopping }
    }

    /// `alSourceStop`.
    func stop() {
        if let v = voice { detach(v) }
        voice = nil
        sourcePaused = false
    }

    private func detach(_ v: Voice) {
        v.hasBuffer = false; v.looping = false
        if v.state == .playing { v.state = .stopping }
        if v.state != .stopped { retired.append(v) }
        voice = nil
    }

    /// One device update of `n` frames into `l` / `r` (overwritten), in mixes of at most BufferLineSize.
    func render(_ n: Int, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>) {
        var done = 0
        while done < n {
            let todo = min(n - done, Self.bufferLineSize)
            mix(todo, l + done, r + done)
            done += todo
        }
    }

    /// One mix (`aluMixData` with SamplesToDo ≤ 1024).
    private func mix(_ n: Int, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>) {
        for i in 0..<n { l[i] = 0; r[i] = 0 }
        // CalcSourceParams for the voice that has the source.
        if let v = voice {
            if hrtf != nil {
                if let f = hrtfFilters {
                    for (c, filt) in v.filters.enumerated() where c < f.count { filt.target = f[c] }
                }
                for filt in v.filters { filt.targetGain = hrtfGain }
            } else {
                v.target = targets
            }
        }
        if ambi.count != 3 || ambi[0].count < n { ambi = Array(repeating: [Float](repeating: 0, count: n), count: 3) }
        for c in 0..<3 { for i in 0..<n { ambi[c][i] = 0 } }
        accum?.begin(n)
        var mixed = false
        for v in retired + (voice.map { [$0] } ?? []) where v.state != .stopped {
            v.mix(n, owner: self)
            mixed = true
        }
        retired.removeAll { $0.state == .stopped }
        if let v = voice, !v.hasSource {
            // The buffer ran out: the source is stopped; the voice mixes its fade next time.
            voice = nil
            if v.state != .stopped { retired.append(v) }
        }
        if let accum {
            accum.finish(left: l, right: r)
            tailSamples = mixed ? HrtfAccumulator.tailLength : max(tailSamples - n, 0)
        } else {
            let dl = SoundSpatial.decoder.left, dr = SoundSpatial.decoder.right
            let gl = [dl.x, dl.y, dl.z], gr = [dr.x, dr.y, dr.z]
            for c in 0..<3 {
                ambi[c].withUnsafeBufferPointer { a in
                    for i in 0..<n { l[i] += a[i] * gl[c] }
                    for i in 0..<n { r[i] += a[i] * gr[c] }
                }
            }
        }
    }

    /// One OpenAL voice (`Voice`).
    final class Voice {
        enum State { case stopped, playing, stopping }
        var state = State.playing
        var position = 0, frac = 0
        /// mCurrentBuffer != nullptr / mLoopBuffer != nullptr.
        var hasBuffer = true
        var looping: Bool
        /// mSourceID != 0.
        var hasSource = true
        var fading = false
        var prev: [[Float]]
        // Speaker path: Gains.Current / Gains.Target of the (W, Y, X) dry channels.
        var current = [Float](repeating: 0, count: 3)
        var target = [Float](repeating: 0, count: 3)
        let filters: [HrtfVoiceFilter]
        private var src: [Float] = []
        private var resampled: [Float] = []

        init(channels: Int, loops: Bool, hrtf: HrtfStore?) {
            looping = loops
            prev = Array(repeating: [Float](repeating: 0, count: VoiceMixer.padding), count: channels)
            filters = hrtf.map { s in (0..<channels).map { _ in HrtfVoiceFilter(irSize: s.irSize) } } ?? []
        }

        /// `Voice::mix` for SamplesToDo = n.
        func mix(_ n: Int, owner m: VoiceMixer) {
            let stopping = state == .stopping
            let inc = m.increment
            let half = VoiceMixer.padding / 2
            var pos = position, frac = self.frac
            var hasBuf = hasBuffer
            let loopActive = looping
            let count = m.channels[0].count
            var counter = fading ? n : 0
            if counter == 0 {
                // No fading: overwrite the old / current parameters with the targets.
                if filters.isEmpty { current = target } else { for f in filters { f.copyTargetToOld() } }
            } else if !hasBuf {
                counter = min(counter, 64)
            }
            if src.count < VoiceMixer.bufferLineSize + VoiceMixer.padding { src = [Float](repeating: 0, count: VoiceMixer.bufferLineSize + VoiceMixer.padding) }
            if resampled.count < VoiceMixer.bufferLineSize { resampled = [Float](repeating: 0, count: VoiceMixer.bufferLineSize) }
            var outPos = 0
            repeat {
                var dst = n - outPos
                let srcSize: Int
                if inc <= VoiceMixer.fracOne {
                    srcSize = (((dst - 1) * inc + frac) >> VoiceMixer.fracBits) + 1 + VoiceMixer.padding
                } else {
                    let size = ((dst * inc + frac) >> VoiceMixer.fracBits) + VoiceMixer.padding
                    if size <= VoiceMixer.bufferLineSize + VoiceMixer.padding {
                        srcSize = size
                    } else {
                        srcSize = VoiceMixer.bufferLineSize + VoiceMixer.padding
                        let fit = (((srcSize - VoiceMixer.padding) << VoiceMixer.fracBits) - frac) / inc
                        if fit < dst { dst = fit & ~3 }
                    }
                }
                for c in 0..<m.channels.count {
                    let data = m.channels[c]
                    var w = 0
                    for i in 0..<half { src[w] = prev[c][i]; w += 1 }
                    if !hasBuf {
                        // A voice that ended or stopped: its held samples up to the one closest to 0 amplitude.
                        var minIdx = half
                        for i in (half + 1)..<VoiceMixer.padding where abs(prev[c][i]) < abs(prev[c][minIdx]) { minIdx = i }
                        for i in half..<minIdx { src[w] = prev[c][i]; w += 1 }
                    } else if loopActive && pos < count {
                        // LoadBufferStatic, looping: the rest of this iteration, then whole loops.
                        var p = pos
                        while w < srcSize {
                            let k = min(srcSize - w, count - p)
                            for i in 0..<k { src[w + i] = data[p + i] }
                            w += k; p = 0
                        }
                    } else {
                        let k = min(srcSize - w, count - pos)
                        if k > 0 { for i in 0..<k { src[w + i] = data[pos + i] } ; w += k }
                    }
                    if w < srcSize {
                        let s = src[w - 1]
                        for i in w..<srcSize { src[i] = s }
                    }
                    let keep = (inc * dst + frac) >> VoiceMixer.fracBits
                    for i in 0..<VoiceMixer.padding { prev[c][i] = src[keep + i] }
                    // Resample from src[24].
                    if inc == VoiceMixer.fracOne && frac == 0 {
                        for i in 0..<dst { resampled[i] = src[half + i] }
                    } else {
                        var s = half, f = frac
                        let scale: Float = 1 / Float(VoiceMixer.fracOne)
                        for i in 0..<dst {
                            let a = src[s], b = src[s + 1]
                            let mu = Float(f) * scale
                            resampled[i] = a + mu * (b - a)
                            f += inc
                            s += f >> VoiceMixer.fracBits
                            f &= VoiceMixer.fracMask
                        }
                    }
                    if filters.isEmpty {
                        // Speaker path: mono (channel 0) into the dry buffer.
                        if c == 0 {
                            resampled.withUnsafeBufferPointer { inp in
                                for a in 0..<3 {
                                    m.ambi[a].withUnsafeMutableBufferPointer { out in
                                        VoiceMixer.mix(inp.baseAddress!, dst, out.baseAddress! + outPos, current: &current[a],
                                                       target: stopping ? 0 : target[a], counter: counter)
                                    }
                                }
                            }
                        }
                    } else if let acc = m.accum, c < filters.count {
                        let f = filters[c]
                        resampled.withUnsafeBufferPointer {
                            f.mix($0.baseAddress!, dst, into: acc, outPos: outPos, counter: counter,
                                  targetGain: stopping ? 0 : f.targetGain)
                        }
                    }
                }
                frac += inc * dst
                pos += frac >> VoiceMixer.fracBits
                frac &= VoiceMixer.fracMask
                outPos += dst
                counter = max(dst, counter) - dst
                if hasBuf {
                    if loopActive {
                        if pos >= count { pos %= count }
                    } else if pos >= count {
                        hasBuf = false
                        break
                    }
                }
            } while outPos < n
            fading = true
            if stopping {
                // Stopping: stopped, position untouched.
                state = .stopped
                return
            }
            position = pos; self.frac = frac; hasBuffer = hasBuf
            if !hasBuf {
                // The voice just ended: it leaves its source and mixes once more as Stopping.
                looping = false; hasSource = false
                state = .stopping
            }
        }
    }

    /// `Mix_` (core/mixer/mixer_c.cpp; the SSE / NEON versions compute the same values): step = (target − current) ·
    /// (1/Counter); with |step| > FLT_EPSILON the first min(Counter, n) samples get current + step·i and the gain
    /// ends at the target when the fade completes, else the target throughout. The rest of the mix runs at that gain,
    /// skipped when it is not above GainSilenceThreshold (1e-5).
    static func mix(_ input: UnsafePointer<Float>, _ n: Int, _ dst: UnsafeMutablePointer<Float>, current: inout Float, target: Float, counter: Int) {
        let delta: Float = counter > 0 ? 1 / Float(counter) : 0
        let minLen = min(counter, n)
        var gain = current
        let step = (target - gain) * delta
        var pos = 0
        if !(abs(step) > Float.ulpOfOne) {
            gain = target
        } else {
            var sc: Float = 0
            while pos < minLen { dst[pos] += input[pos] * (gain + step * sc); sc += 1; pos += 1 }
            if pos == counter { gain = target } else { gain += step * sc }
        }
        current = gain
        guard abs(gain) > 0.00001 else { return }
        while pos < n { dst[pos] += input[pos] * gain; pos += 1 }
    }
}
