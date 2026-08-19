import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Media Architecture Cutover 01: `MediaStore` is a **derived, disposable
/// local working cache** — not the authoritative original. The declared
/// media contract, in full:
///
/// - **Authoritative durable local media:** `StoredItem.imageData`
///   (`@Attribute(.externalStorage)`). Populated synchronously inside
///   `Repository.fileCapture`, the same moment `MediaStore`'s file is
///   written — see the authority-transition note below.
/// - **Remote durable media:** the private CloudKit database, via the
///   CKAsset SwiftData's CloudKit integration mirrors from `imageData`.
///   Entirely framework-managed; nothing in this file talks to CloudKit.
/// - **Derived local working cache:** `MediaStore`, this type. Bounded,
///   purgeable, reconstructable byte-for-byte from `imageData` at any
///   time, and excluded from device backup (`excludeFromBackup()`) — the
///   durable copy backup protects is `imageData`/`_EXTERNAL_DATA`, never
///   this directory.
///
/// **The authority transition, precisely:** every capture surface writes
/// to `MediaStore` *first* (staging the file before a `StoredItem` even
/// exists), then `Repository.fileCapture` reads that file back into
/// `imageData` in the same synchronous call that inserts and saves the
/// `StoredItem`. BEFORE that `save()` succeeds, `MediaStore`'s
/// just-written file may be the sole local copy — draft/staging cleanup
/// (`ScreenshotCaptureFlowView`, `ShareViewController`, `CaptureSheetView`)
/// still treats it as such and remains unchanged. The INSTANT that
/// `save()` returns successfully, `imageData` is durable (SQLite's own
/// ACID commit) and `MediaStore`'s file becomes redundant cache — still
/// useful for fast reads, no longer required for correctness. Capture
/// ordering itself is unchanged; only what happens to `MediaStore`'s file
/// *afterward* (eviction-eligible vs. permanent) has changed.
///
/// This was validated empirically, not assumed — see Option 2 Validation
/// Gate 01's two-device test: a `StoredItem` never became query-visible
/// on a receiving device without `imageData` already being fully present,
/// byte-readable, and decodable.
public struct MediaStore: Sendable {
    public static let shared = MediaStore()

    /// Media Cache Foundation 01 §6 / Cutover §6: 1GB fixed default.
    /// Deliberately not adaptive/proportional — at a blended ~800KB-1.6MB
    /// per item, this comfortably covers 640-1,300+ recently-used
    /// originals, far beyond any realistic single review session's
    /// working set, and cold full-resolution reconstruction measured
    /// ~8ms on a physical device (Media Cache Foundation 01). One clear
    /// constant, not a policy engine.
    public static let cacheCapacityBytes: Int64 = 1_073_741_824

    /// **Ramp closed (Media Cache Eviction Activation 01), enabled
    /// deliberately, not by default.** The Media Architecture Cutover 01
    /// ramp held this `false` for one release specifically to let
    /// reconstruction accumulate real production runtime before deletion
    /// went live. This milestone's own deletion-contract audit then found
    /// — and fixed — two real structural gaps eviction had before this
    /// flag could safely flip: (1) no protection against evicting a very
    /// recently staged, not-yet-saved capture (`evictionGracePeriod`,
    /// below — structural, not timing-luck), and (2) no protection
    /// against evicting a historical/pre-`ImageBackfill` item's `imageData`-
    /// still-nil sole local copy (`Repository.filenamesLackingImageData()`,
    /// threaded through as `evictIfNeeded(protecting:)` at the one
    /// production call site with SwiftData access, `RootView`). Both are
    /// unit-tested; the full mixed concurrent-read/reconstruct/evict
    /// stress path, deletion-failure tolerance, directory recreation, and
    /// real-device performance (135ms scan+trim at a realistic ~1,500-
    /// file scale, entirely off the main actor) all passed. `true` here
    /// is the production decision this milestone exists to make.
    public static let evictionEnabled = true

    /// Media Cache Eviction Activation 01 §1/§7: a file younger than this
    /// is NEVER eviction-eligible, regardless of cache size or how it
    /// sorts by recency. This is the **structural** (not timing-luck)
    /// protection against the pre-save/authority-transition window: a
    /// freshly-staged capture file has no `StoredItem`/`imageData` yet,
    /// and eviction has no way to know that from the filesystem alone —
    /// its modification date being "recent" was already almost always
    /// enough to protect it in practice (freshly-written files sort last
    /// for removal), but "almost always" is exactly the "timing luck"
    /// this milestone's own audit was asked to rule out. Comfortably
    /// longer than any realistic capture-to-save latency, including a
    /// careful crop-review session before tapping ✓.
    public static let evictionGracePeriod: TimeInterval = 300


    /// The directory every filename from `url(for:)` lives in — exposed
    /// (read-only) for `IntegrityCheck`'s orphan scan, which needs to
    /// enumerate what's actually on disk rather than look up one known
    /// filename at a time. Defaults to the real App Group `Media/`
    /// directory; overridable ONLY via `init(isolatedRoot:)`, which every
    /// production call site (`MediaStore.shared`, every bare `MediaStore()`)
    /// deliberately never uses — see that initializer's doc comment.
    public let root: URL

    public init() {
        self.root = AppGroup.containerURL.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Reaffirmed on every init, not assumed to persist across a
        // delete+recreate of this directory (Option 2 Validation Gate
        // 01 §7's directory-recreation test found this survives on at
        // least one platform/filesystem combination, but that was never
        // treated as a guarantee to build on — this call is cheap,
        // idempotent, and unconditional).
        excludeFromBackup()
    }

    /// **Test/diagnostic-only isolation seam.** Every real code path
    /// (`MediaStore.shared`, any bare `MediaStore()`) uses the real App
    /// Group directory via `init()` above — this exists solely so
    /// on-device stress tools and tests can exercise the exact same
    /// cache/reconstruction/eviction logic against a throwaway scratch
    /// directory instead, without ever touching real user media. Not
    /// `#if DEBUG` (release builds can still construct one harmlessly —
    /// it's just a struct pointed at a URL — but nothing in this
    /// codebase's release configuration ever calls it).
    public init(isolatedRoot: URL) {
        self.root = isolatedRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        excludeFromBackup()
    }

    public func url(for filename: String) -> URL {
        root.appendingPathComponent(filename)
    }

    /// Persists raw image data and returns the generated filename.
    @discardableResult
    public func save(data: Data, id: UUID = UUID(), ext: String = "jpg") throws -> String {
        let filename = "\(id.uuidString).\(ext)"
        try data.write(to: url(for: filename), options: .atomic)
        return filename
    }

    public func data(for filename: String) -> Data? {
        try? Data(contentsOf: url(for: filename))
    }

    /// Copies an already-encoded file straight into `MediaStore` — never
    /// materializes its bytes as an in-memory `Data` buffer at all.
    /// Share/Capture Reliability Foundation 01: the preferred write path
    /// whenever the source is already file-backed and already in a
    /// format `MediaStore` can store as-is (see `ShareViewController`'s
    /// already-JPEG fast path) — for a large photo, this is the
    /// difference between a filesystem copy and materializing a full
    /// decoded bitmap (which `save(image:)` below requires) just to
    /// re-encode the same bytes back into the same format they already
    /// were.
    ///
    /// Storage/Disk Pressure Foundation 01: copies to a temporary sibling
    /// in this same directory first, then atomically moves it into
    /// place — unlike `save(data:)` above (which gets atomicity for free
    /// from `Data.write(options: .atomic)`), a bare
    /// `FileManager.copyItem(at:to:)` writes directly to the destination
    /// path with no such guarantee. A process kill or disk-full error
    /// partway through that direct copy could otherwise leave a
    /// truncated file sitting at the exact filename a `StoredItem` is
    /// about to reference as its original — this closes that gap. The
    /// temporary file and the destination are on the same volume (same
    /// directory), so the final move is a single atomic rename, not a
    /// slow second copy.
    @discardableResult
    public func save(copyingFileAt sourceURL: URL, id: UUID = UUID(), ext: String = "jpg") throws -> String {
        let filename = "\(id.uuidString).\(ext)"
        let destination = url(for: filename)
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: sourceURL, to: staging)
        do {
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return filename
    }

    /// The routine cold-cache-miss path — NOT emergency repair. Under the
    /// declared media contract, a missing `MediaStore` file is ordinary:
    /// it means this cache entry was never written or has been evicted,
    /// nothing more. Reconstructs byte-for-byte from `source` (typically
    /// `item.imageData`) through `MediaCacheCoordinator`, which coalesces
    /// concurrent requests for the same filename into a single
    /// reconstruction (Media Cache Foundation 01 §10 — demonstrated, not
    /// hypothetical: the uncoalesced path really does duplicate work
    /// under concurrent misses).
    ///
    /// Never overwrites an existing file — the plain `data(for:)` lookup
    /// is tried first, and `source` is only ever invoked when that comes
    /// back nil.
    ///
    /// If the reconstruction write itself fails (e.g. low disk), this
    /// still returns the freshly-reconstructed bytes — a failed cache
    /// write must never prevent viewing a Cherry whose durable source
    /// (`imageData`) is readable; only the on-disk cache copy is
    /// missing, not the Cherry. Callers wanting a THUMBNAIL should NOT
    /// call this — decode directly from `source`'s bytes instead (see
    /// `LocalImageView`) so a cold Archive scroll never materializes full
    /// originals merely to render small tiles.
    ///
    /// Must be called off the main actor — this performs synchronous
    /// disk I/O before ever reaching `MediaCacheCoordinator`.
    public func data(for filename: String, reconstructingFrom source: @escaping @Sendable () -> Data?) async -> Data? {
        if let existing = data(for: filename) {
            touch(filename)
            return existing
        }
        return await MediaCacheCoordinator.shared.data(for: filename, store: self, reconstructingFrom: source)
    }

    /// The actual reconstruction write — called only from
    /// `MediaCacheCoordinator`, which guarantees at most one concurrent
    /// call per filename. Re-checks existence first (a different
    /// filename's coordination can't race this specific one, but this
    /// keeps the "never overwrite" contract explicit and cheap to verify
    /// even if called some other way in the future).
    func reconstruct(filename: String, from source: @Sendable () -> Data?) -> Data? {
        if let existing = data(for: filename) { return existing }
        guard let fresh = source() else { return nil }
        let destination = url(for: filename)
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)")
        do {
            try fresh.write(to: staging, options: .atomic)
            try FileManager.default.moveItem(at: staging, to: destination)
            // Media Cache Eviction Activation 01: deliberately does NOT
            // trigger eviction here. `MediaStore` has no SwiftData access
            // at this call site, so it can't compute the "items whose
            // imageData is still nil" protected set — evicting without
            // that protection risks deleting the sole local copy of a
            // historical, not-yet-backfilled item. The once-per-
            // foreground-activation trigger (`RootView`), which DOES have
            // SwiftData access, is the only production eviction entry
            // point — see its own call site for the protected-filenames
            // computation.
        } catch {
            try? FileManager.default.removeItem(at: staging)
            // Product rule: render anyway. Only the cache write failed;
            // the durable source (`imageData`) is untouched.
        }
        return fresh
    }

    /// Approximates recency via the filesystem's own modification date —
    /// no new metadata/schema, per Media Cache Foundation 01 §4. A
    /// best-effort touch; failure just means this file is slightly more
    /// eviction-eligible next pass, never a correctness issue.
    private func touch(_ filename: String) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url(for: filename).path)
    }

    public func delete(filename: String) {
        try? FileManager.default.removeItem(at: url(for: filename))
    }

    /// Single bounded pass, oldest-by-modification-date first, until
    /// under `capacityBytes` (defaults to the real production
    /// `MediaStore.cacheCapacityBytes`) — no daemon, no perpetual
    /// background worker (Media Cache Foundation 01 §4). The ONLY
    /// production trigger is once per foreground activation (`RootView`'s
    /// `scenePhase` hook, mirroring `ImageBackfill`/`SeedGate`'s existing
    /// pattern) — see that call site for why the post-write trigger this
    /// used to also have was removed. Safe to call from any thread/actor
    /// — pure filesystem work, no main-actor requirement.
    ///
    /// Two independent, structural (not timing-based) protections, per
    /// Media Cache Eviction Activation 01's deletion-contract audit:
    /// - `protecting`: filenames that must never be removed regardless of
    ///   age or cache pressure — the caller-computed set of items whose
    ///   `imageData` isn't populated yet, for which this file is (for
    ///   now) the ONLY local copy, not a cache entry. Still counts toward
    ///   `capacityBytes` accounting (it's real disk usage), just never a
    ///   removal candidate.
    /// - `evictionGracePeriod`: no file younger than this is ever a
    ///   removal candidate either, regardless of `protecting` — see that
    ///   constant's own doc comment.
    ///
    /// `capacityBytes`/`gracePeriod` are parameters (not just the
    /// hardcoded constants) solely so tests can exercise real eviction-
    /// ordering/protection behavior with small files and without waiting
    /// 5 real minutes — every production call site omits both, using the
    /// two real constants.
    @discardableResult
    public func evictIfNeeded(capacityBytes: Int64 = MediaStore.cacheCapacityBytes, gracePeriod: TimeInterval = MediaStore.evictionGracePeriod, protecting protectedFilenames: Set<String> = []) -> (evictedCount: Int, scannedCount: Int) {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }

        let now = Date()
        var candidates: [(url: URL, size: Int64, modified: Date)] = []
        var total: Int64 = 0
        var scanned = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? 0)
            total += size
            scanned += 1
            guard !protectedFilenames.contains(fileURL.lastPathComponent) else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) > gracePeriod else { continue }
            candidates.append((fileURL, size, modified))
        }
        guard total > capacityBytes else { return (0, scanned) }

        var evicted = 0
        for file in candidates.sorted(by: { $0.modified < $1.modified }) {
            guard total > capacityBytes else { break }
            do {
                try FileManager.default.removeItem(at: file.url)
                // Only decremented on CONFIRMED removal — Cutover
                // Activation 01 §9: a silently-failed deletion must never
                // be counted as if it succeeded, which could otherwise
                // make this loop stop early while genuinely still over
                // cap. Self-correcting either way: a failed removal here
                // just leaves that file to be reconsidered, accurately,
                // on the next opportunistic pass.
                total -= file.size
                evicted += 1
            } catch {
                continue
            }
        }
        return (evicted, scanned)
    }

    /// Storage/Disk Pressure Foundation 01 (Phase 9): approximate total
    /// bytes currently on disk in this directory — a plain `FileManager`
    /// enumeration summing each file's allocated size via
    /// `.totalFileAllocatedSizeKey` (actual disk blocks used, not the
    /// logical byte count, so this reflects real footprint). Diagnostic/
    /// test use only — nothing in the app surfaces this to a user. O(file
    /// count): cheap relative to a typical archive's file count, but not
    /// free, so callers should compute on demand, never at launch.
    ///
    /// Under the cache contract, this now reflects current CACHE
    /// footprint (bounded by `cacheCapacityBytes`), not total archive
    /// media footprint — that distinction matters if this is ever
    /// surfaced in a future storage-usage UI.
    public func totalBytesOnDisk() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Excludes this directory from normal device backup (Finder/iTunes
    /// local backup and iCloud device backup both honor this — it is not
    /// iCloud-specific). Safe/idempotent to call repeatedly. Only ever
    /// applied to this derived cache directory — `StoredItem.imageData`'s
    /// `_EXTERNAL_DATA` representation and the SwiftData store itself are
    /// never touched by this or anything else in this file, and must stay
    /// backup-eligible (they're the actual durable copy).
    public func excludeFromBackup() {
        var mutableRoot = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableRoot.setResourceValues(values)
    }

    #if canImport(UIKit)
    /// Saves a UIImage as JPEG and returns (filename, pixel size).
    public func save(image: UIImage, id: UUID = UUID(), quality: CGFloat = 0.9) throws -> (filename: String, size: CGSize) {
        guard let data = image.jpegData(compressionQuality: quality) else {
            throw MediaError.encodingFailed
        }
        let name = try save(data: data, id: id, ext: "jpg")
        return (name, image.size)
    }
    #endif

    public enum MediaError: Error { case encodingFailed }
}
