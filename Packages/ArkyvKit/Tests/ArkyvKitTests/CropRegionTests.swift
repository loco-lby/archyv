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

    func testRenderTransformDegenerateSizesReturnIdentityRatherThanCrashing() {
        let zeroImage = CropRegion.fullImage.renderTransform(imageSize: .zero, containerSize: CGSize(width: 300, height: 300))
        XCTAssertEqual(zeroImage.scale, 1)
        XCTAssertEqual(zeroImage.offset, .zero)

        let zeroContainer = CropRegion.fullImage.renderTransform(imageSize: CGSize(width: 100, height: 100), containerSize: .zero)
        XCTAssertEqual(zeroContainer.scale, 1)
        XCTAssertEqual(zeroContainer.offset, .zero)
    }
}
