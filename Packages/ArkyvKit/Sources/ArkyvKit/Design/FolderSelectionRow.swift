import SwiftUI

/// Item Detail's refined single-folder row language (first established in
/// `FolderEditorView`, then reused by the app-target Import/Make Cherry
/// drawer) — moved here, into `ArkyvKit`, during Share Extension Visual
/// Consistency 01 so the Share Extension (a separate compilation target
/// that cannot see `Sources/iOS/*`) can finally share the exact same
/// component instead of maintaining its own independent, never-updated
/// folder row. Pure typography (no icon, no color-coded dot) — selected
/// reads Semibold at full `textPrimary` with a small leading-anchored
/// scale-up, everything else Medium at 75% opacity — with a trailing
/// checkmark as the one selection signal. Callers are responsible for
/// wrapping their own selection-state mutation in
/// `withAnimation(ArkyvMotion.settle)`, same as `FolderEditorView.select(_:)`,
/// so the row's font/color/scale/checkmark all settle together under
/// Cherries' one "fast hands, calm room" token rather than snapping.
public struct FolderSelectionRow: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void

    public init(name: String, isSelected: Bool, action: @escaping () -> Void) {
        self.name = name
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(name)
                    .font(isSelected ? ArkyvFont.sans(size: 16, weight: .semibold) : ArkyvFont.mono(.medium, size: 16))
                    .tracking(1)
                    .foregroundStyle(isSelected ? ArkyvColor.textPrimary : ArkyvColor.textPrimary.opacity(0.75))
                    .scaleEffect(isSelected ? 17 / 16 : 1, anchor: .leading)
                Spacer()
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ArkyvColor.textPrimary)
                    .opacity(isSelected ? 1 : 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
