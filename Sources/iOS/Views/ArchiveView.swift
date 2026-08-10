import SwiftUI
import SwiftData
import ArkyvKit

/// A stable, immutable navigation value for pushing to an item's detail
/// view. `StoredItem` is a SwiftData `@Model` class — using it directly as
/// a `NavigationPath` value risks the same live-backing-data hash
/// instability documented on the legacy `FolderRoute`/`ItemRoute` types
/// this replaces (see git history on `FolderGridView.swift`). `itemID`
/// never changes for a given item's lifetime.
private struct ItemRoute: Hashable {
    let itemID: UUID
}

/// `screen-archive`: the v0.2 canonical root — ONE continuous masonry
/// surface over every archived image reference, with a horizontal filter
/// rail (All / Unfiled / Favorites / user folders) as the only lens
/// control. Folders are memberships, not places you navigate into:
/// selecting a filter changes what this same screen shows in place, it
/// never pushes a new screen.
///
/// Replaces the legacy folder-card `HomeView` → `FolderGridView` push
/// navigation. `FolderGridView` itself is left in place, unused, rather
/// than deleted — see Milestone C's report for why.
struct ArchiveView: View {
    /// Owned by `RootView`. Bound (not just read) because item taps push by
    /// calling `archivePath.append(_:)` directly rather than relying on
    /// `NavigationLink(value:)` to find the enclosing `NavigationStack` —
    /// same reasoning the old `HomeView` documented for folder taps.
    @Binding var archivePath: NavigationPath
    /// Owned by `RootView` — explicit application state, never inferred
    /// from `archivePath` or `StoredItem.folder`. Because it's owned above
    /// this view's own `NavigationStack` destination for Item Detail,
    /// pushing/popping to Item Detail never touches it, so "Back" always
    /// returns to whatever filter was active before the push.
    @Binding var activeFilter: ArchiveFilter

    /// Unfiltered by `#Predicate` — see `allImageItems`'s doc comment below
    /// for why: a `deletedAt == nil` predicate combined with a `sort:`
    /// array in the same `@Query` initializer hit the same SwiftData/Swift
    /// type-checker complexity limit encountered previously with a compound
    /// boolean predicate. Soft-delete filtering happens in-memory instead,
    /// via `folders`.
    @Query(sort: [SortDescriptor(\StoredFolder.sortOrder), SortDescriptor(\StoredFolder.createdAt)])
    private var allFoldersRaw: [StoredFolder]

    private var folders: [StoredFolder] {
        allFoldersRaw.filter { !$0.isSoftDeleted }
    }

    /// Unfiltered by `#Predicate` for the same type-checker-complexity
    /// reason as `allFoldersRaw` above (confirmed by direct trial: even the
    /// simple `$0.deletedAt == nil` comparison, combined with this query's
    /// `sort:` argument, was enough to trip "unable to type-check this
    /// expression in reasonable time" — not just the earlier compound
    /// boolean-OR case). Both soft-delete state and the IMAGE-ONLY MVP
    /// media-kind filter (`ItemKind.isMedia` — the same test used elsewhere:
    /// `ItemDetailView`, the old `FolderCardView` cover-image lookup) are
    /// applied in-memory below, via `allImageItems`. Standalone `.note`/
    /// `.text` items are excluded from this surface but never deleted or
    /// migrated — they remain valid persisted data, just not shown here. An
    /// `.image`/`.screenshot` item's own `noteBody` is unrelated to this
    /// filter and doesn't affect inclusion; it stays a normal image
    /// reference.
    @Query(sort: [SortDescriptor(\StoredItem.createdAt, order: .reverse)])
    private var allItemsRaw: [StoredItem]

    private var allImageItems: [StoredItem] {
        allItemsRaw.filter { !$0.isSoftDeleted && $0.kind.isMedia }
    }

    @State private var searching = false
    @State private var query = ""

    private var filters: [ArchiveFilter] {
        [.all, .unfiled, .favorites] + folders.map { .folder($0.id) }
    }

    private func label(for filter: ArchiveFilter) -> String {
        switch filter {
        case .all: return "All"
        case .unfiled: return "Unfiled"
        case .favorites: return "Favorites"
        case .folder(let id): return folders.first(where: { $0.id == id })?.name ?? "Folder"
        }
    }

    /// Derived, never stored: an item is Unfiled purely because it has
    /// zero active memberships to a non-deleted folder. Mirrors
    /// `Repository.memberships(for:)`'s exact predicate; duplicated inline
    /// (rather than calling the throwing repository method from a
    /// computed property) since it's two lines and this milestone's scope
    /// explicitly keeps repository changes at zero.
    private func isUnfiled(_ item: StoredItem) -> Bool {
        (item.memberships ?? []).filter { !$0.isSoftDeleted && $0.folder?.isSoftDeleted == false }.isEmpty
    }

    private func isMember(_ item: StoredItem, of folderID: UUID) -> Bool {
        (item.memberships ?? []).contains { !$0.isSoftDeleted && $0.folder?.id == folderID && $0.folder?.isSoftDeleted == false }
    }

    /// FILTER chooses the lens; everything below only ever narrows within
    /// whatever `activeFilter` already selected — never a second,
    /// independent global-search surface.
    private var filteredItems: [StoredItem] {
        switch activeFilter {
        case .all: return allImageItems
        case .unfiled: return allImageItems.filter(isUnfiled)
        case .favorites: return allImageItems.filter(\.isFavorite)
        case .folder(let id): return allImageItems.filter { isMember($0, of: id) }
        }
    }

    private var displayedItems: [StoredItem] {
        guard searching, !query.isEmpty else { return filteredItems }
        let q = query.lowercased()
        return filteredItems.filter { item in
            ([item.title, item.noteBody, item.ocrText, item.sourceURL].compactMap { $0 } + item.tags)
                .contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        ScrollView {
            if searching {
                searchField
            }
            if displayedItems.isEmpty {
                emptyState
            } else {
                MasonryGrid(items: displayedItems, columns: 2, spacing: 8) { item in
                    // Full-cell Button + manual append, not
                    // NavigationLink(value: item) — don't put a live
                    // SwiftData model in the NavigationPath (see
                    // `ItemRoute`'s doc comment). contentShape is set here
                    // so the whole visible tile is tappable, not just its
                    // non-transparent pixels.
                    Button {
                        log("item tap: id=\(item.id) — archivePath.count before=\(archivePath.count)")
                        archivePath.append(ItemRoute(itemID: item.id))
                    } label: {
                        // The masonry cell IS the image — no caption,
                        // title, date, or favorite badge. Content is the
                        // color and texture of this surface; anything more
                        // belongs in Item Detail.
                        LocalImageView(filename: item.localFilename)
                            .aspectRatio(item.aspectRatio, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: ArkyvRadius.button))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                // Generous bottom clearance (not the usual ~24pt) so the
                // last row can scroll fully clear of the floating dock
                // rather than settling permanently underneath it.
                .padding(.bottom, 96)
            }
        }
        .background(ArkyvColor.background)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                header
                ArchiveFilterRail(filters: filters, active: $activeFilter, label: label(for:))
                    .padding(.bottom, 12)
            }
            .background(ArkyvColor.background)
        }
        .navigationDestination(for: ItemRoute.self) { route in
            if let item = resolveItem(route.itemID) {
                ItemDetailView(item: item)
                    .onAppear { log("item detail appeared for \(route.itemID)") }
            } else {
                missingItemView
                    .onAppear { log("item lookup FAILED for \(route.itemID)") }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    /// Resolves an `ItemRoute` back to its live `StoredItem` by `id`, from
    /// the full (unfiltered-by-search, unfiltered-by-active-filter) image
    /// set — same reasoning the old `FolderGridView.resolveItem` used: a
    /// route pushed before a search was typed, or while a different filter
    /// was active, still needs to resolve correctly.
    private func resolveItem(_ id: UUID) -> StoredItem? {
        allImageItems.first(where: { $0.id == id })
    }

    private func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[ArchiveView] \(message())")
        #endif
    }

    private var header: some View {
        HStack {
            Text("cherries")
                .font(.system(size: 26, weight: .semibold, design: .serif))
                .foregroundStyle(ArkyvColor.textPrimary)
            Spacer()
            Button {
                withAnimation {
                    searching.toggle()
                    if !searching { query = "" }
                }
            } label: {
                Image(systemName: searching ? "xmark" : "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(ArkyvColor.textPrimary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(ArkyvColor.textDim)
            TextField("Search \(label(for: activeFilter))", text: $query)
                .font(.arkyvBody)
                .foregroundStyle(ArkyvColor.textPrimary)
                .autocorrectionDisabled()
        }
        .padding(12)
        .arkyvOutlinedSurface()
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: emptyStateIcon)
                .font(.system(size: 28))
                .foregroundStyle(ArkyvColor.textDim)
            Text(emptyStateTitle)
                .font(.arkyvLabel)
                .foregroundStyle(ArkyvColor.textSecondary)
            if let subtitle = emptyStateSubtitle {
                Text(subtitle)
                    .font(.arkyvCaption)
                    .foregroundStyle(ArkyvColor.textDim)
                    .multilineTextAlignment(.center)
            }
            if !searching, case .folder = activeFilter {
                Button("Show All") { activeFilter = .all }
                    .font(.arkyvCaption)
                    .foregroundStyle(ArkyvColor.textSecondary)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .padding(.horizontal, 32)
    }

    private var emptyStateIcon: String {
        searching ? "magnifyingglass" : "photo.on.rectangle.angled"
    }

    private var emptyStateTitle: String {
        if searching { return "No matches" }
        switch activeFilter {
        case .all: return "Nothing saved yet"
        case .unfiled: return "Everything's filed"
        case .favorites: return "No favorites yet"
        case .folder: return "Nothing filed here yet"
        }
    }

    private var emptyStateSubtitle: String? {
        guard !searching else { return nil }
        switch activeFilter {
        case .all: return "Screenshot something, or tap the scissors to add from your library."
        case .unfiled: return "Every saved reference currently belongs to a folder."
        case .favorites: return "Tap the heart on anything you want to find quickly."
        case .folder: return nil
        }
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
}
