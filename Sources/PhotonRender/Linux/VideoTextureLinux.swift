#if os(Linux)
import CPhotonMedia
import CryptoKit
import Foundation
import Metal

/// VideoTexture.swift on GStreamer (docs/linux-port.md §3.5): the same interface and the same frame choice, with
/// `photon_video` (decodebin → videoconvert → BGRA appsink) in place of AVAssetReader.
///
/// Frames are converted from Y'CbCr to BGRA with the standard BT.601/709 matrices in photon_media.c (VideoToolbox's
/// output on macOS matches those, GStreamer's videoconvert does not to within 4 levels).
///
/// The decoder is pulled on the render thread, driven by the scene clock, so offline renders are deterministic:
/// `update(time:)` shows the last frame whose presentation time is <= time mod duration, restarting (loop or seek) when
/// time goes backwards or jumps more than 2 s ahead, exactly as the macOS reader does. A restart at t > 0.05 seeks to
/// t − 0.001 (the macOS reader's `timeRange` start); the first frame after a restart is always shown.
public final class VideoTexture {
    public let url: URL
    public let width: Int
    public let height: Int
    public let duration: Double
    /// Stable texture the materials bind; each new video frame is uploaded into it.
    public let texture: MTLTexture
    /// SceneScript video wrapper state (ScriptVideo.swift); nil = the video follows the scene clock.
    public var scriptClock: ScriptVideoClock?

    private let video: OpaquePointer
    private var started = false
    /// Presentation time of the decoded frame not yet due (photon_video's pending slot).
    private var pendingTime: Double?
    /// BGRA rows (`width * 4` bytes) of the shown frame, converted only when it is uploaded.
    private var upload: [UInt8]
    private var dirty = false
    private var shownTime = -Double.infinity
    private var lastUpdate: Double?

    public init?(device: MTLDevice, url: URL, label: String) {
        self.url = url
        var error = [CChar](repeating: 0, count: 512)
        guard let v = photon_video_open(url.path, &error, error.count) else {
            NSLog("photon: video %@ cannot be decoded: %@", url.lastPathComponent, String(cString: error))
            return nil
        }
        video = v
        width = max(Int(photon_video_width(v)), 1)
        height = max(Int(photon_video_height(v)), 1)
        // AVFoundation's track.timeRange.duration: the video track's own duration, edit lists applied. The container
        // duration GStreamer reports can be the longer audio track's, so the MP4 track header comes first.
        let d = MP4Probe.videoTrackDuration(url) ?? photon_video_duration(v)
        duration = d.isFinite && d > 0 ? d : 0
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc) else {
            photon_video_close(v)
            return nil
        }
        tex.label = label
        texture = tex
        upload = [UInt8](repeating: 0, count: width * height * 4)
    }

    deinit { photon_video_close(video) }

    /// Advances to the frame for `time` (seconds, scene clock) and uploads it into `texture` if it changed.
    public func update(time sceneTime: Double, commandBuffer: MTLCommandBuffer) {
        guard duration > 0 else { return }
        let time = scriptClock?.time ?? sceneTime
        if lastUpdate == time, !dirty { return }
        lastUpdate = time
        let local = time.truncatingRemainder(dividingBy: duration)
        let t = local < 0 ? local + duration : local

        if !started || t + 1e-4 < shownTime || t > max(shownTime, 0) + 2 {
            restart(at: t)
        }
        while true {
            if pendingTime == nil { pendingTime = readFrame() }
            guard let pts = pendingTime else { break }
            if pts <= t + 1e-4 || !dirty && shownTime == -.infinity {
                photon_video_show_pending(video)
                dirty = true; shownTime = pts; pendingTime = nil
            } else {
                break
            }
        }
        if dirty {
            // Queue-ordered upload (Metal facade): runs after the frames already submitted and before this one.
            upload.withUnsafeMutableBytes { photon_video_convert_shown(video, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), width * 4) }
            upload.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4)
            }
            dirty = false
        }
    }

    private func restart(at t: Double) {
        started = true
        pendingTime = nil
        shownTime = -.infinity
        if photon_video_seek(video, t > 0.05 ? max(0, t - 0.001) : 0) != 0 {
            NSLog("photon: video seek failed for %@", url.path)
        }
    }

    private func readFrame() -> Double? {
        var pts = 0.0
        return photon_video_next(video, &pts) == 1 ? pts : nil
    }

    // MARK: - Embedded MP4 cache

    /// Writes an embedded MP4 (mip 0 of a flag-0x20 `.tex`) to `$XDG_CACHE_HOME/photon2/video/<sha256>.mp4` (default
    /// `~/.cache`), the counterpart of macOS's `~/Library/Caches/photon2/video`. GStreamer's filesrc needs a file; the
    /// engine likewise passes file + offset/size to its player.
    static func cacheFile(for data: Data) -> URL? {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_CACHE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        let dir = base.appendingPathComponent("photon2/video", isDirectory: true)
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

/// The few MP4/QuickTime boxes AVFoundation's `AVAssetTrack.timeRange` comes from: the first video track's `tkhd`
/// duration in `mvhd` timescale units (the sum of its edit list, or the media duration without one).
enum MP4Probe {
    static func videoTrackDuration(_ url: URL) -> Double? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()).map(Int.init) ?? 0
        // Top level: find `moov` without reading `mdat`.
        var offset = 0
        while offset + 8 <= size {
            guard let (type, boxSize, header) = boxHeader(fh, at: offset, limit: size) else { return nil }
            if type == "moov" {
                try? fh.seek(toOffset: UInt64(offset))
                guard let moov = try? fh.read(upToCount: boxSize) else { return nil }
                return parseMoov([UInt8](moov), from: header, to: moov.count)
            }
            offset += boxSize
        }
        return nil
    }

    private static func boxHeader(_ fh: FileHandle, at offset: Int, limit: Int) -> (String, Int, Int)? {
        try? fh.seek(toOffset: UInt64(offset))
        guard let h = try? fh.read(upToCount: 16), h.count >= 8 else { return nil }
        let b = [UInt8](h)
        var size = Int(be32(b, 0))
        var header = 8
        if size == 1, b.count >= 16 { size = Int(be64(b, 8)); header = 16 }
        if size == 0 { size = limit - offset }
        guard size >= header else { return nil }
        return (String(decoding: b[4..<8], as: UTF8.self), size, header)
    }

    private static func children(_ b: [UInt8], _ from: Int, _ to: Int) -> [(type: String, start: Int, end: Int)] {
        var out: [(String, Int, Int)] = []
        var o = from
        while o + 8 <= to {
            var size = Int(be32(b, o)), header = 8
            if size == 1, o + 16 <= to { size = Int(be64(b, o + 8)); header = 16 }
            if size == 0 { size = to - o }
            guard size >= header, o + size <= to else { break }
            out.append((String(decoding: b[o + 4..<o + 8], as: UTF8.self), o + header, o + size))
            o += size
        }
        return out
    }

    private static func parseMoov(_ b: [UInt8], from: Int, to: Int) -> Double? {
        var timescale: Double = 0
        for box in children(b, from, to) where box.type == "mvhd" {
            let v = b[box.start]
            timescale = Double(be32(b, box.start + (v == 1 ? 20 : 12)))
        }
        guard timescale > 0 else { return nil }
        for trak in children(b, from, to) where trak.type == "trak" {
            let boxes = children(b, trak.start, trak.end)
            guard let mdia = boxes.first(where: { $0.type == "mdia" }),
                  let hdlr = children(b, mdia.start, mdia.end).first(where: { $0.type == "hdlr" }),
                  hdlr.start + 12 <= hdlr.end, String(decoding: b[hdlr.start + 8..<hdlr.start + 12], as: UTF8.self) == "vide",
                  let tkhd = boxes.first(where: { $0.type == "tkhd" }) else { continue }
            let v = b[tkhd.start]
            let d = v == 1 ? Double(be64(b, tkhd.start + 28)) : Double(be32(b, tkhd.start + 20))
            return d > 0 && d < Double(UInt32.max) ? d / timescale : nil
        }
        return nil
    }

    private static func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o + 4 <= b.count else { return 0 }
        return UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }

    private static func be64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(be32(b, o)) << 32 | UInt64(be32(b, o + 4)) }
}
#endif
