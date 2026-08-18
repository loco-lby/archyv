import Foundation

#if DEBUG
/// Media Cache Foundation 01: an ISOLATED prototype of the disk-backed
/// cache design Option 2 (Media Storage Architecture 01) would require
/// `MediaStore` to become — bounded, LRU-ish, reconstructable-from-a-
/// source-of-truth. NOT wired into any production code path.
/// `MediaStore` itself is completely untouched by this file; nothing here
/// is reachable from a release build or any real capture/render call
/// site. Every use site in this codebase points this at a scratch/test
/// directory, never the real `Media/` directory.
///
/// Deliberately reuses `MediaStore`'s own proven shapes rather than
/// inventing new ones: the atomic-write-via-staging-file pattern
/// (Storage Foundation 01) and the "reconstruct only if missing, never
/// overwrite an existing file" contract (`data(for:restoringFrom:)`, D4).
public struct MediaCachePrototype: Sendable {
    public let root: URL
    public let capacityBytes: Int64

    public init(root: URL, capacityBytes: Int64) {
        self.root = root
        self.capacityBytes = capacityBytes
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func url(for filename: String) -> URL { root.appendingPathComponent(filename) }

    /// Section 5 (cache file identity): filenames are exactly `MediaStore`'s
    /// existing scheme (`StoredItem.localFilename`, already deterministic
    /// and already persisted) — no new identity scheme needed.
    ///
    /// Section 11 (disk pressure): if the reconstruction write fails (e.g.
    /// low disk), this still returns the freshly-reconstructed `Data` for
    /// the CALLER to render — a failed cache write must never prevent
    /// viewing a Cherry whose durable source is readable. Only the
    /// on-disk cache copy is missing; the caller already has the bytes.
    public func data(for filename: String, reconstructingFrom source: @autoclosure () -> Data?) -> Data? {
        if let existing = try? Data(contentsOf: url(for: filename)) {
            touch(filename)
            return existing
        }
        guard let fresh = source() else { return nil }
        let destination = url(for: filename)
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)")
        do {
            try fresh.write(to: staging, options: .atomic)
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            // Section 11's product rule: render anyway.
        }
        return fresh
    }

    /// Approximates recency via the filesystem's own modification date —
    /// Section 4's "avoid new metadata/schema" instruction. Best-effort;
    /// a failed touch just means this file is slightly less likely to
    /// survive the next eviction pass, never a correctness issue.
    private func touch(_ filename: String) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url(for: filename).path)
    }

    /// Single bounded pass, oldest-by-modification-date first, until
    /// under `capacityBytes` — no daemon, no background loop (Section 4).
    /// Safe to call from any thread/actor; pure filesystem work.
    @discardableResult
    public func evictIfNeeded() -> (evictedCount: Int, scannedCount: Int) {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }

        var files: [(url: URL, size: Int64, modified: Date)] = []
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? 0)
            files.append((fileURL, size, values.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > capacityBytes else { return (0, files.count) }

        var evicted = 0
        for file in files.sorted(by: { $0.modified < $1.modified }) {
            guard total > capacityBytes else { break }
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
            evicted += 1
        }
        return (evicted, files.count)
    }

    public func totalBytesOnDisk() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Section 6: the exact mechanism a real Option 2 migration would use
    /// to exclude the cache directory (never the durable `_EXTERNAL_DATA`
    /// representation) from device backup. Verified — see
    /// `MediaCachePrototypeTests` — that this does NOT need to be
    /// reaffirmed on every file added afterward: the OS enforces this at
    /// the directory level, at backup time, for the directory's contents
    /// including files added later.
    public func excludeFromBackup() {
        var mutableRoot = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableRoot.setResourceValues(values)
    }
}

/// Section 10 (concurrency): `MediaCachePrototype` itself has no locking —
/// two simultaneous callers requesting the same missing filename will both
/// reconstruct independently (demonstrated in
/// `testConcurrentMissesForTheSameFilenameDuplicateReconstructionWork`).
/// This actor coalesces concurrent requests for the SAME filename into a
/// single in-flight reconstruction, which every other caller awaits
/// instead of duplicating — the narrow mechanism Section 10 asks for,
/// validated but not wired into any production path.
public actor MediaCacheCoordinator {
    private let cache: MediaCachePrototype
    private var inFlight: [String: Task<Data?, Never>] = [:]

    public init(cache: MediaCachePrototype) {
        self.cache = cache
    }

    public func data(for filename: String, reconstructingFrom source: @escaping @Sendable () -> Data?) async -> Data? {
        if let existingTask = inFlight[filename] {
            return await existingTask.value
        }
        let task = Task<Data?, Never> { [cache] in
            cache.data(for: filename, reconstructingFrom: source())
        }
        inFlight[filename] = task
        let result = await task.value
        inFlight[filename] = nil
        return result
    }
}
#endif
