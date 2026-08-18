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
    @discardableResult
    public func save(copyingFileAt sourceURL: URL, id: UUID = UUID(), ext: String = "jpg") throws -> String {
        let filename = "\(id.uuidString).\(ext)"
        try FileManager.default.copyItem(at: sourceURL, to: url(for: filename))
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
