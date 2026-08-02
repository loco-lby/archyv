import SwiftUI
import SwiftData
import ArkyvKit

/// `screen-folder-view`: header + masonry grid of captures & notes.
struct FolderGridView: View {
    @Bindable var folder: StoredFolder
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var searching = false
    @State private var query = ""

    private var items: [StoredItem] {
        let live = folder.items.filter { !$0.isDeleted }
        let sorted = live.sorted { $0.createdAt > $1.createdAt }
        guard searching, !query.isEmpty else { return sorted }
        let q = query.lowercased()
        return sorted.filter { item in
            ([item.title, item.noteBody, item.ocrText, item.sourceURL].compactMap { $0 } + item.tags)
                .contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        ScrollView {
            if searching {
                searchField
            }
            if items.isEmpty {
                emptyState
            } else {
                MasonryGrid(items: items, columns: 2, spacing: 12) { item in
                    NavigationLink(value: item) {
                        ItemCardView(item: item)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
        }
        .background(ArkyvColor.background)
        .safeAreaInset(edge: .top) { header }
        .navigationDestination(for: StoredItem.self) { item in
            ItemDetailView(item: item)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { dismiss() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.left").font(.system(size: 20))
                        Text("Archive").font(ArkyvFont.mono(.medium, size: 17))
                    }
                    .foregroundStyle(ArkyvColor.textPrimary)
                }
                Spacer()
                Menu {
                    Button("Rename", systemImage: "pencil") {}
                    Button("Delete Folder", systemImage: "trash", role: .destructive) {
                        try? Repository(context: context).softDelete(folder)
                        dismiss()
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 20))
                        .foregroundStyle(ArkyvColor.textPrimary)
                }
            }
            HStack(spacing: 10) {
                FolderIconView(icon: folder.icon, size: 22)
                Text(folder.name)
                    .font(.arkyvHeading)
                    .foregroundStyle(ArkyvColor.textPrimary)
            }
            HStack {
                Text("\(folder.referenceCount) references")
                    .font(.arkyvCaption)
                    .foregroundStyle(ArkyvColor.textSecondary)
                Spacer()
                Button {
                    withAnimation { searching.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: searching ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12))
                        Text(searching ? "Close search" : "Pull to search")
                            .font(.arkyvCaption)
                    }
                    .foregroundStyle(ArkyvColor.textSecondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(ArkyvColor.background)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(ArkyvColor.textDim)
            TextField("Search this folder", text: $query)
                .font(.arkyvBody)
                .foregroundStyle(ArkyvColor.textPrimary)
                .autocorrectionDisabled()
        }
        .padding(12)
        .arkyvOutlinedSurface()
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ArkyvMarkView(height: 40, color: ArkyvColor.textDim)
            Text(searching ? "No matches" : "Nothing here yet")
                .font(.arkyvLabel)
                .foregroundStyle(ArkyvColor.textSecondary)
            if !searching {
                Text("Screenshot something, or tap + to add from your library.")
                    .font(.arkyvCaption)
                    .foregroundStyle(ArkyvColor.textDim)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

/// A grid tile: media thumbnail or a sticky-note card.
struct ItemCardView: View {
    @Bindable var item: StoredItem

    var body: some View {
        switch item.kind {
        case .screenshot, .image:
            LocalImageView(filename: item.localFilename)
                .aspectRatio(item.aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: ArkyvRadius.card))
                .overlay(alignment: .topLeading) {
                    if item.isFavorite { favoriteBadge }
                }
        case .note, .text:
            noteCard
        }
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Snippet")
                .font(ArkyvFont.mono(.medium, size: 12))
                .foregroundStyle(ArkyvColor.textSecondary)
            Text(item.noteBody ?? "")
                .font(.arkyvBody)
                .foregroundStyle(ArkyvColor.textPrimary)
                .lineLimit(6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .arkyvOutlinedSurface(radius: ArkyvRadius.card)
    }

    private var favoriteBadge: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .padding(8)
    }
}
