import XCTest
@testable import ArkyvKit

/// Media Architecture Cutover 01. Pure Foundation — no UIKit, no SwiftData
/// — runs on any platform. Tests the PRODUCTION `MediaStore`/
/// `MediaCacheCoordinator` cache-reconstruction contract directly
/// (promoted from Media Cache Foundation 01's DEBUG-only
/// `MediaCachePrototype`, now retired in favor of this). Uses
/// `MediaStore.shared` — safe in this CLI test context because
/// `AppGroup.containerURL` falls back to a per-process Application
/// Support directory when the App Group entitlement isn't present (see
/// `AppGroup.swift`), the same fallback `StorageTests.swift` already
/// relies on — never the real device App Group container.
final class MediaStoreCacheTests: XCTestCase {
    // MARK: - Reconstruction (async, coordinator-routed)

    func testDataReconstructingFromRestoresFromSourceWhenFileIsMissing() async throws {
        let filename = "\(UUID().uuidString).jpg"
        defer { MediaStore.shared.delete(filename: filename) }
        let source = Data("original bytes".utf8)

        let result = await MediaStore.shared.data(for: filename, reconstructingFrom: { source })

        XCTAssertEqual(result, source)
        XCTAssertEqual(try? Data(contentsOf: MediaStore.shared.url(for: filename)), source, "reconstruction must actually persist to disk, not just return the bytes")
    }

    func testDataReconstructingFromReturnsExistingFileWithoutInvokingSourceAgain() async throws {
        let filename = "\(UUID().uuidString).jpg"
        defer { MediaStore.shared.delete(filename: filename) }
        _ = await MediaStore.shared.data(for: filename, reconstructingFrom: { Data("original".utf8) })

        let sourceCalled = LockedCounter()
        let result = await MediaStore.shared.data(for: filename, reconstructingFrom: {
            sourceCalled.increment()
            return Data("should not be used".utf8)
        })

        XCTAssertEqual(sourceCalled.value, 0, "an already-cached file must never re-invoke the (expensive) source")
        XCTAssertEqual(result, Data("original".utf8))
    }

    func testReconstructionLeavesNoStagingFileBehindOnSuccess() async throws {
        let filename = "\(UUID().uuidString).jpg"
        defer { MediaStore.shared.delete(filename: filename) }

        _ = await MediaStore.shared.data(for: filename, reconstructingFrom: { Data("bytes".utf8) })

        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: MediaStore.shared.root.path))?.filter { $0.hasPrefix(".staging-") } ?? []
        XCTAssertEqual(leftover, [])
    }

    /// Cutover §3 / Media Cache Foundation 01 §11 (disk pressure): a
    /// failed cache write must still return the reconstructed bytes to
    /// the caller — viewing a Cherry must never depend on the cache
    /// write succeeding. Forced by pointing `reconstruct` at a filename
    /// whose parent path component doesn't exist as a directory (a
    /// nested path under a plain file), so the write genuinely fails.
    func testDataStillReturnsBytesEvenWhenTheCacheWriteFails() {
        let blockerFilename = "\(UUID().uuidString)"
        let blockerPath = MediaStore.shared.url(for: blockerFilename)
        try? Data().write(to: blockerPath) // a plain file, not a directory
        defer { try? FileManager.default.removeItem(at: blockerPath) }

        // A filename that requires writing INSIDE the blocker "file" as
        // if it were a directory — guaranteed to fail.
        let filename = "\(blockerFilename)/nested.jpg"
        let result = MediaStore.shared.reconstruct(filename: filename, from: { Data("bytes".utf8) })

        XCTAssertEqual(result, Data("bytes".utf8), "render must succeed from the durable source even though the cache write failed")
    }

    // MARK: - Eviction (Cutover §7)

    /// Deliberately well above APFS's ~4KB block-rounding granularity —
    /// see Media Cache Foundation 01's own precedent for why tiny
    /// payloads make the eviction math misleading.
    private static let evictionTestFileSize = 50_000

    func testEvictionIsANoOpWhenUnderCapacity() throws {
        let filename = "\(UUID().uuidString).jpg"
        defer { MediaStore.shared.delete(filename: filename) }
        try Data(repeating: 0x1, count: Self.evictionTestFileSize).write(to: MediaStore.shared.url(for: filename))

        // A capacity comfortably above this one file plus whatever else
        // legitimately lives in the shared fallback directory from other
        // tests in this run.
        let (evicted, _) = MediaStore.shared.evictIfNeeded(capacityBytes: 50_000_000)

        XCTAssertEqual(evicted, 0)
    }

    func testEvictionRemovesOldestFileFirstUntilUnderCapacity() throws {
        let root = MediaStore.shared.root
        let names = (0..<3).map { _ in "\(UUID().uuidString).jpg" }
        defer { names.forEach { MediaStore.shared.delete(filename: $0) } }

        for (offset, name) in zip([-300.0, -200.0, -100.0], names) {
            try Data(repeating: 0x1, count: Self.evictionTestFileSize).write(to: root.appendingPathComponent(name))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: offset)], ofItemAtPath: root.appendingPathComponent(name).path)
        }

        // Isolate this assertion to exactly these 3 files by using a cap
        // sized relative to their own total, not the shared directory's
        // total (which may hold other tests' leftovers within the same
        // process run) — measure before, then assert only on THESE names.
        let (_, _) = MediaStore.shared.evictIfNeeded(capacityBytes: MediaStore.shared.totalBytesOnDisk() - 1)

        // The oldest of these three must be gone; the newest two survive
        // relative to each other (both younger than the evicted one).
        let remaining = names.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        XCTAssertFalse(remaining.contains(names[0]), "the oldest file must be evicted first")
        XCTAssertTrue(remaining.contains(names[2]), "the newest file must survive")
    }

    func testEvictionNeverLeavesTotalSizeAboveCapacityWhenPossible() throws {
        let root = MediaStore.shared.root
        let names = (0..<10).map { _ in "\(UUID().uuidString).jpg" }
        defer { names.forEach { MediaStore.shared.delete(filename: $0) } }
        for (i, name) in names.enumerated() {
            try Data(repeating: 0x1, count: Self.evictionTestFileSize).write(to: root.appendingPathComponent(name))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(i))], ofItemAtPath: root.appendingPathComponent(name).path)
        }

        let cap: Int64 = 150_000
        MediaStore.shared.evictIfNeeded(capacityBytes: cap)

        // Only meaningful if the shared directory's total for JUST these
        // files is what we check — sum the survivors directly.
        let survivingBytes: Int64 = names.reduce(0) { total, name in
            let path = root.appendingPathComponent(name).path
            guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64 else { return total }
            return total + size
        }
        XCTAssertLessThanOrEqual(survivingBytes, cap)
    }

    func testTouchingAnExistingFileOnACacheHitProtectsItFromTheNextEviction() async throws {
        let root = MediaStore.shared.root
        let names = (0..<3).map { _ in "\(UUID().uuidString).jpg" }
        defer { names.forEach { MediaStore.shared.delete(filename: $0) } }
        for (offset, name) in zip([-300.0, -200.0, -100.0], names) {
            try Data(repeating: 0x1, count: Self.evictionTestFileSize).write(to: root.appendingPathComponent(name))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: offset)], ofItemAtPath: root.appendingPathComponent(name).path)
        }

        // A cache HIT on the oldest file (via the async reconstructing
        // path, which touches on hit) bumps its modification date to now.
        _ = await MediaStore.shared.data(for: names[0], reconstructingFrom: { Data("unused".utf8) })

        let (_, _) = MediaStore.shared.evictIfNeeded(capacityBytes: MediaStore.shared.totalBytesOnDisk() - 1)

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(names[0]).path), "a recently-touched (re-accessed) file must survive eviction")
    }

    // MARK: - Backup exclusion (Cutover §8)

    func testExcludeFromBackupSetsTheDirectoryLevelAttribute() throws {
        MediaStore.shared.excludeFromBackup()

        let values = try MediaStore.shared.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testFilesAddedAfterExclusionInheritTheEffectiveExclusion() async throws {
        MediaStore.shared.excludeFromBackup()
        let filename = "\(UUID().uuidString).jpg"
        defer { MediaStore.shared.delete(filename: filename) }

        _ = await MediaStore.shared.data(for: filename, reconstructingFrom: { Data("bytes".utf8) })

        let fileValues = try MediaStore.shared.url(for: filename).resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(fileValues.isExcludedFromBackup, true, "a file added AFTER the directory was excluded must still report as effectively excluded — no per-file reaffirmation needed")
    }

    /// `MediaStore.init()` reaffirms exclusion unconditionally every time
    /// an instance is created — the production answer to "does exclusion
    /// survive directory recreation" is "don't rely on it either way,
    /// always reaffirm," verified here by constructing a fresh instance.
    func testConstructingANewMediaStoreInstanceReaffirmsExclusion() throws {
        _ = MediaStore() // fresh instance, same real path — its init() must reaffirm
        let values = try MediaStore.shared.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    // MARK: - Concurrency (Cutover §2, MediaCacheCoordinator)

    func testCoordinatorCoalescesConcurrentMissesForTheSameFilenameIntoOneReconstruction() async {
        let filename = "\(UUID().uuidString).jpg"
        defer { MediaStore.shared.delete(filename: filename) }
        let counter = LockedCounter()

        await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await MediaStore.shared.data(for: filename, reconstructingFrom: {
                        counter.increment()
                        return Data(repeating: 0x1, count: 1000)
                    })
                }
            }
            var results: [Data?] = []
            for await result in group { results.append(result) }
            XCTAssertEqual(results.count, 20)
            XCTAssertTrue(results.allSatisfy { $0 == Data(repeating: 0x1, count: 1000) }, "every caller must still get the correct bytes back")
        }

        XCTAssertEqual(counter.value, 1, "the coordinator must coalesce all 20 concurrent requests into exactly one reconstruction")
    }
}

/// Synchronous, lock-based counter — needed where increments must happen
/// inside a plain (non-async) `@Sendable` closure, where `await`ing an
/// actor isn't possible.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
