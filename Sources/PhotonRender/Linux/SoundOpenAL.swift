#if os(Linux)
import COpenAL
import CPhotonMedia
import Foundation
import simd

// Sound objects on Linux play through OpenAL Soft, the library the engine itself uses: mediaextensions64.dll links
// OpenAL Soft 1.21.1 (docs/re/06 §4.1, loader-keys §6.9). The engine's calls, reproduced here:
// * one device and context, `alcOpenDevice(NULL)` + `alcCreateContext(dev, NULL)` (0x18000ef96 / 0x18000efb0): no
//   attributes, so HRTF is OpenAL Soft's own default (on when the output is headphones; with PulseAudio/PipeWire that is
//   the sink's active port or `device.form_factor` headphone/headset), the pair-wise panning otherwise;
// * the listener at the origin facing −Z, +Y up (0x18000efcd–0x18000f063), the default distance model
//   (AL_INVERSE_DISTANCE_CLAMPED: no alDistanceModel call), sources with default state (not listener-relative,
//   AL_SOURCE_SPATIALIZE_SOFT = AL_AUTO, so only mono buffers are spatialised);
// * per track on play AL_ROLLOFF_FACTOR = attenuation, AL_REFERENCE_DISTANCE = mindistance (0x18000e520 / 0x18000e530),
//   per frame AL_POSITION (0x18000e580) and the gain volume² × master (Sound.swift decides both).
// So panning, HRTF (the built-in MinPHR03 set, byte-identical to the dll's), distance attenuation and OpenAL's gain
// fades match the engine by construction instead of by emulation (SoundSpatial.swift / SoundHRTF.swift on macOS).
// Tracks are decoded with GStreamer to float32 at their own rate; OpenAL resamples to the device rate.
// PHOTON_HRTF=1/0 adds ALC_HRTF_SOFT = ALC_TRUE / ALC_FALSE to the context attributes (alsoft.ini `hrtf = true/false`).

public enum SoundOutput {
    /// Kept for Sound.swift (the macOS HRTF store reads the dll from there); OpenAL Soft carries its own HRTF data.
    public static var engineDirectory: URL?
}

/// The process's OpenAL device and context, opened on the first voice.
public final class OpenALOutput {
    public static let shared = OpenALOutput()
    let device: OpaquePointer?
    let context: OpaquePointer?
    /// "1.1 ALSOFT 1.21.1" for the pinned build.
    public private(set) var version = ""
    public private(set) var deviceName = ""
    /// ALC_HRTF_STATUS_SOFT and the HRTF name ("" without HRTF).
    public private(set) var hrtfStatus: Int32 = 0
    public private(set) var hrtfName = ""

    /// ALC_HRTF_SOFT for PHOTON_HRTF=1/0, else nil (the engine's NULL attribute list).
    static func contextAttributes() -> [ALCint]? {
        switch ProcessInfo.processInfo.environment["PHOTON_HRTF"] {
        case "1"?: return [ALC_HRTF_SOFT, ALC_TRUE, 0]
        case "0"?: return [ALC_HRTF_SOFT, ALC_FALSE, 0]
        default: return nil
        }
    }

    private init() {
        device = alcOpenDevice(nil)
        guard let device else {
            context = nil
            FileHandle.standardError.write(Data("photon: OpenAL: no output device; sound objects stay silent\n".utf8))
            return
        }
        let attrs = Self.contextAttributes()
        context = attrs.map { a in a.withUnsafeBufferPointer { alcCreateContext(device, $0.baseAddress) } } ?? alcCreateContext(device, nil)
        guard let context else {
            FileHandle.standardError.write(Data("photon: OpenAL: alcCreateContext failed; sound objects stay silent\n".utf8))
            return
        }
        alcMakeContextCurrent(context)
        version = alGetString(AL_VERSION).map { String(cString: $0) } ?? ""
        deviceName = alcGetString(device, ALC_ALL_DEVICES_SPECIFIER).map { String(cString: $0) }
            ?? alcGetString(device, ALC_DEVICE_SPECIFIER).map { String(cString: $0) } ?? ""
        var status: ALCint = 0
        alcGetIntegerv(device, ALC_HRTF_STATUS_SOFT, 1, &status)
        hrtfStatus = status
        if let s = alcGetString(device, ALC_HRTF_SPECIFIER_SOFT) { hrtfName = String(cString: s) }
        let mode = Self.hrtfStatusName(status) + (hrtfName.isEmpty ? "" : " (\(hrtfName))")
        FileHandle.standardError.write(Data("photon: OpenAL \(version) on \"\(deviceName)\", HRTF \(mode)\n".utf8))
    }

    static func hrtfStatusName(_ s: ALCint) -> String {
        switch s {
        case ALC_HRTF_DISABLED_SOFT: return "disabled"
        case ALC_HRTF_ENABLED_SOFT: return "enabled"
        case ALC_HRTF_DENIED_SOFT: return "denied"
        case ALC_HRTF_REQUIRED_SOFT: return "required"
        case ALC_HRTF_HEADPHONES_DETECTED_SOFT: return "enabled (headphones detected)"
        case ALC_HRTF_UNSUPPORTED_FORMAT_SOFT: return "unsupported format"
        default: return "status \(s)"
        }
    }

    var isAvailable: Bool { context != nil }
}

/// Decoded tracks shared by the voices that play them; an AL buffer is deleted when its last voice goes.
final class ALBufferCache {
    static let shared = ALBufferCache()
    private struct Entry { var buffer: ALuint; var users: Int; var channels: Int; var frames: Int; var rate: Int }
    private var entries: [Int: Entry] = [:]
    private let lock = NSLock()

    /// (buffer, channels, duration) for `data`, decoding on first use.
    func acquire(_ data: Data, fileExtension: String) -> (buffer: ALuint, key: Int, channels: Int, duration: Double)? {
        // FNV-1a over the whole file (Data's own hash covers only its first bytes).
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        data.withUnsafeBytes { for b in $0 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 } }
        let key = Int(truncatingIfNeeded: h)
        lock.lock(); defer { lock.unlock() }
        if var e = entries[key] {
            e.users += 1
            entries[key] = e
            return (e.buffer, key, e.channels, Double(e.frames) / Double(e.rate))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("photon-voice-\(UUID().uuidString).\(fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url)) != nil else { return nil }
        var rate: Int32 = 0, channels: Int32 = 0, frames = 0
        guard let pcm = photon_audio_decode(url.path, &rate, &channels, &frames) else { return nil }
        defer { free(pcm) }
        var buffer: ALuint = 0
        alGenBuffers(1, &buffer)
        guard alGetError() == AL_NO_ERROR else { return nil }
        let format = channels == 1 ? AL_FORMAT_MONO_FLOAT32 : AL_FORMAT_STEREO_FLOAT32
        alBufferData(buffer, format, pcm, ALsizei(frames * Int(channels) * MemoryLayout<Float>.size), ALsizei(rate))
        guard alGetError() == AL_NO_ERROR else { alDeleteBuffers(1, &buffer); return nil }
        entries[key] = Entry(buffer: buffer, users: 1, channels: Int(channels), frames: frames, rate: Int(rate))
        return (buffer, key, Int(channels), Double(frames) / Double(rate))
    }

    func release(_ key: Int) {
        lock.lock(); defer { lock.unlock() }
        guard var e = entries[key] else { return }
        e.users -= 1
        if e.users <= 0 {
            var b = e.buffer
            alDeleteBuffers(1, &b)
            entries[key] = nil
        } else {
            entries[key] = e
        }
    }
}

/// One playing track: an OpenAL source on a cached buffer (the dll's per-track source, 0x18000dfc0).
final class ALVoice: SoundVoice {
    let duration: TimeInterval
    let channelCount: Int
    private var source: ALuint = 0
    private let key: Int

    init?(data: Data, fileExtension: String, loops: Bool) {
        guard OpenALOutput.shared.isAvailable,
              let b = ALBufferCache.shared.acquire(data, fileExtension: fileExtension) else { return nil }
        key = b.key
        channelCount = b.channels
        duration = b.duration
        alGenSources(1, &source)
        guard alGetError() == AL_NO_ERROR else { ALBufferCache.shared.release(b.key); return nil }
        alSourcei(source, AL_BUFFER, ALint(bitPattern: b.buffer))
        // A single-track loop sound loops natively (Sound_Play: AL_LOOPING when n ≤ 1).
        alSourcei(source, AL_LOOPING, loops ? AL_TRUE : AL_FALSE)
    }

    deinit {
        alSourceStop(source)
        alDeleteSources(1, &source)
        ALBufferCache.shared.release(key)
    }

    /// AL_ROLLOFF_FACTOR / AL_REFERENCE_DISTANCE (on play).
    func setDistance(rolloff: Float, reference: Float) {
        alSourcef(source, AL_ROLLOFF_FACTOR, rolloff)
        alSourcef(source, AL_REFERENCE_DISTANCE, reference)
    }

    /// AL_POSITION (the engine's view-space position, SoundSpatial.sourcePosition) and AL_GAIN.
    func update(position p: SIMD3<Float>, gain: Float) {
        alSource3f(source, AL_POSITION, p.x, p.y, p.z)
        alSourcef(source, AL_GAIN, max(gain, 0))
    }

    var isPlaying: Bool {
        var state: ALint = 0
        alGetSourcei(source, AL_SOURCE_STATE, &state)
        return state == AL_PLAYING
    }

    @discardableResult func play() -> Bool {
        alSourcePlay(source)
        return alGetError() == AL_NO_ERROR
    }
    func pause() { alSourcePause(source) }
    func stop() { alSourceStop(source) }
}
#endif
