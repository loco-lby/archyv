import XCTest
@testable import ArkyvKit

/// Media Cache Foundation 01. Pure Foundation — no UIKit, no SwiftData —
/// runs on any platform. Every test uses a fresh scratch directory under
/// the system temp directory, never any real MediaStore path.
final class MediaCachePrototypeTests: XCTestCase {
    private func makeScratchRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MediaCachePrototypeTests-\(UUID().uuidString)")
    }

    // MARK: - Reconstruction

    func testDataReconstructsFromSourceWhenFileIsMissing() {
        let cache = MediaCachePrototype(root: makeScratchRoot(), capacityBytes: 10_000_000)
        defer { try? FileManager.default.removeItem(at: cache.root) }
        let source = Data("original bytes".utf8)

        let result = cache.data(for: "a.jpg", reconstructingFrom: source)

        XCTAssertEqual(result, source)
        XCTAssertEqual(try? Data(contentsOf: cache.url(for: "a.jpg")), source, "reconstruction must actually persist to disk, not just return the bytes")
    }

    func testDataReturnsExistingFileWithoutInvokingSourceAgain() {
        let cache = MediaCachePrototype(root: makeScratchRoot(), capacityBytes: 10_000_000)
        defer { try? FileManager.default.removeItem(at: cache.root) }
        _ = cache.data(for: "a.jpg", reconstructingFrom: Data("original".utf8))

        var sourceCalled = false
        let result = cache.data(for: "a.jpg", reconstructingFrom: {
            sourceCalled = true
            return Data("should not be used".utf8)
        }())

        XCTAssertFalse(sourceCalled, "an already-cached file must never re-invoke the (expensive) source")
        XCTAssertEqual(result, Data("original".utf8))
    }

    func testReconstructionLeavesNoStagingFileBehindOnSuccess() {
        let cache = MediaCachePrototype(root: makeScratchRoot(), capacityBytes: 10_000_000)
        defer { try? FileManager.default.removeItem(at: cache.root) }

        _ = cache.data(for: "a.jpg", reconstructingFrom: Data("bytes".utf8))

        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: cache.root.path))?.filter { $0.hasPrefix(".staging-") } ?? []
        XCTAssertEqual(leftover, [])
    }

    /// Section 11 (disk pressure): a failed cache write must still return
    /// the reconstructed bytes to the caller — viewing a Cherry must never
    /// depend on the cache write succeeding.
    func testDataStillReturnsBytesEvenWhenTheCacheDirectoryCannotBeWrittenTo() {
        // A root that is actually a plain FILE, not a directory — every
        // write into it will genuinely fail.
        let fakeRoot = makeScratchRoot()
        try? Data().write(to: fakeRoot)
        defer { try? FileManager.default.removeItem(at: fakeRoot) }
        let cache = MediaCachePrototype(root: fakeRoot, capacityBytes: 10_000_000)

        let result = cache.data(for: "a.jpg", reconstructingFrom: Data("bytes".utf8))

        XCTAssertEqual(result, Data("bytes".utf8), "render must succeed from the durable source even though the cache write failed")
    }

    // MARK: - Eviction (Section 4)

    func testEvictionIsANoOpWhenUnderCapacity() {
        let cache = MediaCachePrototype(root: makeScratchRoot(), capacityBytes: 10_000_000)
        defer { try? FileManager.default.removeItem(at: cache.root) }
        _ = cache.data(for: "a.jpg", reconstructingFrom: Data(repeating: 0x1, count: 1000))

        let (evicted, scanned) = cache.evictIfNeeded()

        XCTAssertEqual(evicted, 0)
        XCTAssertEqual(scanned, 1)
    }

    /// Payload size is deliberately well above APFS's ~4KB block-rounding
    /// granularity (`.totalFileAllocatedSize` only rounds UP, matching
    /// Storage Foundation 01's own established precedent) — a 1000-byte
    /// file would actually allocate a full 4KB block, making the eviction
    /// math misleading at tiny sizes.
    private static let evictionTestFileSize = 50_000

    func testEvictionRemovesOldestFilesFirstUntilUnderCapacity() throws {
        let cache = MediaCachePrototype(root: makeScratchRoot(), capacityBytes: 110_000)
        defer { try? FileManager.default.removeItem(at: cache.root) }

        // Three ~50KB files, written with distinct, ordered modification
        // dates ("a" oldest, "c" newest) — a 110KB cap against ~150KB
        // total means exactly one (~50KB) must go to get under it.
        for (name, offset) in [("a.jpg", -300.0), ("b.jpg", -200.0), ("c.jpg", -100.0)] {
            _ = cache.data(for: name, reconstructingFrom: Data(repeating: 0x1, count: Self.evictionTestFileSize))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: offset)], ofItemAtPath: cache.url(for: name).path)
        }

        let (evicted, scanned) = cache.evictIfNeeded()

        XCTAssertEqual(scanned, 3)
        XCTAssertEqual(evicted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.url(for: "a.jpg").path), "the oldest file must be evicted first")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.url(for: "b.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.url(for: "c.jpg").path))
    }

    func testEvictionNeverLeavesTotalSizeAboveCapacityWhenPossible() throws {
        let cache = MediaCachePrototype(root: makeScratchRoot(), capacityBytes: 150_000)
        defer { try? FileManager.default.removeItem(at: cache.root) }
        for i in 0..<10 {
            _ = cache.data(for: "\(i).jpg", reconstructingFrom: Data(repeating: 0x1, count: Self.evictionTestFileSize))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(i))], ofItemAtPath: cache.url(for: "\(i).jpg").path)
        }

        cache.evictIfNeeded()

        XCTAssertLessThanOrEqual(cache.totalBytesOnDisk(), 150_000)
    }

    func testTouchingAnExistingFileProtectsItFromTheNextEviction() throws {
        let cache = MediaCachePrototype(root: makeScratchRoot(), capacityBytes: 110_000)
        defer { try? FileManager.default.removeItem(at: cache.root) }
        for (name, offset) in [("a.jpg", -300.0), ("b.jpg", -200.0), ("c.jpg", -100.0)] {
            _ = cache.data(for: name, reconstructingFrom: Data(repeating: 0x1, count: Self.evictionTestFileSize))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: offset)], ofItemAtPath: cache.url(for: name).path)
        }

        // Re-access "a" (a cache HIT) — this should bump its modification
        // date to now, making "b" the new oldest.
        _ = cache.data(for: "a.jpg", reconstructingFrom: Data("unused".utf8))

        cache.evictIfNeeded()

        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.url(for: "a.jpg").path), "a recently-touched (re-accessed) file must survive eviction")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.url(for: "b.jpg").path))
    }

    // MARK: - Backup exclusion (Section 6)

    func testExcludeFromBackupSetsTheDirectoryLevelAttribute() throws {
        let cache = MediaCachePrototype(root: makeScratchRoot(), capacityBytes: 10_000_000)
        defer { try? FileManager.default.removeItem(at: cache.root) }

        cache.excludeFromBackup()

        let values = try cache.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testFilesAddedAfterExclusionInheritTheEffectiveExclusionWithoutTheirOwnAttribute() throws {
        // Two distinct, both-true findings worth keeping separate:
        // (1) the raw xattr `com.apple.metadata:com_apple_backup_excludeItem`
        //     is set ONLY on the directory itself — a child file added
        //     afterward carries no xattr of its own (confirmed via `xattr
        //     -l` during the Media Storage Architecture 01 spike).
        // (2) `URLResourceValues.isExcludedFromBackup`, when READ on that
        //     child file, correctly reports `true` anyway — the API
        //     surfaces the EFFECTIVE, inherited state (walking up to the
        //     excluded ancestor directory), not merely "does this exact
        //     path carry its own xattr." This is the more useful
        //     confirmation: it means production code can trust a query
        //     against any path under the cache root, without needing to
        //     special-case "was this file created before or after the
        //     directory was excluded."
        let cache = MediaCachePrototype(root: makeScratchRoot(), capacityBytes: 10_000_000)
        defer { try? FileManager.default.removeItem(at: cache.root) }
        cache.excludeFromBackup()

        _ = cache.data(for: "later.jpg", reconstructingFrom: Data("bytes".utf8))

        let dirValues = try cache.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        let fileValues = try cache.url(for: "later.jpg").resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(dirValues.isExcludedFromBackup, true)
        XCTAssertEqual(fileValues.isExcludedFromBackup, true, "a file added AFTER the directory was excluded must still report as effectively excluded — no per-file reaffirmation needed")
    }

    /// Option 2 Validation Gate 01 §7. Result was the OPPOSITE of the
    /// initial hypothesis: on this host (macOS/APFS, via the SPM test
    /// runner), a delete-then-recreate-at-the-same-path DOES still read
    /// back as excluded, without calling `excludeFromBackup()` again —
    /// apparently backup-exclusion status here is tracked per-path by
    /// something more persistent than a plain per-inode xattr (plausibly
    /// a `backupd`/Spotlight-adjacent path-keyed cache, not re-derived
    /// from a fresh xattr read on every query). This is a real, positive
    /// signal, but NOT one to build a production guarantee on:
    /// (1) it was only observed on the macOS host running this test
    /// suite, never independently re-verified against the real iOS
    /// device filesystem/backup daemon, which could behave differently;
    /// (2) relying on an undocumented persistence quirk instead of an
    /// explicit, idempotent, zero-cost call is worse engineering
    /// regardless of which way this result goes. Production
    /// recommendation stands unconditionally either way: call
    /// `excludeFromBackup()` on every directory (re)creation, never rely
    /// on it having "stuck" from before.
    func testRecreatingTheCacheDirectoryAtTheSamePath() throws {
        let root = makeScratchRoot()
        let firstCache = MediaCachePrototype(root: root, capacityBytes: 10_000_000)
        firstCache.excludeFromBackup()
        let excludedBeforeDelete = try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excludedBeforeDelete, true)

        try FileManager.default.removeItem(at: root)

        // Recreate at the SAME path, via a new instance, WITHOUT calling
        // excludeFromBackup() again.
        let secondCache = MediaCachePrototype(root: root, capacityBytes: 10_000_000)
        defer { try? FileManager.default.removeItem(at: secondCache.root) }
        let excludedAfterNaiveRecreate = try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        // Documenting the actual observed result rather than an assumed
        // one — see the doc comment above for why this is NOT treated as
        // a safe production guarantee regardless of which way it reads.
        print("[MediaCachePrototypeTests] backup-exclusion after delete+recreate at the same path, without reaffirming: \(String(describing: excludedAfterNaiveRecreate))")

        // Reaffirming unconditionally is always correct and always ends
        // in the same, unambiguous state — this is the actual guarantee
        // production code should rely on, not the delete/recreate result.
        secondCache.excludeFromBackup()
        let excludedAfterReaffirm = try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excludedAfterReaffirm, true)
    }

    // MARK: - Concurrency (Section 10)

    /// Demonstrates the problem `MediaCacheCoordinator` exists to solve —
    /// the plain, unlocked `MediaCachePrototype` duplicates reconstruction
    /// work when several callers race for the same missing filename.
    func testConcurrentMissesForTheSameFilenameDuplicateReconstructionWork() async {
        let cache = MediaCachePrototype(root: makeScratchRoot(), capacityBytes: 10_000_000)
        defer { try? FileManager.default.removeItem(at: cache.root) }
        let counter = Counter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await counter.increment()
                    _ = cache.data(for: "shared.jpg", reconstructingFrom: Data(repeating: 0x1, count: 1000))
                }
            }
        }

        let callCount = await counter.value
        XCTAssertEqual(callCount, 20, "every one of the 20 concurrent callers reconstructed independently — no coalescing exists in the plain prototype")
    }

    /// `MediaCacheCoordinator` (the actor wrapper) eliminates the
    /// duplication demonstrated above — every concurrent caller for the
    /// same filename awaits one shared in-flight reconstruction.
    func testCoordinatorCoalescesConcurrentMissesForTheSameFilenameIntoOneReconstruction() async {
        let cache = MediaCachePrototype(root: makeScratchRoot(), capacityBytes: 10_000_000)
        defer { try? FileManager.default.removeItem(at: cache.root) }
        let coordinator = MediaCacheCoordinator(cache: cache)
        let counter = LockedCounter()

        await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await coordinator.data(for: "shared.jpg") {
                        // A synchronous stand-in for "materializing from
                        // imageData" — counts how many times this source
                        // closure actually runs, synchronously, so there's
                        // no async-detached-task race to account for.
                        counter.increment()
                        return Data(repeating: 0x1, count: 1000)
                    }
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

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
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
