#if os(Linux)
import CPhotonSystem
import Foundation

// System-audio capture for the spectrum on Linux (docs/linux-port.md §3.6): the default sink's monitor through
// PipeWire, else PulseAudio's `@DEFAULT_MONITOR@` (photon_capture.c). Each buffer the stream delivers is one packet, as
// one WASAPI GetBuffer is in the engine's loopback capture (docs/re/06 §5.1); a packet of exact zeros is marked silent,
// as on macOS (a monitor keeps delivering zeros where WASAPI loopback would deliver nothing or silent packets). The
// analysis (`AudioSystem.run`, `AudioAnalyzer`) is the shared code. PHOTON_AUDIO_BACKEND=pipewire|pulse picks one.

final class LinuxAudioCapture: AudioCaptureBackend {
    let name: String
    let sampleRate: Double
    private var handle: OpaquePointer?
    private let queue: Unmanaged<AudioPacketQueue>

    init(queue q: AudioPacketQueue, backend: String?) throws {
        queue = Unmanaged.passRetained(q)
        var err = [CChar](repeating: 0, count: 320)
        let h = photon_capture_open(backend, { ctx, samples, frames, channels in
            guard let ctx, let samples, frames > 0, channels > 0 else { return }
            let q = Unmanaged<AudioPacketQueue>.fromOpaque(ctx).takeUnretainedValue()
            q.push(makePacket(interleaved: samples, frames: Int(frames), channels: Int(channels)))
        }, queue.toOpaque(), &err, err.count)
        guard let h else {
            queue.release()
            throw NSError(domain: "photon.audio", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: err)])
        }
        handle = h
        name = String(cString: photon_capture_backend(h))
        sampleRate = Double(photon_capture_rate(h))
    }

    func stop() {
        guard let h = handle else { return }
        handle = nil
        photon_capture_close(h)
        queue.release()
    }

    deinit { stop() }
}

extension AudioSystem {
    static let silenceHint = "photon: system audio capture has delivered only silence for 5 s (nothing playing, or the "
        + "capture stream is not linked to the default sink's monitor)"

    /// PipeWire, then PulseAudio (PHOTON_AUDIO_BACKEND forces one).
    func startPlatformBackend() {
        let want = ProcessInfo.processInfo.environment["PHOTON_AUDIO_BACKEND"]
        do {
            attach(try LinuxAudioCapture(queue: packets, backend: want))
        } catch {
            Self.logOnce("photon: system audio capture unavailable (\(error.localizedDescription)); audio spectrum stays zero")
        }
    }
}
#endif
