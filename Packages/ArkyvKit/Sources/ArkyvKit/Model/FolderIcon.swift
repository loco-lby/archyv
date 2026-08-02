import Foundation

/// A folder's icon. Stored as a short token string in the `folders.icon`
/// column. We support two forms so users can pick an emoji later while the
/// seeded folders use crisp SF Symbols that match the Figma set:
///   - `sf:star`     → SF Symbol "star"
///   - `emoji:🔥`    → literal emoji
public struct FolderIcon: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case symbol, emoji }
    public var kind: Kind
    public var value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    public static func symbol(_ name: String) -> FolderIcon { .init(kind: .symbol, value: name) }
    public static func emoji(_ char: String) -> FolderIcon { .init(kind: .emoji, value: char) }

    /// Encoded token stored in the DB.
    public var token: String {
        switch kind {
        case .symbol: return "sf:\(value)"
        case .emoji: return "emoji:\(value)"
        }
    }

    public init(token: String) {
        if token.hasPrefix("sf:") {
            self = .symbol(String(token.dropFirst(3)))
        } else if token.hasPrefix("emoji:") {
            self = .emoji(String(token.dropFirst(6)))
        } else if token.count <= 2 {
            self = .emoji(token) // bare emoji
        } else {
            self = .symbol(token) // bare symbol name
        }
    }

    public static let `default` = FolderIcon.symbol("folder")

    /// SF Symbols matching the Figma folder icons, offered in the icon picker.
    public static let palette: [FolderIcon] = [
        .symbol("star"), .symbol("face.smiling"), .symbol("fork.knife"),
        .symbol("airplane"), .symbol("paintpalette"), .symbol("heart"),
        .symbol("bolt"), .symbol("camera"), .symbol("book"),
        .symbol("music.note"), .symbol("cart"), .symbol("tshirt"),
        .symbol("house"), .symbol("map"), .symbol("lightbulb"),
        .symbol("flame"), .symbol("leaf"), .symbol("gamecontroller"),
    ]
}
