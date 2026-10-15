import Foundation

/// Playback state behind the SceneScript video-texture wrapper (`layer.getVideoTexture()`, 0x14020e7b0; methods
/// 0x1401fa510–0x1401fa730, reflection map 0x1404e86e0). The engine forwards each method to its video player:
/// play (vt+0x38; when the player reports it has ended it first seeks to 0), pause (vt+0x30), stop (pause + seek 0;
/// for a looping video it also clears +0xf4), isPlaying (vt+0x40 playing && !vt+0x48 ended), getCurrentTime (vt+0x58),
/// setCurrentTime (seek, clears +0xf4 when looping), `duration` (vt+0x60), `rate` (vt+0x68), `loop` (vt+0x70) and
/// `addEndedCallback` (+0x100 vector). photon's videos are otherwise driven by the scene clock; the first
/// getVideoTexture call hands the texture this clock, starting at the current position, playing and looping.
public final class ScriptVideoClock {
    public var time: Double
    public var rate: Float = 1
    public var playing = true
    public var loop = true
    public private(set) var ended = false
    /// Set when a non-looping video reached its end since the last `takeEnded()`.
    private var endedEvent = false
    private var lastScene: Double?

    public init(start: Double) { time = start }

    /// Advanced once per script tick with the scene time (the player runs on its own clock in the engine).
    @discardableResult
    func advance(_ sceneTime: Double, duration: Double) -> Double {
        let dt = lastScene.map { max(0, sceneTime - $0) } ?? 0
        lastScene = sceneTime
        if playing && !ended {
            time += dt * Double(rate)
            if !loop && time >= duration {
                time = max(0, duration - 1e-3)
                ended = true
                endedEvent = true
            }
        }
        return time
    }

    func play() { if ended { seek(0) }; playing = true }
    func pause() { playing = false }
    func stop() { playing = false; seek(0) }
    func seek(_ t: Double) { time = max(0, t); ended = false }
    var isPlaying: Bool { playing && !ended }
    func takeEnded() -> Bool { defer { endedEvent = false }; return endedEvent }
}
