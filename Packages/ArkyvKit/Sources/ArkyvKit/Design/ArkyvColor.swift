import SwiftUI

/// Color tokens from Figma's "🎨 Design Tokens" page (node 135:4) — the
/// canonical source of truth. Defined once here; never hard-code a hex
/// anywhere else.
public enum ArkyvColor {
    /// `background` — `#111111`
    public static let background = Color(hex: 0x111111)
    /// `accent` — `#FF3700`. The one warm note in an otherwise neutral
    /// palette; use sparingly (folder-identity glyphs), not as a UI color.
    public static let accent = Color(hex: 0xFF3700)
    /// Slightly raised surfaces / selected chips — `#222`. Not present as a
    /// distinct token on the Design Tokens page (which defines a single
    /// `surface` = `#1A1A1A`) — see note in ArkyvColor.swift discussion.
    public static let surface = Color(hex: 0x222222)
    /// `surface` — `#1A1A1A`. Card & folder-button fill.
    public static let card = Color(hex: 0x1A1A1A)
    /// `border` — `#333333`
    public static let border = Color(hex: 0x333333)

    /// `text-primary` — `#FFFFFF`
    public static let textPrimary = Color(hex: 0xFFFFFF)
    /// Brand ink used by the wordmark/mark — `#dbdbdb`. Not on the Design
    /// Tokens page; left as-is.
    public static let ink = Color(hex: 0xDBDBDB)
    /// `text-secondary` — `#999999`
    public static let textSecondary = Color(hex: 0x999999)
    /// Disabled / placeholder text — `#6e6e6a`. Not on the Design Tokens
    /// page; left as-is.
    public static let textDim = Color(hex: 0x6E6E6A)
    /// `icon-default` — `#6E6E6A`. Default folder-glyph fill per the Icons
    /// section. Same numeric value as `textDim` (kept distinct on purpose —
    /// this one names the icon-system meaning specifically).
    public static let iconDefault = Color(hex: 0x6E6E6A)
    /// Home indicator / handle — `#666`. Not on the Design Tokens page;
    /// left as-is.
    public static let handle = Color(hex: 0x666666)

    /// Sheet scrim — translucent `rgba(17,17,17,0.7)`, derived from
    /// `background`.
    public static let sheetScrim = Color(hex: 0x111111).opacity(0.7)
}

public extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
