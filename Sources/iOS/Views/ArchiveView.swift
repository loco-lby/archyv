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

    #if DEBUG
    /// Option 2 Validation Gate 01 (two-device test) — DEBUG-only,
    /// read-only, no UI. See `OptionTwoValidationLog`. Seeded on first
    /// appearance so items already present at launch are never mistaken
    /// for a live arrival; every id inserted here is permanent for the
    /// view's lifetime (a soft-deleted/re-fetched item should never
    /// re-log as "new").
    @State private var optionTwoValidationSeenIDs: Set<UUID> = []
    #endif

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
        // One Archive Bottom Scroll / Safe Area 01: `MasonryGrid` reports
        // a FIXED, self-computed height via its own `.frame(height:
        // totalHeight())` — this `ScrollView`'s total scrollable content
        // height is exactly that number plus whatever padding is applied
        // directly to the content itself. A `safeAreaInset` on the
        // `ScrollView` was tried first and had NO effect at all on
        // physical-device QA — confirming this hierarchy doesn't treat it
        // as additional scrollable room the way a simpler, unnested
        // ScrollView would. Reverted to the mechanism that was already
        // structurally correct (content-level padding, which genuinely
        // adds to `MasonryGrid`'s reported size) — the ORIGINAL bug was
        // never the mechanism, only the hardcoded `96`'s magnitude:
        // it silently assumed the device's own bottom safe area was
        // "free" on top of it, which this hierarchy does not confirm.
        // This `GeometryReader` reads the real value directly rather than
        // assuming, so the total is unambiguously correct regardless of
        // device/orientation — no iPhone-model-specific magic number.
        GeometryReader { geometry in
            ScrollView {
                if searching {
                    searchField
                }
                if displayedItems.isEmpty {
                    // No dock-clearance padding here — an empty/near-
                    // empty Archive has no "final Cherry" that needs to
                    // clear the dock, and Section 7 explicitly warns
                    // against a bizarre giant empty scrolling region for
                    // short content.
                    emptyState
                } else {
                    MasonryGrid(items: displayedItems, columns: 2, spacing: 8, availableWidth: geometry.size.width - 16) { item in
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
                        // Performance Foundation 01: masonry tiles decode
                        // a small thumbnail (native ImageIO downsampling,
                        // cached) rather than a full-resolution bitmap for
                        // a ~200pt-wide cell — see `LocalImageView`'s own
                        // doc comment. `originalPixelSize` is free,
                        // already-stored metadata; passing it lets the
                        // thumbnail target the column's actual (width-
                        // constrained) edge rather than under-resolving
                        // tall portrait screenshots. Purely a decode-
                        // resolution change — same crop, same content,
                        // same everything else.
                        LocalImageView(
                            filename: item.localFilename,
                            fallbackImageData: { item.imageData },
                            cropRegion: item.cropRegion,
                            decodeTarget: .thumbnail(shortEdgeTarget: LocalImageView.masonryThumbnailShortEdge),
                            originalPixelSize: CGSize(width: item.aspectWidth, height: item.aspectHeight)
                        )
                            .aspectRatio(item.aspectRatio, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            // Sharp-tile experiment: 0pt corner radius,
                            // local to this masonry cell only — deliberately
                            // NOT a change to ArkyvRadius.button itself,
                            // which other, unrelated UI still uses.
                            .clipShape(Rectangle())
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                // The final row's real, direct clearance: the floating
                // dock's own footprint (`ArkyvFloatingDock.totalHeight` —
                // the SAME shared constant `RootView` positions the dock
                // from, so the two can never drift apart), the device's
                // OWN real bottom safe-area inset (read directly, not
                // assumed to already be "free"), and one spacing token of
                // intentional Cherries breathing room on top. This is only
                // effective now that `MasonryGrid` itself reports its true
                // rendered height (see its own doc comment) — appended
                // after an under-reserved height, this same padding was
                // already present and had no visible effect, because the
                // grid's own overflow silently ate it.
                .padding(.bottom, bottomScrollClearance(safeAreaBottom: geometry.safeAreaInsets.bottom))
                }
            }
            // One Archive should read as an open visual field, not a
            // utility scroll container — no persistent gutter/indicator
            // on the right edge. Not replaced with anything; a future
            // transient during-scroll-only indicator is a separate, later
            // experiment.
            .scrollIndicators(.hidden)
            .background(ArkyvColor.canvas)
            .safeAreaInset(edge: .top) {
                topBar
            }
            .ignoresSafeArea(edges: .bottom)
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
        #if DEBUG
        .onAppear {
            if optionTwoValidationSeenIDs.isEmpty {
                optionTwoValidationSeenIDs = Set(allItemsRaw.map(\.id))
            }
        }
        .onChange(of: allItemsRaw) { _, newValue in
            OptionTwoValidationLog.observeNewItems(newValue, seen: &optionTwoValidationSeenIDs)
        }
        #endif
    }

    /// One Archive Bottom Scroll / Safe Area 01: the exact bottom
    /// clearance the masonry content needs so its final row can rise
    /// completely clear of the floating dock. `safeAreaBottom` is the
    /// device's own real inset (read via `GeometryReader`, never
    /// hardcoded per iPhone model) — added explicitly because the
    /// `ScrollView` above is deliberately marked `.ignoresSafeArea
    /// (edges: .bottom)`, so nothing else accounts for it automatically.
    private func bottomScrollClearance(safeAreaBottom: CGFloat) -> CGFloat {
        safeAreaBottom + ArkyvFloatingDock.totalHeight + ArkyvSpacing.lg
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

    /// Try10 One Archive shell: filter rail + search only — the old brand
    /// header row (wordmark + search) above the rail is gone entirely; the
    /// wordmark now lives as a floating mark over the content instead (see
    /// `RootView.floatingWordmark`), not replaced by an empty slot here.
    /// `ArchiveFilterRail` itself is untouched (same scroll/active-filter
    /// behavior). The search toggle now sits in its own right-aligned row
    /// above the rail, in the safe-area space that was previously just
    /// empty canvas, rather than overlaid on the rail's trailing edge —
    /// that overlay used to collide with folder names scrolled under it;
    /// this gives the rail a clean, uninterrupted row.
    private var topBar: some View {
        VStack(spacing: 8) {
            HStack {
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
                .padding(.trailing, 20)
            }

            ArchiveFilterRail(filters: filters, active: $activeFilter, label: label(for:))
        }
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(ArkyvColor.canvas)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(ArkyvColor.subdued)
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
                .foregroundStyle(ArkyvColor.subdued)
            Text(emptyStateTitle)
                .font(.arkyvLabel)
                .foregroundStyle(ArkyvColor.textSecondary)
            if let subtitle = emptyStateSubtitle {
                Text(subtitle)
                    .font(.arkyvCaption)
                    .foregroundStyle(ArkyvColor.subdued)
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
                .foregroundStyle(ArkyvColor.subdued)
            Text("This item no longer exists")
                .font(.arkyvLabel)
                .foregroundStyle(ArkyvColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .background(ArkyvColor.canvas)
    }
}
