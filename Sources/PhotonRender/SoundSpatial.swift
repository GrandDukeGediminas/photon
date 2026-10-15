#if !os(Linux)
import AVFoundation
import os
#endif
import Foundation
import simd

/// 3D sound for `spatialization` sound objects (Sound +0x310 bit 2, loader 0x14019bfa0; `attenuation` +0x304 and
/// `mindistance` +0x308, both 1.0 in the ctor at 0x14019062a).
///
/// Engine side (wallpaper64.exe):
/// * Per frame (`Sound_Update` 0x1401f4f50 → 0x1401f5029–0x1401f53ff) and on play (`Sound_Play` 0x1401f68f4 →
///   `Sound_UpdateSpatial` 0x1401f5460 with apply = 1) the source position handed to every voice is
///   d = world origin (vt+0x80 row 3) − g_EyePosition (C+0x68); p = (d·g_ViewRight, −(d·g_ViewUp), d·g_ViewForward)
///   (C+0x16c, C+0x178, C+0x160). In ortho scenes (C+0x118 & 0x400) p = normalize(p) · max(0, s − world.z) / s with
///   s = (C+0x84 + C+0x88) · 0.25. Before the first frame (C+0x144 < 1) p = (0, 0, 99999).
///   Media services (C+0x158 = 0x1404e55a0, vtable 0x140485fe0) forwards vt+0xf8 / +0xe0 / +0xe8 to the
///   `mediaextensions64.dll` object (`CreateMediaExtensions`, vtable 0x1802dcc70 slots 0x98 / 0x80 / 0x88).
/// * On play only: vt+0xe0 (attenuation) and vt+0xe8 (mindistance) per track.
///
/// mediaextensions64.dll (sha256 898ffaa0…dbc3) is OpenAL Soft: positions → `alSource3f(AL_POSITION)` (0x18000e580),
/// attenuation → `alSourcef(AL_ROLLOFF_FACTOR)` (0x18000e520), mindistance → `alSourcef(AL_REFERENCE_DISTANCE)`
/// (0x18000e530). Sources are created with defaults only (0x18000dfc0: alGenSources, AL_BUFFER 0): not
/// listener-relative, AL_MAX_DISTANCE = FLT_MAX, AL_SOURCE_SPATIALIZE_SOFT = AL_AUTO (only mono buffers are spatialised).
/// No `alDistanceModel` call exists, so the model is AL_INVERSE_DISTANCE_CLAMPED. The listener (0x18000efcd–0x18000f063)
/// sits at the origin facing −Z with +Y up.
enum SoundSpatial {
    struct Listener {
        var eye: SIMD3<Float>
        var right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>
        var ortho: Bool
        var projectionSize: SIMD2<Float>
        var frameIndex: Int
    }

    /// The position the engine hands to OpenAL.
    static func sourcePosition(world: SIMD3<Float>, _ l: Listener) -> SIMD3<Float> {
        guard l.frameIndex >= 1 else { return SIMD3(0, 0, 99999) }
        let d = world - l.eye
        var p = SIMD3(simd_dot(d, l.right), -simd_dot(d, l.up), simd_dot(d, l.forward))
        if l.ortho {
            let len = simd_length(p)
            p = len > 0 ? p / len : p
            let s = (l.projectionSize.x + l.projectionSize.y) * 0.25
            p *= max(s - world.z, 0) / s
        }
        return p
    }

    /// `ToSource.normalize(RefDistance / 1024)` (alc/alu.cpp `CalcAttnSourceParams`; dll 0x180190a9f, `mulss` by
    /// 2⁻¹⁰, then 0x1801952f0): limit = max(FLT_EPSILON, reference · 2⁻¹⁰); |p|² = (x·x + y·y) + z·z. Above limit² the
    /// direction is p · (1/|p|) and the distance |p|; otherwise both are 0 and the source counts as at the listener.
    static func toSource(_ p: SIMD3<Float>, reference: Float) -> (dir: SIMD3<Float>, distance: Float) {
        let r = reference * 0.0009765625
        let limit = Float.ulpOfOne > r ? Float.ulpOfOne : r   // maxss
        let lenSq = (p.x * p.x + p.y * p.y) + p.z * p.z
        guard lenSq > limit * limit else { return (.zero, 0) }
        let len = lenSq.squareRoot()
        let inv = 1 / len
        return (SIMD3(p.x * inv, p.y * inv, p.z * inv), len)
    }

    /// minf / maxf / clampf of common/alnumeric.h (the comparison order matters only for NaN and ±0).
    @inline(__always) static func minf(_ a: Float, _ b: Float) -> Float { a > b ? b : a }
    @inline(__always) static func maxf(_ a: Float, _ b: Float) -> Float { a > b ? a : b }
    @inline(__always) static func clampf(_ v: Float, _ lo: Float, _ hi: Float) -> Float { minf(hi, maxf(lo, v)) }

    /// DryGain.Base of a spatialised source (`CalcAttnSourceParams`, AL_INVERSE_DISTANCE_CLAMPED, AL_MAX_DISTANCE
    /// FLT_MAX): clamped = clamp(distance, ref, max); with ref > 0, d = ref + (clamped − ref)·rolloff and, when d > 0,
    /// gain × ref/d; then clamp(AL_MIN_GAIN 0, AL_MAX_GAIN 1) (direct and listener gains 1). `distance` is
    /// `toSource`'s (0 at the listener, which clamps to ref: no attenuation).
    static func dryGain(distance: Float, sourceGain: Float, rolloff: Float, reference: Float) -> Float {
        var base = sourceGain
        let clamped = clampf(distance, reference, .greatestFiniteMagnitude)
        if reference > 0 {
            let d = reference + (clamped - reference) * rolloff
            if d > 0 { base *= reference / d }
        }
        return minf(clampf(base, 0, 1), 16)   // GainMixMax
    }

    static func dryGain(_ p: SIMD3<Float>, sourceGain: Float, rolloff: Float, reference: Float) -> Float {
        dryGain(distance: toSource(p, reference: reference).distance, sourceGain: sourceGain, rolloff: rolloff, reference: reference)
    }

    /// `ScaleAzimuthFront` (alc/alu.cpp): |az| < π/2 → copysign(min(|az|·scale, π/2), az).
    static func scaleAzimuthFront(_ az: Float, _ scale: Float) -> Float {
        let a = abs(az), half = Float.pi * 0.5
        return !(a >= half) ? copysign(minf(a * scale, half), az) : az
    }

    /// OpenAL Soft 1.21.1 (mediaextensions64.dll: "1.1 ALSOFT 1.21.1") dry-path gains of a **mono** source on a stereo
    /// device with the default configuration: no alsoft.ini, so `stereo-encoding` keeps the default pair-wise ("panpot")
    /// render mode (renderer +0x54 == 1) and no HRTF (speakers; `stereo-mode` auto). AL_AUTO spatialises every mono
    /// buffer, so this applies to non-spatialised mono tracks too (their position is the default (0, 0, 0)).
    ///
    /// The source is panned into the device's first-order 2-D ambisonic dry buffer (W, Y, X = ACN 0, 1, 3) and the
    /// buffer is decoded to the speakers afterwards (`StereoDecode`):
    /// * Positional (`toSource` distance > FLT_EPSILON, `CalcPanningAndFilters` 0x180192ecb–0x180192f31):
    ///   ev = asin(clamp(dir.y, −1, 1)), az = `ScaleAzimuthFront`(atan2(dir.x, −dir.z), 1.5).
    /// * At the listener: the mono channel's own angle, `ScaleAzimuthFront`(0, 3) = 0, elevation 0.
    /// * `CalcAngleCoeffs` 0x180190340: x = −sin az·cos ev, z = cos az·cos ev; N3D W = 1, Y(ACN 1) = √3·x,
    ///   X(ACN 3) = √3·z; `ComputePanGains`: each × DryGain (`dryGain`).
    /// The returned (W, Y, X) are the voice's target gains; `VoiceMixer` ramps each one (`Mix_`) and decodes.
    static func ambiGains(_ p: SIMD3<Float>, sourceGain: Float, rolloff: Float, reference: Float) -> SIMD3<Float> {
        let (dir, dist) = toSource(p, reference: reference)
        let dry = dryGain(distance: dist, sourceGain: sourceGain, rolloff: rolloff, reference: reference)
        var az: Float = scaleAzimuthFront(0, 3), ev: Float = 0
        if dist > Float.ulpOfOne {
            ev = asin(clampf(dir.y, -1, 1))
            az = scaleAzimuthFront(atan2(dir.x, -dir.z), 1.5)
        }
        let x = -sin(az) * cos(ev), z = cos(az) * cos(ev)
        let sqrt3: Float = 1.732050808
        return SIMD3(1 * dry, (sqrt3 * x) * dry, (sqrt3 * z) * dry)
    }

    /// `CalcPanningAndFilters` render mode 2: positional (`toSource` distance > FLT_EPSILON) → one `GetHrtfCoeffs` for
    /// the direction; otherwise MonoMap front centre 0° / StereoMap −30° / +30° (0x18019239b–0x18019241d), elevation 0,
    /// distance +inf.
    static func hrtfFilters(_ store: HrtfStore, position: SIMD3<Float>, reference: Float, channels: Int) -> [HrtfStore.Filter] {
        let (d, dist) = toSource(position, reference: reference)
        if dist > Float.ulpOfOne {
            let ev = asin(clampf(d.y, -1, 1)), az = atan2(d.x, -d.z)
            return Array(repeating: store.filter(elevation: ev, azimuth: az, distance: dist, spread: 0), count: channels)
        }
        let angles: [Float] = channels == 1 ? [0] : [Float(bitPattern: 0xbf06_0a92), Float(bitPattern: 0x3f06_0a92)]
        return angles.map { store.filter(elevation: 0, azimuth: $0, distance: .infinity, spread: 0) }
    }

    /// The `StereoConfig` decoder (dll 0x2cbb30: order 1, 2-D, single band, order gains 1):
    /// L = 0.5·W + 0.288675135·Y + 0.0552305643·X, R = 0.5·W − 0.288675135·Y + 0.0552305643·X, accumulated in that order
    /// (`BFormatDec::process`, one `MixSamples` per ambisonic channel). Nothing clamps the result: just behind the side
    /// (azimuth 90° + δ, 0 < δ < 21.7°) the far speaker is slightly negative, 0.5·(1 − cos δ) − 0.0957·sin δ.
    static let decoder: (left: SIMD3<Float>, right: SIMD3<Float>) = (SIMD3(0.5, 0.288675135, 0.0552305643),
                                                                      SIMD3(0.5, -0.288675135, 0.0552305643))

    /// The per-speaker gains of a steady source (decoded `ambiGains`); a centred mono source plays at 0.5957 per
    /// speaker (−4.5 dB), hard right at (0, 1) only past ±60°.
    static func stereoGains(_ p: SIMD3<Float>, sourceGain: Float, rolloff: Float, reference: Float) -> (left: Float, right: Float) {
        let g = ambiGains(p, sourceGain: sourceGain, rolloff: rolloff, reference: reference)
        func dec(_ c: SIMD3<Float>) -> Float { var v: Float = 0; v += g.x * c.x; v += g.y * c.y; v += g.z * c.z; return v }
        return (dec(decoder.left), dec(decoder.right))
    }
}

/// The playback handle a sound object holds: `PCMVoice` (OpenAL Soft's voice, `VoiceMixer`) for mono tracks, and on
/// headphones for stereo tracks too; `AVAudioPlayer` for tracks OpenAL Soft would play unpanned (multi-channel tracks on
/// speakers: their channels are panned to ±30° · 3 = hard left/right, i.e. plain stereo at the dry gain).
protocol SoundVoice: AnyObject {
    var duration: TimeInterval { get }
    var isPlaying: Bool { get }
    @discardableResult func play() -> Bool
    func pause()
    func stop()
}

#if !os(Linux) // Linux: OpenAL Soft plays every voice (Linux/SoundOpenAL.swift)
extension AVAudioPlayer: SoundVoice {}

/// A decoded track rendered by an `AVAudioSourceNode` on a shared `AVAudioEngine` at the output rate; each render quantum
/// is one OpenAL device update of `VoiceMixer`, which resamples the track from its own rate with OpenAL Soft's linear
/// resampler (as the engine's sources do, docs/re/06 §4.2).
/// * Speaker path (mono only): `SoundSpatial.ambiGains` targets, ramped per dry channel and decoded.
/// * HRTF path (mono or stereo): `HrtfVoiceFilter` per channel.
/// A stopped voice keeps its node until its stop fade (and HRTF tail) has played.
final class PCMVoice: SoundVoice {
    let duration: TimeInterval
    /// Non-nil in the HRTF path.
    let hrtf: HrtfStore?
    let channelCount: Int
    private let node: AVAudioSourceNode
    private let state: State

    /// Shared between the voice and the render block (which keeps it alive while the node may still render).
    private final class State {
        let mixer: VoiceMixer
        var lock = os_unfair_lock()
        init(_ mixer: VoiceMixer) { self.mixer = mixer }

        func render(_ n: Int, _ abl: UnsafeMutableAudioBufferListPointer) {
            guard abl.count >= 2, let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return }
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            mixer.render(n, l, r)
        }

        var isActive: Bool {
            os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
            return mixer.isActive
        }
    }

    private static let engine = AVAudioEngine()

    /// Mono tracks always; stereo tracks only in the HRTF path. nil otherwise (or when decoding fails).
    init?(data: Data, fileExtension: String, loops: Bool) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("photon-voice-\(UUID().uuidString).\(fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url)) != nil, let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let chans = Int(file.processingFormat.channelCount)
        let e = Self.engine
        let outRate = e.outputNode.outputFormat(forBus: 0).sampleRate
        guard outRate > 0 else { return nil }
        let store = SoundOutput.hrtf(rate: outRate)
        guard chans == 1 || (chans == 2 && store != nil) else { return nil }
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil, let ch = buf.floatChannelData else { return nil }
        let rate = file.processingFormat.sampleRate
        let st = State(VoiceMixer(channels: (0..<chans).map { Array(UnsafeBufferPointer(start: ch[$0], count: Int(buf.frameLength))) },
                                  loops: loops, hrtf: store, rate: Int(rate.rounded()), deviceRate: Int(outRate.rounded())))
        state = st
        hrtf = store
        channelCount = chans
        duration = Double(buf.frameLength) / rate
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: outRate, channels: 2) else { return nil }
        node = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl in
            st.render(Int(frameCount), UnsafeMutableAudioBufferListPointer(abl))
            return noErr
        }
        e.attach(node)
        e.connect(node, to: e.mainMixerNode, format: fmt)
        if !e.isRunning { try? e.start() }
    }

    deinit {
        let node = self.node, st = state
        // A stopped (or ended) voice still mixes its fade and the HRTF accumulator its tail: detach once they are done.
        func detach(_ tries: Int) {
            if tries > 0 && st.isActive {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { detach(tries - 1) }
                return
            }
            Self.engine.disconnectNodeOutput(node)
            Self.engine.detach(node)
        }
        detach(20)
    }

    /// Speaker path: the dry (W, Y, X) gains from `SoundSpatial.ambiGains`.
    func setGains(_ ambi: SIMD3<Float>) {
        os_unfair_lock_lock(&state.lock)
        state.mixer.setTargets(ambi)
        os_unfair_lock_unlock(&state.lock)
    }

    /// HRTF path: `position` is the source position handed to OpenAL (at the listener by `SoundSpatial.toSource`, i.e.
    /// within max(FLT_EPSILON, reference/1024): the channels' own angles), `dryGain` the clamped direct gain.
    func setHrtf(position: SIMD3<Float>, reference: Float, dryGain: Float) {
        guard let store = hrtf else { return }
        let filters = SoundSpatial.hrtfFilters(store, position: position, reference: reference, channels: channelCount)
        os_unfair_lock_lock(&state.lock)
        state.mixer.setHrtf(filters, gain: dryGain)
        os_unfair_lock_unlock(&state.lock)
    }

    var isPlaying: Bool {
        os_unfair_lock_lock(&state.lock); defer { os_unfair_lock_unlock(&state.lock) }
        return state.mixer.isPlaying
    }

    @discardableResult func play() -> Bool {
        if !Self.engine.isRunning { try? Self.engine.start() }
        os_unfair_lock_lock(&state.lock)
        state.mixer.play()
        os_unfair_lock_unlock(&state.lock)
        return Self.engine.isRunning
    }
    func pause() {
        os_unfair_lock_lock(&state.lock)
        state.mixer.pause()
        os_unfair_lock_unlock(&state.lock)
    }
    func stop() {
        os_unfair_lock_lock(&state.lock)
        state.mixer.stop()
        os_unfair_lock_unlock(&state.lock)
    }
}
#endif
