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
    /// Provenance Foundation 01: how this draft's mechanism of entry into
    /// Cherries is known at the moment of capture — see
    /// `AcquisitionOrigin`'s own doc comment. Defaults to `.unknown` only
    /// for callers that genuinely don't have a stronger truth to state
    /// (debug/test harnesses); every real producer (`ScreenshotDetector`,
    /// `CaptureSheetView`, `ShareViewController`) sets this explicitly.
    public var acquisitionOrigin: AcquisitionOrigin
    /// Editorial Cover V1: `true` only when `URLCherryResolver` found a
    /// real, standards-based article signal (schema.org `Article`/
    /// `NewsArticle`/`BlogPosting` JSON-LD, or an `og:type="article"`
    /// fallback) for this capture's `sourceURL` — see
    /// `EditorialArticleDetector`. Never inferred from merely having a
    /// `sourceURL` + `title`, never a domain allowlist. Defaults to
    /// `false` so every non-URL draft producer (screenshots, Photos
    /// import, notes) needs no change.
    public var isEditorial: Bool
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
        cropRegion: CropRegion = .fullImage,
        isEditorial: Bool = false,
        acquisitionOrigin: AcquisitionOrigin = .unknown
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
        self.isEditorial = isEditorial
        self.acquisitionOrigin = acquisitionOrigin
    }

    /// A text/note draft from the quick-capture field. Provenance
    /// Foundation Recon 01 found no current live call site for this
    /// helper — every real `.note`-kind draft today is actually produced
    /// inside `ShareViewController`'s own fallback branches, which set
    /// `.shareExtension` directly rather than going through here. Kept at
    /// `.unknown` rather than guessing a mechanism this unused helper has
    /// never actually had.
    public static func note(_ body: String, sourceDevice: SourcePlatform = .iOS, acquisitionOrigin: AcquisitionOrigin = .unknown) -> CaptureDraft {
        CaptureDraft(kind: .note, noteBody: body, sourceDevice: sourceDevice, acquisitionOrigin: acquisitionOrigin)
    }
}
