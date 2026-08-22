import SwiftUI
import UIKit
import ArkyvKit

/// Editorial Cover Typography Refinement 03: a third pass, all ratios
/// measured directly off a new Aeon before/after mockup (card ≈439×439px
/// in the supplied screenshot). Two things were explicitly confirmed with
/// Sammy before implementing, since the mockup and its own accompanying
/// text brief disagreed: the mockup's ACTUAL layout is left-aligned and
/// positioned in the lower half of the card (headline top ≈38%, domain
/// bottom ≈88%) — NOT the horizontally/vertically centered composition
/// the brief's prose described. The mockup was confirmed as the real
/// source of truth; every ratio below reflects what's actually measured
/// in it, not the prose description.
///
/// Builds on Visual Refinement 01's structure (the bottom-anchored,
/// single-VStack "headline + domain" group) unchanged — that architecture
/// was proven correct in Editorial Regression Trace 01 (rendered
/// correctly both in isolation and wrapped exactly as `ArchiveView`'s
/// real `MasonryGrid`/`ScrollView` uses it) and this pass only updates
/// its parameters, not its shape:
///   - headline font: Semibold → Medium (`Lora-Regular_Medium`, the same
///     confirmed-at-runtime name `ArkyvFont.mono(.medium)` already uses
///     elsewhere in the shipped app)
///   - headline size: further reduced (line-height ratio 0.101 → 0.091,
///     measured). Leading Tightening 01 follow-up: that 0.091 card-width
///     ratio turned out to read visually loose — `.lineSpacing` adds
///     extra space on top of the font's REAL native line height, which
///     the original calculation approximated as the font's point size
///     (too small an assumption for Lora). Now computed via
///     `headlineLineSpacing(fontSize:)`, which queries `UIFont`'s actual
///     metrics and targets a tighter, font-size-relative 1.02× leading
///     instead — see that function's own doc comment.
///   - headline max lines: 3 → 4 — NOT directly measurable from this
///     specific mockup (the shown headline truncates at line 3 either
///     way), but the brief explicitly and repeatedly asked for
///     "substantially more than the current 3-line treatment," so this
///     is a deliberate inference from stated intent where the image
///     itself was inconclusive, not a measurement — flagged as such in
///     this milestone's report.
///   - headline/domain gap: widened noticeably (0.03 → 0.13, measured) —
///     a deliberate reversal of Refinement 01's "tight/attached" goal;
///     this brief explicitly asks for the two to "remain distinct," not
///     attached.
///   - domain size: reduced (0.07575 → 0.046, measured) — quieter
///     relative to the now-smaller headline than before.
///   - left margin / bottom margin: 0.089/0.075 → 0.098/0.116 (measured)
///
/// Still a DERIVED PRESENTATION, not a transformation of stored media:
/// `LocalImageView` underneath renders the exact same original hero
/// bytes Item Detail shows, unmodified — only this view's own overlay
/// (scrim + veil + text) is drawn on top, every time, live. Nothing is
/// ever flattened into `imageData`/`localFilename`.
///
/// Legibility Refinement 04 added one more layer to that stack, in this
/// order: hero image → flat global scrim (unchanged) → a new, subtle,
/// left-anchored local contrast veil → typography. The veil exists only
/// to keep the headline readable over mixed-contrast source images
/// (e.g. Vice's editorial photography) without darkening the whole
/// image further or resorting to text shadows/strokes/glows — see
/// `contrastVeilStops`' own doc comment for the exact curve. Nothing
/// about the typography itself (font, size, leading, line cap, width,
/// position, domain styling) changed in this pass.
struct EditorialCoverView: View {
    let item: StoredItem

    // MARK: Ratios (fraction of the cover's own width; the cover is
    // always square, so width-based and height-based percentages are
    // the same number). All measured off the Refinement 03 mockup unless
    // noted otherwise above.
    private static let leftMarginRatio: CGFloat = 0.098
    private static let bottomMarginRatio: CGFloat = 0.116
    private static let headlineWidthRatio: CGFloat = 0.70
    private static let headlineFontRatio: CGFloat = 0.082
    /// Leading tightening pass: the target is now expressed directly as
    /// a multiple of the headline's OWN font size (≈1.02×, "this first
    /// test" per Sammy), not as a separate card-width ratio — see
    /// `headlineLineSpacing(fontSize:)` for how this gets translated
    /// into SwiftUI's `.lineSpacing`, which needs the font's REAL native
    /// line height (queried via `UIFont`, not assumed to equal the point
    /// size) to land on this target accurately.
    private static let headlineLineHeightMultiplier: CGFloat = 1.02
    /// Must match the exact PostScript name `ArkyvFont.mono(.medium:)`
    /// resolves to internally (see that file's own doc comment) — there
    /// is no public accessor for the raw name, so it's duplicated here
    /// only for `UIFont` metric lookup, never for building the `Font`
    /// itself (that still goes through `ArkyvFont.mono` unchanged).
    private static let headlineFontPostScriptName = "Lora-Regular_Medium"
    private static let domainFontRatio: CGFloat = 0.046
    /// Deliberately generous — this brief explicitly wants headline and
    /// domain to "remain distinct," the opposite instruction from
    /// Refinement 01's "feel attached." Still expressed as a gap in one
    /// bottom-anchored group (not independent absolute positions), so it
    /// stays visually correct regardless of the headline's actual
    /// rendered line count.
    private static let headlineDomainGapRatio: CGFloat = 0.13
    private static let scrimOpacity: Double = 0.3
    /// Not directly measurable from this mockup (see this file's own doc
    /// comment) — a deliberate inference from the brief's explicit,
    /// repeated request for "substantially more than 3 lines."
    private static let headlineMaxLines = 4

    /// Legibility Refinement 04: a broad, soft, LEFT-anchored horizontal
    /// contrast veil, layered between the existing flat scrim and the
    /// text — NOT a replacement for the scrim, NOT a luminance-adaptive
    /// effect. Every Editorial Cover gets the exact same deterministic
    /// curve regardless of what's under it; the goal is "the text is
    /// easier to read," not "there is a gradient on this image," so the
    /// falloff is intentionally wide (fully transparent by ~73% of card
    /// width) rather than a narrow text-box/vignette shape. Stop values
    /// are Sammy's own suggested starting curve, taken as given rather
    /// than measured off an asset (there is no mockup for this milestone).
    private static let contrastVeilStops: [Gradient.Stop] = [
        .init(color: .black.opacity(0.38), location: 0.0),
        .init(color: .black.opacity(0.27), location: 0.32),
        .init(color: .black.opacity(0.12), location: 0.53),
        .init(color: .black.opacity(0.0), location: 0.73),
        .init(color: .black.opacity(0.0), location: 1.0)
    ]

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.size.width
            let leftMargin = side * Self.leftMarginRatio
            let bottomMargin = side * Self.bottomMarginRatio
            let headlineFontSize = side * Self.headlineFontRatio
            let domainFontSize = side * Self.domainFontRatio
            let contentWidth = side * Self.headlineWidthRatio
            let gap = side * Self.headlineDomainGapRatio

            ZStack(alignment: .bottomLeading) {
                // Original hero image, full-bleed, centered, cover-fit —
                // never cropped/composited differently for Editorial;
                // the same `LocalImageView` every ordinary cell uses.
                LocalImageView(
                    filename: item.localFilename,
                    fallbackImageData: { item.imageData },
                    contentMode: .fill,
                    cropRegion: item.cropRegion,
                    decodeTarget: .thumbnail(shortEdgeTarget: LocalImageView.masonryThumbnailShortEdge),
                    originalPixelSize: CGSize(width: item.aspectWidth, height: item.aspectHeight)
                )
                .frame(width: side, height: side)
                .clipped()

                // Flat, uniform darkening — no gradient, no luminance
                // analysis. Untouched by this visual pass; no evidence
                // in the new mockup of a different value.
                Color.black
                    .opacity(Self.scrimOpacity)
                    .blendMode(.multiply)
                    .frame(width: side, height: side)

                // Legibility Refinement 04: subtle local contrast veil,
                // left-anchored (typography is left-aligned), broad and
                // soft rather than a narrow text-box shadow. Supplements
                // the flat scrim above only where the text sits — it does
                // not change the scrim's own value. No text
                // shadow/stroke/glow anywhere in this view; this gradient
                // is the entire legibility treatment.
                LinearGradient(
                    stops: Self.contrastVeilStops,
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: side, height: side)

                // Headline + domain as one bottom-anchored group — the
                // domain's position stays a fixed gap below the headline
                // regardless of the headline's actual rendered line
                // count (1–4). Left-aligned, not centered: confirmed
                // against the real mockup, not the brief's prose — see
                // this file's own doc comment.
                VStack(alignment: .leading, spacing: gap) {
                    if let headline = item.title, !headline.isEmpty {
                        Text(headline)
                            .font(ArkyvFont.mono(.medium, size: headlineFontSize))
                            .lineSpacing(Self.headlineLineSpacing(fontSize: headlineFontSize))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                            .lineLimit(Self.headlineMaxLines)
                            .truncationMode(.tail)
                            .frame(width: contentWidth, alignment: .leading)
                    }

                    if let domain = LinkCherryContext.displayDomain(sourceURL: item.sourceURL) {
                        Text(domain)
                            .font(ArkyvFont.publicSans(size: domainFontSize, weight: .regular))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            // No overflow handling in the original
                            // Figma source for domain text at all —
                            // Editorial Hell 01 proved that's a real
                            // failure mode on a long domain, so this
                            // stays constrained to the same content
                            // width the headline uses, with safe tail
                            // truncation (unchanged since V1).
                            .frame(width: contentWidth, alignment: .leading)
                    }
                }
                .padding(.leading, leftMargin)
                .padding(.bottom, bottomMargin)
            }
        }
        // 1:1 square, flat corners — no radius. Untouched by this
        // visual pass (see `MasonryGrid`'s `aspect` closure for the
        // matching layout-geometry side of this).
        .aspectRatio(1, contentMode: .fit)
        .clipShape(Rectangle())
    }

    /// Leading tightening pass: SwiftUI's `.lineSpacing` adds *extra*
    /// space on top of the font's own REAL natural line height — not on
    /// top of its point size, which is what the previous implementation
    /// wrongly assumed (Lora's natural line height runs noticeably
    /// taller than its point size, so that version was quietly stacking
    /// extra space on top of extra space, reading as too loose). This
    /// queries `UIFont`'s actual `lineHeight` for the exact same
    /// PostScript name/size the headline renders with, and solves for
    /// whatever `.lineSpacing` value is needed — including negative — to
    /// land on `headlineLineHeightMultiplier × fontSize` exactly. No
    /// `max(..., 0)` clamp: tightening below the font's own natural
    /// leading is the explicit goal here, not a bug to guard against.
    private static func headlineLineSpacing(fontSize: CGFloat) -> CGFloat {
        let targetLineHeight = fontSize * Self.headlineLineHeightMultiplier
        let nativeLineHeight = UIFont(name: Self.headlineFontPostScriptName, size: fontSize)?.lineHeight
            ?? fontSize * 1.2 // defensive fallback only — the named instance is UIAppFonts-registered and already confirmed to resolve at runtime elsewhere in this app; this is never expected to actually trigger.
        return targetLineHeight - nativeLineHeight
    }
}
