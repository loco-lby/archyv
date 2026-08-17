import SwiftUI

/// Typography tokens. App-wide experiment: ordinary Cherries UI now uses
/// Lora (`Resources/Fonts/Lora-VariableFont_wght.ttf`, upright/roman only,
/// `UIAppFonts`-registered) rather than IBM Plex Sans — this file's API
/// surface (the `Mono` weight cases, the `mono(_:size:)`/
/// `sans(size:weight:)` functions, and every named semantic token below)
/// is unchanged so call sites needed no edits; only what each one
/// *resolves to* changed. Hierarchy is preserved through point size/weight
/// (unchanged from before), not through family — the same contract every
/// prior typography experiment this session has kept.
///
/// This variable font's own default instance genuinely is Regular
/// (wght=400, its axis floor — there's no lighter weight below it), but
/// like Space Grotesk/Commissioner before it, its fvar table declares no
/// explicit PostScript name per weight instance, so CoreText exposes each
/// one under a synthesized `Lora-Regular_<Subfamily>` name instead of a
/// guessable one — confirmed via
/// `UIFont.fontNames(forFamilyName: "Lora")` at runtime (Regular/Medium/
/// SemiBold/Bold are all exposed as named instances, so no `.weight()`
/// axis interpolation is needed here either).
///
/// This is deliberately not a Dynamic Type restructuring — every size here
/// is still a fixed point size, same as before switching families. Making
/// these scale with the user's text-size setting (via semantic text
/// styles / `@ScaledMetric`) is a real, separate accessibility milestone,
/// not folded in here; `Font.custom(_:size:)` without `relativeTo:`
/// preserves exactly the same (non-scaling) behavior `.system(size:)` had.
public enum ArkyvFont {
    public enum Mono {
        case regular, medium, bold
    }

    /// Named Lora instances confirmed to resolve at runtime — see this
    /// file's top doc comment for how they were confirmed, not guessed.
    public static func mono(_ weight: Mono, size: CGFloat) -> Font {
        let name: String
        switch weight {
        case .regular: name = "Lora-Regular"
        case .medium: name = "Lora-Regular_Medium"
        case .bold: name = "Lora-Regular_Bold"
        }
        return .custom(name, size: size)
    }

    /// Covers the weights actually requested across the app (`.regular`,
    /// `.medium`, `.semibold`, `.bold`), each a confirmed, directly-named
    /// instance rather than an interpolated one.
    public static func sans(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold: name = "Lora-Regular_Bold"
        case .semibold: name = "Lora-Regular_SemiBold"
        case .medium: name = "Lora-Regular_Medium"
        default: name = "Lora-Regular"
        }
        return .custom(name, size: size)
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
