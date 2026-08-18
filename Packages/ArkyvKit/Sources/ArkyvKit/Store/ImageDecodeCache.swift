import Foundation
#if canImport(UIKit)
import UIKit
import ImageIO

/// Native (ImageIO-based) decoding for `MediaStore`'s raw bytes, with an
/// optional downsampled path that decodes directly to a target pixel
/// budget instead of materializing a full-resolution bitmap and scaling it
/// down afterward — the standard technique (WWDC18 "Image and Graphics
/// Best Practices") for rendering a small on-screen copy of a large source
/// image without paying the memory/CPU cost of decoding it at full
/// resolution first.
///
/// `maxPixelSize` constrains ImageIO's thumbnail to that size on its
/// *longer* edge only; the shorter edge scales down proportionally, so the
/// result's aspect ratio always exactly matches the source's. That's what
/// lets `CropRegion.renderTransform` — resolution-independent by
/// construction, since it only ever consumes a decoded image's `.size`
/// relative to its own normalized crop rect, never an absolute pixel count
/// — render the identical visible crop regardless of which resolution
/// variant it's handed. Downsampling here never touches crop semantics.
public enum ImageDecoding {
    /// `maxPixelSize == nil` decodes at full resolution via the same
    /// `UIImage(data:)` every existing call site already used — a
    /// byte-for-byte unchanged result for any caller that doesn't
    /// explicitly opt into downsampling.
    public static func decode(_ data: Data, maxPixelSize: CGFloat? = nil) -> UIImage? {
        guard let maxPixelSize else {
            return UIImage(data: data)
        }

        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            // Bakes EXIF orientation directly into the returned pixel
            // buffer, so wrapping it in a plain `UIImage(cgImage:)`
            // (which otherwise assumes `.up`) displays identically
            // oriented to `UIImage(data:)`'s own auto-orientation.
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Forces the decode to happen now, on the calling (background)
            // thread — never lazily deferred to the next main-thread draw.
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            // Never fail into a blank/missing tile — fall back to a full
            // decode. Downsample failures should be rare; correctness
            // beats the memory saving on this path.
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }

    /// Reads an image's pixel dimensions from its header/metadata only —
    /// no pixel decoding at all, cheap regardless of source resolution.
    /// Share/Capture Reliability Foundation 01: the whole reason this
    /// exists is that a caller (e.g. `ShareViewController`'s already-JPEG
    /// fast path) that only needs `CaptureDraft.pixelSize` — not a
    /// decoded bitmap — shouldn't have to pay for one just to learn a
    /// width and height.
    public static func pixelSize(ofData data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return pixelSize(of: source)
    }

    /// Same as `pixelSize(ofData:)`, reading straight from a file URL —
    /// avoids materializing the file's bytes into a `Data` buffer at all
    /// when the caller only needs dimensions, not content.
    public static func pixelSize(ofFileAt url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return pixelSize(of: source)
    }

    private static func pixelSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}

/// Bounded in-memory cache of already-decoded `UIImage`s, keyed by source
/// filename plus the pixel budget they were decoded at. Exists purely to
/// avoid re-reading-from-disk-and-re-decoding the *same* image every time a
/// `LocalImageView` is recreated during ordinary use — most importantly,
/// masonry grid cells routinely deinit/reinit as they leave and re-enter
/// the visible scroll range.
///
/// Backed directly by `NSCache`, which is already thread-safe for
/// concurrent access from any thread and already auto-evicts under system
/// memory pressure — this type adds nothing on top of that beyond a stable
/// key format and a rough per-image byte cost so `totalCostLimit` has
/// something meaningful to work with. Deliberately not a custom
/// eviction/LRU implementation.
///
/// Filenames are write-once (`MediaStore.save` always mints a fresh UUID
/// filename; the only path that writes to an existing filename is the D4
/// CloudKit-restore fallback, and only when that file doesn't already
/// exist locally), and crop is a display-time transform that never touches
/// the decoded pixels — so a cache entry never needs invalidating for the
/// lifetime of the app process.
public final class ImageDecodeCache: @unchecked Sendable {
    public static let shared = ImageDecodeCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        // A proactive ceiling on top of NSCache's own memory-pressure
        // eviction, so the cache doesn't grow unboundedly large over a
        // single long scroll session even before the system signals
        // pressure. Approximate, not a precise budget.
        //
        // Sized against real masonry thumbnails, not a round number: a
        // `LocalImageView.masonryThumbnailShortEdge` (640) decode of a
        // typical ~1:2.17 portrait screenshot is ~640×1387px ≈ 3.5MB of
        // raw RGBA. An earlier, smaller limit (100MB ≈ 28 thumbnails) was
        // physically verified to evict well within a single ordinary
        // scroll session — items shown at the top were already gone by
        // the time a ~70-tile scroll returned to them, so revisiting
        // recently-seen content was still re-decoding instead of hitting
        // cache. ~320MB (≈90 thumbnails at that size) was the smallest
        // bump that held up in the same physical re-test.
        cache.totalCostLimit = 320 * 1024 * 1024
        cache.countLimit = 200
    }

    /// A masonry-thumbnail decode and a full-resolution decode of the same
    /// file are different cache entries — the pixel budget is part of the
    /// key, never conflated.
    public static func key(filename: String, maxPixelSize: CGFloat?) -> String {
        guard let maxPixelSize else { return filename }
        return "\(filename)#\(Int(maxPixelSize))"
    }

    public func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    public func store(_ image: UIImage, forKey key: String) {
        let pixelCount = image.size.width * image.size.height * image.scale * image.scale
        cache.setObject(image, forKey: key as NSString, cost: Int(pixelCount * 4)) // ~4 bytes/pixel (RGBA)
    }
}
#endif
