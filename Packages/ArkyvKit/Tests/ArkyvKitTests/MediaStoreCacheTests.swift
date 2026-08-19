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
        // gracePeriod: 0 isolates pure LRU-ordering behavior from the
        // separate grace-period protection (tested on its own below).
        let (_, _) = MediaStore.shared.evictIfNeeded(capacityBytes: MediaStore.shared.totalBytesOnDisk() - 1, gracePeriod: 0)

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
            // All safely in the PAST (ascending, oldest first) — a future
            // modification date would never satisfy the real eviction
            // algorithm's age check (`now.timeIntervalSince(modified) >
            // gracePeriod`), which is correct/desired production
            // behavior, but would make this test's premise incoherent.
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(i) - 10)], ofItemAtPath: root.appendingPathComponent(name).path)
        }

        let cap: Int64 = 150_000
        MediaStore.shared.evictIfNeeded(capacityBytes: cap, gracePeriod: 0)

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

        let (_, _) = MediaStore.shared.evictIfNeeded(capacityBytes: MediaStore.shared.totalBytesOnDisk() - 1, gracePeriod: 0)

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(names[0]).path), "a recently-touched (re-accessed) file must survive eviction")
    }

    // MARK: - Grace period (Eviction Activation 01 §1/§7 — structural pre-save protection)

    func testAFileYoungerThanTheGracePeriodIsNeverEvictedEvenWhenItIsTheOldestCandidate() throws {
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("grace-period-\(UUID().uuidString)")
        let cache = MediaStore(isolatedRoot: cacheRoot)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        // Only ONE file — deliberately the "oldest" (only) candidate,
        // freshly written (age ~0s), cap set to force eviction.
        let filename = "\(UUID().uuidString).jpg"
        try Data(repeating: 0x1, count: Self.evictionTestFileSize).write(to: cacheRoot.appendingPathComponent(filename))

        let (evicted, _) = cache.evictIfNeeded(capacityBytes: 1, gracePeriod: 300)

        XCTAssertEqual(evicted, 0, "a file within the grace period must never be evicted, no matter how far over cap the cache is")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent(filename).path))
    }

    func testAFileOlderThanTheGracePeriodIsEvictedNormally() throws {
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("grace-period-\(UUID().uuidString)")
        let cache = MediaStore(isolatedRoot: cacheRoot)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let filename = "\(UUID().uuidString).jpg"
        try Data(repeating: 0x1, count: Self.evictionTestFileSize).write(to: cacheRoot.appendingPathComponent(filename))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -400)], ofItemAtPath: cacheRoot.appendingPathComponent(filename).path)

        let (evicted, _) = cache.evictIfNeeded(capacityBytes: 1, gracePeriod: 300)

        XCTAssertEqual(evicted, 1, "a file genuinely older than the grace period must evict normally once over cap")
    }

    // MARK: - Protected filenames (Eviction Activation 01 §1/§11 — legacy nil-imageData items)

    func testAProtectedFilenameIsNeverEvictedEvenWhenItIsTheOldestCandidate() throws {
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("protected-\(UUID().uuidString)")
        let cache = MediaStore(isolatedRoot: cacheRoot)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let protectedName = "\(UUID().uuidString).jpg"
        let ordinaryName = "\(UUID().uuidString).jpg"
        for (offset, name) in [(-500.0, protectedName), (-100.0, ordinaryName)] {
            try Data(repeating: 0x1, count: Self.evictionTestFileSize).write(to: cacheRoot.appendingPathComponent(name))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: offset)], ofItemAtPath: cacheRoot.appendingPathComponent(name).path)
        }

        // protectedName is the OLDER of the two — ordinary LRU would pick
        // it first. Protection must override that.
        let (evicted, _) = cache.evictIfNeeded(capacityBytes: 1, gracePeriod: 0, protecting: [protectedName])

        XCTAssertEqual(evicted, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent(protectedName).path), "a protected filename (item whose imageData isn't populated yet) must survive even as the oldest candidate")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent(ordinaryName).path), "the unprotected file must still be evicted normally")
    }

    func testProtectedFilenamesStillCountTowardCapacityAccounting() throws {
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("protected-accounting-\(UUID().uuidString)")
        let cache = MediaStore(isolatedRoot: cacheRoot)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let protectedName = "\(UUID().uuidString).jpg"
        try Data(repeating: 0x1, count: Self.evictionTestFileSize).write(to: cacheRoot.appendingPathComponent(protectedName))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -500)], ofItemAtPath: cacheRoot.appendingPathComponent(protectedName).path)

        // Cache is entirely one protected file, already over the (tiny)
        // cap — nothing CAN be evicted, but the scan must still see it.
        let (evicted, scanned) = cache.evictIfNeeded(capacityBytes: 1, gracePeriod: 0, protecting: [protectedName])

        XCTAssertEqual(evicted, 0)
        XCTAssertEqual(scanned, 1, "a protected file must still be scanned/counted, even though it's never a removal candidate")
    }

    // MARK: - Deletion-failure tolerance (Eviction Activation 01 §9)

    func testEvictionContinuesPastAFileItCannotDeleteAndOnlyCountsConfirmedRemovals() throws {
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("delete-failure-\(UUID().uuidString)")
        let cache = MediaStore(isolatedRoot: cacheRoot)
        let undeletableName = "\(UUID().uuidString).jpg"
        let deletableName = "\(UUID().uuidString).jpg"
        for (offset, name) in [(-500.0, undeletableName), (-400.0, deletableName)] {
            try Data(repeating: 0x1, count: Self.evictionTestFileSize).write(to: cacheRoot.appendingPathComponent(name))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: offset)], ofItemAtPath: cacheRoot.appendingPathComponent(name).path)
        }

        // Remove write permission on the directory itself — on POSIX
        // filesystems, unlinking an entry requires write permission on
        // its PARENT directory, not the file, so this makes EVERY
        // deletion inside `cacheRoot` genuinely fail, a real (not
        // simulated-in-name-only) FileManager deletion failure.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: cacheRoot.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cacheRoot.path)
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        let (evicted, scanned) = cache.evictIfNeeded(capacityBytes: 1, gracePeriod: 0)

        XCTAssertEqual(evicted, 0, "no deletion could actually succeed against a read-only directory — the count must reflect that honestly, not claim false success")
        XCTAssertEqual(scanned, 2)
        // Restore permissions before checking existence/cleanup.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cacheRoot.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent(undeletableName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent(deletableName).path), "neither file's logical/Cherry state changes just because the cache directory was temporarily unwritable — no crash, no partial corruption")
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

    /// Eviction Activation 01 §6: reads racing eviction must never see a
    /// partial file, crash, or corrupt result — the worst acceptable
    /// outcome is a clean cache miss followed by ordinary reconstruction.
    /// This is a genuine mixed-workload stress run (many concurrent
    /// readers, reconstructors, AND eviction passes, all against the same
    /// isolated store simultaneously), not a mocked/simulated race.
    /// Structurally, this is safe by construction: `data(for:)` reads via
    /// `Data(contentsOf:)`, and POSIX/APFS guarantee an already-open file
    /// descriptor keeps working even if the directory entry is unlinked
    /// concurrently (deletion only reclaims space once the last
    /// descriptor closes) — a race either reads the old complete bytes or
    /// gets `nil` (file gone before open), never a torn read. Reconstruction
    /// writes to a dot-prefixed staging file first (invisible to
    /// `.skipsHiddenFiles` enumeration) and only becomes the real filename
    /// via one atomic rename, so eviction can never observe or remove a
    /// partially-written file either.
    func testConcurrentReadsReconstructionsAndEvictionNeverCrashOrCorrupt() async throws {
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("concurrency-\(UUID().uuidString)")
        let cache = MediaStore(isolatedRoot: cacheRoot)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let itemCount = 15
        let payloads: [(filename: String, data: Data)] = (0..<itemCount).map { i in
            ("\(UUID().uuidString).jpg", Data(repeating: UInt8(i), count: Self.evictionTestFileSize))
        }
        // Pre-populate about half so both "warm read" and "cold reconstruct" paths are exercised.
        for (filename, data) in payloads.prefix(itemCount / 2) {
            try data.write(to: cacheRoot.appendingPathComponent(filename))
        }

        await withTaskGroup(of: Bool.self) { group in
            for (filename, data) in payloads {
                group.addTask {
                    let result = await cache.data(for: filename, reconstructingFrom: { data })
                    // Acceptable outcomes: correct bytes, or nil (a clean
                    // miss if evicted mid-race, immediately followed by
                    // a normal reconstruction below). Never anything else.
                    return result == nil || result == data
                }
            }
            // Concurrent eviction passes racing the reads/reconstructs above.
            for _ in 0..<5 {
                group.addTask {
                    _ = cache.evictIfNeeded(capacityBytes: Int64(Self.evictionTestFileSize) * 3, gracePeriod: 0)
                    return true
                }
            }
            var allAcceptable = true
            for await outcome in group { allAcceptable = allAcceptable && outcome }
            XCTAssertTrue(allAcceptable, "every concurrent read/reconstruct must return either correct bytes or a clean nil — never corrupt data")
        }

        // Final pass: everything must still be cleanly reconstructable —
        // proves no permanent corruption resulted from the race.
        for (filename, data) in payloads {
            let result = await cache.data(for: filename, reconstructingFrom: { data })
            XCTAssertEqual(result, data, "every item must remain cleanly reconstructable after the concurrent stress run")
        }
    }

    // MARK: - Directory recreation (Eviction Activation 01 §10)

    func testFullLifecycleWorksCorrectlyAfterDeletingAndRecreatingTheCacheDirectory() async throws {
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("recreate-\(UUID().uuidString)")
        var cache = MediaStore(isolatedRoot: cacheRoot)
        let filename = "\(UUID().uuidString).jpg"
        _ = await cache.data(for: filename, reconstructingFrom: { Data("original".utf8) })

        // Simulate a full external wipe of the cache directory (e.g. a
        // low-storage cleanup, or the isolated fixture being reset).
        try FileManager.default.removeItem(at: cacheRoot)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        // Recreate via a fresh instance — the exact shape any real
        // "MediaStore.shared access after the directory vanished"
        // scenario has, since `MediaStore` is a plain struct with no
        // persistent state beyond `root`.
        cache = MediaStore(isolatedRoot: cacheRoot)

        // Backup exclusion reapplied.
        let excluded = try cacheRoot.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true, "exclusion must be reapplied on recreation, not assumed to persist")

        // Reconstruction still works from a clean slate.
        let reconstructed = await cache.data(for: filename, reconstructingFrom: { Data("original".utf8) })
        XCTAssertEqual(reconstructed, Data("original".utf8))

        // Eviction/cap enforcement still works post-recreation.
        for i in 0..<5 {
            let name = "\(UUID().uuidString).jpg"
            _ = await cache.data(for: name, reconstructingFrom: { Data(repeating: UInt8(i), count: Self.evictionTestFileSize) })
        }
        let (evicted, _) = cache.evictIfNeeded(capacityBytes: Int64(Self.evictionTestFileSize) * 2, gracePeriod: 0)
        XCTAssertGreaterThan(evicted, 0, "cap enforcement must work normally on a recreated directory")
        XCTAssertLessThanOrEqual(cache.totalBytesOnDisk(), Int64(Self.evictionTestFileSize) * 2)
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
