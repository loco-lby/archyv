import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Stores capture image bytes on disk (App Group container) so media is fully
/// available offline. Remote Storage upload (Phase 2) references the same
/// bytes by `localFilename`.
public struct MediaStore: Sendable {
    public static let shared = MediaStore()

    private var root: URL { AppGroup.containerURL.appendingPathComponent("Media", isDirectory: true) }

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
