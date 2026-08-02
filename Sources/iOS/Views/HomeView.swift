import SwiftUI
import SwiftData
import ArkyvKit

/// `screen-home`: the arkyv header + a vertical list of folder cards.
struct HomeView: View {
    @Query(
        filter: #Predicate<StoredFolder> { !$0.isDeleted },
        sort: [SortDescriptor(\StoredFolder.sortOrder), SortDescriptor(\StoredFolder.createdAt)]
    )
    private var folders: [StoredFolder]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                ForEach(folders) { folder in
                    NavigationLink(value: folder) {
                        FolderCardView(folder: folder)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(ArkyvColor.background)
        .safeAreaInset(edge: .top) { header }
        .navigationDestination(for: StoredFolder.self) { folder in
            FolderGridView(folder: folder)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack {
            ArkyvWordmarkView(height: 34)
            Spacer()
            ArkyvMarkView(height: 34)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .background(ArkyvColor.background)
    }
}

/// A single folder cover card: cover image + name + "N references • Updated".
struct FolderCardView: View {
    @Bindable var folder: StoredFolder

    private var coverFilename: String? {
        folder.items
            .filter { !$0.isDeleted && $0.kind.isMedia }
            .max(by: { $0.createdAt < $1.createdAt })?
            .localFilename
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LocalImageView(filename: coverFilename)
                .frame(height: 190)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: ArkyvRadius.card))

            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    FolderIconView(icon: folder.icon, size: 16)
                    Text(folder.name)
                        .font(.arkyvLabel)
                        .foregroundStyle(ArkyvColor.textPrimary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Text("\(folder.referenceCount) refs")
                    Text("•")
                    Text("Updated \(folder.updatedAt.arkyvRelative)")
                }
                .font(.arkyvCaption)
                .foregroundStyle(ArkyvColor.textSecondary)
            }
        }
    }
}

extension Date {
    /// Compact relative label like "2d ago" / "just now".
    var arkyvRelative: String {
        let seconds = Date.now.timeIntervalSince(self)
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86400: return "\(Int(seconds / 3600))h ago"
        default: return "\(Int(seconds / 86400))d ago"
        }
    }
}
