import Foundation
import CoreGraphics

/// A user's normalized "point of view" into an original image — a
/// rectangle in [0,1] × [0,1] space, relative to the image's own pixel
/// bounds, independent of any display size.
///
/// This is the non-destructive crop model: the original image is always
/// the canonical source, and `CropRegion` is metadata describing what to
/// present from it. `.fullImage` (the default) represents "no crop" —
/// every item that predates this feature, and every new item where the
/// user never adjusts the crop, is simply a full-image `CropRegion`.
///
/// Pure data only — no pixel-cropping logic, no display/coordinate math.
/// Those are separate concerns for later milestones (persistence
/// threading, rendering, and the interactive crop UI are all explicitly
/// out of scope for this type).
public struct CropRegion: Equatable, Sendable {
    /// Normalized origin/size. Always valid — see `init`, the only way to
    /// construct one — so a `CropRegion` can never represent an
    /// out-of-bounds or degenerate (zero-area) selection.
    public var rect: CGRect

    /// The default, and what every existing item implicitly has: the
    /// whole image, uncropped.
    public static let fullImage = CropRegion(rect: CGRect(x: 0, y: 0, width: 1, height: 1))

    /// Clamps `rect` into valid normalized bounds before storing it:
    /// - size never exceeds the full [0,1] extent on either axis
    /// - size never falls below `minimumDimension` (a degenerate,
    ///   effectively-invisible selection is never valid)
    /// - origin is clamped so the rect never extends past the far edge
    public init(rect: CGRect, minimumDimension: CGFloat = 0.02) {
        self.rect = Self.clamped(rect, minimumDimension: minimumDimension)
    }

    /// Constructs directly from normalized x/y/width/height — the shape
    /// `StoredItem`'s stored `cropX`/`cropY`/`cropWidth`/`cropHeight`
    /// fields naturally come in as.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(rect: CGRect(x: x, y: y, width: width, height: height))
    }

    private static func clamped(_ rect: CGRect, minimumDimension: CGFloat) -> CGRect {
        let standardized = rect.standardized
        let width = min(max(standardized.width, minimumDimension), 1)
        let height = min(max(standardized.height, minimumDimension), 1)
        let minX = min(max(standardized.minX, 0), 1 - width)
        let minY = min(max(standardized.minY, 0), 1 - height)
        return CGRect(x: minX, y: minY, width: width, height: height)
    }

    /// `true` iff this is (equivalent to) the full, uncropped image.
    public var isFullImage: Bool { self == .fullImage }

    // MARK: - Non-destructive rendering

    /// How to render the *original, untouched* image so this crop region
    /// exactly and fully fills a given container — scale the whole image
    /// up, then translate it so the crop's origin aligns with the
    /// container's origin, then (the caller's responsibility) clip to the
    /// container bounds. No pixels are ever modified; this only describes
    /// a transform to apply to the full image.
    ///
    /// Behaves like aspect-*fill* for the crop itself: if the crop's own
    /// aspect ratio doesn't exactly match the container's, the crop is
    /// centered within the container and any excess is left for the
    /// caller's clip to remove, rather than letterboxing.
    ///
    /// `scale`/`offset` are plain, animatable values by construction —
    /// interpolating between the transform for `item.cropRegion` and the
    /// transform for `.fullImage` is exactly the "zoom out to reveal the
    /// original" interaction this is meant to support later, without
    /// this type needing to know anything about that UI.
    public struct RenderTransform: Equatable {
        public var scale: CGFloat
        public var offset: CGSize
    }

    /// - Parameters:
    ///   - imageSize: the *original* image's pixel dimensions (not a
    ///     downscaled preview's).
    ///   - containerSize: the size, in points, the image should fill.
    public func renderTransform(imageSize: CGSize, containerSize: CGSize) -> RenderTransform {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return RenderTransform(scale: 1, offset: .zero)
        }

        let cropPixelSize = CGSize(width: rect.width * imageSize.width, height: rect.height * imageSize.height)
        guard cropPixelSize.width > 0, cropPixelSize.height > 0 else {
            return RenderTransform(scale: 1, offset: .zero)
        }

        let scale = max(containerSize.width / cropPixelSize.width, containerSize.height / cropPixelSize.height)
        let scaledImageSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let cropOriginInScaledImage = CGPoint(x: rect.minX * scaledImageSize.width, y: rect.minY * scaledImageSize.height)
        let scaledCropSize = CGSize(width: cropPixelSize.width * scale, height: cropPixelSize.height * scale)

        // Center the (possibly container-exceeding) scaled crop rect
        // within the container, on each axis independently.
        let offset = CGSize(
            width: containerSize.width / 2 - cropOriginInScaledImage.x - scaledCropSize.width / 2,
            height: containerSize.height / 2 - cropOriginInScaledImage.y - scaledCropSize.height / 2
        )
        return RenderTransform(scale: scale, offset: offset)
    }
}
