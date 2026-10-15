import Foundation
import simd

/// Fixed test scenes for checking sound-object output across platforms (docs/linux-port.md §3.6): mono noise tracks
/// played through a sequence of device updates while the source moves, its gain changes, and it pauses, resumes, stops,
/// restarts and runs out. `render` produces what photon2's macOS voice (`PCMVoice` in SoundSpatial.swift, through
/// `VoiceMixer`) mixes for a scene: OpenAL Soft 1.21.1's voice rules on speakers (`SoundSpatial.ambiGains`) and on
/// headphones (`HrtfVoiceFilter`, output 256 samples late), resampled to the 48 kHz device with OpenAL's linear
/// resampler. `photon-tool sound-ref` writes these on macOS; `photon-linux sound-check` renders the same scenes through
/// OpenAL Soft 1.21.1's loopback device and compares.
public enum SoundReference {
    /// The device rate.
    public static let rate = 48000
    public static let mixFrames = 480

    /// One device update: the source state set before it, then `action` (alSourcePlay / alSourcePause / alSourceStop;
    /// `restart` is alSourceStop then alSourcePlay, as the engine's `Sound_Play` does). `rolloff` / `reference` are
    /// AL_ROLLOFF_FACTOR / AL_REFERENCE_DISTANCE, `gain` AL_GAIN.
    public struct Step {
        public enum Action: Equatable { case none, play, pause, stop, restart }
        public var position: SIMD3<Float>
        public var gain: Float
        public var action: Action
        public var rolloff: Float = 1
        public var reference: Float = 1

        public init(position: SIMD3<Float>, gain: Float, action: Action = .none, rolloff: Float = 1, reference: Float = 1) {
            self.position = position; self.gain = gain; self.action = action; self.rolloff = rolloff; self.reference = reference
        }
    }

    /// A track (mono noise of `frames` samples at `sourceRate`, looping or not) and the updates (`mixFrames` frames each).
    public struct Scene {
        public var name: String
        public var sourceRate: Int
        public var frames: Int
        public var loops: Bool
        public var mixFrames: Int
        public var steps: [Step]
        /// The track: `samples`, or the noise sequence.
        public var samples: [Float]?
        public var input: [Float] { samples ?? SoundReference.input(frames: frames) }
        /// Updates in which the voice starts, stops, pauses, resumes or ends (and the one after), for the per-event rows.
        public var events: Set<Int>

        public init(name: String, sourceRate: Int, frames: Int, loops: Bool, mixFrames: Int, steps: [Step], events: Set<Int>,
                    samples: [Float]? = nil) {
            self.name = name; self.sourceRate = sourceRate; self.frames = frames; self.loops = loops
            self.mixFrames = mixFrames; self.steps = steps; self.events = events; self.samples = samples
        }
    }

    /// OpenAL's fixed-point step for a track at `sourceRate` on the 48 kHz device (units of 1/4096).
    public static func increment(sourceRate: Int) -> Int { VoiceMixer.increment(sourceRate: sourceRate, deviceRate: rate) }

    /// Mono noise in [−0.5, 0.5) from a 32-bit LCG (the same sequence on every platform).
    public static func input(frames: Int) -> [Float] {
        var x: UInt32 = 0x1234_5678
        return (0..<frames).map { _ in
            x = x &* 1_664_525 &+ 1_013_904_223
            return Float(x >> 8) / Float(1 << 24) - 0.5
        }
    }

    /// The original scene, 200 updates (2 s) at the device rate: at the listener for 10, a circle of radius 2 at ear
    /// height (40), a sweep in elevation, distance attenuation with rolloff 2 / reference 0.5 from 0.25 to 8 units, gain
    /// steps (including 0 and above 1), a pause of 10 and a resume at the listener, moving right by 0.0004 per update:
    /// 0.0004 and 0.0008 are inside OpenAL's at-the-listener radius (AL_REFERENCE_DISTANCE/1024 = 0.00098).
    public static func steps() -> [Step] {
        var s: [Step] = []
        for i in 0..<10 { s.append(Step(position: .zero, gain: 0.8, action: i == 0 ? .play : .none)) }
        for i in 0..<40 {
            let a = Float(i) / 40 * 2 * .pi
            s.append(Step(position: SIMD3(2 * sin(a), 0, -2 * cos(a)), gain: 0.8))
        }
        for i in 0..<30 {
            let e = (Float(i) / 29 - 0.5) * .pi
            s.append(Step(position: SIMD3(0.7 * cos(e), 1.5 * sin(e), -1.5 * cos(e)), gain: 1))
        }
        for i in 0..<40 {
            let d = 0.25 * powf(2, Float(i) / 39 * 5)
            s.append(Step(position: SIMD3(-d * 0.6, 0.1 * d, -d * 0.8), gain: 0.9, rolloff: 2, reference: 0.5))
        }
        let gains: [Float] = [0.5, 0, 0, 0.25, 1.6, 1, 0.05, 0.7, 0.7, 0.3]
        for (i, g) in gains.enumerated() {
            for _ in 0..<4 { s.append(Step(position: SIMD3(1, 0.2 * Float(i % 3), 0.5), gain: g)) }
        }
        for i in 0..<10 { s.append(Step(position: SIMD3(1, 0, 0.5), gain: 0.7, action: i == 0 ? .pause : .none)) }
        for i in 0..<30 { s.append(Step(position: SIMD3(Float(i) * 0.0004, 0, 0), gain: 0.6, action: i == 0 ? .play : .none)) }
        return s
    }

    /// A source circling the listener (radius 1.5, one turn per 37 updates) with a slowly changing gain.
    static func orbit(_ k: Int) -> (SIMD3<Float>, Float) {
        let a = Float(k) / 37 * 2 * .pi
        return (SIMD3(1.5 * sin(a), 0.3 * sin(a * 0.5), -1.5 * cos(a)), 0.5 + 0.3 * sin(Float(k) * 0.21))
    }

    /// Steps from `count` orbit positions and an action per update index.
    static func scripted(_ count: Int, _ actions: [Int: Step.Action], atListener: Set<Int> = []) -> [Step] {
        (0..<count).map { k in
            let (p, g) = orbit(k)
            return Step(position: atListener.contains(k) ? .zero : p, gain: g, action: actions[k] ?? .none)
        }
    }

    static func events(_ steps: [Step], ends: [Int]) -> Set<Int> {
        var e = Set<Int>()
        for (k, s) in steps.enumerated() where s.action != .none { e.insert(k); e.insert(k + 1) }
        for k in ends { e.insert(k); e.insert(k + 1) }
        return e
    }

    /// Updates at which a one-shot track that started (position 0) at update `start` runs out, for a scene's rate.
    static func endUpdate(start: Int, frames: Int, sourceRate: Int, mix: Int) -> Int {
        let inc = VoiceMixer.increment(sourceRate: sourceRate, deviceRate: rate)
        // Device samples until the position reaches `frames`: ceil(frames · 4096 / inc).
        let samples = (frames * VoiceMixer.fracOne + inc - 1) / inc
        return start + (samples - 1) / mix
    }

    /// Every scene `sound-check` compares:
    /// * main: `steps()` at the device rate.
    /// * stop: 48 kHz; stop while playing, play again, pause then stop while paused (silent: the pause already faded),
    ///   play, restart (stop and play in one update: the old voice fades while the new one starts), stop then play,
    ///   the one-shot track running out mid-update (the rest of that update holds its last sample, the next fades), a
    ///   fresh play and a stop at the listener.
    /// * r22050 / r44100 / r96000: the same kind of script with a 22.05 / 44.1 / 96 kHz track (increments 1882, 3763,
    ///   8192 in 1/4096), including the end of the track.
    /// * r96000-1024: 96 kHz in 1024-frame updates, so a mix needs more source samples than one pass holds and is mixed
    ///   in two passes of 512 (`Voice::mix`'s saturated source size).
    /// * loop22050: a 700-sample looping track at 22.05 kHz (it wraps about every 1.5 updates), paused, resumed, stopped.
    public static func scenes() -> [Scene] {
        var out: [Scene] = []
        let main = steps()
        out.append(Scene(name: "main", sourceRate: rate, frames: main.count * mixFrames, loops: false, mixFrames: mixFrames,
                         steps: main, events: events(main, ends: [])))
        // stop
        do {
            let frames = 28 * mixFrames + 137
            let acts: [Int: Step.Action] = [0: .play, 10: .stop, 15: .play, 25: .pause, 30: .stop, 33: .play, 41: .restart,
                                             51: .stop, 52: .play, 90: .play, 100: .stop]
            let s = scripted(106, acts, atListener: [100, 101])
            out.append(Scene(name: "stop", sourceRate: rate, frames: frames, loops: false, mixFrames: mixFrames, steps: s,
                             events: events(s, ends: [endUpdate(start: 52, frames: frames, sourceRate: rate, mix: mixFrames)])))
        }
        for (r, frames, n) in [(22050, 15003, mixFrames), (44100, 30011, mixFrames), (96000, 60007, mixFrames), (96000, 90001, 1024)] {
            let acts: [Int: Step.Action] = [0: .play, 20: .pause, 25: .play, 35: .stop, 37: .play, 45: .restart]
            let end = endUpdate(start: 45, frames: frames, sourceRate: r, mix: n)
            let s = scripted(end + 6, acts)
            out.append(Scene(name: "r\(r)" + (n == mixFrames ? "" : "-\(n)"), sourceRate: r, frames: frames, loops: false,
                             mixFrames: n, steps: s, events: events(s, ends: [end])))
        }
        do {
            let acts: [Int: Step.Action] = [0: .play, 30: .pause, 33: .play, 50: .stop, 53: .play, 58: .stop]
            let s = scripted(62, acts)
            out.append(Scene(name: "loop22050", sourceRate: 22050, frames: 700, loops: true, mixFrames: mixFrames, steps: s,
                             events: events(s, ends: [])))
        }
        return out
    }

    /// The macOS voice (`VoiceMixer`, which `PCMVoice` renders through) over a scene, driven as `sound-check` drives
    /// OpenAL: per update set the source properties, then the action, then render. `store` nil: speaker path; else HRTF
    /// with that store (at the device rate). Interleaved stereo.
    public static func render(_ scene: Scene, store: HrtfStore?) -> [Float] {
        let n = scene.mixFrames
        var out = [Float](repeating: 0, count: scene.steps.count * n * 2)
        let voice = VoiceMixer(channels: [scene.input], loops: scene.loops, hrtf: store, rate: scene.sourceRate, deviceRate: rate)
        var l = [Float](repeating: 0, count: n), r = l
        for (k, st) in scene.steps.enumerated() {
            if let store {
                let dry = SoundSpatial.dryGain(st.position, sourceGain: st.gain, rolloff: st.rolloff, reference: st.reference)
                voice.setHrtf(SoundSpatial.hrtfFilters(store, position: st.position, reference: st.reference, channels: 1), gain: dry)
            } else {
                voice.setTargets(SoundSpatial.ambiGains(st.position, sourceGain: st.gain, rolloff: st.rolloff, reference: st.reference))
            }
            switch st.action {
            case .none: break
            case .play: voice.play()
            case .pause: voice.pause()
            case .stop: voice.stop()
            case .restart: voice.stop(); voice.play()
            }
            voice.render(n, &l, &r)
            for i in 0..<n { out[(k * n + i) * 2] = l[i]; out[(k * n + i) * 2 + 1] = r[i] }
        }
        return out
    }

    /// The main scene's input and `render` of `steps` (photon-linux hrtf-ir).
    public static func render(_ input: [Float], _ steps: [Step], store: HrtfStore?) -> [Float] {
        render(Scene(name: "custom", sourceRate: rate, frames: input.count, loops: false, mixFrames: mixFrames, steps: steps,
                     events: [], samples: input), store: store)
    }

    /// Speaker path (`SoundSpatial.ambiGains`, decoded).
    public static func renderSpeaker(_ input: [Float], _ steps: [Step]) -> [Float] { render(input, steps, store: nil) }

    /// HRTF path with `store` at `rate`.
    public static func renderHrtf(_ input: [Float], _ steps: [Step], store: HrtfStore) -> [Float] { render(input, steps, store: store) }
}
