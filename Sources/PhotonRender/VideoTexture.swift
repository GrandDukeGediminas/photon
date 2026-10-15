import AVFoundation
import CoreVideo
import CryptoKit
import Foundation
import Metal

/// A looping video decoded with AVAssetReader into a fixed Metal texture (docs/re/01 §3.8).
///
/// The engine hands the file and the MP4's offset/size to its video player and samples the frames as a
/// normal texture. Here the video is decoded on the render thread, driven by the scene clock, so offline
/// renders are deterministic: `update(time:)` shows the last frame whose presentation time is <= time mod duration.
public final class VideoTexture {
    public let url: URL
    public let width: Int
    public let height: Int
    public let duration: Double
    /// Stable texture the materials bind; each new video frame is copied into it.
    public let texture: MTLTexture

    private let device: MTLDevice
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var pending: (CVPixelBuffer, Double)?
    private var shownTime = -Double.infinity
    private var dirty: CVPixelBuffer?
    private var textureCache: CVMetalTextureCache?
    private var lastUpdate: Double?

    public init?(device: MTLDevice, url: URL, label: String) {
        self.device = device
        self.url = url
        asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = Self.videoTrack(asset) else {
            NSLog("photon: no video track in %@", url.path)
            return nil
        }
        self.track = track
        let size = track.naturalSize.applying(track.preferredTransform)
        width = max(Int(abs(size.width).rounded()), 1)
        height = max(Int(abs(size.height).rounded()), 1)
        let d = CMTimeGetSeconds(track.timeRange.duration)
        duration = d.isFinite && d > 0 ? d : CMTimeGetSeconds(asset.duration)

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.label = label
        texture = tex
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    /// Scene loading is synchronous, so block on the async track load.
    private static func videoTrack(_ asset: AVURLAsset) -> AVAssetTrack? {
        let sema = DispatchSemaphore(value: 0)
        var result: AVAssetTrack?
        Task.detached {
            result = try? await asset.loadTracks(withMediaType: .video).first
            sema.signal()
        }
        sema.wait()
        return result
    }

    /// SceneScript video wrapper state (ScriptVideo.swift); nil = the video follows the scene clock.
    public var scriptClock: ScriptVideoClock?

    /// Advances to the frame for `time` (seconds, scene clock) and copies it into `texture` if it changed.
    public func update(time sceneTime: Double, commandBuffer: MTLCommandBuffer) {
        guard duration > 0 else { return }
        let time = scriptClock?.time ?? sceneTime
        if lastUpdate == time, dirty == nil { return }
        lastUpdate = time
        let local = time.truncatingRemainder(dividingBy: duration)
        let t = local < 0 ? local + duration : local

        // Restart (loop or seek) when time went backwards or jumped far ahead of the decoder.
        if reader == nil || t + 1e-4 < shownTime || t > max(shownTime, 0) + 2 {
            startReader(at: t)
        }
        while true {
            if pending == nil { pending = readSample() }
            guard let (buf, pts) = pending else { break }
            // Always take the first frame after a restart so something is shown.
            if pts <= t + 1e-4 || dirty == nil && shownTime == -.infinity {
                dirty = buf; shownTime = pts; pending = nil
            } else {
                break
            }
        }
        if let buf = dirty { copy(buf, commandBuffer: commandBuffer); dirty = nil }
    }

    private func startReader(at t: Double) {
        reader?.cancelReading()
        reader = nil; output = nil; pending = nil
        shownTime = -.infinity
        guard let r = try? AVAssetReader(asset: asset) else { return }
        let start = CMTime(seconds: max(0, t - 0.001), preferredTimescale: 600_000)
        if t > 0.05 { r.timeRange = CMTimeRange(start: start, end: .positiveInfinity) }
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        o.alwaysCopiesSampleData = false
        guard r.canAdd(o) else { return }
        r.add(o)
        guard r.startReading() else {
            NSLog("photon: video reader failed for %@: %@", url.path, "\(String(describing: r.error))")
            return
        }
        reader = r; output = o
    }

    private func readSample() -> (CVPixelBuffer, Double)? {
        guard let output, let sample = output.copyNextSampleBuffer() else { return nil }
        guard let buf = CMSampleBufferGetImageBuffer(sample) else { return readSample() }
        return (buf, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
    }

    private func copy(_ buf: CVPixelBuffer, commandBuffer: MTLCommandBuffer) {
        guard let cache = textureCache else { return }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        var cvTex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buf, nil, .bgra8Unorm, w, h, 0, &cvTex) == kCVReturnSuccess,
              let cvTex, let src = CVMetalTextureGetTexture(cvTex) else { return }
        if w == width && h == height {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
            blit.copy(from: src, to: texture)
            blit.endEncoding()
        } else {
            Blitter.shared(device).draw(src, into: texture, commandBuffer: commandBuffer)
        }
        // Keep the pixel buffer and its Metal view alive until the GPU has read them.
        commandBuffer.addCompletedHandler { _ in _ = cvTex; _ = buf }
    }

    // MARK: - Embedded MP4 cache

    /// Writes an embedded MP4 (mip 0 of a flag-0x20 `.tex`) to `~/Library/Caches/photon2/video/<sha256>.mp4`.
    /// AVFoundation needs a file (or a resource loader); the engine likewise passes file + offset/size.
    static func cacheFile(for data: Data) -> URL? {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("photon2/video", isDirectory: true)
        let url = dir.appendingPathComponent(digest + ".mp4")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           (attrs[.size] as? NSNumber)?.intValue == data.count { return url }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            NSLog("photon: cannot cache video: %@", "\(error)")
            return nil
        }
    }
}
