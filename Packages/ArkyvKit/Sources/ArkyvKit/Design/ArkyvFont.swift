import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Typography tokens. Two families from Figma:
/// - `Intel One Mono` for display / labels / folder names
/// - `Instrument Sans` for small UI text (status bar, meta, section headers)
///
/// Intel One Mono ships Light/Regular/Medium/Bold — the design's "SemiBold"
/// maps to `.medium` here.
public enum ArkyvFont {
    public enum Mono: String {
        case regular = "IntelOneMono-Regular"
        case medium = "IntelOneMono-Medium"
        case bold = "IntelOneMono-Bold"
    }

    /// Instrument Sans is bundled as a variable font; the PostScript name
    /// resolves to the default instance and weights are applied via traits.
    public static let sansName = "InstrumentSans-Regular"

    /// Monospace display / label font. Falls back to the system monospaced
    /// font if the bundled font failed to register.
    public static func mono(_ weight: Mono, size: CGFloat) -> Font {
        if fontIsRegistered(weight.rawValue) {
            return .custom(weight.rawValue, fixedSize: size)
        }
        let systemWeight: Font.Weight = weight == .bold ? .bold : (weight == .medium ? .medium : .regular)
        return .system(size: size, weight: systemWeight, design: .monospaced)
    }

    /// Small sans UI text. Falls back to the system font.
    public static func sans(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if fontIsRegistered(sansName) {
            return .custom(sansName, fixedSize: size).weight(weight)
        }
        return .system(size: size, weight: weight)
    }

    // MARK: - Verification

    /// Every `.ttf` in `Resources/Fonts` is declared in each target's
    /// `UIAppFonts` (see `project.yml`), so iOS registers them automatically
    /// at process launch — manually calling `CTFontManagerRegisterFontsForURL`
    /// on top of that double-registers the same files, which is what produced
    /// the `GSFont: file already registered` console spam. There is nothing
    /// left for this file to *do* at launch; `UIAppFonts` is the whole
    /// registration story now.
    ///
    /// DEBUG-only: confirms the automatic registration actually worked, by
    /// checking `UIFont(name:size:)` for each PostScript name this file
    /// hands out via `mono(_:size:)` / `sans(size:weight:)`. If a bundling
    /// regression (like the folder-reference bug this replaced) ever strips
    /// a font back out of the bundle, this prints a clear failure instead of
    /// letting the graceful system-font fallback hide it silently.
    #if DEBUG
    public static func verifyFontsAvailable() {
        #if canImport(UIKit)
        let postScriptNames = [Mono.regular.rawValue, Mono.medium.rawValue, Mono.bold.rawValue, sansName]
        for name in postScriptNames {
            let loaded = UIFont(name: name, size: 12) != nil
            print("[ArkyvFont] \(name): \(loaded ? "loaded" : "NOT loaded — falling back to system font")")
        }
        #endif
    }
    #endif

    private static func fontIsRegistered(_ postScriptName: String) -> Bool {
        #if canImport(UIKit)
        return UIFont(name: postScriptName, size: 12) != nil
        #else
        return true
        #endif
    }
}

// Convenience semantic styles used across screens.
public extension Font {
    /// "Save to..." / big sheet title (~30pt bold mono)
    static let arkyvSheetTitle = ArkyvFont.mono(.bold, size: 30)
    /// Folder button / folder name label (15pt bold mono)
    static let arkyvLabel = ArkyvFont.mono(.bold, size: 15)
    /// Folder title on folder-view header (28pt bold mono)
    static let arkyvHeading = ArkyvFont.mono(.bold, size: 28)
    /// Reference title (22pt bold mono)
    static let arkyvTitle = ArkyvFont.mono(.bold, size: 22)
    /// Body / notes text (14pt mono regular)
    static let arkyvBody = ArkyvFont.mono(.regular, size: 14)
    /// Status bar clock / small semibold sans (15pt)
    static let arkyvStatus = ArkyvFont.sans(size: 15, weight: .semibold)
    /// Metadata caption (13pt sans)
    static let arkyvCaption = ArkyvFont.sans(size: 13)
    /// Section header ALL CAPS (12pt bold sans)
    static let arkyvSection = ArkyvFont.sans(size: 12, weight: .bold)
}
