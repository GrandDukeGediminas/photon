#if os(Linux)
import COpenAL
import CPhotonSystem
import Foundation
import PhotonRender
import simd

// Phase-4 checks (docs/linux-port.md §3.6, §5.1), each printing numbers a CI step can gate on:
//   sound-check [mac-ref-dir] [--mhr file]   OpenAL Soft 1.21.1 loopback renders of SoundReference's scene (speaker panning
//                                            and HRTF) against photon2's own voice model computed here and, with a
//                                            directory from `photon-tool sound-ref`, against the macOS output
//   spectrum-check <seconds> <left Hz> <right Hz>   live capture through AudioSystem (PipeWire / PulseAudio) of a test
//                                            tone; the smoothed 64-bin peaks must sit where the analyzer maps the tones
//   media-check <seconds>                    ScriptMedia events from MPRIS (the SceneScript media path), as JSON lines
//   system-check <seconds>                   the playback-rule inputs (UPower, logind, screensaver) as they change
//   hrtf-ir <x> <y> <z>                      OpenAL's HRTF impulse response for a static source next to photon2's filter
enum AudioCheck {
    // MARK: sound-check

    struct Stats: CustomStringConvertible {
        var maxAbs: Float = 0, rmsDiff: Double = 0, rmsRef: Double = 0, count = 0
        var snr: Double { rmsDiff > 0 ? 20 * log10(rmsRef / rmsDiff) : .infinity }
        var description: String {
            String(format: "max |Δ| %.3g, RMS Δ %.3g, SNR %.1f dB", maxAbs, rmsDiff, snr)
        }
    }

    /// Per-sample comparison of interleaved stereo buffers, skipping the updates in `skip` (`n` frames each).
    static func compare(_ a: [Float], _ b: [Float], n: Int = SoundReference.mixFrames, skip: Set<Int> = []) -> Stats {
        var s = Stats(), d2 = 0.0, r2 = 0.0
        for i in 0..<min(a.count, b.count) where !skip.contains(i / (n * 2)) {
            let d = a[i] - b[i]
            s.maxAbs = max(s.maxAbs, abs(d))
            d2 += Double(d * d); r2 += Double(b[i] * b[i]); s.count += 1
        }
        s.rmsDiff = (d2 / Double(max(s.count, 1))).squareRoot()
        s.rmsRef = (r2 / Double(max(s.count, 1))).squareRoot()
        return s
    }

    /// A scene through an OpenAL Soft loopback device at 48 kHz float stereo, HRTF on or off (ALC_HRTF_SOFT), with the
    /// engine's source setup (defaults; AL_ROLLOFF_FACTOR / AL_REFERENCE_DISTANCE / AL_POSITION / AL_GAIN per update, then
    /// alSourcePlay / alSourcePause / alSourceStop). The track is a float buffer at the scene's rate (AL_LOOPING when it
    /// loops: the same samples as the engine's SFML stream, which refills its queue seamlessly).
    static func renderOpenAL(_ scene: SoundReference.Scene, hrtf: Bool) -> (out: [Float], info: String)? {
        guard let dev = alcLoopbackOpenDeviceSOFT(nil) else { return nil }
        defer { alcCloseDevice(dev) }
        let attrs: [ALCint] = [ALC_FORMAT_CHANNELS_SOFT, ALC_STEREO_SOFT, ALC_FORMAT_TYPE_SOFT, ALC_FLOAT_SOFT,
                               ALC_FREQUENCY, ALCint(SoundReference.rate), ALC_HRTF_SOFT, hrtf ? ALC_TRUE : ALC_FALSE, 0]
        guard let ctx = attrs.withUnsafeBufferPointer({ alcCreateContext(dev, $0.baseAddress) }) else { return nil }
        defer { alcMakeContextCurrent(nil); alcDestroyContext(ctx) }
        alcMakeContextCurrent(ctx)
        var status: ALCint = 0
        alcGetIntegerv(dev, ALC_HRTF_STATUS_SOFT, 1, &status)
        let version = alGetString(AL_VERSION).map { String(cString: $0) } ?? "?"
        let hrtfName = alcGetString(dev, ALC_HRTF_SPECIFIER_SOFT).map { String(cString: $0) } ?? ""
        let resampler = alGetInteger(AL_DEFAULT_RESAMPLER_SOFT)
        var buffer: ALuint = 0, source: ALuint = 0
        alGenBuffers(1, &buffer)
        scene.input.withUnsafeBytes { alBufferData(buffer, AL_FORMAT_MONO_FLOAT32, $0.baseAddress, ALsizei($0.count), ALsizei(scene.sourceRate)) }
        alGenSources(1, &source)
        alSourcei(source, AL_BUFFER, ALint(bitPattern: buffer))
        if scene.loops { alSourcei(source, AL_LOOPING, AL_TRUE) }
        let n = scene.mixFrames
        var out = [Float](repeating: 0, count: scene.steps.count * n * 2)
        for (k, st) in scene.steps.enumerated() {
            alSourcef(source, AL_ROLLOFF_FACTOR, st.rolloff)
            alSourcef(source, AL_REFERENCE_DISTANCE, st.reference)
            alSource3f(source, AL_POSITION, st.position.x, st.position.y, st.position.z)
            alSourcef(source, AL_GAIN, st.gain)
            switch st.action {
            case .none: break
            case .play: alSourcePlay(source)
            case .pause: alSourcePause(source)
            case .stop: alSourceStop(source)
            case .restart: alSourceStop(source); alSourcePlay(source)
            }
            out.withUnsafeMutableBufferPointer { alcRenderSamplesSOFT(dev, $0.baseAddress! + k * n * 2, ALCsizei(n)) }
        }
        let err = alGetError()
        alDeleteSources(1, &source)
        alDeleteBuffers(1, &buffer)
        guard err == AL_NO_ERROR else { return nil }
        return (out, "OpenAL \(version), default resampler \(resampler), HRTF status \(status)\(hrtfName.isEmpty ? "" : " (\(hrtfName))")")
    }

    /// `photon-linux hrtf-ir x y z`: OpenAL's impulse response for a static source at (x, y, z) next to photon2's filter.
    static func hrtfIR(_ args: [String]) -> Int32 {
        let v = args.compactMap(Float.init)
        guard v.count == 3, let raw = (try? Data(contentsOf: URL(fileURLWithPath: "/usr/local/share/openal/default-hrtf-1.21.1.mhr"))).flatMap(HrtfStore.parse03) else { return 2 }
        let store = raw.resampled(to: SoundReference.rate)
        let p = SIMD3<Float>(v[0], v[1], v[2])
        var input = [Float](repeating: 0, count: 960 * 4); input[0] = 1
        let steps = (0..<8).map { SoundReference.Step(position: p, gain: 1, action: $0 == 0 ? .play : .none, rolloff: 0, reference: 1) }
        let scene = SoundReference.Scene(name: "ir", sourceRate: SoundReference.rate, frames: input.count, loops: false,
                                         mixFrames: SoundReference.mixFrames, steps: steps, events: [], samples: input)
        guard let al = renderOpenAL(scene, hrtf: true) else { return 2 }
        let sw = SoundReference.renderHrtf(input, steps, store: store)
        let d = simd_length(p), n = p / d
        let f = store.filter(elevation: asin(n.y), azimuth: atan2(n.x, -n.z), distance: d, spread: 0)
        print("photon filter delays \(f.delay), store fields \(store.fields.map { ($0.distance, $0.evCount) })")
        for ch in 0..<2 {
            let a = (0..<60).map { al.out[(255 + $0) * 2 + ch] }, b = (0..<60).map { sw[(255 + $0) * 2 + ch] }
            print("ch\(ch) openal: " + a.map { String(format: "%.3f", $0) }.joined(separator: " "))
            print("ch\(ch) photon: " + b.map { String(format: "%.3f", $0) }.joined(separator: " "))
        }
        return 0
    }

    static func readFloats(_ url: URL) -> [Float]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func soundCheck(_ args: [String]) -> Int32 {
        var refDir: URL?, mhr = "/usr/local/share/openal/default-hrtf-1.21.1.mhr", outDir: URL?
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--mhr": mhr = it.next() ?? mhr
            case "--out": outDir = it.next().map { URL(fileURLWithPath: $0) }
            default: refDir = URL(fileURLWithPath: a)
            }
        }
        // OpenAL Soft 1.21.1's "Default HRTF.mhr" is byte-identical to the MinPHR03 blob in mediaextensions64.dll.
        guard let raw = (try? Data(contentsOf: URL(fileURLWithPath: mhr))).flatMap(HrtfStore.parse03) else {
            print("sound-check: cannot read the HRTF set \(mhr)"); return 2
        }
        let store = raw.resampled(to: SoundReference.rate)
        var failed = false
        func row(_ label: String, _ s: Stats, limit: Float?) {
            let ok = limit.map { s.maxAbs <= $0 } ?? true
            if !ok { failed = true }
            print("  \(label): \(s)\(limit.map { String(format: " (limit %.0e)%@", $0, ok ? "" : " FAIL") } ?? "")")
        }
        if let outDir { try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true) }
        var printed = false
        for scene in SoundReference.scenes() {
            let swiftSpeaker = SoundReference.render(scene, store: nil)
            let swiftHrtf = SoundReference.render(scene, store: store)
            guard let alSpeaker = renderOpenAL(scene, hrtf: false), let alHrtf = renderOpenAL(scene, hrtf: true) else {
                print("sound-check: OpenAL loopback device unavailable"); return 2
            }
            if !printed {
                print("speaker: \(alSpeaker.info)")
                print("hrtf:    \(alHrtf.info); store \(raw.sampleRate) Hz → \(store.sampleRate) Hz, \(store.irSize) taps, \(store.irCount) IRs")
                printed = true
            }
            if let outDir {
                for (name, v) in [("openal-speaker", alSpeaker.out), ("openal-hrtf", alHrtf.out), ("swift-speaker", swiftSpeaker), ("swift-hrtf", swiftHrtf)] {
                    try? v.withUnsafeBytes { Data($0) }.write(to: outDir.appendingPathComponent("\(scene.name).\(name).f32"))
                }
            }
            // OpenAL Soft 1.21.1 delays the per-source HRTF mix by HrtfDirectDelay = 256 samples; photon2's
            // HrtfVoiceFilter does the same, so the outputs are compared as they are. The event rows cover the updates
            // where the voice starts, pauses, resumes, stops or runs out, and the update after (in the all-update rows too).
            let n = scene.mixFrames
            let others = Set(scene.steps.indices).subtracting(scene.events)
            print("\(scene.name): \(scene.steps.count) updates of \(n) frames, track \(scene.frames) frames at \(scene.sourceRate) Hz\(scene.loops ? " looping" : ""), increment \(SoundReference.increment(sourceRate: scene.sourceRate))")
            print(" OpenAL Soft vs photon2's voice model (this build):")
            row("speaker, all updates  ", compare(alSpeaker.out, swiftSpeaker, n: n), limit: 1e-6)
            row("speaker, event updates", compare(alSpeaker.out, swiftSpeaker, n: n, skip: others), limit: nil)
            row("hrtf, all updates     ", compare(alHrtf.out, swiftHrtf, n: n), limit: 1e-6)
            row("hrtf, event updates   ", compare(alHrtf.out, swiftHrtf, n: n, skip: others), limit: nil)
            if let refDir {
                guard let macSpeaker = readFloats(refDir.appendingPathComponent("\(scene.name).speaker.f32")),
                      let macHrtf = readFloats(refDir.appendingPathComponent("\(scene.name).hrtf.f32")) else {
                    print("sound-check: no \(scene.name).speaker.f32 / .hrtf.f32 in \(refDir.path)"); return 2
                }
                print(" against macOS (photon-tool sound-ref, \(refDir.lastPathComponent)):")
                row("photon2 Linux vs macOS, speaker", compare(swiftSpeaker, macSpeaker, n: n), limit: 1e-6)
                row("photon2 Linux vs macOS, hrtf   ", compare(swiftHrtf, macHrtf, n: n), limit: 1e-6)
                row("OpenAL vs macOS, speaker, all updates  ", compare(alSpeaker.out, macSpeaker, n: n), limit: 1e-6)
                row("OpenAL vs macOS, speaker, event updates", compare(alSpeaker.out, macSpeaker, n: n, skip: others), limit: nil)
                row("OpenAL vs macOS, hrtf, all updates     ", compare(alHrtf.out, macHrtf, n: n), limit: 1e-6)
                row("OpenAL vs macOS, hrtf, event updates   ", compare(alHrtf.out, macHrtf, n: n, skip: others), limit: nil)
            }
        }
        print(failed ? "sound-check: FAILED" : "sound-check: passed")
        return failed ? 1 : 0
    }

    // MARK: spectrum-check

    /// The 64-bin index the analyzer maps `hz` to (the same walk as `photon-tool audio-test synth`).
    static func expectedBin(_ hz: Double, _ an: AudioAnalyzer) -> Int {
        let k = Int((hz * Double(an.N) / an.sampleRate).rounded())
        var prev = 0
        for i in 1...max(k, 1) { prev = min(Int(powf(Float(i - 1) / Float(an.M - 1), 0.25) * 64) % 64, prev + 1) }
        return prev
    }

    static func spectrumCheck(_ args: [String]) -> Int32 {
        let secs = args.first.flatMap(Double.init) ?? 4
        let left = args.count > 1 ? Double(args[1]) ?? 440 : 440, right = args.count > 2 ? Double(args[2]) ?? 2000 : 2000
        let audio = AudioSystem.shared
        audio.start()
        let sm = AudioSpectrumSmoother()
        let start = Date()
        var last = start, peaksL: [Int: Int] = [:], peaksR: [Int: Int] = [:], frames = 0, nonzero = 0
        while Date().timeIntervalSince(start) < secs {
            usleep(16_000)
            let now = Date()
            let spec = audio.latestSpectrum()
            sm.update(input: spec, dt: Float(now.timeIntervalSince(last)))
            last = now
            guard now.timeIntervalSince(start) > 1 else { continue } // capture start-up and smoothing settle
            frames += 1
            let l = sm.arrays.left64, r = sm.arrays.right64
            if l.max() ?? 0 > 0.1 { nonzero += 1 }
            peaksL[l.indices.max { l[$0] < l[$1] }!, default: 0] += 1
            peaksR[r.indices.max { r[$0] < r[$1] }!, default: 0] += 1
        }
        guard let name = audio.backendName else { print("spectrum-check: no capture backend"); return 2 }
        let rate = audio.captureRate
        let an = AudioAnalyzer(sampleRate: rate)
        let eL = expectedBin(left, an), eR = expectedBin(right, an)
        let pL = peaksL.max { $0.value < $1.value }?.key ?? -1, pR = peaksR.max { $0.value < $1.value }?.key ?? -1
        print("capture: \(name) at \(Int(rate)) Hz, N \(an.N), fill \(an.fill); \(frames) frames sampled, \(nonzero) with signal")
        print("left \(Int(left)) Hz: peak bin \(pL) (expected \(eL)), right \(Int(right)) Hz: peak bin \(pR) (expected \(eR))")
        print("16L: " + sm.arrays.left16.map { String(format: "%.2f", $0) }.joined(separator: " "))
        print("16R: " + sm.arrays.right16.map { String(format: "%.2f", $0) }.joined(separator: " "))
        audio.stop()
        let ok = nonzero > frames / 2 && abs(pL - eL) <= 1 && abs(pR - eR) <= 1
        print(ok ? "spectrum-check: passed" : "spectrum-check: FAILED")
        return ok ? 0 : 1
    }

    // MARK: system-check

    static func systemCheck(_ args: [String]) -> Int32 {
        let secs = args.first.flatMap(Double.init) ?? 5
        photon_system_watch_start()
        var last = photon_system_state(), first = true
        let start = Date()
        func line(_ s: photon_system_state) -> String {
            "system bus \(s.system_bus), session bus \(s.session_bus), upower \(s.upower) on_battery \(s.on_battery), "
                + "logind \(s.logind) preparing_sleep \(s.preparing_sleep) locked \(s.locked), screensaver \(s.screensaver) "
                + "(events: sleep \(s.sleep_events), lock \(s.lock_events), screensaver \(s.screensaver_events), battery \(s.battery_events))"
        }
        while Date().timeIntervalSince(start) < secs {
            var s = photon_system_state()
            photon_system_state_get(&s)
            if first || memcmp(&s, &last, MemoryLayout<photon_system_state>.size) != 0 {
                print(String(format: "t=%5.2f ", Date().timeIntervalSince(start)) + line(s))
                last = s; first = false
            }
            usleep(50_000)
        }
        return 0
    }
}
#endif
