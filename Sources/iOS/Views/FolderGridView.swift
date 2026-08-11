import SwiftUI
import SwiftData
import ArkyvKit

/// A stable, immutable navigation value for pushing to an item's detail
/// view — same rationale as `FolderRoute` in HomeView.swift: `StoredItem` is
/// a SwiftData `@Model` class, and using it directly as a NavigationPath
/// value risks the same live-backing-data hash instability that caused
/// folders to intermittently fail to open. `itemID` never changes for a
/// given item's lifetime.
private struct ItemRoute: Hashable {
    let itemID: UUID
}

/// `screen-folder-view`: header + masonry grid of captures & notes.
struct FolderGridView: View {
    @Bindable var folder: StoredFolder
    /// Owned by RootView, threaded through HomeView. Item taps push onto
    /// this same path (via `archivePath.append(ItemRoute(...))`), so
    /// Archive's path reads: root → FolderRoute → ItemRoute, and Archive-tab
    /// reselect (which resets the whole path to root) unwinds both levels
    /// at once, same as it already does for a bare folder push.
    @Binding var archivePath: NavigationPath
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var searching = false
    @State private var query = ""

    private var items: [StoredItem] {
        let live = (folder.items ?? []).filter { !$0.isSoftDeleted }
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
                    // Full-cell Button + manual append, not
                    // NavigationLink(value: item) — same lesson as
                    // HomeView's folder cards: don't put a live SwiftData
                    // model in the NavigationPath. contentShape is set here
                    // AND on ItemCardView's own body (see below) so the
                    // whole visible tile is tappable, not just its
                    // non-transparent pixels.
                    Button {
                        log("item-cell tap received (anywhere on cell): id=\(item.id) — archivePath.count before=\(archivePath.count)")
                        archivePath.append(ItemRoute(itemID: item.id))
                        log("archivePath.count after append: \(archivePath.count)")
                    } label: {
                        ItemCardView(item: item)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
        }
        .background(ArkyvColor.background)
        .safeAreaInset(edge: .top) { header }
        .navigationDestination(for: ItemRoute.self) { route in
            if let item = resolveItem(route.itemID) {
                ItemDetailView(item: item)
                    .onAppear {
                        log("item lookup succeeded for \(route.itemID)")
                    }
            } else {
                missingItemView
                    .onAppear {
                        log("item lookup FAILED for \(route.itemID) — no matching StoredItem (deleted or otherwise missing)")
                    }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    /// Resolves an `ItemRoute` back to its live `StoredItem` by `id`. Looks
    /// at `folder.items` directly (not the search-filtered `items` computed
    /// property above) so a route pushed before a search was typed still
    /// resolves correctly. Plain function, not `@ViewBuilder` — it returns
    /// a model, not a View.
    private func resolveItem(_ id: UUID) -> StoredItem? {
        (folder.items ?? []).first(where: { $0.id == id && !$0.isSoftDeleted })
    }

    private var missingItemView: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: 28))
                .foregroundStyle(ArkyvColor.textDim)
            Text("This item no longer exists")
                .font(.arkyvLabel)
                .foregroundStyle(ArkyvColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .background(ArkyvColor.background)
    }

    private func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[FolderGridView] \(message())")
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { dismiss() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.backward").font(.system(size: 20, weight: .semibold))
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
        Group {
            switch item.kind {
            case .screenshot, .image:
                LocalImageView(filename: item.localFilename, fallbackImageData: { item.imageData })
                    .aspectRatio(item.aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: ArkyvRadius.card))
                    // Decorative — the cell's tap belongs entirely to the
                    // enclosing Button in FolderGridView.
                    .allowsHitTesting(false)
                    .overlay(alignment: .topLeading) {
                        if item.isFavorite {
                            favoriteBadge.allowsHitTesting(false)
                        }
                    }
            case .note, .text:
                noteCard
            }
        }
        // Same reasoning as FolderCardView: set on this view's own
        // top-level content, not just on the wrapping Button, so the
        // entire tile — image included — is reliably one tap target.
        .contentShape(Rectangle())
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
