import SwiftUI
import ArkyvKit

/// Launch Shell 01 §13: the smallest set of questions a genuinely confused
/// first-time user might actually ask — not a documentation encyclopedia,
/// and nothing speculative about features that don't exist yet (no Public
/// Cherries content). Each answer is checked against real current behavior,
/// not aspirational copy.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let entries: [(question: String, answer: String)] = [
        ("What is Cherries?",
         "A personal archive for the things that catch your eye — screenshots, photos, links, and more. Save something once, and find it again in One Archive."),
        ("How do I save something?",
         "Choose a photo, share a link or image from another app, or capture your screen. A new Cherry starts in Unfiled — filing it into a folder is optional."),
        ("How does Screen Capture work?",
         "Set it up once, then double-tap the back of your iPhone to send whatever's on your screen straight to Cherries — it opens the same crop and folder flow as any other Cherry."),
        ("Where is my data stored?",
         "In your own iCloud account, in Cherries' private database. It isn't stored on a server Cherries operates."),
        ("Does Cherries upload my archive to its own servers?",
         "No. Cherries has no servers of its own — everything moves directly between your devices and iCloud."),
        ("Why didn't a link have an image?",
         "Some pages don't offer one, or block Cherries from reading it. Cherries only ever saves what it can genuinely find — never a placeholder standing in for a real picture."),
        ("Why does a GIF sometimes look still in One Archive?",
         "One Archive keeps motion restrained so scrolling stays smooth — only a few Cherries animate at once. Open any GIF on its own to see it play."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(entries, id: \.question) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.question)
                            .font(ArkyvFont.publicSans(size: 15, weight: .medium))
                            .foregroundStyle(ArkyvColor.textPrimary)
                        Text(entry.answer)
                            .font(ArkyvFont.publicSans(size: 13))
                            .foregroundStyle(ArkyvColor.textSecondary)
                    }
                }
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
            Text("Help & FAQ").font(ArkyvFont.publicSans(size: 12, weight: .medium)).foregroundStyle(ArkyvColor.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(ArkyvColor.canvas)
    }
}
