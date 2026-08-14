import Foundation
import CoreGraphics

/// Pure geometry for the interactive crop editor: converting between the
/// editor's screen/view space and `CropRegion`'s normalized [0,1] space,
/// and applying move/resize gestures to a `CropRegion`. No SwiftUI
/// dependency — the future `CropEditorView` is a thin gesture-recognizing
/// wrapper around these functions, not the other way around, so this
/// entire layer is unit-testable without a host app or simulator.
///
/// The editor always begins from an *existing* `CropRegion` — `.fullImage`
/// for a first-time crop, or an item's persisted region for a re-crop —
/// and these functions only ever move or resize that region. There is no
/// "draw a new rectangle from scratch" operation.
public enum CropEditorMath {

    /// Which corner of a `CropRegion` a resize gesture is dragging. The
    /// opposite corner stays anchored in place for the duration of the
    /// drag.
    public enum Corner: Sendable, CaseIterable, Hashable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// Which single edge of a `CropRegion` a resize gesture is dragging.
    /// Unlike `Corner`, only that edge's own axis moves — the opposite
    /// edge, and the entire cross-axis extent, stay fixed.
    public enum Edge: Sendable, CaseIterable, Hashable {
        case top, bottom, left, right
    }

    // MARK: - Layout

    /// The on-screen rect the image itself occupies within `containerSize`
    /// under aspect-fit layout — the same centered, smaller-axis-scaled
    /// rule as SwiftUI's `.aspectRatio(contentMode: .fit)`. This is
    /// smaller than `containerSize` on one axis whenever the image and
    /// container aspect ratios don't match (letterboxing/pillarboxing).
    /// Every gesture-math function below must be scaled against THIS
    /// rect, not the raw container, or drags would be measured against
    /// empty letterbox space instead of the actual image pixels.
    public static func displayedImageRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (containerSize.width - size.width) / 2, y: (containerSize.height - size.height) / 2)
        return CGRect(origin: origin, size: size)
    }

    // MARK: - Normalized <-> screen space

    /// Maps a normalized `CropRegion` to the screen-space rect within
    /// `displayedImageRect` where the editor should draw the crop
    /// rectangle and its handles.
    public static func rect(for region: CropRegion, in displayedImageRect: CGRect) -> CGRect {
        CGRect(
            x: displayedImageRect.minX + region.rect.minX * displayedImageRect.width,
            y: displayedImageRect.minY + region.rect.minY * displayedImageRect.height,
            width: region.rect.width * displayedImageRect.width,
            height: region.rect.height * displayedImageRect.height
        )
    }

    /// The inverse of `rect(for:in:)` — maps a screen-space rect back to a
    /// normalized `CropRegion`.
    public static func region(for rect: CGRect, in displayedImageRect: CGRect) -> CropRegion {
        guard displayedImageRect.width > 0, displayedImageRect.height > 0 else { return .fullImage }
        return CropRegion(
            x: (rect.minX - displayedImageRect.minX) / displayedImageRect.width,
            y: (rect.minY - displayedImageRect.minY) / displayedImageRect.height,
            width: rect.width / displayedImageRect.width,
            height: rect.height / displayedImageRect.height
        )
    }

    // MARK: - Gestures

    /// Moves `region` by a drag translation expressed in the container's
    /// raw point space (e.g. a `DragGesture.translation`), without
    /// resizing it. The translation is scaled into normalized space using
    /// `displayedImageRect` — the actual on-screen image bounds, not the
    /// (possibly larger, letterboxed) container — and the result is
    /// clamped so the region never leaves [0,1] on either axis. Width and
    /// height are always preserved exactly.
    public static func translate(_ region: CropRegion, by translation: CGSize, displayedImageRect: CGRect) -> CropRegion {
        guard displayedImageRect.width > 0, displayedImageRect.height > 0 else { return region }
        let dx = translation.width / displayedImageRect.width
        let dy = translation.height / displayedImageRect.height
        let rect = region.rect
        let x = min(max(rect.minX + dx, 0), 1 - rect.width)
        let y = min(max(rect.minY + dy, 0), 1 - rect.height)
        return CropRegion(x: x, y: y, width: rect.width, height: rect.height)
    }

    /// Resizes `region` by dragging `corner` by a translation expressed in
    /// the container's raw point space. The opposite corner stays
    /// anchored. The dragged corner is clamped to [0,1] and to never come
    /// within `minimumDimension` of the anchor on either axis — so a drag
    /// that overshoots the anchor settles at the smallest valid rect on
    /// the dragged side rather than crossing over and inverting the
    /// region (which would silently mirror the crop instead of shrinking
    /// it).
    public static func resize(
        _ region: CropRegion,
        corner: Corner,
        by translation: CGSize,
        displayedImageRect: CGRect,
        minimumDimension: CGFloat = 0.02
    ) -> CropRegion {
        guard displayedImageRect.width > 0, displayedImageRect.height > 0 else { return region }
        let dx = translation.width / displayedImageRect.width
        let dy = translation.height / displayedImageRect.height
        let rect = region.rect

        let anchor: CGPoint
        let proposed: CGPoint
        let xDirection: AxisDirection
        let yDirection: AxisDirection
        switch corner {
        case .topLeft:
            anchor = CGPoint(x: rect.maxX, y: rect.maxY)
            proposed = CGPoint(x: rect.minX + dx, y: rect.minY + dy)
            xDirection = .towardZero
            yDirection = .towardZero
        case .topRight:
            anchor = CGPoint(x: rect.minX, y: rect.maxY)
            proposed = CGPoint(x: rect.maxX + dx, y: rect.minY + dy)
            xDirection = .towardOne
            yDirection = .towardZero
        case .bottomLeft:
            anchor = CGPoint(x: rect.maxX, y: rect.minY)
            proposed = CGPoint(x: rect.minX + dx, y: rect.maxY + dy)
            xDirection = .towardZero
            yDirection = .towardOne
        case .bottomRight:
            anchor = CGPoint(x: rect.minX, y: rect.minY)
            proposed = CGPoint(x: rect.maxX + dx, y: rect.maxY + dy)
            xDirection = .towardOne
            yDirection = .towardOne
        }

        let clampedX = clamp(proposed.x, anchor: anchor.x, direction: xDirection, minimumDimension: minimumDimension)
        let clampedY = clamp(proposed.y, anchor: anchor.y, direction: yDirection, minimumDimension: minimumDimension)

        let newRect = CGRect(
            x: min(clampedX, anchor.x),
            y: min(clampedY, anchor.y),
            width: abs(clampedX - anchor.x),
            height: abs(clampedY - anchor.y)
        )
        return CropRegion(rect: newRect, minimumDimension: minimumDimension)
    }

    /// Resizes `region` along a single axis by dragging `edge` by a
    /// translation expressed in the container's raw point space. Only
    /// that edge's own coordinate moves — the opposite edge and the
    /// entire cross-axis extent are untouched — unlike `resize(_:corner:
    /// ...)`, which can change both axes from one drag. Clamped the same
    /// way as corner resizing: [0,1], and never closer than
    /// `minimumDimension` to the opposite edge, so a drag that overshoots
    /// settles at the smallest valid rect rather than crossing over and
    /// inverting the region.
    public static func resizeEdge(
        _ region: CropRegion,
        edge: Edge,
        by translation: CGSize,
        displayedImageRect: CGRect,
        minimumDimension: CGFloat = 0.02
    ) -> CropRegion {
        guard displayedImageRect.width > 0, displayedImageRect.height > 0 else { return region }
        let dx = translation.width / displayedImageRect.width
        let dy = translation.height / displayedImageRect.height
        let rect = region.rect

        switch edge {
        case .top:
            let anchor = rect.maxY
            let clampedY = clamp(rect.minY + dy, anchor: anchor, direction: .towardZero, minimumDimension: minimumDimension)
            return CropRegion(x: rect.minX, y: clampedY, width: rect.width, height: anchor - clampedY)
        case .bottom:
            let anchor = rect.minY
            let clampedY = clamp(rect.maxY + dy, anchor: anchor, direction: .towardOne, minimumDimension: minimumDimension)
            return CropRegion(x: rect.minX, y: rect.minY, width: rect.width, height: clampedY - anchor)
        case .left:
            let anchor = rect.maxX
            let clampedX = clamp(rect.minX + dx, anchor: anchor, direction: .towardZero, minimumDimension: minimumDimension)
            return CropRegion(x: clampedX, y: rect.minY, width: anchor - clampedX, height: rect.height)
        case .right:
            let anchor = rect.minX
            let clampedX = clamp(rect.maxX + dx, anchor: anchor, direction: .towardOne, minimumDimension: minimumDimension)
            return CropRegion(x: rect.minX, y: rect.minY, width: clampedX - anchor, height: rect.height)
        }
    }

    // MARK: - Image positioning (pan/zoom of the source image underneath a fixed frame)
    //
    // The functions above treat the crop rectangle as the thing that
    // moves/resizes over a fixed image. These treat the *image* as the
    // thing that moves/scales underneath a fixed crop frame — the
    // "viewport" interaction model. Both still resolve back to the same
    // normalized CropRegion via `region(for:in:)`: at any moment, the
    // frame's rect and the image's current on-screen rect are just two
    // plain CGRects, and `region(for: frameRect, in: imageRect)` gives the
    // crop exactly as before. No new persistence concept is introduced.

    /// The smallest image size (preserving `imageAspectSize`'s aspect
    /// ratio) that still fully covers `frameRect` on both axes — the
    /// aspect-*fill* counterpart to `displayedImageRect`'s aspect-fit.
    /// This is the minimum valid zoom level: any smaller and some part of
    /// the frame would show empty canvas instead of image pixels.
    public static func minimumCoveringSize(imageAspectSize: CGSize, toCover frameRect: CGRect) -> CGSize {
        guard imageAspectSize.width > 0, imageAspectSize.height > 0 else { return frameRect.size }
        let scale = max(frameRect.width / imageAspectSize.width, frameRect.height / imageAspectSize.height)
        return CGSize(width: imageAspectSize.width * scale, height: imageAspectSize.height * scale)
    }

    /// Clamps `imageRect`'s origin — never its size — so it fully
    /// contains `frameRect`. Assumes `imageRect` is already at least as
    /// large as `frameRect` on both axes (both `panImage` and `zoomImage`
    /// guarantee this before calling here; `zoomImage` clamps size to
    /// `minimumCoveringSize` first).
    public static func clampImageOrigin(_ imageRect: CGRect, toCover frameRect: CGRect) -> CGRect {
        guard imageRect.width > 0, imageRect.height > 0 else { return imageRect }
        let minX = min(max(imageRect.minX, frameRect.maxX - imageRect.width), frameRect.minX)
        let minY = min(max(imageRect.minY, frameRect.maxY - imageRect.height), frameRect.minY)
        return CGRect(origin: CGPoint(x: minX, y: minY), size: imageRect.size)
    }

    /// Pans `imageRect` by `translation` (screen-space, cumulative since
    /// gesture start — e.g. a `UIPanGestureRecognizer.translation`),
    /// without changing its size. Clamped so it always fully covers
    /// `frameRect` — never reveals empty canvas around or inside the crop.
    public static func panImage(_ imageRect: CGRect, by translation: CGSize, coveringFrame frameRect: CGRect) -> CGRect {
        clampImageOrigin(imageRect.offsetBy(dx: translation.width, dy: translation.height), toCover: frameRect)
    }

    /// Combines a two-finger gesture's scale and centroid movement into
    /// one resulting image rect. A real pinch reports both a scale factor
    /// and a moving centroid at once, and they must be applied together
    /// as a single transform, not as two separately-clamped steps (which
    /// would fight each other right at the coverage boundary and produce
    /// a "sticky" feel near the edges).
    ///
    /// `scaleFactor` (cumulative since gesture start — e.g. a
    /// `UIPinchGestureRecognizer.scale`) is applied around
    /// `startingCentroid`, so a pinch with a stationary centroid zooms in
    /// place. Moving the centroid from `startingCentroid` to
    /// `currentCentroid` then translates that scaled result by exactly
    /// that delta — so moving two fingers together with no separation
    /// change pans the image by the same amount the fingers moved, and
    /// spreading fingers apart while also moving them zooms and pans in
    /// the same gesture. The combined, unclamped result is clamped once
    /// at the end (scale first, against `minimumCoveringSize`/
    /// `maximumScaleMultiplier`, then origin) so it always fully covers
    /// `frameRect`.
    public static func pinchTransformImage(
        _ imageRect: CGRect,
        scaleFactor: CGFloat,
        startingCentroid: CGPoint,
        currentCentroid: CGPoint,
        imageAspectSize: CGSize,
        coveringFrame frameRect: CGRect,
        maximumScaleMultiplier: CGFloat = 9
    ) -> CGRect {
        guard imageRect.width > 0, imageRect.height > 0,
              imageAspectSize.width > 0, imageAspectSize.height > 0 else { return imageRect }

        let minimumSize = minimumCoveringSize(imageAspectSize: imageAspectSize, toCover: frameRect)
        let minimumScale = minimumSize.width / imageAspectSize.width
        let maximumScale = minimumScale * maximumScaleMultiplier
        let currentScale = imageRect.width / imageAspectSize.width
        let clampedScale = min(max(currentScale * scaleFactor, minimumScale), maximumScale)
        let newSize = CGSize(width: imageAspectSize.width * clampedScale, height: imageAspectSize.height * clampedScale)

        // Scale around the STARTING centroid: the image point under the
        // fingers' starting position stays under that same starting
        // screen point once scale alone is applied.
        let fractionX = (startingCentroid.x - imageRect.minX) / imageRect.width
        let fractionY = (startingCentroid.y - imageRect.minY) / imageRect.height
        let scaledOrigin = CGPoint(
            x: startingCentroid.x - fractionX * newSize.width,
            y: startingCentroid.y - fractionY * newSize.height
        )

        // Then translate by however far the centroid itself has moved.
        let centroidDelta = CGSize(width: currentCentroid.x - startingCentroid.x, height: currentCentroid.y - startingCentroid.y)
        let translatedOrigin = CGPoint(x: scaledOrigin.x + centroidDelta.width, y: scaledOrigin.y + centroidDelta.height)

        return clampImageOrigin(CGRect(origin: translatedOrigin, size: newSize), toCover: frameRect)
    }

    private enum AxisDirection {
        case towardZero
        case towardOne
    }

    /// Clamps a dragged corner's coordinate to [0,1] and to stay at least
    /// `minimumDimension` away from `anchor` on the side `direction`
    /// specifies — the side the corner started on — so it can shrink down
    /// to the minimum but never cross past the anchor. Relies on `anchor`
    /// already being a valid `CropRegion` corner, which guarantees
    /// `anchor - minimumDimension >= 0` and `anchor + minimumDimension <=
    /// 1` (every `CropRegion` satisfies `minimumDimension <=
    /// width`/`height` by construction), so both branches below always
    /// land back inside [0,1].
    private static func clamp(_ value: CGFloat, anchor: CGFloat, direction: AxisDirection, minimumDimension: CGFloat) -> CGFloat {
        let bounded = min(max(value, 0), 1)
        switch direction {
        case .towardZero: return min(bounded, anchor - minimumDimension)
        case .towardOne: return max(bounded, anchor + minimumDimension)
        }
    }

    // MARK: - Traction (gesture sensitivity)
    //
    // Deliberately NOT smoothing, inertia, or rubber-banding — both
    // functions below are pure, stateless multiplies of the CURRENT
    // gesture value, applied before it reaches `panImage`/
    // `pinchTransformImage`. Motion stays exactly and immediately tied to
    // the gesture; only how much of it registers changes. `sensitivity ==
    // 1` is always the identity/raw-input case.

    /// Damps a raw gesture translation by `sensitivity` — a value below 1
    /// makes panning slightly less responsive per point of finger travel.
    public static func dampedTranslation(_ translation: CGSize, sensitivity: CGFloat) -> CGSize {
        CGSize(width: translation.width * sensitivity, height: translation.height * sensitivity)
    }

    /// Damps a raw multiplicative pinch scale factor by `sensitivity` —
    /// softens how far the scale deviates from 1 (no change), not the
    /// scale value itself, so `scaleFactor == 1` (no pinch movement)
    /// always maps to exactly `1` regardless of sensitivity.
    public static func dampedScaleFactor(_ scaleFactor: CGFloat, sensitivity: CGFloat) -> CGFloat {
        1 + (scaleFactor - 1) * sensitivity
    }

    // MARK: - Presentation transform (focus preview)
    //
    // A presentation-only transform between "real" crop/image geometry —
    // frameRect, imageDisplayRect, the values CropRegion resolves from —
    // and what's actually drawn/touched on screen. `.identity` means no
    // visual difference: real geometry renders and is touched exactly
    // where it says. A non-identity value is purely a "camera"
    // repositioning; real geometry underneath never changes because of
    // it, so CropRegion resolution is completely unaffected by whatever
    // this currently is.

    public struct PresentationTransform: Equatable, Sendable {
        public var scale: CGFloat
        public var offset: CGSize

        public static let identity = PresentationTransform(scale: 1, offset: .zero)

        public init(scale: CGFloat, offset: CGSize) {
            self.scale = scale
            self.offset = offset
        }

        /// Real → presented (screen) space.
        public func apply(to rect: CGRect) -> CGRect {
            CGRect(
                x: rect.minX * scale + offset.width,
                y: rect.minY * scale + offset.height,
                width: rect.width * scale,
                height: rect.height * scale
            )
        }

        /// Real → presented (screen) space.
        public func apply(to point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * scale + offset.width, y: point.y * scale + offset.height)
        }

        /// Presented (screen) → real space — the inverse of `apply(to:)`
        /// for an absolute point (e.g. a pinch centroid).
        public func inverse(_ point: CGPoint) -> CGPoint {
            guard scale != 0 else { return point }
            return CGPoint(x: (point.x - offset.width) / scale, y: (point.y - offset.height) / scale)
        }

        /// Presented (screen) → real space for a *delta*/translation, not
        /// an absolute point — deltas only scale, they never need the
        /// offset subtracted (a translation has no fixed origin). This is
        /// also the mechanism that makes the enlarged presentation a real
        /// precision aid, not just a visual effect: the same raw finger
        /// travel now maps to a smaller real-geometry change, because
        /// `scale > 1` divides it down.
        public func inverseDelta(_ delta: CGSize) -> CGSize {
            guard scale != 0 else { return delta }
            return CGSize(width: delta.width / scale, height: delta.height / scale)
        }

        /// Linearly interpolates between two transforms. Used to drive
        /// the focus-presentation animation explicitly, frame by frame,
        /// rather than relying on SwiftUI's own implicit interpolation —
        /// which sets `@State` to its final target the instant
        /// `withAnimation` runs, with no reliable way to query the
        /// value actually on screen mid-transition. A gesture starting
        /// mid-animation needs exactly that on-screen value to stay
        /// continuous, so the animation loop writes its own interpolated
        /// result into the same state gestures read.
        public static func interpolate(from start: PresentationTransform, to end: PresentationTransform, progress: CGFloat) -> PresentationTransform {
            PresentationTransform(
                scale: start.scale + (end.scale - start.scale) * progress,
                offset: CGSize(
                    width: start.offset.width + (end.offset.width - start.offset.width) * progress,
                    height: start.offset.height + (end.offset.height - start.offset.height) * progress
                )
            )
        }
    }

    /// The presentation transform that fits `frameRect` into `viewport`,
    /// centered, scaled up to at most `maximumScale` — never scaled down
    /// below `.identity` (a crop already filling most of the workspace
    /// should move/scale very little, never shrink). This is the "focus"
    /// state the crop editor settles into after an edit gesture ends.
    public static func idealPresentationTransform(for frameRect: CGRect, fitting viewport: CGRect, maximumScale: CGFloat) -> PresentationTransform {
        guard frameRect.width > 0, frameRect.height > 0, viewport.width > 0, viewport.height > 0 else { return .identity }
        let fitScale = min(viewport.width / frameRect.width, viewport.height / frameRect.height)
        let scale = min(max(fitScale, 1), maximumScale)
        let offset = CGSize(
            width: viewport.midX - frameRect.midX * scale,
            height: viewport.midY - frameRect.midY * scale
        )
        return PresentationTransform(scale: scale, offset: offset)
    }

    /// Standard cubic ease-in-out — accelerates, then decelerates, no
    /// overshoot. Shapes the focus animation's progress before
    /// interpolating, for calm, deliberate motion.
    public static func easedProgress(_ t: CGFloat) -> CGFloat {
        let clamped = min(max(t, 0), 1)
        return clamped < 0.5 ? 4 * clamped * clamped * clamped : 1 - pow(-2 * clamped + 2, 3) / 2
    }
}
