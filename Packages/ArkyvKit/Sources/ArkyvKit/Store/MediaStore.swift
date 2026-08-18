import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Stores capture image bytes on disk (App Group container) so media is fully
/// available offline. Remote Storage upload (Phase 2) references the same
/// bytes by `localFilename`.
public struct MediaStore: Sendable {
    public static let shared = MediaStore()

    /// The directory every filename from `url(for:)` lives in — exposed
    /// (read-only) for `IntegrityCheck`'s orphan scan, which needs to
    /// enumerate what's actually on disk rather than look up one known
    /// filename at a time.
    public var root: URL { AppGroup.containerURL.appendingPathComponent("Media", isDirectory: true) }

    public init() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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

    /// D4: reads `filename` from disk, materializing it first from
    /// `fallbackData` if the file doesn't exist locally yet — the
    /// situation a CloudKit-restored `StoredItem` is in on a fresh
    /// device: its `imageData` synced correctly, but `MediaStore` itself
    /// (a plain local file, never synced by CloudKit) never had this file
    /// written on this device. Once materialized, the file exists exactly
    /// as if `MediaStore` had written it at capture time — a one-time,
    /// self-healing write; every subsequent read for the same filename
    /// hits `data(for:)` above with no fallback involved.
    ///
    /// Never overwrites an existing file — the plain `data(for:)` lookup
    /// is tried first, and `fallbackData` is only ever used when that
    /// comes back nil.
    public func data(for filename: String, restoringFrom fallbackData: Data?) -> Data? {
        if let existing = data(for: filename) { return existing }
        guard let fallbackData else { return nil }
        try? fallbackData.write(to: url(for: filename), options: .atomic)
        return fallbackData
    }

    public func delete(filename: String) {
        try? FileManager.default.removeItem(at: url(for: filename))
    }

    /// Storage/Disk Pressure Foundation 01 (Phase 9): approximate total
    /// bytes currently on disk in this directory — a plain `FileManager`
    /// enumeration summing each file's allocated size via
    /// `.totalFileAllocatedSizeKey` (actual disk blocks used, not the
    /// logical byte count, so this reflects real footprint). Diagnostic/
    /// test use only — nothing in the app surfaces this to a user. O(file
    /// count): cheap relative to a typical archive's file count, but not
    /// free, so callers should compute on demand, never at launch.
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
