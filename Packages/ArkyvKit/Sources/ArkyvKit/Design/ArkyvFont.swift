import SwiftUI

/// Typography tokens. Design Foundation 00: ordinary Cherries UI now uses
/// Apple's system font family (SF Pro) rather than the previously bundled
/// Intel One Mono / Instrument Sans — this file's API surface (the `Mono`
/// weight cases, the `mono(_:size:)`/`sans(size:weight:)` functions, and
/// every named semantic token below) is unchanged so call sites needed no
/// edits; only what each one *resolves to* changed. Hierarchy is preserved
/// through point size/weight (unchanged from before), not through family.
///
/// This is deliberately not a Dynamic Type restructuring — every size here
/// is still a fixed point size, same as before. Making these scale with
/// the user's text-size setting (via semantic text styles / `@ScaledMetric`)
/// is a real, separate accessibility milestone, not folded in here.
public enum ArkyvFont {
    public enum Mono {
        case regular, medium, bold
    }

    /// Was the Intel One Mono display/label font; now plain SF Pro at the
    /// same weight mapping ("SemiBold" in the original design still maps
    /// to `.medium`, matching the prior behavior exactly).
    public static func mono(_ weight: Mono, size: CGFloat) -> Font {
        let systemWeight: Font.Weight = weight == .bold ? .bold : (weight == .medium ? .medium : .regular)
        return .system(size: size, weight: systemWeight)
    }

    /// Was the Instrument Sans small-UI-text font; now plain SF Pro.
    public static func sans(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

// Convenience semantic styles used across screens. Same names, same sizes,
// same weights as before — only the family changed (see `ArkyvFont` above).
public extension Font {
    /// "Save to..." / big sheet title (~30pt bold) — currently unused
    /// anywhere in the app; kept for parity with the pre-existing token set.
    static let arkyvSheetTitle = ArkyvFont.mono(.bold, size: 30)
    /// Folder button / folder name label (15pt bold)
    static let arkyvLabel = ArkyvFont.mono(.bold, size: 15)
    /// Folder title on folder-view header (28pt bold)
    static let arkyvHeading = ArkyvFont.mono(.bold, size: 28)
    /// Reference title (22pt bold)
    static let arkyvTitle = ArkyvFont.mono(.bold, size: 22)
    /// Body / notes text (14pt regular)
    static let arkyvBody = ArkyvFont.mono(.regular, size: 14)
    /// Status bar clock / small semibold text (15pt)
    static let arkyvStatus = ArkyvFont.sans(size: 15, weight: .semibold)
    /// Metadata caption (13pt)
    static let arkyvCaption = ArkyvFont.sans(size: 13)
    /// Section header ALL CAPS (12pt bold)
    static let arkyvSection = ArkyvFont.sans(size: 12, weight: .bold)
}
