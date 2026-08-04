import Foundation

/// A folder's icon. Stored as a short token string in the `folders.icon`
/// column. Three forms:
///   - `glyph:star`  → a Design System geometric `FolderGlyph` (the default,
///                     on-brand set — star/triangle/circle/diamond/cross)
///   - `sf:star`     → SF Symbol "star" (legacy; existing stored folders)
///   - `emoji:🔥`    → literal emoji (future user picker)
public struct FolderIcon: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case symbol, emoji, glyph }
    public var kind: Kind
    public var value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    public static func symbol(_ name: String) -> FolderIcon { .init(kind: .symbol, value: name) }
    public static func emoji(_ char: String) -> FolderIcon { .init(kind: .emoji, value: char) }
    public static func glyph(_ glyph: FolderGlyph) -> FolderIcon { .init(kind: .glyph, value: glyph.rawValue) }

    /// Encoded token stored in the DB.
    public var token: String {
        switch kind {
        case .symbol: return "sf:\(value)"
        case .emoji: return "emoji:\(value)"
        case .glyph: return "glyph:\(value)"
        }
    }

    public init(token: String) {
        if token.hasPrefix("glyph:") {
            self = .init(kind: .glyph, value: String(token.dropFirst(6)))
        } else if token.hasPrefix("sf:") {
            self = .symbol(String(token.dropFirst(3)))
        } else if token.hasPrefix("emoji:") {
            self = .emoji(String(token.dropFirst(6)))
        } else if token.count <= 2 {
            self = .emoji(token) // bare emoji
        } else {
            self = .symbol(token) // bare symbol name
        }
    }

    public static let `default` = FolderIcon.glyph(.star)

    /// The Design System's geometric folder-category set, offered in the
    /// icon picker.
    public static let palette: [FolderIcon] = FolderGlyph.allCases.map(FolderIcon.glyph)
}
