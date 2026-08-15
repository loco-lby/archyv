import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Design Foundation 00: adaptive semantic color roles. Each token follows
/// the system's native Light/Dark appearance — `light`/`dark` are
/// independent values below, not one value with the other mechanically
/// inverted, so each can be tuned on its own once both are physically
/// reviewed on device.
///
/// Dark canvas starts at `#070707` (down from the previous `#111111`)
/// specifically so the background recedes and archived imagery dominates,
/// rather than reading as a styled "dark tech UI." Light values are
/// reasonable neutral starting points, not art-directed from theory yet.
public enum ArkyvColor {
    /// Primary canvas/background.
    public static let canvas = Color(light: 0xFAFAFA, dark: 0x070707)
    /// The one elevated-surface role — cards, folder buttons, sheet/dropdown
    /// fills. Collapses the previous `surface` (#222, undocumented origin)
    /// and `card` (#1A1A1A, the actual Figma `surface` token under a
    /// confusing name) into a single deliberate role; nothing so far
    /// demonstrates a genuine need for two elevation levels.
    public static let surface = Color(light: 0xF0F0F0, dark: 0x1A1A1A)
    /// The one warm note in an otherwise neutral palette — folder-identity
    /// glyphs, selection/focus indication. Use sparingly, not as a general
    /// UI color. Kept at its existing value in both appearances for now;
    /// flagged for a legibility check once Light mode is physically visible.
    public static let accent = Color(hex: 0xFF3700)

    public static let textPrimary = Color(light: 0x111111, dark: 0xFFFFFF)
    public static let textSecondary = Color(light: 0x6B6B6B, dark: 0x999999)
    /// Hairlines, outlined-surface strokes.
    public static let divider = Color(light: 0xDDDDDD, dark: 0x333333)
    /// Disabled/placeholder text, default icon fill — anything meant to
    /// read as quieter than `textSecondary` without being a separate color
    /// family.
    public static let subdued = Color(light: 0xB3B3B3, dark: 0x6E6E6A)
    /// Scrim behind a sheet/overlay — derived from `canvas`, not a fixed
    /// independent value, so it stays visually consistent with whatever
    /// canvas value is active.
    public static let overlay = canvas.opacity(0.7)

    /// Brand ink used by the wordmark/mark. Not a general semantic role —
    /// left as its previous fixed value pending the later, intentional
    /// wordmark pass.
    public static let ink = Color(hex: 0xDBDBDB)
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

    /// An adaptive color that follows the system's Light/Dark appearance.
    /// `light`/`dark` are independent hex values — deliberately not one
    /// value with the other derived by inversion.
    init(light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? NSColor(hex: dark) : NSColor(hex: light)
        }))
        #else
        self.init(hex: dark)
        #endif
    }
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
#elseif canImport(AppKit)
private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
#endif
