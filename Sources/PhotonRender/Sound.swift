#if !os(Linux)
import AVFoundation
#endif
import Foundation
import PhotonCore

/// A sound object (docs/re/06 §4, `Sound_Update` 0x1401f5980).
final class SoundObject: SceneObject {
    enum Mode { case loop, random, single }

    /// Offline rendering never plays audio.
    static var playbackEnabled = true
    /// Master volume (0–1), squared gain like the engine.
    static var masterVolume: Float = 1

    let resources: SceneResources
    let tracks: [String]
    var mode: Mode
    var volume: Float { didSet { volumeChanged() } }
    var minTime: Float
    var maxTime: Float
    let startSilent: Bool
    private var player: SoundVoice?
    private var countdown: Float = 0
    /// +0x300: what is left of the current random / single track, set to its duration on play and run down per frame
    /// while the renderer volume is above 0 (0x1401f4ffc–0x1401f5021).
    private var remaining: Float = 0
    /// The media object's state of the current track (handle +0xc: 0 stopped, 1 paused, 2 playing). It is only changed
    /// by play / pause / stop calls, so a track that ran out still reads playing.
    private enum TrackState { case stopped, paused, playing }
    private var trackState = TrackState.stopped
    /// The host paused a playing track (`setPaused`); photon2's own pause, not the engine's.
    private var hostHeld = false
    /// The renderer volume the volume rule last ran with.
    private var lastRendererVolume: Float?
    private var started = false
    // 3D sound (SoundSpatial.swift): `attenuation` +0x304, `mindistance` +0x308 (ctor 1.0), `spatialization` +0x310 bit 2.
    var attenuation: Float = 1, minDistance: Float = 1
    var spatialization = false
    /// Set by SceneRenderer before the object updates (the previous frame's camera, as the engine reads C).
    var listener: SoundSpatial.Listener?
    /// AL_ROLLOFF_FACTOR / AL_REFERENCE_DISTANCE as last applied on play (0x1401f5839–0x1401f589b).
    private var appliedRolloff: Float = 1, appliedReference: Float = 1

    init(json: [String: Any], id: Int, resources: SceneResources) {
        self.resources = resources
        // Sound_LoadTracks 0x1401f5980: a string is one track; an array contributes its string members (0x1401f5a3a–0x1401f5b0a).
        switch json["sound"] {
        case let one as String: tracks = [one]
        case let list as [Any]: tracks = list.compactMap { $0 as? String }
        default: tracks = []
        }
        switch json["playbackmode"] as? String {
        case "random": mode = .random
        case "single": mode = .single
        default: mode = .loop
        }
        volume = jsonFloats(json["volume"]).first ?? 1
        minTime = jsonFloats(json["mintime"]).first ?? 1
        maxTime = jsonFloats(json["maxtime"]).first ?? 5
        startSilent = jsonBool(json["startsilent"], default: false)
        attenuation = EngineValue.float(json["attenuation"], default: 1)
        minDistance = EngineValue.float(json["mindistance"], default: 1)
        spatialization = EngineValue.bool(json["spatialization"], default: false)
        super.init(json: json, id: id)
        if let a = PropertyAnimation(json: json["volume"]) { animations["volume"] = a }
    }

    /// Object volume squared, times the master and host volume.
    var gain: Float { volume * volume * rendererVolume }
    /// The renderer volume (C+0x2d8 = R+0x2e8): the wallpaper `volume` / 100 × the mute fade (docs/re/09 §2), here also
    /// photon's own master volume.
    var rendererVolume: Float { Self.masterVolume * resources.volume }
    /// AL_GAIN as the engine sets it: the media object's volume slot 0x70 (0x180003fdc) scales the gain by 100 (SFML's
    /// percent volume) and `sf::SoundSource::setVolume` (0x18000e5d0) by 0.01 before `alSourcef(AL_GAIN)`.
    var alGain: Float { (gain * 100) * 0.01 }
    func refreshVolume() { updateSpatial() }

    /// OpenAL Soft source position: set per frame only for `spatialization` sounds; the default (0, 0, 0) otherwise.
    private var sourcePosition = SIMD3<Float>(0, 0, 0)

    /// Gains of the current track. AL_AUTO spatialises every mono buffer, so mono tracks always go through OpenAL Soft's
    /// panning (`SoundSpatial.ambiGains`) or, on headphones, its HRTF (`SoundHRTF.swift`); multi-channel tracks play
    /// at the plain gain on speakers and through HRTF virtual speakers on headphones (`PCMVoice`).
    private func updateSpatial() {
        if spatialization, let l = listener {
            sourcePosition = SoundSpatial.sourcePosition(world: SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z), l)
        }
        #if os(Linux)
        // OpenAL Soft itself (Linux/SoundOpenAL.swift): AL_GAIN and AL_POSITION; the library applies the distance
        // model, AL_AUTO spatialisation, the pair-wise panning or HRTF, and the gain fades.
        (player as? ALVoice)?.update(position: sourcePosition, gain: alGain)
        #else
        if let v = player as? PCMVoice {
            if v.hrtf != nil {
                // DryGain: AL_GAIN × distance attenuation (mono, spatialised under AL_AUTO), clamped to [0, 1]; a
                // stereo buffer is not spatialised (no distance term).
                let dry = v.channelCount == 1
                    ? SoundSpatial.dryGain(sourcePosition, sourceGain: alGain, rolloff: appliedRolloff, reference: appliedReference)
                    : SoundSpatial.clampf(alGain, 0, 1)
                v.setHrtf(position: v.channelCount == 1 ? sourcePosition : .zero, reference: appliedReference, dryGain: dry)
            } else {
                v.setGains(SoundSpatial.ambiGains(sourcePosition, sourceGain: alGain, rolloff: appliedRolloff, reference: appliedReference))
            }
        } else if let p = player as? AVAudioPlayer {
            p.volume = alGain
        }
        #endif
    }

    /// Host pause: hold the current track where it is (only a track that is actually playing), and resume it after.
    func setPaused(_ paused: Bool) {
        if paused {
            if player?.isPlaying ?? false { player?.pause(); hostHeld = true }
        } else if hostHeld {
            hostHeld = false
            if Self.playbackEnabled, resources.soundEnabled, effectiveVisible, trackState == .playing { player?.play() }
        }
    }

    /// The renderer volume may have changed (called by SceneRenderer.setSound every frame): runs the volume rule when
    /// it did, as the renderer's volume setter 0x1401816d0 does for every sound object (skipped when the value is equal).
    func rendererVolumeMaybeChanged() {
        guard Self.playbackEnabled, resources.soundEnabled, !resources.soundPaused, started else { updateSpatial(); return }
        if lastRendererVolume == rendererVolume { updateSpatial(); return }
        volumeChanged()
    }

    /// The volume rule: `Sound_VolumeChanged` 0x1401f4c20 (the `volume` property's change callback, registered at
    /// 0x1401f7144) and the same code inlined in the renderer's volume setter 0x1401816d0 (0x140181740–0x1401818f8),
    /// which runs it for every sound object (type 7) whenever the renderer volume changes:
    /// 1. Start: single never; random when its countdown ≤ 0; loop / random otherwise only when every track is stopped
    ///    (or the sound is script-paused). Then `Sound_Play` unless script-paused (bit 30), `startsilent` not yet played
    ///    (bit 1) or stopped (bit 31); `Sound_Play` itself does nothing while the gain is 0.
    /// 2. Per track: the media volume (volume² × renderer volume). With the renderer volume ≤ 0: a playing track is
    ///    paused (`alSourcePause`), and in random / single mode also stopped when its time (+0x300) has run out. Above
    ///    0: a paused track resumes (play with loop = mode loop) unless the sound is script-paused.
    /// So muting (the mute fade reaches 0) or a wallpaper volume of 0 pauses the sound and unmuting resumes it where it
    /// was; a loop / random sound that never started (silent at load) starts once the volume is above 0.
    private func volumeChanged() {
        updateSpatial()
        guard Self.playbackEnabled, resources.soundEnabled, !resources.soundPaused, started, effectiveVisible else { return }
        lastRendererVolume = rendererVolume
        var start: Bool
        switch mode {
        case .single: start = false
        case .random where !(countdown > 0): start = true
        default: start = trackState == .stopped || scriptPaused
        }
        if start && !scriptPaused && !stopped { soundPlay() }
        guard player != nil else { return }
        if !(rendererVolume > 0) {
            if trackState == .playing {
                player?.pause(); trackState = .paused
                if mode != .loop && !(remaining > 0) { player?.stop(); trackState = .stopped }
            }
        } else if !scriptPaused, trackState == .paused {
            player?.play(); trackState = .playing
        }
    }

    override func apply(_ key: String, _ v: [Float]) {
        if key == "volume", let f = v.first { volume = f } else { super.apply(key, v) }
    }

    /// MSVC `rand()`-style pick: clamp((int)(rand()/32767 · count), 0, count-1).
    private func pick() -> String? {
        guard !tracks.isEmpty else { return nil }
        let idx = min(max(Int(Float.random(in: 0...1) * Float(tracks.count)), 0), tracks.count - 1)
        return tracks[idx]
    }

    /// Tests: makes the track's voice (data, file extension, loops) instead of OpenAL / AVFoundation.
    static var voiceFactory: ((Data, String, Bool) -> SoundVoice?)?

    private func play(_ path: String, loops: Bool) -> Float {
        guard let data = resources.fs.read(path) else { return 0 }
        if let make = Self.voiceFactory {
            guard let v = make(data, (path as NSString).pathExtension, loops) else { return 0 }
            player = v
            updateSpatial()
            v.play()
            trackState = .playing
            return Float(v.duration)
        }
        let p: SoundVoice
        SoundOutput.engineDirectory = SoundOutput.engineDirectory ?? resources.fs.workingDirectory
        #if os(Linux)
        guard let v = ALVoice(data: data, fileExtension: (path as NSString).pathExtension, loops: loops) else { return 0 }
        p = v
        player = p
        if spatialization { appliedRolloff = attenuation; appliedReference = minDistance }
        // AL_ROLLOFF_FACTOR / AL_REFERENCE_DISTANCE per track on play (0x1401f5839–0x1401f589b).
        v.setDistance(rolloff: appliedRolloff, reference: appliedReference)
        #else
        if let v = PCMVoice(data: data, fileExtension: (path as NSString).pathExtension, loops: loops) {
            p = v
        } else {
            guard let ap = try? AVAudioPlayer(data: data) else { return 0 }
            ap.numberOfLoops = loops ? -1 : 0
            p = ap
        }
        player = p
        if spatialization { appliedRolloff = attenuation; appliedReference = minDistance }
        #endif
        updateSpatial()
        p.play()
        trackState = .playing
        return Float(p.duration)
    }

    /// Script `stop()` / the start of every play (0x1401f58e0): flag bit 31, playback stops and the countdown resets.
    private var stopped = false
    /// Script `pause()`: flag bit 30; `play()` then resumes the paused track (0x1401f694f–0x1401f69ef).
    private var scriptPaused = false

    /// `Sound_Play` 0x1401f5980. Nothing starts while the gain (volume² × master) is 0 (0x1401f59b7). loop: a random
    /// track, looped natively when it is the only one, else replayed after its duration; random: when the countdown
    /// is 0, one random track, then a pause of mintime + rand·(maxtime − mintime) after it; single: one random track once.
    private func soundPlay() {
        // A zero gain plays nothing but clears the stopped / paused / startsilent bits (0x1401f6d6f).
        guard gain > 0 else { stopped = false; scriptPaused = false; return }
        if scriptPaused, let p = player {
            scriptPaused = false
            p.play(); trackState = .playing
            return
        }
        switch mode {
        case .single:
            stopTrack(); stopped = false; countdown = 0
            if let t = pick() { remaining = play(t, loops: false) }
        case .random:
            guard countdown == 0 else { return }
            stopTrack(); stopped = false
            if let t = pick() {
                let duration = play(t, loops: false)
                remaining = duration
                countdown = Float.random(in: 0...1) * (maxTime - minTime) + minTime + duration
            }
        case .loop:
            stopTrack(); stopped = false
            if let t = pick() {
                let duration = play(t, loops: tracks.count <= 1)
                countdown = tracks.count > 1 ? duration : 0
            }
        }
        scriptPaused = false
    }

    /// `Sound_StopAll` 0x1401f58e0's per-track stop (only a track that is not already stopped).
    private func stopTrack() {
        if trackState != .stopped { player?.stop() }
        trackState = .stopped; hostHeld = false
    }

    override func update(_ dt: Float) {
        super.update(dt)
        if resources.soundPaused { return }
        guard Self.playbackEnabled, resources.soundEnabled, effectiveVisible else {
            if player != nil { stopTrack() }
            return
        }
        if !started {
            // Load (vt+0x40 0x1401f4f20) plays unless `startsilent` (flag bit 1). A zero gain plays nothing; the volume
            // rule (`volumeChanged`) starts a loop / random sound once the volume is above 0.
            started = true
            lastRendererVolume = rendererVolume
            if startSilent { stopped = true; return }
            soundPlay()
            return
        }
        // Per-frame (0x1401f4f6a): skipped while paused or stopped; with an audible gain and a running countdown,
        // countdown −= dt / C+0x154 and at 0 plays again. C+0x154 is the frame's time scale (rate · pause fade,
        // 0x1401114dc), so the countdown runs in wall-clock time whatever the playback rate; a scale ≤ FLT_EPSILON
        // (paused) stops it (0x1401f4f93–0x1401f4faa).
        updateSpatial()   // Sound_Update 0x1401f5029: positions every frame for spatialised sounds
        guard !stopped, !scriptPaused else { return }
        let scale = resources.timeScale
        let step = scale > Float.ulpOfOne ? dt / scale : 0
        if gain > 0, countdown > 0 {
            countdown -= step
            if countdown <= 0 {
                countdown = 0
                soundPlay()
            }
        }
        // +0x300 runs down while the renderer volume is above 0 (0x1401f4ffc–0x1401f5021).
        if rendererVolume > 0, remaining > 0 { remaining -= step }
    }

    // SceneScript sound-layer methods (docs/re/08 §3.10).
    var isPlaying: Bool { player?.isPlaying ?? false }
    func scriptPlay() {
        guard Self.playbackEnabled, resources.soundEnabled else { return }
        started = true
        if !scriptPaused { stopped = false; countdown = 0 }
        soundPlay()
    }
    func scriptPause() {
        if trackState == .playing { player?.pause(); trackState = .paused }
        scriptPaused = true
    }
    func scriptStop() { stopTrack(); player = nil; stopped = true; scriptPaused = false; countdown = 0 }

    deinit { player?.stop() }
}
