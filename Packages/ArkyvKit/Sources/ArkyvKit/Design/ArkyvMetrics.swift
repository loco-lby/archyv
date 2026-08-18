import SwiftUI

/// Spacing, corner-radius and sizing tokens from Figma.
public enum ArkyvRadius {
    /// Folder buttons / grid cards — intentionally sharp `2px`
    public static let button: CGFloat = 2
    /// Tag pills / suggestion chip — `4px`
    public static let pill: CGFloat = 4
    /// Cards & media thumbnails — `12px`
    public static let card: CGFloat = 12
    /// Bottom sheet top corners — `16px` (Design System `radius-sheet`)
    public static let sheet: CGFloat = 16
    /// Dropdown row corners (folder picker) — `8px` (Design System `radius-sm`)
    public static let row: CGFloat = 8
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

/// Cherries' motion principle: **fast hands, calm room**. Input responds
/// immediately, but a visual state change should *settle* into place, not
/// pop or celebrate — no spring/overshoot, nothing flashes, nothing feels
/// spring-loaded or rushed. One token for now (small local state changes,
/// e.g. a selection highlight); deliberately not a whole animation
/// framework — add the next case only when a genuinely different kind of
/// transition needs it.
public enum ArkyvMotion {
    /// Calm settle for small, local state changes — 200ms, native
    /// ease-in-out. Communicates "understood, settling here," not
    /// "look at this."
    public static let settle: Animation = .easeInOut(duration: 0.2)
}

/// Brand images from the asset catalog.
public enum ArkyvAsset {
    public static let wordmark = "ArkyvWordmark"
    public static let mark = "ArkyvMark"
}

public extension View {
    /// Standard sharp-cornered outlined surface used by folder buttons & chips.
    func arkyvOutlinedSurface(
        fill: Color = ArkyvColor.surface,
        stroke: Color = ArkyvColor.divider,
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
