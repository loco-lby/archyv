import Foundation
import CoreGraphics

/// An in-flight capture awaiting a folder. Produced by the screenshot
/// observer, the Share Extension, the Action Button shortcut, or the quick
/// text field, then filed by `Repository.fileCapture`.
public struct CaptureDraft: Identifiable, Sendable {
    public let id: UUID
    public var kind: ItemKind
    /// Local media filename (already written to MediaStore) for image kinds.
    public var localFilename: String?
    public var pixelSize: CGSize?
    public var ocrText: String?
    public var noteBody: String?
    public var title: String?
    public var sourceURL: String?
    public var tags: [String]
    public var sourceDevice: SourcePlatform
    /// The user's point of view into `localFilename`'s original pixels —
    /// see `CropRegion`. Defaults to `.fullImage`, so a draft that never
    /// sets this behaves exactly as every capture does today: the whole
    /// screenshot, unchanged. Not yet set by any producer (`ScreenshotDetector`,
    /// the Share Extension, the "+" flow) — this is persistence plumbing
    /// only; a future crop UI would set this before the draft is filed.
    public var cropRegion: CropRegion

    public init(
        id: UUID = UUID(),
        kind: ItemKind,
        localFilename: String? = nil,
        pixelSize: CGSize? = nil,
        ocrText: String? = nil,
        noteBody: String? = nil,
        title: String? = nil,
        sourceURL: String? = nil,
        tags: [String] = [],
        sourceDevice: SourcePlatform = .unknown,
        cropRegion: CropRegion = .fullImage
    ) {
        self.id = id
        self.kind = kind
        self.localFilename = localFilename
        self.pixelSize = pixelSize
        self.ocrText = ocrText
        self.noteBody = noteBody
        self.title = title
        self.sourceURL = sourceURL
        self.tags = tags
        self.sourceDevice = sourceDevice
        self.cropRegion = cropRegion
    }

    /// A text/note draft from the quick-capture field.
    public static func note(_ body: String, sourceDevice: SourcePlatform = .iOS) -> CaptureDraft {
        CaptureDraft(kind: .note, noteBody: body, sourceDevice: sourceDevice)
    }
}
