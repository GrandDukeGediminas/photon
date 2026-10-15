#if os(Linux)
import CPhotonMedia
import Foundation
import PhotonCore
import PhotonRender

/// The sound of a video wallpaper on Linux: Sources/photon/VideoAudio.swift with GStreamer's playbin (audio only) in
/// place of AVPlayer, behind the same `sync` call. The engine's VideoWallpaper plays the file with audio on at the
/// wallpaper `volume` / 100 and `rate` / 100 (docs/re/09 §7); the picture comes from VideoTexture on the scene clock, and
/// this player is kept within 0.15 s of that clock (a flushing seek otherwise), paused with the wallpaper.
final class VideoAudio {
    private let player: OpaquePointer
    private let duration: Double
    private var playing = false
    private var rate: Float = 1
    private var lastLog = Date.distantPast
    private let log = ProcessInfo.processInfo.environment["PHOTON_VIDEO_AUDIO_LOG"] == "1"

    /// `project` is the wallpaper folder; its project.json `file` is the video. Nil without an audio track or player.
    init?(project: URL) {
        let file = (SceneRenderer.readProject(project)["file"] as? String) ?? ""
        let url = project.appendingPathComponent(file)
        guard !file.isEmpty, FileManager.default.fileExists(atPath: url.path), let p = photon_audio_open(url.path) else { return nil }
        let d = photon_audio_duration(p)
        guard d.isFinite, d > 0 else {
            photon_audio_close(p)
            return nil
        }
        player = p
        duration = d
    }

    deinit { photon_audio_close(player) }

    /// Follows the wallpaper clock (seconds of scene time; the video loops every `duration`).
    func sync(clock: Double, rate: Float, volume: Float, paused: Bool) {
        photon_audio_poll(player)
        photon_audio_set_volume(player, Double(max(volume, 0)))
        if paused {
            if playing { photon_audio_set_playing(player, 0); playing = false }
            return
        }
        let target = clock.truncatingRemainder(dividingBy: duration)
        let now = photon_audio_position(player)
        if now < 0 || abs(now - target) > 0.15 && abs(now - target) < duration - 0.15 || rate != self.rate {
            _ = photon_audio_seek(player, target, Double(rate))
            self.rate = rate
        }
        if !playing { photon_audio_set_playing(player, 1); playing = true }
        if log, Date().timeIntervalSince(lastLog) >= 1 {
            lastLog = Date()
            print(String(format: "video audio: clock %.3f target %.3f position %.3f rate %.2f", clock, target, now, rate))
        }
    }
}
#endif
