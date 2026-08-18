import XCTest
import CoreGraphics
@testable import ArkyvKit

final class CropRegionTests: XCTestCase {
    func testFullImageIsZeroZeroOneOne() {
        XCTAssertEqual(CropRegion.fullImage.rect, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertTrue(CropRegion.fullImage.isFullImage)
    }

    func testInBoundsRectIsPreservedExactly() {
        let region = CropRegion(x: 0.2, y: 0.3, width: 0.4, height: 0.25)
        XCTAssertEqual(region.rect, CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.25))
        XCTAssertFalse(region.isFullImage)
    }

    func testOversizedWidthAndHeightAreClampedToOne() {
        let region = CropRegion(x: 0, y: 0, width: 5, height: 5)
        XCTAssertEqual(region.rect.width, 1)
        XCTAssertEqual(region.rect.height, 1)
    }

    func testNegativeOriginIsClampedToZero() {
        let region = CropRegion(x: -0.5, y: -0.5, width: 0.3, height: 0.3)
        XCTAssertEqual(region.rect.minX, 0)
        XCTAssertEqual(region.rect.minY, 0)
    }

    func testOriginIsPulledBackSoTheRectNeverExtendsPastTheFarEdge() {
        let region = CropRegion(x: 0.9, y: 0.9, width: 0.5, height: 0.5)
        XCTAssertEqual(region.rect.maxX, 1, accuracy: 0.0001)
        XCTAssertEqual(region.rect.maxY, 1, accuracy: 0.0001)
        // Width/height themselves are still clamped to <= 1, not shrunk to
        // fit — only the origin moves.
        XCTAssertEqual(region.rect.width, 0.5, accuracy: 0.0001)
        XCTAssertEqual(region.rect.height, 0.5, accuracy: 0.0001)
    }

    func testDegenerateZeroAreaRectIsRaisedToMinimumDimension() {
        let region = CropRegion(x: 0.5, y: 0.5, width: 0, height: 0)
        XCTAssertGreaterThan(region.rect.width, 0)
        XCTAssertGreaterThan(region.rect.height, 0)
    }

    func testEquality() {
        XCTAssertEqual(CropRegion(x: 0.1, y: 0.1, width: 0.5, height: 0.5), CropRegion(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        XCTAssertNotEqual(CropRegion(x: 0.1, y: 0.1, width: 0.5, height: 0.5), CropRegion.fullImage)
    }

    // MARK: - StoredItem.cropRegion wrapper

    @MainActor
    func testNewStoredItemDefaultsToFullImageCrop() {
        let item = StoredItem(kind: .screenshot)
        XCTAssertEqual(item.cropRegion, .fullImage)
    }

    @MainActor
    func testStoredItemCropRegionRoundTrips() {
        let item = StoredItem(kind: .screenshot)
        let region = CropRegion(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        item.cropRegion = region
        XCTAssertEqual(item.cropRegion, region)
        XCTAssertEqual(item.cropX, 0.1, accuracy: 0.0001)
        XCTAssertEqual(item.cropY, 0.2, accuracy: 0.0001)
        XCTAssertEqual(item.cropWidth, 0.3, accuracy: 0.0001)
        XCTAssertEqual(item.cropHeight, 0.4, accuracy: 0.0001)
    }

    // MARK: - renderTransform (non-destructive rendering math)

    func testFullImageSquareIntoSquareContainerHasNoOffset() {
        let transform = CropRegion.fullImage.renderTransform(
            imageSize: CGSize(width: 1000, height: 1000),
            containerSize: CGSize(width: 300, height: 300)
        )
        XCTAssertEqual(transform.scale, 0.3, accuracy: 0.0001)
        XCTAssertEqual(transform.offset, .zero)
    }

    func testFullImageAspectMismatchCentersOnTheShortAxis() {
        // Tall image (1:2) into a square container — aspect-fill behavior:
        // scaled to cover width, vertical excess centered (offset < 0).
        let transform = CropRegion.fullImage.renderTransform(
            imageSize: CGSize(width: 1000, height: 2000),
            containerSize: CGSize(width: 300, height: 300)
        )
        XCTAssertEqual(transform.scale, 0.3, accuracy: 0.0001)
        XCTAssertEqual(transform.offset.width, 0, accuracy: 0.0001)
        XCTAssertEqual(transform.offset.height, -150, accuracy: 0.0001)
    }

    func testCenteredSquareCropRendersAtExpectedScaleAndOffset() {
        let region = CropRegion(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let transform = region.renderTransform(
            imageSize: CGSize(width: 1000, height: 1000),
            containerSize: CGSize(width: 300, height: 300)
        )
        // crop is 500x500 px; scale to fill 300x300 -> 0.6.
        XCTAssertEqual(transform.scale, 0.6, accuracy: 0.0001)
        // scaled image is 600x600; crop origin in scaled image is (150,150);
        // centering that 300x300 crop window in the 300x300 container means
        // shifting the whole scaled image by (-150,-150).
        XCTAssertEqual(transform.offset.width, -150, accuracy: 0.0001)
        XCTAssertEqual(transform.offset.height, -150, accuracy: 0.0001)
    }

    // These tests do not trust `renderTransform`'s internal scale/offset
    // algebra at all. They independently re-derive, from first principles,
    // which normalized region of the *original* image ends up visible in
    // the container under the transform — using the same direct-origin
    // placement contract the consuming views use (`.position()` at
    // `offset + scaledSize/2`, i.e. image top-left placed directly at
    // `offset`, not a `.offset()`-style shift from a centered default).
    // If `renderTransform` or its consumption drifts from that contract,
    // these fail by showing the wrong *source content*, not just a wrong
    // number.
    private func visibleSourceFraction(
        region: CropRegion,
        imageSize: CGSize,
        containerSize: CGSize
    ) -> CGRect {
        let transform = region.renderTransform(imageSize: imageSize, containerSize: containerSize)
        let minX = (0 - transform.offset.width) / transform.scale / imageSize.width
        let maxX = (containerSize.width - transform.offset.width) / transform.scale / imageSize.width
        let minY = (0 - transform.offset.height) / transform.scale / imageSize.height
        let maxY = (containerSize.height - transform.offset.height) / transform.scale / imageSize.height
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func assertVisibleFraction(
        _ region: CropRegion,
        imageSize: CGSize,
        containerSize: CGSize,
        expected: CGRect,
        accuracy: CGFloat = 0.0001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let visible = visibleSourceFraction(region: region, imageSize: imageSize, containerSize: containerSize)
        XCTAssertEqual(visible.minX, expected.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(visible.minY, expected.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(visible.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(visible.height, expected.height, accuracy: accuracy, file: file, line: line)
    }

    func testFullImageRegionRevealsTheEntireSource() {
        assertVisibleFraction(
            .fullImage,
            imageSize: CGSize(width: 1000, height: 1000),
            containerSize: CGSize(width: 300, height: 300),
            expected: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
    }

    func testLeftHalfRegionRevealsOnlyTheLeftHalfOfTheSource() {
        assertVisibleFraction(
            CropRegion(x: 0, y: 0, width: 0.5, height: 1),
            imageSize: CGSize(width: 1000, height: 1000),
            containerSize: CGSize(width: 300, height: 600),
            expected: CGRect(x: 0, y: 0, width: 0.5, height: 1)
        )
    }

    func testRightHalfRegionRevealsOnlyTheRightHalfOfTheSource() {
        assertVisibleFraction(
            CropRegion(x: 0.5, y: 0, width: 0.5, height: 1),
            imageSize: CGSize(width: 1000, height: 1000),
            containerSize: CGSize(width: 300, height: 600),
            expected: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        )
    }

    func testTopHalfRegionRevealsOnlyTheTopHalfOfTheSource() {
        assertVisibleFraction(
            CropRegion(x: 0, y: 0, width: 1, height: 0.5),
            imageSize: CGSize(width: 1000, height: 1000),
            containerSize: CGSize(width: 600, height: 300),
            expected: CGRect(x: 0, y: 0, width: 1, height: 0.5)
        )
    }

    func testBottomHalfRegionRevealsOnlyTheBottomHalfOfTheSource() {
        assertVisibleFraction(
            CropRegion(x: 0, y: 0.5, width: 1, height: 0.5),
            imageSize: CGSize(width: 1000, height: 1000),
            containerSize: CGSize(width: 600, height: 300),
            expected: CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        )
    }

    func testCenteredMiddleRegionRevealsOnlyTheCenteredMiddleOfTheSource() {
        assertVisibleFraction(
            CropRegion(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            imageSize: CGSize(width: 1000, height: 1000),
            containerSize: CGSize(width: 300, height: 300),
            expected: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        )
    }

    // MARK: - Resolution independence (Performance Foundation 01)

    // `renderTransform` only ever consumes `imageSize` relative to its own
    // normalized `rect` — never an absolute pixel count — so a caller that
    // hands it a downsampled decode's `.size` instead of the original's
    // must render the *exact* same visible crop, as long as the
    // downsampled image's aspect ratio still matches the original's. This
    // is the property that makes it safe for `LocalImageView` to decode a
    // masonry thumbnail at a fraction of the original's resolution without
    // any change to `CropRegion` itself — see `ImageDecoding`.
    func testRenderTransformIsScaleInvariantAcrossDecodedResolutions() {
        let region = CropRegion(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
        let containerSize = CGSize(width: 300, height: 450)
        let fullSize = CGSize(width: 3000, height: 4000)

        let fullTransform = region.renderTransform(imageSize: fullSize, containerSize: containerSize)
        for downsampleFactor: CGFloat in [0.5, 0.25, 0.1, 0.01] {
            let downsampledSize = CGSize(width: fullSize.width * downsampleFactor, height: fullSize.height * downsampleFactor)
            let downsampledTransform = region.renderTransform(imageSize: downsampledSize, containerSize: containerSize)
            // `scale` differs (it's relative to whichever imageSize was
            // handed in) but the *effective* rendered geometry —
            // `imageSize * scale` and the resulting offset — must be
            // identical regardless of which resolution was decoded.
            XCTAssertEqual(downsampledTransform.scale * downsampledSize.width, fullTransform.scale * fullSize.width, accuracy: 0.01)
            XCTAssertEqual(downsampledTransform.scale * downsampledSize.height, fullTransform.scale * fullSize.height, accuracy: 0.01)
            XCTAssertEqual(downsampledTransform.offset.width, fullTransform.offset.width, accuracy: 0.01)
            XCTAssertEqual(downsampledTransform.offset.height, fullTransform.offset.height, accuracy: 0.01)
        }
    }

    func testVisibleSourceFractionIsIdenticalAcrossDecodedResolutions() {
        let region = CropRegion(x: 0.1, y: 0.35, width: 0.6, height: 0.2)
        let containerSize = CGSize(width: 320, height: 200)
        let expected = visibleSourceFraction(region: region, imageSize: CGSize(width: 4032, height: 3024), containerSize: containerSize)

        for thumbnailSize in [CGSize(width: 1008, height: 756), CGSize(width: 640, height: 480), CGSize(width: 64, height: 48)] {
            let visible = visibleSourceFraction(region: region, imageSize: thumbnailSize, containerSize: containerSize)
            XCTAssertEqual(visible.minX, expected.minX, accuracy: 0.001)
            XCTAssertEqual(visible.minY, expected.minY, accuracy: 0.001)
            XCTAssertEqual(visible.width, expected.width, accuracy: 0.001)
            XCTAssertEqual(visible.height, expected.height, accuracy: 0.001)
        }
    }

    func testRenderTransformDegenerateSizesReturnIdentityRatherThanCrashing() {
        let zeroImage = CropRegion.fullImage.renderTransform(imageSize: .zero, containerSize: CGSize(width: 300, height: 300))
        XCTAssertEqual(zeroImage.scale, 1)
        XCTAssertEqual(zeroImage.offset, .zero)

        let zeroContainer = CropRegion.fullImage.renderTransform(imageSize: CGSize(width: 100, height: 100), containerSize: .zero)
        XCTAssertEqual(zeroContainer.scale, 1)
        XCTAssertEqual(zeroContainer.offset, .zero)
    }
}
