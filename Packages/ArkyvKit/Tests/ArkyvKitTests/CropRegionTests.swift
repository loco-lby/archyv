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
}
