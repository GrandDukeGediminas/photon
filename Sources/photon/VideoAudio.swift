import AVFoundation
import Foundation
import PhotonRender

/// The sound of a video wallpaper. The engine's VideoWallpaper plays the file through Media Foundation with audio on
/// (`videoaudiooutput`, default true, 0x140047808; off selects the "mf.muted"/"mfEngine.muted" players, 0x1400ff820),
/// at the wallpaper `volume` / 100 and `rate` / 100 (0x1400ffdb5–0x1400ffe77). photon2 decodes the picture on the scene
/// clock (`VideoTexture`), so this player carries only the audio track and is kept within 0.15 s of that clock.
final class VideoAudio {
    private let player: AVPlayer
    private let duration: Double

    /// `project` is the wallpaper folder; its project.json `file` is the video.
    init?(project: URL) {
        let file = (SceneRenderer.readProject(project)["file"] as? String) ?? ""
        let url = project.appendingPathComponent(file)
        guard !file.isEmpty, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        let d = CMTimeGetSeconds(asset.duration)
        guard d.isFinite, d > 0 else { return nil }
        duration = d
        let item = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = false
        // Audio only: the picture comes from VideoTexture.
        Task { @MainActor [weak item] in
            guard let tracks = try? await asset.loadTracks(withMediaType: .video) else { return }
            for t in item?.tracks ?? [] where tracks.contains(where: { $0.trackID == t.assetTrack?.trackID }) { t.isEnabled = false }
        }
    }

    /// Follows the wallpaper clock (seconds of scene time; the video loops every `duration`).
    func sync(clock: Double, rate: Float, volume: Float, paused: Bool) {
        player.volume = max(volume, 0)
        if paused {
            if player.rate != 0 { player.pause() }
            return
        }
        let target = clock.truncatingRemainder(dividingBy: duration)
        let now = CMTimeGetSeconds(player.currentTime())
        if !now.isFinite || abs(now - target) > 0.15 && abs(now - target) < duration - 0.15 {
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if player.rate != rate { player.rate = rate }
    }

    deinit { player.pause() }
}
