import SwiftUI

/// Color tokens pulled directly from the "arkyv test" Figma file.
/// Defined once here; never hard-code a hex anywhere else.
public enum ArkyvColor {
    /// App background — `#111`
    public static let background = Color(hex: 0x111111)
    /// Slightly raised surfaces / selected chips — `#222`
    public static let surface = Color(hex: 0x222222)
    /// Card & folder-button fill — `#1a1a1a`
    public static let card = Color(hex: 0x1A1A1A)
    /// Hairline borders around cards/buttons — `#2a2a2a`
    public static let border = Color(hex: 0x2A2A2A)

    /// Primary text / active outline — `#e0e0e0`
    public static let textPrimary = Color(hex: 0xE0E0E0)
    /// Brand ink used by the wordmark/mark — `#dbdbdb`
    public static let ink = Color(hex: 0xDBDBDB)
    /// Secondary / metadata text — `#999`
    public static let textSecondary = Color(hex: 0x999999)
    /// Disabled / placeholder text — `#6e6e6a`
    public static let textDim = Color(hex: 0x6E6E6A)
    /// Home indicator / handle — `#666`
    public static let handle = Color(hex: 0x666666)

    /// Sheet scrim — translucent `rgba(17,17,17,0.7)`
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
