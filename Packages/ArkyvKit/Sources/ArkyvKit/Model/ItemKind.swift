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
