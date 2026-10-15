import AppKit
import Foundation
import ImageIO

/// Preview thumbnails, decoded off the main thread and downsampled.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "photon.thumbnails", qos: .userInitiated, attributes: .concurrent)

    func image(_ url: URL, maxPixels: Int = 480, completion: @escaping (NSImage?) -> Void) {
        let key = "\(url.path)#\(maxPixels)" as NSString
        if let img = cache.object(forKey: key) { completion(img); return }
        queue.async {
            var image: NSImage?
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                   kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                   kCGImageSourceCreateThumbnailWithTransform: true,
               ] as CFDictionary) {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            DispatchQueue.main.async {
                if let image { self.cache.setObject(image, forKey: key) }
                completion(image)
            }
        }
    }
}
