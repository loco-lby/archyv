import SwiftUI
import ArkyvKit

/// Quiet, typographic horizontal rail of `ArchiveFilter` values — the only
/// affordance for changing what the one Archive surface shows. Deliberately
/// NOT pill/card/button styled: per the canonical product screens,
/// typography and contrast alone carry the active/inactive distinction —
/// no underline, pill, background, divider, or icon. Filter selection is
/// navigation state, not the kind of transient semantic feedback the
/// design system reserves cherry red for, so no persistent accent color is
/// used here.
///
/// Visual-authority pass: both states are Lora Medium at 16pt, inactive
/// folders read at 75% of `textPrimary`'s own opacity rather than the
/// separate, dimmer `textSecondary` token (scoped to this rail only —
/// `textSecondary` itself is unchanged for every other use across the
/// app), so they stay clearly secondary without reading as disabled. Both
/// colors are relative to `textPrimary`, so this still adapts correctly in
/// Light mode instead of hardcoding a fixed white.
///
/// A small (4pt) dot beneath the active label is the only selection
/// indicator — no underline/pill/background. It's an always-present,
/// opacity-toggled `Circle` (not conditionally inserted) specifically so
/// every cell's `VStack` has identical height/spacing whether or not it's
/// selected — an `if`-inserted dot would leave inactive cells shorter,
/// which under the row's default center alignment would visibly shift
/// their text baseline relative to the active cell's. `VStack`'s own
/// center alignment horizontally centers the dot under the label's own
/// width, not the button's full hit-target width.
///
/// Order is exactly whatever `filters` is handed — this view never sorts,
/// reorders on selection, or promotes a "recently used" filter to the
/// front. The caller (`ArchiveView`) is responsible for building that list
/// from `StoredFolder.sortOrder`.
struct ArchiveFilterRail: View {
    let filters: [ArchiveFilter]
    @Binding var active: ArchiveFilter
    let label: (ArchiveFilter) -> String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(filters, id: \.self) { filter in
                    Button {
                        active = filter
                    } label: {
                        VStack(spacing: 4) {
                            Text(label(filter))
                                .font(ArkyvFont.mono(.medium, size: 16))
                                .tracking(1)
                                .foregroundStyle(active == filter ? ArkyvColor.textPrimary : ArkyvColor.textPrimary.opacity(0.75))
                            Circle()
                                .fill(ArkyvColor.textPrimary)
                                .frame(width: 4, height: 4)
                                .opacity(active == filter ? 1 : 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }
}
