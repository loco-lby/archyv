import Foundation

/// The `type` column on `items`: screenshot | image | note | text.
public enum ItemKind: String, Codable, CaseIterable, Sendable {
    case screenshot
    case image
    case note
    case text

    public var isMedia: Bool { self == .screenshot || self == .image }
    public var isTextual: Bool { self == .note || self == .text }
}

/// Which device produced a capture — informs the "source" chip and sync.
public enum SourcePlatform: String, Codable, Sendable {
    case iOS
    case macOS
    case unknown
}

/// Provenance Foundation 01: "how did this item enter Cherries?" — a
/// question distinct from `ItemKind` ("what kind of stored object is
/// this?"). Deliberately scoped to ACQUISITION MECHANISM only, never to
/// source family (Instagram/Pinterest/Spotify/etc. — that stays derived
/// from `sourceURL` at read time, see `LinkCherryContext`) and never to
/// future public-eligibility policy. See Provenance Foundation Recon
/// 01's "Model A" for the evidence this was built from.
///
/// `.unknown` is the CloudKit-required inline default for every
/// pre-existing record — it means "we genuinely don't know," primarily
/// legacy/migrated items, never a fallback for a new capture whose
/// mechanism is actually known. No current producer should construct a
/// new `StoredItem`/`CaptureDraft` as `.unknown` on purpose.
public enum AcquisitionOrigin: String, Codable, Sendable {
    /// Native OS screenshot detection AND the Action Button/Shortcuts
    /// bridge — both already the same `ScreenshotDetector` code path
    /// today, so they share one case rather than two indistinguishable
    /// ones.
    case actionCapture
    /// The "+" / `PhotosPicker` Camera Roll import path.
    case photoLibraryImport
    /// Anything that entered through the Share Extension — a raw image
    /// payload, a `public.url`, or a recognized `public.plain-text` URL
    /// alike. Deliberately ONE case, not three: the recon found no
    /// current need to distinguish share sub-shapes here, since
    /// `sourceURL`'s presence already tells that story when relevant.
    case shareExtension
    case unknown
}
