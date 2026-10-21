import UIKit
import ImageIO
import AVFoundation

/// Off-main thumbnail decoding with an in-memory cache. Videos use their first frame as a poster.
final class MediaLoader {
    static let shared = MediaLoader()
    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "media.decode", qos: .userInitiated, attributes: .concurrent)

    init() { cache.totalCostLimit = 256 * 1024 * 1024 }

    func cached(_ item: FeedItem, maxPixel: CGFloat) -> UIImage? {
        cache.object(forKey: key(item, maxPixel))
    }

    /// Sizes decoded so far, per media (main thread), to find any decode of a media quickly.
    private var decodedSizes: [String: Set<Int>] = [:]

    /// Any decode of this media still in memory, preferring the size nearest to `maxPixel`
    /// (a zooming grid shows it scaled until the right size is ready).
    func anyCached(_ item: FeedItem, near maxPixel: CGFloat) -> UIImage? {
        guard let sizes = decodedSizes[item.mediaId] else { return nil }
        for px in sizes.sorted(by: { abs(CGFloat($0) - maxPixel) < abs(CGFloat($1) - maxPixel) }) {
            if let img = cache.object(forKey: key(item, CGFloat(px))) { return img }
        }
        return nil
    }

    func load(_ item: FeedItem, maxPixel: CGFloat, completion: @escaping (UIImage?) -> Void) {
        let k = key(item, maxPixel)
        if let img = cache.object(forKey: k) { completion(img); return }
        queue.async { [cache, self] in
            let img = item.kind == .video ? Self.poster(item.fileURL, maxPixel) : Self.thumbnail(item.fileURL, maxPixel)
            if let img { cache.setObject(img, forKey: k, cost: Int(img.size.width * img.size.height * img.scale * img.scale * 4)) }
            DispatchQueue.main.async {
                if img != nil { self.decodedSizes[item.mediaId, default: []].insert(Int(maxPixel)) }
                completion(img)
            }
        }
    }

    /// Thumbnail for an arbitrary media file (progress previews).
    func load(path: String, isVideo: Bool, maxPixel: CGFloat, completion: @escaping (UIImage?) -> Void) {
        let k = "\(path)@\(Int(maxPixel))" as NSString
        if let img = cache.object(forKey: k) { completion(img); return }
        queue.async { [cache] in
            let url = URL(fileURLWithPath: path)
            let img = isVideo ? Self.poster(url, maxPixel) : Self.thumbnail(url, maxPixel)
            if let img { cache.setObject(img, forKey: k, cost: Int(img.size.width * img.size.height * 4)) }
            DispatchQueue.main.async { completion(img) }
        }
    }

    private func key(_ item: FeedItem, _ px: CGFloat) -> NSString { "\(item.mediaId)@\(Int(px))" as NSString }

    /// Drops cached thumbnails of a media (after its file was replaced).
    func forget(_ item: FeedItem) { cache.removeAllObjects(); reported.remove(item.mediaId) }

    /// A media that failed to decode is reported to the core once per launch, which verifies the
    /// file and records the damage (the card then shows a badge and offers a re-download).
    private var reported = Set<String>()
    func reportIfBroken(_ item: FeedItem) {
        guard !reported.contains(item.mediaId) else { return }
        reported.insert(item.mediaId)
        // async all the way (a thread blocked on a semaphore while Swift concurrency loads the
        // asset could starve the shared thread pool)
        Task.detached(priority: .utility) {
            // A video whose poster frame failed may still play fine: only an unplayable one counts.
            if item.kind == .video, (try? await AVURLAsset(url: item.fileURL).load(.isPlayable)) == true { return }
            let reason = Core.reportBad(item.mediaId)
            if reason != item.bad { await MainActor.run { NotificationCenter.default.post(name: .libraryChanged, object: nil) } }
        }
    }

    private static func thumbnail(_ url: URL, _ maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary).map { UIImage(cgImage: $0) }
    }

    private static func poster(_ url: URL, _ maxPixel: CGFloat) -> UIImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
        return (try? gen.copyCGImage(at: .zero, actualTime: nil)).map { UIImage(cgImage: $0) }
    }
}
