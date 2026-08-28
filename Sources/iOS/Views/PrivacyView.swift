import SwiftUI
import ArkyvKit

/// Launch Shell 01 §14: in-product privacy language only — a formal
/// Privacy Policy document is separate App Store launch work, not this
/// milestone. Every claim here is checked directly against the real
/// persistence architecture (`ArkyvStore`), not written from memory or
/// aspiration: Cherries has no backend of its own, and the archive lives
/// in a CloudKit PRIVATE database under the user's own iCloud account —
/// nothing stronger than that (e.g. specific end-to-end-encryption
/// guarantees) is claimed, because nothing stronger has been verified.
struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Your archive is stored in your own iCloud account.")
                    .font(ArkyvFont.publicSans(size: 15, weight: .medium))
                    .foregroundStyle(ArkyvColor.textPrimary)
                Text("Cherries doesn't operate its own servers. Everything you save moves directly between your devices and iCloud, in a private database only your iCloud account can read.")
                    .font(ArkyvFont.publicSans(size: 13))
                    .foregroundStyle(ArkyvColor.textSecondary)
                Text("This page describes how Cherries actually works today. A complete privacy policy will accompany Cherries' public release.")
                    .font(ArkyvFont.publicSans(size: 13))
                    .foregroundStyle(ArkyvColor.subdued)
            }
            .padding(20)
        }
        .background(ArkyvColor.canvas)
        .safeAreaInset(edge: .top) { header }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.backward").font(.system(size: 18, weight: .semibold))
                    Text("Settings").font(ArkyvFont.publicSans(size: 15, weight: .medium))
                }
                .foregroundStyle(ArkyvColor.textPrimary)
            }
            Spacer()
            Text("Privacy").font(ArkyvFont.publicSans(size: 12, weight: .medium)).foregroundStyle(ArkyvColor.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(ArkyvColor.canvas)
    }
}
