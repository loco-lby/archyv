import XCTest
@testable import ArkyvKit

/// Share/Capture Reliability Foundation 01.
final class IngestionTests: XCTestCase {
    // MARK: - MediaStore.save(copyingFileAt:) — pure Foundation, runs on
    // any platform (no UIKit needed to copy bytes around).

    func testSaveCopyingFileAtPreservesBytesExactly() throws {
        let sourceBytes = Data("not actually a JPEG, just needs to round-trip byte-for-byte".utf8)
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try sourceBytes.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let filename = try MediaStore.shared.save(copyingFileAt: sourceURL)
        defer { MediaStore.shared.delete(filename: filename) }

        XCTAssertEqual(MediaStore.shared.data(for: filename), sourceBytes, "a copy must be byte-for-byte identical — this path exists specifically to avoid ever decoding/re-encoding the original")
    }

    func testSaveCopyingFileAtGeneratesUniqueFilenamesForRepeatedCalls() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("x".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let first = try MediaStore.shared.save(copyingFileAt: sourceURL)
        let second = try MediaStore.shared.save(copyingFileAt: sourceURL)
        defer {
            MediaStore.shared.delete(filename: first)
            MediaStore.shared.delete(filename: second)
        }

        XCTAssertNotEqual(first, second, "copying the same source twice must never collide/overwrite — each call is its own capture attempt")
    }

    func testSaveCopyingFileAtThrowsRatherThanSilentlyFailingWhenSourceIsMissing() {
        let missingSource = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-does-not-exist")
        XCTAssertThrowsError(try MediaStore.shared.save(copyingFileAt: missingSource))
    }

    #if canImport(UIKit)
    // MARK: - ImageDecoding.pixelSize — header-only reads, no bitmap decode.

    private func makeSyntheticJPEG(width: Int, height: Int) -> Data {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    @MainActor
    func testPixelSizeOfDataMatchesTheFullyDecodedImagesOwnSize() {
        let data = makeSyntheticJPEG(width: 1170, height: 2532)
        let headerOnly = ImageDecoding.pixelSize(ofData: data)
        let fullyDecoded = UIImage(data: data)!.size

        XCTAssertEqual(headerOnly?.width, fullyDecoded.width, accuracy: 0.5)
        XCTAssertEqual(headerOnly?.height, fullyDecoded.height, accuracy: 0.5)
    }

    @MainActor
    func testPixelSizeOfFileAtMatchesPixelSizeOfData() throws {
        let data = makeSyntheticJPEG(width: 800, height: 600)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(ImageDecoding.pixelSize(ofFileAt: url), ImageDecoding.pixelSize(ofData: data), "both entry points must agree — a caller shouldn't get a different answer just because it had a URL instead of Data in hand")
    }

    func testPixelSizeReturnsNilForGarbageData() {
        XCTAssertNil(ImageDecoding.pixelSize(ofData: Data("not an image".utf8)))
    }
    #endif
}
