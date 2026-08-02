import SwiftUI
import ArkyvKit

/// Create-folder sheet: name + icon picker matching the Figma icon set.
struct NewFolderView: View {
    /// Called with the chosen name + icon when the user taps Create.
    var onCreate: (String, FolderIcon) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon: FolderIcon = .symbol("star")
    @FocusState private var nameFocused: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 6)

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                TextField("Folder name", text: $name)
                    .font(.arkyvHeading)
                    .foregroundStyle(ArkyvColor.textPrimary)
                    .focused($nameFocused)
                    .padding(16)
                    .arkyvOutlinedSurface()

                Text("ICON")
                    .font(.arkyvSection)
                    .foregroundStyle(ArkyvColor.textSecondary)

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(FolderIcon.palette, id: \.token) { candidate in
                        Button {
                            icon = candidate
                        } label: {
                            FolderIconView(icon: candidate, size: 20,
                                           color: candidate == icon ? ArkyvColor.background : ArkyvColor.textPrimary)
                                .frame(width: 44, height: 44)
                                .background(candidate == icon ? ArkyvColor.textPrimary : ArkyvColor.card,
                                            in: RoundedRectangle(cornerRadius: ArkyvRadius.button))
                        }
                    }
                }
                Spacer()
            }
            .padding(20)
            .background(ArkyvColor.background)
            .navigationTitle("New Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(ArkyvColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onCreate(trimmed, icon)
                        dismiss()
                    }
                    .foregroundStyle(ArkyvColor.textPrimary)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { nameFocused = true }
        }
        .preferredColorScheme(.dark)
    }
}
