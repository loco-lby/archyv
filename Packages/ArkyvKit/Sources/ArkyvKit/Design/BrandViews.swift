import SwiftUI

/// Shared, platform-agnostic brand + icon views used by the iOS app, the Share
/// Extension, and the macOS app. Asset images resolve from the hosting target's
/// bundle (each app/extension bundles `Assets.xcassets`).

/// Renders a `FolderIcon` as a Design System geometric glyph, an SF Symbol
/// (legacy), or an emoji.
public struct FolderIconView: View {
    let icon: FolderIcon
    var size: CGFloat
    var color: Color

    public init(icon: FolderIcon, size: CGFloat = 18, color: Color = ArkyvColor.textPrimary) {
        self.icon = icon
        self.size = size
        self.color = color
    }

    public var body: some View {
        switch icon.kind {
        case .glyph:
            let glyph = FolderGlyph(rawValue: icon.value) ?? .star
            FolderGlyphView(glyph: glyph, size: size, color: color)
                .frame(width: size + 2, height: size + 2)
        case .symbol:
            Image(systemName: icon.value)
                .font(.system(size: size))
                .foregroundStyle(color)
                .frame(width: size + 2, height: size + 2)
        case .emoji:
            Text(icon.value)
                .font(.system(size: size))
                .frame(width: size + 2, height: size + 2)
        }
    }
}

/// The `arkyv` pixel wordmark.
public struct ArkyvWordmarkView: View {
    var height: CGFloat
    public init(height: CGFloat = 32) { self.height = height }
    public var body: some View {
        Image(ArkyvAsset.wordmark)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .foregroundStyle(ArkyvColor.ink)
    }
}

/// The `arkyv` mark (the stacked-chevron glyph).
public struct ArkyvMarkView: View {
    var height: CGFloat
    var color: Color
    public init(height: CGFloat = 32, color: Color = ArkyvColor.ink) {
        self.height = height
        self.color = color
    }
    public var body: some View {
        Image(ArkyvAsset.mark)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .foregroundStyle(color)
    }
}
