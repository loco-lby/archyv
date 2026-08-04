import SwiftUI
import SwiftData
import ArkyvKit

/// A stable, immutable navigation value for pushing to a folder's grid.
///
/// Root cause of the intermittent dead-tap bug: `NavigationLink(value: folder)`
/// was using `StoredFolder` — a SwiftData `@Model` class — directly as the
/// path value. SwiftData doesn't give `@Model` classes a custom `Hashable`
/// conformance based on `id` alone; its synthesized identity tracks the
/// model's live backing data, so the hash NavigationStack computed when the
/// link was registered can silently drift from the hash it computes when
/// resolving the tap, for any folder whose other properties (a new cover
/// item, `updatedAt`, `referenceCount` via its `items` relationship) mutate
/// around the same time — exactly why "Inspiration" (untouched) always
/// worked while folders that had just received a capture (changing their
/// live cover/updatedAt) intermittently didn't. `FolderRoute` only carries
/// `folderID`, which never changes for a given folder's lifetime, so its
/// hash is stable regardless of what happens to the folder's content.
private struct FolderRoute: Hashable {
    let folderID: UUID
}

/// `screen-home`: the arkyv header + a vertical list of folder cards.
struct HomeView: View {
    /// Owned by `RootView`. Bound here (not just read) because folder taps
    /// now push by calling `archivePath.append(_:)` directly — see the
    /// `Button` in `body` — rather than relying on `NavigationLink(value:)`
    /// to find the nearest enclosing `NavigationStack`'s path implicitly.
    @Binding var archivePath: NavigationPath

    @Query(
        filter: #Predicate<StoredFolder> { !$0.isDeleted },
        sort: [SortDescriptor(\StoredFolder.sortOrder), SortDescriptor(\StoredFolder.createdAt)]
    )
    private var folders: [StoredFolder]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                ForEach(folders) { folder in
                    // Explicit full-card Button + manual `archivePath.append`,
                    // not `NavigationLink(value:)` — see `FolderRoute`'s doc
                    // comment for why the model-object-as-value approach was
                    // unreliable. This also sidesteps any ambiguity about
                    // whether a child view inside the card could intercept
                    // NavigationLink's own gesture recognizer: a plain
                    // Button's action always fires on tap, full stop, and
                    // `.contentShape(Rectangle())` guarantees the entire
                    // visible card — not just its non-transparent pixels —
                    // is tappable.
                    Button {
                        log("folder-card tap received (anywhere on card): id=\(folder.id) name=\"\(folder.name)\" — archivePath.count before=\(archivePath.count)")
                        let route = FolderRoute(folderID: folder.id)
                        archivePath.append(route)
                        log("archivePath.count after append: \(archivePath.count)")
                    } label: {
                        FolderCardView(folder: folder)
                    }
                    .buttonStyle(.plain)
                    // Belt-and-braces: contentShape is also set on
                    // FolderCardView's own root VStack (see that file). A
                    // custom multi-child label — image + clipShape + text
                    // row — can otherwise report a tap-responsive region
                    // narrower than its visual bounds to the wrapping
                    // Button; setting it in both places closes that gap
                    // regardless of which layer SwiftUI actually consults.
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(folder.name))
                    .accessibilityHint(Text("Opens this folder"))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(ArkyvColor.background)
        .safeAreaInset(edge: .top) { header }
        .navigationDestination(for: FolderRoute.self) { route in
            // Each branch here is a single View-producing expression chain —
            // `.onAppear` carries the logging. A bare `log(...)` statement
            // sitting next to the View expression inside a `@ViewBuilder`
            // block doesn't work: every statement in a ViewBuilder block is
            // run through `buildExpression`, and there's no overload of
            // `buildExpression` for `Void` — only for `View`-conforming
            // types. That's the exact "Type '()' cannot conform to 'View'"
            // failure this caused when `log(...)` (which returns `Void`)
            // was a standalone statement here.
            if let folder = resolveFolder(route.folderID) {
                FolderGridView(folder: folder, archivePath: $archivePath)
                    .onAppear {
                        log("folder lookup succeeded for \(route.folderID) -> \"\(folder.name)\"")
                        log("FolderGridView appeared for \"\(folder.name)\"")
                    }
            } else {
                missingFolderView
                    .onAppear {
                        log("folder lookup FAILED for \(route.folderID) — no matching StoredFolder (deleted or otherwise missing)")
                    }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    /// Resolves a `FolderRoute` back to its live `StoredFolder` by `id`.
    /// Folders are soft-deleted (see `Repository.softDelete` / `isDeleted`),
    /// so a route that outlives its folder is unlikely but not impossible —
    /// e.g. a delete racing a still-in-flight navigation. Handled as a plain
    /// "not found" state rather than force-unwrapping into a crash.
    ///
    /// Deliberately a plain function, not `@ViewBuilder` — it returns a
    /// model, not a View, so there's no builder-block restriction on what
    /// can live in its body.
    private func resolveFolder(_ id: UUID) -> StoredFolder? {
        folders.first(where: { $0.id == id })
    }

    private var missingFolderView: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 28))
                .foregroundStyle(ArkyvColor.textDim)
            Text("This folder no longer exists")
                .font(.arkyvLabel)
                .foregroundStyle(ArkyvColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .background(ArkyvColor.background)
    }

    private func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[HomeView] \(message())")
        #endif
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
                // Purely decorative — the card's tap is owned entirely by
                // the enclosing Button in HomeView. Opting this out of hit
                // testing means it can never compete for the gesture,
                // regardless of what LocalImageView's internals do
                // (spinner, placeholder, etc).
                .allowsHitTesting(false)

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
        // Set here too, not just on the wrapping Button in HomeView — this
        // is what actually fixes "only the text row is tappable, not the
        // image": defining the tap-responsive region on the label's own
        // top-level content is the documented way to make the *complete*
        // composed view (image, spacing, padding included) register as one
        // control, rather than depending on the Button to infer it.
        .contentShape(Rectangle())
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
