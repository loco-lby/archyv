import SwiftUI

/// Spacing, corner-radius and sizing tokens from Figma.
public enum ArkyvRadius {
    /// Folder buttons / grid cards — intentionally sharp `2px`
    public static let button: CGFloat = 2
    /// Tag pills / suggestion chip — `4px`
    public static let pill: CGFloat = 4
    /// Cards & media thumbnails — `12px`
    public static let card: CGFloat = 12
    /// Bottom sheet — `28px`
    public static let sheet: CGFloat = 28
    /// Sheet container / screen corners — `32px`
    public static let screen: CGFloat = 32
}

public enum ArkyvSpacing {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 20
    public static let xxl: CGFloat = 24
    /// Gap between sheet sections
    public static let sheetSection: CGFloat = 18
}

/// Brand images from the asset catalog.
public enum ArkyvAsset {
    public static let wordmark = "ArkyvWordmark"
    public static let mark = "ArkyvMark"
}

public extension View {
    /// Standard sharp-cornered outlined surface used by folder buttons & chips.
    func arkyvOutlinedSurface(
        fill: Color = ArkyvColor.card,
        stroke: Color = ArkyvColor.border,
        lineWidth: CGFloat = 1,
        radius: CGFloat = ArkyvRadius.button
    ) -> some View {
        background(fill)
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(stroke, lineWidth: lineWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}
