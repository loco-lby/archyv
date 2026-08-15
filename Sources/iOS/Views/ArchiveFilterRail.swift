import SwiftUI
import ArkyvKit

/// Quiet, typographic horizontal rail of `ArchiveFilter` values — the only
/// affordance for changing what the one Archive surface shows. Deliberately
/// NOT pill/card/button styled: per the canonical product screens, an
/// inactive filter is secondary-weight text and the active filter is
/// primary-weight text, nothing more. Filter selection is navigation state,
/// not the kind of transient semantic feedback the design system reserves
/// cherry red for, so no persistent accent color is used here.
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
            HStack(spacing: 22) {
                ForEach(filters, id: \.self) { filter in
                    Button {
                        active = filter
                    } label: {
                        Text(label(filter))
                            .font(ArkyvFont.mono(active == filter ? .medium : .regular, size: 15))
                            .tracking(1)
                            .foregroundStyle(active == filter ? ArkyvColor.textPrimary : ArkyvColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }
}
