import SwiftUI
import ArkyvKit

/// `screen-saved-confirmation` toast: "✓ Saved to <Folder>".
struct SavedToastView: View {
    let toast: SavedToast
    var body: some View {
        HStack(spacing: 6) {
            ArkyvMarkView(height: 18, color: ArkyvColor.textPrimary)
            Text("Saved to")
                .foregroundStyle(ArkyvColor.textSecondary)
            Text(toast.folderName)
                .foregroundStyle(ArkyvColor.textPrimary)
        }
        .font(.arkyvLabel)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(ArkyvColor.surface, in: RoundedRectangle(cornerRadius: ArkyvRadius.button))
        .overlay(
            RoundedRectangle(cornerRadius: ArkyvRadius.button)
                .strokeBorder(ArkyvColor.divider, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
    }
}
