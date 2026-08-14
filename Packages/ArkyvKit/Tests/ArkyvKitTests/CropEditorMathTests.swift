import XCTest
import CoreGraphics
@testable import ArkyvKit

final class CropEditorMathTests: XCTestCase {

    // MARK: - displayedImageRect: aspect-fit letterboxing

    func testDisplayedImageRectForSquareImageInSquareContainerFillsExactly() {
        let rect = CropEditorMath.displayedImageRect(imageSize: CGSize(width: 1000, height: 1000), containerSize: CGSize(width: 300, height: 300))
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 300, height: 300))
    }

    func testDisplayedImageRectForPortraitImagePillarboxesInSquareContainer() {
        let rect = CropEditorMath.displayedImageRect(imageSize: CGSize(width: 1000, height: 2000), containerSize: CGSize(width: 300, height: 300))
        XCTAssertEqual(rect, CGRect(x: 75, y: 0, width: 150, height: 300))
    }

    func testDisplayedImageRectForLandscapeImageLetterboxesInSquareContainer() {
        let rect = CropEditorMath.displayedImageRect(imageSize: CGSize(width: 2000, height: 1000), containerSize: CGSize(width: 300, height: 300))
        XCTAssertEqual(rect, CGRect(x: 0, y: 75, width: 300, height: 150))
    }

    func testDisplayedImageRectForExtremelyWideSourceLetterboxesHeavily() {
        let rect = CropEditorMath.displayedImageRect(imageSize: CGSize(width: 5000, height: 100), containerSize: CGSize(width: 300, height: 300))
        XCTAssertEqual(rect.height, 6, accuracy: 0.0001)
        XCTAssertEqual(rect.width, 300, accuracy: 0.0001)
        XCTAssertEqual(rect.minY, 147, accuracy: 0.0001)
    }

    func testDisplayedImageRectForExtremelyTallSourcePillarboxesHeavily() {
        let rect = CropEditorMath.displayedImageRect(imageSize: CGSize(width: 100, height: 5000), containerSize: CGSize(width: 300, height: 300))
        XCTAssertEqual(rect.width, 6, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 300, accuracy: 0.0001)
        XCTAssertEqual(rect.minX, 147, accuracy: 0.0001)
    }

    // MARK: - translate: whole-region movement, no resize

    func testTranslateMovesRegionWithoutChangingItsSize() {
        let region = CropRegion(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        let displayed = CGRect(x: 0, y: 0, width: 300, height: 300)
        let moved = CropEditorMath.translate(region, by: CGSize(width: 30, height: 30), displayedImageRect: displayed)
        XCTAssertEqual(moved.rect.minX, 0.3, accuracy: 0.0001)
        XCTAssertEqual(moved.rect.minY, 0.3, accuracy: 0.0001)
        XCTAssertEqual(moved.rect.width, 0.3, accuracy: 0.0001)
        XCTAssertEqual(moved.rect.height, 0.3, accuracy: 0.0001)
    }

    func testTranslateUsesDisplayedImageRectNotContainerSizeWhenLetterboxed() {
        // A portrait image pillarboxed into a square container: the
        // displayed image is only 150pt wide inside a 300pt-wide
        // container. A 15pt horizontal drag should read as half the
        // displayed width (0.1), not a 30th of the container (0.05).
        let region = CropRegion(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        let displayed = CGRect(x: 75, y: 0, width: 150, height: 300)
        let moved = CropEditorMath.translate(region, by: CGSize(width: 15, height: 30), displayedImageRect: displayed)
        XCTAssertEqual(moved.rect.minX, 0.3, accuracy: 0.0001)
        XCTAssertEqual(moved.rect.minY, 0.3, accuracy: 0.0001)
        XCTAssertEqual(moved.rect.width, 0.3, accuracy: 0.0001)
        XCTAssertEqual(moved.rect.height, 0.3, accuracy: 0.0001)
    }

    func testTranslateClampsAtFarEdgeRatherThanOvershooting() {
        let region = CropRegion(x: 0.8, y: 0.8, width: 0.1, height: 0.1)
        let displayed = CGRect(x: 0, y: 0, width: 300, height: 300)
        let moved = CropEditorMath.translate(region, by: CGSize(width: 1000, height: 1000), displayedImageRect: displayed)
        XCTAssertEqual(moved.rect.maxX, 1, accuracy: 0.0001)
        XCTAssertEqual(moved.rect.maxY, 1, accuracy: 0.0001)
        XCTAssertEqual(moved.rect.width, 0.1, accuracy: 0.0001)
        XCTAssertEqual(moved.rect.height, 0.1, accuracy: 0.0001)
    }

    // MARK: - resize: all four corners, opposite corner anchored

    func testResizeTopLeftCornerKeepsBottomRightAnchored() {
        let region = CropRegion(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let displayed = CGRect(x: 0, y: 0, width: 300, height: 300)
        let resized = CropEditorMath.resize(region, corner: .topLeft, by: CGSize(width: -30, height: -30), displayedImageRect: displayed)
        XCTAssertEqual(resized.rect.minX, 0.2, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.minY, 0.2, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.width, 0.5, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.height, 0.5, accuracy: 0.0001)
    }

    func testResizeTopRightCornerKeepsBottomLeftAnchored() {
        let region = CropRegion(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let displayed = CGRect(x: 0, y: 0, width: 300, height: 300)
        let resized = CropEditorMath.resize(region, corner: .topRight, by: CGSize(width: 30, height: -30), displayedImageRect: displayed)
        XCTAssertEqual(resized.rect.minX, 0.3, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.minY, 0.2, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.width, 0.5, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.height, 0.5, accuracy: 0.0001)
    }

    func testResizeBottomLeftCornerKeepsTopRightAnchored() {
        let region = CropRegion(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let displayed = CGRect(x: 0, y: 0, width: 300, height: 300)
        let resized = CropEditorMath.resize(region, corner: .bottomLeft, by: CGSize(width: -30, height: 30), displayedImageRect: displayed)
        XCTAssertEqual(resized.rect.minX, 0.2, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.minY, 0.3, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.width, 0.5, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.height, 0.5, accuracy: 0.0001)
    }

    func testResizeBottomRightCornerKeepsTopLeftAnchored() {
        let region = CropRegion(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let displayed = CGRect(x: 0, y: 0, width: 300, height: 300)
        let resized = CropEditorMath.resize(region, corner: .bottomRight, by: CGSize(width: 30, height: 30), displayedImageRect: displayed)
        XCTAssertEqual(resized.rect.minX, 0.3, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.minY, 0.3, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.width, 0.5, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.height, 0.5, accuracy: 0.0001)
    }

    // MARK: - resize: letterboxed displayed bounds, not container

    func testResizeUsesDisplayedImageRectNotContainerSizeWhenLetterboxed() {
        // Same pillarboxed 150pt-wide-in-300pt-container setup as the
        // translate letterbox test above, this time dragging a corner.
        let region = CropRegion(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let displayed = CGRect(x: 75, y: 0, width: 150, height: 300)
        let resized = CropEditorMath.resize(region, corner: .bottomRight, by: CGSize(width: 15, height: 30), displayedImageRect: displayed)
        XCTAssertEqual(resized.rect.minX, 0.3, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.minY, 0.3, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.width, 0.5, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.height, 0.5, accuracy: 0.0001)
    }

    // MARK: - resize: minimum dimension floor

    func testResizeNeverShrinksBelowMinimumDimension() {
        let region = CropRegion(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let displayed = CGRect(x: 0, y: 0, width: 300, height: 300)
        let resized = CropEditorMath.resize(region, corner: .bottomRight, by: CGSize(width: -1000, height: -1000), displayedImageRect: displayed, minimumDimension: 0.02)
        XCTAssertEqual(resized.rect.width, 0.02, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.height, 0.02, accuracy: 0.0001)
        XCTAssertGreaterThan(resized.rect.width, 0)
        XCTAssertGreaterThan(resized.rect.height, 0)
    }

    // MARK: - resize: overshoot clamps rather than inverting

    func testResizeCornerOvershootingTheOppositeCornerClampsRatherThanInverting() {
        let region = CropRegion(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let displayed = CGRect(x: 0, y: 0, width: 300, height: 300)
        // Drag topLeft far past the anchored bottomRight (0.7, 0.7).
        let resized = CropEditorMath.resize(region, corner: .topLeft, by: CGSize(width: 1000, height: 1000), displayedImageRect: displayed, minimumDimension: 0.02)
        // Must clamp to the minimum-size rect on the correct side of the
        // anchor, not flip into a mirrored/inverted region.
        XCTAssertLessThan(resized.rect.minX, resized.rect.maxX)
        XCTAssertLessThan(resized.rect.minY, resized.rect.maxY)
        XCTAssertEqual(resized.rect.maxX, 0.7, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.maxY, 0.7, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.width, 0.02, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.height, 0.02, accuracy: 0.0001)
    }

    // MARK: - screen-space <-> normalized round trip

    func testRectAndRegionRoundTripForAnOffsetLetterboxedCrop() {
        let displayed = CGRect(x: 75, y: 0, width: 150, height: 300)
        let original = CropRegion(x: 0.1, y: 0.4, width: 0.35, height: 0.25)
        let screenRect = CropEditorMath.rect(for: original, in: displayed)
        let roundTripped = CropEditorMath.region(for: screenRect, in: displayed)
        XCTAssertEqual(roundTripped.rect.minX, original.rect.minX, accuracy: 0.0001)
        XCTAssertEqual(roundTripped.rect.minY, original.rect.minY, accuracy: 0.0001)
        XCTAssertEqual(roundTripped.rect.width, original.rect.width, accuracy: 0.0001)
        XCTAssertEqual(roundTripped.rect.height, original.rect.height, accuracy: 0.0001)
    }

    func testRectAndRegionRoundTripForFullImageIsExactlyFullImage() {
        let displayed = CGRect(x: 0, y: 75, width: 300, height: 150)
        let screenRect = CropEditorMath.rect(for: .fullImage, in: displayed)
        XCTAssertEqual(screenRect, displayed)
        let roundTripped = CropEditorMath.region(for: screenRect, in: displayed)
        XCTAssertEqual(roundTripped, .fullImage)
        XCTAssertEqual(roundTripped.rect, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    // MARK: - degenerate displayed rect

    func testTranslateAndResizeAreNoOpsForADegenerateDisplayedRect() {
        let region = CropRegion(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let moved = CropEditorMath.translate(region, by: CGSize(width: 10, height: 10), displayedImageRect: .zero)
        XCTAssertEqual(moved, region)
        let resized = CropEditorMath.resize(region, corner: .bottomRight, by: CGSize(width: 10, height: 10), displayedImageRect: .zero)
        XCTAssertEqual(resized, region)
    }

    // MARK: - resizeEdge: single-axis resize, cross-axis untouched

    func testResizeEdgeTopMovesOnlyMinYAndLeavesXAxisUntouched() {
        let region = CropRegion(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let displayed = CGRect(x: 0, y: 0, width: 300, height: 300)
        let resized = CropEditorMath.resizeEdge(region, edge: .top, by: CGSize(width: 999, height: -30), displayedImageRect: displayed)
        XCTAssertEqual(resized.rect.minX, 0.3, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.width, 0.4, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.minY, 0.2, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.maxY, 0.7, accuracy: 0.0001)
    }

    func testResizeEdgeBottomMovesOnlyMaxYAndLeavesXAxisUntouched() {
        let region = CropRegion(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let displayed = CGRect(x: 0, y: 0, width: 300, height: 300)
        let resized = CropEditorMath.resizeEdge(region, edge: .bottom, by: CGSize(width: -999, height: 30), displayedImageRect: displayed)
        XCTAssertEqual(resized.rect.minX, 0.3, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.width, 0.4, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.minY, 0.3, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.maxY, 0.8, accuracy: 0.0001)
    }

    func testResizeEdgeLeftMovesOnlyMinXAndLeavesYAxisUntouched() {
        let region = CropRegion(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let displayed = CGRect(x: 0, y: 0, width: 300, height: 300)
        let resized = CropEditorMath.resizeEdge(region, edge: .left, by: CGSize(width: -30, height: 999), displayedImageRect: displayed)
        XCTAssertEqual(resized.rect.minY, 0.3, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.height, 0.4, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.minX, 0.2, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.maxX, 0.7, accuracy: 0.0001)
    }

    func testResizeEdgeRightMovesOnlyMaxXAndLeavesYAxisUntouched() {
        let region = CropRegion(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let displayed = CGRect(x: 0, y: 0, width: 300, height: 300)
        let resized = CropEditorMath.resizeEdge(region, edge: .right, by: CGSize(width: 30, height: -999), displayedImageRect: displayed)
        XCTAssertEqual(resized.rect.minY, 0.3, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.height, 0.4, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.minX, 0.3, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.maxX, 0.8, accuracy: 0.0001)
    }

    func testResizeEdgeNeverShrinksBelowMinimumDimension() {
        let region = CropRegion(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let displayed = CGRect(x: 0, y: 0, width: 300, height: 300)
        let resized = CropEditorMath.resizeEdge(region, edge: .right, by: CGSize(width: -1000, height: 0), displayedImageRect: displayed, minimumDimension: 0.02)
        XCTAssertEqual(resized.rect.width, 0.02, accuracy: 0.0001)
        XCTAssertGreaterThan(resized.rect.width, 0)
    }

    func testResizeEdgeOvershootClampsRatherThanInverting() {
        let region = CropRegion(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let displayed = CGRect(x: 0, y: 0, width: 300, height: 300)
        // Drag top far past the anchored bottom edge (0.7).
        let resized = CropEditorMath.resizeEdge(region, edge: .top, by: CGSize(width: 0, height: 1000), displayedImageRect: displayed, minimumDimension: 0.02)
        XCTAssertLessThan(resized.rect.minY, resized.rect.maxY)
        XCTAssertEqual(resized.rect.maxY, 0.7, accuracy: 0.0001)
        XCTAssertEqual(resized.rect.height, 0.02, accuracy: 0.0001)
    }

    func testResizeEdgeUsesDisplayedImageRectNotContainerSizeWhenLetterboxed() {
        let region = CropRegion(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let displayed = CGRect(x: 75, y: 0, width: 150, height: 300)
        let resized = CropEditorMath.resizeEdge(region, edge: .right, by: CGSize(width: 15, height: 0), displayedImageRect: displayed)
        XCTAssertEqual(resized.rect.maxX, 0.8, accuracy: 0.0001)
    }

    func testResizeEdgeIsANoOpForADegenerateDisplayedRect() {
        let region = CropRegion(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let resized = CropEditorMath.resizeEdge(region, edge: .top, by: CGSize(width: 10, height: 10), displayedImageRect: .zero)
        XCTAssertEqual(resized, region)
    }

    // MARK: - minimumCoveringSize: aspect-fill of the frame

    func testMinimumCoveringSizeForSquareImageAndSquareFrame() {
        let size = CropEditorMath.minimumCoveringSize(imageAspectSize: CGSize(width: 1000, height: 1000), toCover: CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertEqual(size, CGSize(width: 200, height: 200))
    }

    func testMinimumCoveringSizeForPortraitImageAndWideFrameCoversBothAxes() {
        let size = CropEditorMath.minimumCoveringSize(imageAspectSize: CGSize(width: 1000, height: 2000), toCover: CGRect(x: 0, y: 0, width: 300, height: 100))
        XCTAssertEqual(size.width, 300, accuracy: 0.0001)
        XCTAssertEqual(size.height, 600, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(size.width, 300)
        XCTAssertGreaterThanOrEqual(size.height, 100)
    }

    // MARK: - clampImageOrigin: image must always cover the frame

    func testClampImageOriginIsANoOpWhenAlreadyCovering() {
        let imageRect = CGRect(x: 0, y: 0, width: 500, height: 500)
        let frameRect = CGRect(x: 100, y: 100, width: 200, height: 200)
        let clamped = CropEditorMath.clampImageOrigin(imageRect, toCover: frameRect)
        XCTAssertEqual(clamped, imageRect)
    }

    func testClampImageOriginPullsBackWhenImageDriftsPastFrameEdge() {
        let imageRect = CGRect(x: 150, y: 150, width: 500, height: 500)
        let frameRect = CGRect(x: 100, y: 100, width: 200, height: 200)
        let clamped = CropEditorMath.clampImageOrigin(imageRect, toCover: frameRect)
        XCTAssertLessThanOrEqual(clamped.minX, frameRect.minX)
        XCTAssertLessThanOrEqual(clamped.minY, frameRect.minY)
        XCTAssertGreaterThanOrEqual(clamped.maxX, frameRect.maxX)
        XCTAssertGreaterThanOrEqual(clamped.maxY, frameRect.maxY)
    }

    // MARK: - panImage

    func testPanImageTranslatesWithinValidRange() {
        let imageRect = CGRect(x: 0, y: 0, width: 500, height: 500)
        let frameRect = CGRect(x: 100, y: 100, width: 200, height: 200)
        let panned = CropEditorMath.panImage(imageRect, by: CGSize(width: 20, height: -10), coveringFrame: frameRect)
        XCTAssertEqual(panned.origin, CGPoint(x: 20, y: -10))
    }

    func testPanImageClampsAtEdgeRatherThanRevealingEmptyCanvas() {
        let imageRect = CGRect(x: 0, y: 0, width: 500, height: 500)
        let frameRect = CGRect(x: 100, y: 100, width: 200, height: 200)
        let panned = CropEditorMath.panImage(imageRect, by: CGSize(width: 9999, height: 9999), coveringFrame: frameRect)
        XCTAssertLessThanOrEqual(panned.minX, frameRect.minX)
        XCTAssertLessThanOrEqual(panned.minY, frameRect.minY)
        XCTAssertGreaterThanOrEqual(panned.maxX, frameRect.maxX)
        XCTAssertGreaterThanOrEqual(panned.maxY, frameRect.maxY)
    }

    // MARK: - pinchTransformImage

    func testPinchTransformTranslatesByCentroidDeltaWhenScaleIsUnchanged() {
        let imageRect = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let frameRect = CGRect(x: 400, y: 400, width: 200, height: 200)
        // Both fingers move 50pt left together — separation (scale) unchanged.
        let transformed = CropEditorMath.pinchTransformImage(
            imageRect,
            scaleFactor: 1,
            startingCentroid: CGPoint(x: 500, y: 500),
            currentCentroid: CGPoint(x: 450, y: 500),
            imageAspectSize: CGSize(width: 1000, height: 1000),
            coveringFrame: frameRect
        )
        XCTAssertEqual(transformed.width, imageRect.width, accuracy: 0.01)
        XCTAssertEqual(transformed.height, imageRect.height, accuracy: 0.01)
        XCTAssertEqual(transformed.minX, imageRect.minX - 50, accuracy: 0.01)
        XCTAssertEqual(transformed.minY, imageRect.minY, accuracy: 0.01)
    }

    func testPinchTransformPreservesFocalPointWhenCentroidIsStationary() {
        let imageRect = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let frameRect = CGRect(x: 400, y: 400, width: 200, height: 200)
        let centroid = CGPoint(x: 300, y: 250)
        let fx = (centroid.x - imageRect.minX) / imageRect.width
        let fy = (centroid.y - imageRect.minY) / imageRect.height

        let transformed = CropEditorMath.pinchTransformImage(
            imageRect,
            scaleFactor: 2,
            startingCentroid: centroid,
            currentCentroid: centroid,
            imageAspectSize: CGSize(width: 1000, height: 1000),
            coveringFrame: frameRect
        )

        // The same fractional point in the NEW rect should land back on
        // the same screen point the gesture is centered on.
        let recoveredPoint = CGPoint(x: transformed.minX + fx * transformed.width, y: transformed.minY + fy * transformed.height)
        XCTAssertEqual(recoveredPoint.x, centroid.x, accuracy: 0.01)
        XCTAssertEqual(recoveredPoint.y, centroid.y, accuracy: 0.01)
    }

    func testPinchTransformCombinesScaleAndCentroidTranslationSimultaneously() {
        let imageRect = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let frameRect = CGRect(x: 400, y: 400, width: 200, height: 200)
        let startingCentroid = CGPoint(x: 500, y: 500)
        let currentCentroid = CGPoint(x: 550, y: 480)

        let transformed = CropEditorMath.pinchTransformImage(
            imageRect,
            scaleFactor: 1.5,
            startingCentroid: startingCentroid,
            currentCentroid: currentCentroid,
            imageAspectSize: CGSize(width: 1000, height: 1000),
            coveringFrame: frameRect
        )

        // Scale actually changed...
        XCTAssertEqual(transformed.width, 1500, accuracy: 0.01)
        // ...and the point under the STARTING centroid tracks the
        // centroid's own movement, not just the scale-around-start pin.
        let fx = (startingCentroid.x - imageRect.minX) / imageRect.width
        let fy = (startingCentroid.y - imageRect.minY) / imageRect.height
        let trackedPoint = CGPoint(x: transformed.minX + fx * transformed.width, y: transformed.minY + fy * transformed.height)
        XCTAssertEqual(trackedPoint.x, currentCentroid.x, accuracy: 0.01)
        XCTAssertEqual(trackedPoint.y, currentCentroid.y, accuracy: 0.01)
    }

    func testPinchTransformClampsWhenCombinedTransformWouldExposeEmptyCanvas() {
        let imageRect = CGRect(x: 0, y: 0, width: 300, height: 300)
        let frameRect = CGRect(x: 50, y: 50, width: 200, height: 200)
        // A large centroid translation combined with a shrink — either
        // alone could expose empty canvas around the frame.
        let transformed = CropEditorMath.pinchTransformImage(
            imageRect,
            scaleFactor: 0.5,
            startingCentroid: CGPoint(x: 150, y: 150),
            currentCentroid: CGPoint(x: 800, y: 800),
            imageAspectSize: CGSize(width: 1000, height: 1000),
            coveringFrame: frameRect
        )
        XCTAssertLessThanOrEqual(transformed.minX, frameRect.minX)
        XCTAssertLessThanOrEqual(transformed.minY, frameRect.minY)
        XCTAssertGreaterThanOrEqual(transformed.maxX, frameRect.maxX)
        XCTAssertGreaterThanOrEqual(transformed.maxY, frameRect.maxY)
    }

    func testPinchTransformClampsToMinimumScaleRatherThanRevealingEmptyCanvas() {
        let imageRect = CGRect(x: 0, y: 0, width: 300, height: 300)
        let frameRect = CGRect(x: 50, y: 50, width: 200, height: 200)
        let transformed = CropEditorMath.pinchTransformImage(
            imageRect,
            scaleFactor: 0.01,
            startingCentroid: CGPoint(x: 150, y: 150),
            currentCentroid: CGPoint(x: 150, y: 150),
            imageAspectSize: CGSize(width: 1000, height: 1000),
            coveringFrame: frameRect
        )
        let minimumSize = CropEditorMath.minimumCoveringSize(imageAspectSize: CGSize(width: 1000, height: 1000), toCover: frameRect)
        XCTAssertEqual(transformed.width, minimumSize.width, accuracy: 0.01)
        XCTAssertEqual(transformed.height, minimumSize.height, accuracy: 0.01)
    }

    func testPinchTransformClampsToMaximumScaleMultiplier() {
        let imageRect = CGRect(x: 0, y: 0, width: 300, height: 300)
        let frameRect = CGRect(x: 50, y: 50, width: 200, height: 200)
        let transformed = CropEditorMath.pinchTransformImage(
            imageRect,
            scaleFactor: 10_000,
            startingCentroid: CGPoint(x: 150, y: 150),
            currentCentroid: CGPoint(x: 150, y: 150),
            imageAspectSize: CGSize(width: 1000, height: 1000),
            coveringFrame: frameRect,
            maximumScaleMultiplier: 9
        )
        let minimumSize = CropEditorMath.minimumCoveringSize(imageAspectSize: CGSize(width: 1000, height: 1000), toCover: frameRect)
        XCTAssertEqual(transformed.width, minimumSize.width * 9, accuracy: 0.01)
        XCTAssertEqual(transformed.height, minimumSize.height * 9, accuracy: 0.01)
    }

    func testPinchTransformIsANoOpForADegenerateImageRect() {
        let frameRect = CGRect(x: 50, y: 50, width: 200, height: 200)
        let transformed = CropEditorMath.pinchTransformImage(.zero, scaleFactor: 2, startingCentroid: .zero, currentCentroid: CGPoint(x: 10, y: 10), imageAspectSize: CGSize(width: 1000, height: 1000), coveringFrame: frameRect)
        XCTAssertEqual(transformed, .zero)
    }

    // MARK: - dampedTranslation / dampedScaleFactor (traction)

    func testDampedTranslationScalesBothAxesBySensitivity() {
        let damped = CropEditorMath.dampedTranslation(CGSize(width: 100, height: -50), sensitivity: 0.9)
        XCTAssertEqual(damped.width, 90, accuracy: 0.0001)
        XCTAssertEqual(damped.height, -45, accuracy: 0.0001)
    }

    func testDampedTranslationWithSensitivityOneIsIdentity() {
        let translation = CGSize(width: 37, height: -12)
        let damped = CropEditorMath.dampedTranslation(translation, sensitivity: 1)
        XCTAssertEqual(damped, translation)
    }

    func testDampedScaleFactorWithSensitivityOneIsIdentity() {
        XCTAssertEqual(CropEditorMath.dampedScaleFactor(1.5, sensitivity: 1), 1.5, accuracy: 0.0001)
    }

    func testDampedScaleFactorAlwaysMapsNoChangeToNoChangeRegardlessOfSensitivity() {
        XCTAssertEqual(CropEditorMath.dampedScaleFactor(1.0, sensitivity: 0.5), 1.0, accuracy: 0.0001)
    }

    func testDampedScaleFactorSoftensZoomingIn() {
        // Raw scale of 2.0 (doubled) at 0.9 sensitivity should register
        // as slightly less than doubled.
        let damped = CropEditorMath.dampedScaleFactor(2.0, sensitivity: 0.9)
        XCTAssertEqual(damped, 1.9, accuracy: 0.0001)
        XCTAssertLessThan(damped, 2.0)
    }

    func testDampedScaleFactorSoftensZoomingOutSymmetrically() {
        // Raw scale of 0.5 (halved) at 0.9 sensitivity should register as
        // slightly less than halved — softened toward 1 on both sides.
        let damped = CropEditorMath.dampedScaleFactor(0.5, sensitivity: 0.9)
        XCTAssertEqual(damped, 0.55, accuracy: 0.0001)
        XCTAssertGreaterThan(damped, 0.5)
    }

    // MARK: - PresentationTransform

    func testPresentationTransformIdentityApplyIsANoOp() {
        let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
        XCTAssertEqual(CropEditorMath.PresentationTransform.identity.apply(to: rect), rect)
        let point = CGPoint(x: 5, y: 6)
        XCTAssertEqual(CropEditorMath.PresentationTransform.identity.apply(to: point), point)
    }

    func testPresentationTransformAppliesScaleThenOffset() {
        let transform = CropEditorMath.PresentationTransform(scale: 2, offset: CGSize(width: 10, height: -5))
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        let applied = transform.apply(to: rect)
        XCTAssertEqual(applied, CGRect(x: 30, y: 15, width: 40, height: 40))
    }

    func testPresentationTransformApplyThenInverseRoundTripsAPoint() {
        let transform = CropEditorMath.PresentationTransform(scale: 3.4, offset: CGSize(width: -12, height: 27))
        let point = CGPoint(x: 42, y: 17)
        let roundTripped = transform.inverse(transform.apply(to: point))
        XCTAssertEqual(roundTripped.x, point.x, accuracy: 0.0001)
        XCTAssertEqual(roundTripped.y, point.y, accuracy: 0.0001)
    }

    func testPresentationTransformInverseDeltaOnlyScalesIgnoringOffset() {
        let transform = CropEditorMath.PresentationTransform(scale: 4, offset: CGSize(width: 500, height: -300))
        let inverseDelta = transform.inverseDelta(CGSize(width: 40, height: -20))
        XCTAssertEqual(inverseDelta, CGSize(width: 10, height: -5))
    }

    func testPresentationTransformInterpolateAtProgressZeroIsStart() {
        let start = CropEditorMath.PresentationTransform(scale: 1, offset: .zero)
        let end = CropEditorMath.PresentationTransform(scale: 5, offset: CGSize(width: 100, height: 200))
        XCTAssertEqual(CropEditorMath.PresentationTransform.interpolate(from: start, to: end, progress: 0), start)
    }

    func testPresentationTransformInterpolateAtProgressOneIsEnd() {
        let start = CropEditorMath.PresentationTransform(scale: 1, offset: .zero)
        let end = CropEditorMath.PresentationTransform(scale: 5, offset: CGSize(width: 100, height: 200))
        XCTAssertEqual(CropEditorMath.PresentationTransform.interpolate(from: start, to: end, progress: 1), end)
    }

    func testPresentationTransformInterpolateAtProgressHalfIsMidpoint() {
        let start = CropEditorMath.PresentationTransform(scale: 1, offset: .zero)
        let end = CropEditorMath.PresentationTransform(scale: 5, offset: CGSize(width: 100, height: 200))
        let midpoint = CropEditorMath.PresentationTransform.interpolate(from: start, to: end, progress: 0.5)
        XCTAssertEqual(midpoint.scale, 3, accuracy: 0.0001)
        XCTAssertEqual(midpoint.offset, CGSize(width: 50, height: 100))
    }

    // MARK: - idealPresentationTransform

    func testIdealPresentationTransformEnlargesATinyCropSubstantially() {
        let tinyFrame = CGRect(x: 140, y: 140, width: 20, height: 20)
        let viewport = CGRect(x: 26, y: 56, width: 300, height: 400)
        let transform = CropEditorMath.idealPresentationTransform(for: tinyFrame, fitting: viewport, maximumScale: 7)
        XCTAssertEqual(transform.scale, 7, accuracy: 0.0001)
    }

    func testIdealPresentationTransformNeverShrinksACropAlreadyFillingTheViewport() {
        let viewport = CGRect(x: 26, y: 56, width: 300, height: 400)
        let fullFrame = viewport
        let transform = CropEditorMath.idealPresentationTransform(for: fullFrame, fitting: viewport, maximumScale: 7)
        XCTAssertEqual(transform.scale, 1, accuracy: 0.0001)
    }

    func testIdealPresentationTransformCentersTheScaledFrameInTheViewport() {
        let frame = CGRect(x: 100, y: 100, width: 40, height: 40)
        let viewport = CGRect(x: 26, y: 56, width: 300, height: 400)
        let transform = CropEditorMath.idealPresentationTransform(for: frame, fitting: viewport, maximumScale: 7)
        let presented = transform.apply(to: frame)
        XCTAssertEqual(presented.midX, viewport.midX, accuracy: 0.01)
        XCTAssertEqual(presented.midY, viewport.midY, accuracy: 0.01)
    }

    func testIdealPresentationTransformIsIdentityForADegenerateFrame() {
        let viewport = CGRect(x: 26, y: 56, width: 300, height: 400)
        let transform = CropEditorMath.idealPresentationTransform(for: .zero, fitting: viewport, maximumScale: 7)
        XCTAssertEqual(transform, .identity)
    }

    // MARK: - easedProgress

    func testEasedProgressAtZeroIsZero() {
        XCTAssertEqual(CropEditorMath.easedProgress(0), 0, accuracy: 0.0001)
    }

    func testEasedProgressAtOneIsOne() {
        XCTAssertEqual(CropEditorMath.easedProgress(1), 1, accuracy: 0.0001)
    }

    func testEasedProgressAtHalfIsHalf() {
        // The standard cubic ease-in-out curve passes exactly through
        // (0.5, 0.5) — symmetric acceleration/deceleration.
        XCTAssertEqual(CropEditorMath.easedProgress(0.5), 0.5, accuracy: 0.0001)
    }

    func testEasedProgressClampsOutOfRangeInput() {
        XCTAssertEqual(CropEditorMath.easedProgress(-1), 0, accuracy: 0.0001)
        XCTAssertEqual(CropEditorMath.easedProgress(2), 1, accuracy: 0.0001)
    }
}
