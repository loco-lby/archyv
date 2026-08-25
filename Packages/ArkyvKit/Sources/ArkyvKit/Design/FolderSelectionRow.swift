import SwiftUI

/// Item Detail's refined single-folder row language (first established in
/// `FolderEditorView`, then reused by the app-target Import/Make Cherry
/// drawer) — moved here, into `ArkyvKit`, during Share Extension Visual
/// Consistency 01 so the Share Extension (a separate compilation target
/// that cannot see `Sources/iOS/*`) can finally share the exact same
/// component instead of maintaining its own independent, never-updated
/// folder row. Pure typography (no icon, no color-coded dot) — selected
/// reads Semibold at full `foregroundColor` with a small leading-anchored
/// scale-up, everything else Medium at 75% opacity — with a trailing
/// checkmark as the one selection signal. Callers are responsible for
/// wrapping their own selection-state mutation in
/// `withAnimation(ArkyvMotion.settle)`, same as `FolderEditorView.select(_:)`,
/// so the row's font/color/scale/checkmark all settle together under
/// Cherries' one "fast hands, calm room" token rather than snapping.
///
/// One Cherries · Capture UI Unification 01: `foregroundColor` defaults to
/// the adaptive `ArkyvColor.textPrimary` every existing call site already
/// relied on — Capture UI Unification's only real addition is letting
/// `ScreenshotCaptureFlowView` pass its fixed-white darkroom color instead,
/// so it can reuse this exact component rather than reimplementing it a
/// second time for its intentionally-non-adaptive black canvas (see that
/// view's own `DarkroomColor` doc comment). `isSuggested` is the same
/// "tiny structural change" allowance — the capture flow's smart-folder
/// suggestion is real product signal, not decoration, so it needed a
/// non-orange way to stay visible: a small dot at 35% of `foregroundColor`,
/// the same neutral "hierarchy via opacity" language the row's own
/// selected/unselected states already use, never a second accent color.
public struct FolderSelectionRow: View {
    let name: String
    let isSelected: Bool
    let isSuggested: Bool
    let foregroundColor: Color
    let action: () -> Void

    public init(
        name: String,
        isSelected: Bool,
        isSuggested: Bool = false,
        foregroundColor: Color = ArkyvColor.textPrimary,
        action: @escaping () -> Void
    ) {
        self.name = name
        self.isSelected = isSelected
        self.isSuggested = isSuggested
        self.foregroundColor = foregroundColor
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(name)
                    .font(isSelected ? ArkyvFont.sans(size: 16, weight: .semibold) : ArkyvFont.mono(.medium, size: 16))
                    .tracking(1)
                    .foregroundStyle(isSelected ? foregroundColor : foregroundColor.opacity(0.75))
                    .scaleEffect(isSelected ? 17 / 16 : 1, anchor: .leading)
                if isSuggested && !isSelected {
                    Circle()
                        .fill(foregroundColor.opacity(0.35))
                        .frame(width: 5, height: 5)
                }
                Spacer()
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(foregroundColor)
                    .opacity(isSelected ? 1 : 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
