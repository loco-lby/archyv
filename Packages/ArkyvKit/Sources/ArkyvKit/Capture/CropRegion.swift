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
}
