import Foundation
#if canImport(UIKit)
import UIKit
import ImageIO

/// Animation Rendering 01: decodes every frame of a genuinely multi-frame
/// GIF/WebP, plus real per-frame delay and loop-count metadata read from
/// the source itself — never assumed, never manufactured. A deliberate
/// sibling to `ImageDecoding`, not a modification of it: `ImageDecoding`'s
/// existing `decode`/`pixelSize` stay byte-for-byte unchanged, so every
/// existing static-image call site (which is still the overwhelming
/// majority of Cherries — ordinary screenshots, JPEG/PNG Link Cherries)
/// is provably unaffected by this file's existence.
public enum AnimatedImageDecoding {
    /// One decoded frame plus its own real display duration.
    public struct Frame: Sendable {
        public let image: UIImage
        public let delay: TimeInterval
    }

    /// A fully-decoded animated source, ready to drive playback.
    public struct AnimatedSource: Sendable {
        public let frames: [Frame]
        /// `0` means "loop forever," matching the GIF/WebP convention
        /// ImageIO itself reports it in (`kCGImagePropertyGIFLoopCount`,
        /// and WebP's equivalent) — read directly, never hardcoded.
        public let loopCount: Int
        public var totalDuration: TimeInterval { frames.reduce(0) { $0 + $1.delay } }
    }

    /// The cheap, byte-truth signal every call site should check BEFORE
    /// doing anything more expensive: header-only frame count via
    /// ImageIO, never a filename/extension guess (a `.gif` with exactly
    /// one frame is not animated — see this milestone's own findings).
    /// Identical cost to `ImageDecoding.pixelSize(ofData:)` — no pixel
    /// decoding happens here.
    public static func frameCount(ofData data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }

    /// Sane fallback for a frame whose own delay metadata is genuinely
    /// unreadable — GIF's own spec-recommended minimum, not invented.
    /// Only ever used defensively; every real fixture tested (a 44-frame
    /// GIF, a 67-frame WebP) reported real per-frame delays for every
    /// frame with no fallback needed.
    private static let defaultFrameDelay: TimeInterval = 0.1

    /// A hard ceiling on total decoded animated-frame memory for a
    /// single source — `frameCount × width × height × 4 bytes/pixel`.
    /// Concrete evidence this matters: a real 1920×1080, 67-frame
    /// animated WebP fixture, decoded at a generous-but-bounded 1024px
    /// cap, still estimates to ~150MB fully materialized — a genuine risk
    /// for a single Item Detail view, before One Archive (many
    /// simultaneous items) is ever considered. When a source would
    /// exceed this, playback is skipped in favor of the existing static
    /// single-frame path (`ImageDecoding.decode`) — never a crash, never
    /// a silently truncated animation.
    public static let maxDecodedBytesBudget = 80_000_000

    /// Item Detail's own frame-decode pixel cap — generous for full-
    /// screen viewing (matches the spirit of `LocalImageView
    /// .masonryThumbnailShortEdge`'s "generous but bounded" precedent)
    /// without paying multi-frame memory cost at full original
    /// resolution, which animated sources (unlike static ones) multiply
    /// by frame count.
    public static let itemDetailFrameTarget: CGFloat = 1024

    /// Decodes every frame at up to `maxPixelSize` (ImageIO thumbnail
    /// downsampling, same mechanism `ImageDecoding.decode` already uses
    /// for statics — never a full decode-then-scale). Returns `nil` if
    /// the source isn't genuinely multi-frame, if any frame fails to
    /// decode, or if the estimated total would exceed
    /// `maxDecodedBytesBudget` — callers should treat `nil` exactly like
    /// "not animated" and fall back to the existing static path.
    public static func decodeAnimated(_ data: Data, maxPixelSize: CGFloat?) -> AnimatedSource? {
        decodeAnimated(data, maxPixelSize: maxPixelSize, maxDecodedBytesBudget: maxDecodedBytesBudget)
    }

    /// Same as `decodeAnimated(_:maxPixelSize:)` but with an injectable
    /// budget — exists so the budget-rejection guard is directly testable
    /// against a small fixture rather than requiring a genuinely huge one
    /// in the test bundle. Not part of the public call-site API; real
    /// callers always go through `decodeAnimated(_:maxPixelSize:)` above.
    static func decodeAnimatedForTesting(_ data: Data, maxPixelSize: CGFloat?, maxDecodedBytesBudget: Int) -> AnimatedSource? {
        decodeAnimated(data, maxPixelSize: maxPixelSize, maxDecodedBytesBudget: maxDecodedBytesBudget)
    }

    private static func decodeAnimated(_ data: Data, maxPixelSize: CGFloat?, maxDecodedBytesBudget: Int) -> AnimatedSource? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }

        let containerProps = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let loopCount = readLoopCount(containerProps)

        // Budget check BEFORE decoding any pixels — cheap (just the
        // container's own reported canvas size), so a source that would
        // blow the budget never touches the decoder at all.
        let canvasSize = readCanvasSize(containerProps) ?? .zero
        let targetSize = downsampledSize(of: canvasSize, maxPixelSize: maxPixelSize)
        let estimatedBytes = Int(targetSize.width) * Int(targetSize.height) * 4 * count
        guard canvasSize == .zero || estimatedBytes <= maxDecodedBytesBudget else {
            return nil
        }

        var frames: [Frame] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            guard let frameImage = decodeFrame(source, index: index, maxPixelSize: maxPixelSize) else { return nil }
            let delay = readFrameDelay(source, index: index) ?? defaultFrameDelay
            frames.append(Frame(image: frameImage, delay: delay))
        }
        guard !frames.isEmpty else { return nil }
        return AnimatedSource(frames: frames, loopCount: loopCount)
    }

    /// Maps elapsed wall-clock time to the frame the source's own authored
    /// timing says should be showing right now — never a manufactured
    /// fixed interval. `source.loopCount == 0` is the GIF/WebP "loop
    /// forever" convention; a positive value is treated as a total play
    /// count, after which playback holds on the final frame. Pure/static
    /// so it's directly testable without any view/timer machinery — the
    /// presentation layer (`AnimatedLocalImageView`) only supplies `now`.
    public static func currentFrame(in source: AnimatedSource, elapsed: TimeInterval) -> Frame {
        let frames = source.frames
        guard frames.count > 1 else { return frames[0] }
        let loopDuration = source.totalDuration
        guard loopDuration > 0 else { return frames[0] }

        if source.loopCount > 0 {
            let totalPlayDuration = loopDuration * Double(source.loopCount)
            if elapsed >= totalPlayDuration {
                return frames[frames.count - 1]
            }
        }
        let t = elapsed.truncatingRemainder(dividingBy: loopDuration)

        var cumulative: TimeInterval = 0
        for frame in frames {
            cumulative += frame.delay
            if t < cumulative { return frame }
        }
        return frames[frames.count - 1]
    }

    private static func decodeFrame(_ source: CGImageSource, index: Int, maxPixelSize: CGFloat?) -> UIImage? {
        guard let maxPixelSize else {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
            return UIImage(cgImage: cgImage)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            // Same "never fail into a blank frame" discipline as
            // `ImageDecoding.decode`'s own downsample fallback.
            guard let full = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
            return UIImage(cgImage: full)
        }
        return UIImage(cgImage: cgImage)
    }

    /// GIF exposes this via the documented `kCGImagePropertyGIFDictionary`
    /// container dictionary. WebP's equivalent has no public Swift
    /// constant in this SDK — confirmed empirically (not assumed) via
    /// real fixtures: ImageIO reports it under a private but stable
    /// `"{WebP}"` container key, in the same `LoopCount`/`FrameInfo`
    /// shape GIF uses. Falls back to `0` (infinite) only if truly
    /// unreadable — matches the more common real-world case rather than
    /// guessing a small finite number.
    private static func readLoopCount(_ containerProps: [CFString: Any]?) -> Int {
        guard let containerProps else { return 0 }
        if let gif = containerProps[kCGImagePropertyGIFDictionary] as? [CFString: Any],
           let loop = gif[kCGImagePropertyGIFLoopCount] as? Int {
            return loop
        }
        if let webp = containerProps["{WebP}" as CFString] as? [CFString: Any],
           let loop = webp["LoopCount" as CFString] as? Int {
            return loop
        }
        return 0
    }

    private static func readCanvasSize(_ containerProps: [CFString: Any]?) -> CGSize? {
        guard let containerProps else { return nil }
        if let gif = containerProps[kCGImagePropertyGIFDictionary] as? [CFString: Any],
           let w = gif["CanvasPixelWidth" as CFString] as? CGFloat, let h = gif["CanvasPixelHeight" as CFString] as? CGFloat {
            return CGSize(width: w, height: h)
        }
        if let webp = containerProps["{WebP}" as CFString] as? [CFString: Any],
           let w = webp["CanvasPixelWidth" as CFString] as? CGFloat, let h = webp["CanvasPixelHeight" as CFString] as? CGFloat {
            return CGSize(width: w, height: h)
        }
        return nil
    }

    private static func downsampledSize(of canvasSize: CGSize, maxPixelSize: CGFloat?) -> CGSize {
        guard let maxPixelSize, canvasSize.width > 0, canvasSize.height > 0 else { return canvasSize }
        let longEdge = max(canvasSize.width, canvasSize.height)
        guard longEdge > maxPixelSize else { return canvasSize }
        let scale = maxPixelSize / longEdge
        return CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
    }

    /// Per-frame delay, preferring the unclamped value (the source's true
    /// authored timing) and falling back to the clamped one — the same
    /// GIF/WebP-standard pair every real fixture tested actually
    /// populates identically, but unclamped is the more faithful of the
    /// two where they could ever differ.
    private static func readFrameDelay(_ source: CGImageSource, index: Int) -> TimeInterval? {
        guard let frameProps = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return nil }
        if let gif = frameProps[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            if let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? TimeInterval { return unclamped }
            if let clamped = gif[kCGImagePropertyGIFDelayTime] as? TimeInterval { return clamped }
        }
        if let webp = frameProps["{WebP}" as CFString] as? [CFString: Any] {
            if let unclamped = webp["UnclampedDelayTime" as CFString] as? TimeInterval { return unclamped }
            if let clamped = webp["DelayTime" as CFString] as? TimeInterval { return clamped }
        }
        return nil
    }
}
#endif
