import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

/// Media-session thumbnail images (`$mediaThumbnail`, docs/re/script-api.md §M).
extension TexFile {
#if canImport(ImageIO)
    /// Straight RGBA8 pixels of an encoded image (PNG/JPEG …), or nil when it does not decode.
    public static func decodeStraightRGBA(_ blob: Data) -> (pixels: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(blob as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let px = decodeImage(blob, width: image.width, height: image.height) else { return nil }
        return (px, image.width, image.height)
    }
#endif

    /// A `system` user texture (UserTexture ctor 0x1400eb570, branch 0x1400ebbec–0x1400ebc5e): the media session's
    /// current or previous RGBA image, centre-cropped to `aspect` (`UserImage_CenterCrop` 0x1401702f0; 0 keeps it), one mip.
    public static func systemUserImage(_ pixels: Data, width: Int, height: Int, aspect: Float, flags: Flags) -> TexFile? {
        guard width > 0, height > 0, pixels.count >= width * height * 4 else { return nil }
        let (px, w, h) = centerCrop(pixels, width: width, height: height, aspect: aspect)
        guard w > 0, h > 0 else { return nil }
        var t = TexFile(videoWidth: w, height: h, flags: [])
        t.flags = flags.union(.singleMip)
        t.images = [[Mip(width: w, height: h, depth: 1, data: px)]]
        return t
    }
}
