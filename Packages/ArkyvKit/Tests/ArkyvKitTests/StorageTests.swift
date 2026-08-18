import XCTest
@testable import ArkyvKit

/// Storage/Disk Pressure Foundation 01. Pure Foundation — no UIKit, no
/// SwiftData — runs on any platform.
final class StorageTests: XCTestCase {
    // MARK: - save(copyingFileAt:) atomicity

    func testSaveCopyingFileAtLeavesNoStagingFileBehindOnSuccess() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("some bytes".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let filename = try MediaStore.shared.save(copyingFileAt: sourceURL)
        defer { MediaStore.shared.delete(filename: filename) }

        let leftoverStagingFiles = (try? FileManager.default.contentsOfDirectory(atPath: MediaStore.shared.root.path))?
            .filter { $0.hasPrefix(".staging-") } ?? []
        XCTAssertEqual(leftoverStagingFiles, [], "a successful copy must never leave its temporary staging file behind")
    }

    func testSaveCopyingFileAtLeavesNoStagingFileBehindOnFailure() {
        let missingSource = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-does-not-exist")
        XCTAssertThrowsError(try MediaStore.shared.save(copyingFileAt: missingSource))

        let leftoverStagingFiles = (try? FileManager.default.contentsOfDirectory(atPath: MediaStore.shared.root.path))?
            .filter { $0.hasPrefix(".staging-") } ?? []
        XCTAssertEqual(leftoverStagingFiles, [], "a failed copy must never leave its temporary staging file behind either")
    }

    func testSaveCopyingFileAtNeverLeavesAPartialFileAtTheFinalDestination() {
        // The source never existed, so `copyItem` fails before anything
        // reaches the staging file at all — this asserts the OTHER half
        // of the atomicity contract: no file at the *final* filename
        // either, partial or otherwise. (A genuinely truncated mid-copy
        // is not something this test harness can force without a real
        // disk-full condition or a custom FileManager double — see the
        // Storage Contract's note on why this isn't simulated directly.)
        let missingSource = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-does-not-exist")
        let id = UUID()
        XCTAssertThrowsError(try MediaStore.shared.save(copyingFileAt: missingSource, id: id))

        XCTAssertFalse(FileManager.default.fileExists(atPath: MediaStore.shared.url(for: "\(id.uuidString).jpg").path))
    }

    // MARK: - totalBytesOnDisk()

    func testTotalBytesOnDiskIncreasesByAtLeastTheWrittenAmount() throws {
        let before = MediaStore.shared.totalBytesOnDisk()
        let payload = Data(repeating: 0x42, count: 100_000) // 100KB, comfortably above filesystem block rounding noise
        let filename = try MediaStore.shared.save(data: payload)
        defer { MediaStore.shared.delete(filename: filename) }

        let after = MediaStore.shared.totalBytesOnDisk()
        XCTAssertGreaterThanOrEqual(after - before, Int64(payload.count), "allocated size can only round UP from the logical byte count, never down")
    }

    func testTotalBytesOnDiskDecreasesAfterDelete() throws {
        let payload = Data(repeating: 0x42, count: 100_000)
        let filename = try MediaStore.shared.save(data: payload)
        let withFile = MediaStore.shared.totalBytesOnDisk()

        MediaStore.shared.delete(filename: filename)
        let afterDelete = MediaStore.shared.totalBytesOnDisk()

        XCTAssertLessThan(afterDelete, withFile)
    }

    func testTotalBytesOnDiskIgnoresStagingFiles() throws {
        // Simulates a staging file that (per the atomicity fix above)
        // should never normally survive, but this confirms the
        // diagnostic wouldn't count it as archive footprint even if one
        // somehow lingered — `.skipsHiddenFiles` excludes dot-prefixed
        // names, which `.staging-<uuid>` deliberately uses.
        let stagingURL = MediaStore.shared.root.appendingPathComponent(".staging-\(UUID().uuidString)")
        try Data(repeating: 0x42, count: 50_000).write(to: stagingURL)
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        let before = MediaStore.shared.totalBytesOnDisk()
        try Data("x".utf8).write(to: stagingURL) // no-op rewrite, keeps `before` meaningful
        let after = MediaStore.shared.totalBytesOnDisk()

        XCTAssertEqual(before, after, "a dot-prefixed staging file must not be counted toward reported archive size")
    }
}
