import SwiftUI
import SwiftData
import ArkyvKit

/// `screen-reference-detail`: Item Detail is primarily a *view* of a
/// Cherry's context, not a form with several simultaneously-editable
/// fields. The artifact dominates (0pt corners, matching One Archive's
/// own masonry, not a rounded "card"), no manufactured title, and
/// Source/Tags/Folder/Notes are all quiet summary/navigation affordances
/// — "this context exists, tap to inspect or change it" — never inline
/// text fields. Tapping any of them opens a dedicated "sideroom" editor
/// (`NotesEditorView`/`SourceEditorView`/`TagsEditorView`/
/// `FolderEditorView`, in `ItemDetailEditors.swift`) via `activeRoom`, a
/// `fullScreenCover` — the same presentation `CropEditorView` already
/// uses from this screen, chosen specifically because it has no
/// swipe-to-dismiss gesture to disambiguate against: the room's own
/// large Cherries X/✓ (`ContextEditorChrome`) are the only two ways out.
/// Each room owns a local draft and only reports it back on ✓ via
/// `onConfirm` — this file is the only place any of the four properties
/// actually get persisted, so X genuinely means "cancel, nothing
/// changed."
struct ItemDetailView: View {
    @Bindable var item: StoredItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURLAction

    /// Which sideroom (if any) is currently presented.
    private enum EditingRoom: Identifiable {
        case notes, source, tags, folder
        var id: Self { self }
    }
    @State private var activeRoom: EditingRoom?

    /// The item's actual image, loaded on demand for the crop editor — a
    /// single `Identifiable` payload, presented via `.fullScreenCover(item:)`
    /// rather than a separate `Bool` + optional. That combination
    /// (`isPresented: Bool` driving presentation, content reading a
    /// different `@State` optional) is what caused a real, physically
    /// confirmed bug during development: the presented-state boolean
    /// could flip true while the content closure's separately-read
    /// optional still observed nil, so the editor never actually
    /// rendered. `.fullScreenCover(item:)` makes that structurally
    /// impossible — presence and payload are the same value.
    private struct CropEditingSession: Identifiable {
        let id = UUID()
        let image: UIImage
        let region: CropRegion
    }
    @State private var cropEditingSession: CropEditingSession?
    /// `false` (default) = the saved crop, "what I picked" — matches the
    /// artifact the user just tapped from Archive/a folder. `true` = the
    /// untouched original screenshot, "where did this come from" — a
    /// secondary, explicitly-entered view, never the default. Resets to
    /// `false` on a successful re-crop (see `confirmCrop`), so the reward
    /// for confirming a new crop is landing back on it, not staying in
    /// context. A fresh `@State` per navigation push, so it never leaks
    /// between different items.
    @State private var showingFullContext = false
    /// Pinch-to-zoom viewing state for the image above, backed by
    /// `ZoomableImageContainer` (a native `UIScrollView`, for
    /// anchor-correct pinch-toward-your-fingers zooming — see its own doc
    /// comment) — viewing behavior only, never touches
    /// `item.cropRegion`/`imageData`/anything stored. `imageIsZoomed`
    /// mirrors the scroll view's own zoomed/not-zoomed state so the page's
    /// outer `ScrollView` can suspend itself while zoomed (see
    /// `.scrollDisabled` below). `imageZoomResetTick` is bumped whenever
    /// `showingFullContext` changes so switching between the saved crop
    /// and the original doesn't carry a stale zoom/pan into a
    /// differently-sized image.
    @State private var imageIsZoomed = false
    @State private var imageZoomResetTick = 0

    private var repo: Repository { Repository(context: context) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if item.kind.isMedia {
                    // Defaults to the saved crop — "what I picked,"
                    // the same artifact Archive/folder grids just
                    // showed when the user tapped into this item.
                    // showingFullContext is the explicit, secondary
                    // "where did this come from" view of the
                    // untouched original. Same non-destructive
                    // rendering LocalImageView already uses in
                    // Archive: cropRegion: .fullImage takes its own
                    // unchanged code path, so a never-cropped item
                    // renders identically regardless of this toggle.
                    ZoomableImageContainer(
                        isZoomedIn: $imageIsZoomed,
                        resetSignal: imageZoomResetTick,
                        onSingleTap: {
                            guard !item.cropRegion.isFullImage else { return }
                            withAnimation(.easeInOut(duration: 0.2)) { showingFullContext.toggle() }
                        }
                    ) {
                        LocalImageView(
                            filename: item.localFilename,
                            fallbackImageData: { item.imageData },
                            contentMode: .fit,
                            cropRegion: showingFullContext ? .fullImage : item.cropRegion
                        )
                    }
                    .aspectRatio(showingFullContext ? originalAspectRatio : item.aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    // 0pt corners, no border, no shadow — the same sharp
                    // visual language as One Archive's own masonry tiles,
                    // not a rounded "card." Presentation-only; the shared
                    // LocalImageView/CropRegion rendering underneath is
                    // untouched.
                    .clipShape(Rectangle())
                    .padding(.horizontal, Self.contentHorizontalInset)
                    .padding(.top, 12)
                    .overlay(alignment: .topTrailing) {
                        if !item.cropRegion.isFullImage {
                            contextToggleButton
                        }
                    }
                    .onChange(of: showingFullContext) { _, _ in
                        imageZoomResetTick += 1
                    }
                }

                // Context + Single-Folder UX 01: "Link Cherries need a
                // label, not a card." Quiet, left-aligned title + domain
                // — no card, no favicon, no badge, no image overlay —
                // shown only when there's a sourceURL at all (an ordinary
                // screenshot/photo has none, so this renders nothing and
                // Item Detail is pixel-identical to before). The title
                // line itself is further gated by `LinkCherryContext
                // .displayTitle`'s own rule; the domain line alone can
                // still appear even when the title is omitted as
                // untrustworthy.
                linkContextBlock

                // A compact, centered, self-contained control cluster —
                // Source/Tags/Folder as one row of quiet chips, "+ Add
                // note" as a smaller/lighter chip beneath — all
                // summary/navigation affordances, never inline editable
                // fields. See this file's top doc comment. Centered as a
                // group (not stretched edge-to-edge) so it reads as one
                // small contextual unit tied to the image, not three
                // labels spanning the room's width.
                metadataCluster
                    .padding(.horizontal, Self.contentHorizontalInset)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
            }
        }
        .background(ArkyvColor.canvas)
        .safeAreaInset(edge: .top) { header }
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(item: $activeRoom) { room in
            switch room {
            case .notes:
                NotesEditorView(
                    item: item,
                    onConfirm: { draft in
                        // LIFECYCLE / FAULT INJECTION FOUNDATION 01: only
                        // dismiss the room on a successful save — mirrors
                        // CropEditorView's own onConfirm-returns-Bool
                        // pattern below. Before this fix, `try?` silently
                        // swallowed a save failure and `activeRoom = nil`
                        // ran unconditionally, so an injected/genuine
                        // Repository failure closed the room exactly as
                        // if the edit had been saved — the room's local
                        // draft (the user's typed text) was discarded
                        // right along with it, even though nothing was
                        // actually persisted. Rollback already restores
                        // `item.noteBody` to its prior persisted value
                        // (see `Repository.save()`), so staying open here
                        // simply means the user sees their own unsaved
                        // edit again and can retry — never a false
                        // "saved" outcome, never a lost edit.
                        do {
                            try repo.updateNote(item, body: draft)
                            activeRoom = nil
                        } catch {
                            log("notes save FAILED, room stays open: \(error)")
                        }
                    },
                    onCancel: { activeRoom = nil }
                )
            case .source:
                SourceEditorView(
                    item: item,
                    onConfirm: { draft in
                        do {
                            try repo.updateSourceURL(item, to: draft)
                            activeRoom = nil
                        } catch {
                            log("source save FAILED, room stays open: \(error)")
                        }
                    },
                    onCancel: { activeRoom = nil }
                )
            case .tags:
                TagsEditorView(
                    item: item,
                    onConfirm: { tags in
                        do {
                            try repo.updateTags(item, to: tags)
                            activeRoom = nil
                        } catch {
                            log("tags save FAILED, room stays open: \(error)")
                        }
                    },
                    onCancel: { activeRoom = nil }
                )
            case .folder:
                FolderEditorView(
                    item: item,
                    modelContext: context,
                    onConfirm: { folder in
                        do {
                            if let folder {
                                try repo.move(item, to: folder)
                            } else {
                                // "Unfiled" selected — clears every active
                                // membership via the existing, already-public
                                // `setMemberships(_:to:)` (its own doc
                                // comment explicitly covers `to: []` as
                                // "leaving the item alive and Unfiled"), and
                                // clears the legacy single-owner field the
                                // same direct way `move()` itself does.
                                //
                                // `item.folder = nil` mutates the object
                                // directly, before `setMemberships` is
                                // even called — if `setMemberships`'s own
                                // save() then fails, its rollback reverts
                                // EVERY pending change on this shared
                                // context, not just the ones it made
                                // itself, so this direct mutation is
                                // reverted right along with it. No manual
                                // restore needed here — see
                                // LifecycleFaultInjectionTests for direct
                                // proof of this.
                                item.folder = nil
                                try repo.setMemberships(item, to: [])
                            }
                            activeRoom = nil
                        } catch {
                            log("folder save FAILED, room stays open: \(error)")
                        }
                    },
                    onCancel: { activeRoom = nil }
                )
            }
        }
        .fullScreenCover(item: $cropEditingSession) { session in
            CropEditorView(
                image: session.image,
                region: session.region,
                onConfirm: { region in confirmCrop(region) },
                onDismiss: { cropEditingSession = nil }
            )
        }
        .onAppear {
            log("appeared for item \(item.id)")
        }
    }

    /// The untouched original's own aspect ratio — `item.aspectRatio` is
    /// deliberately crop-aware (see `StoredItem.aspectRatio`), which is
    /// exactly wrong when `showingFullContext` is displaying the
    /// original: forcing the crop's shape onto the full image would
    /// stretch or letterbox it incorrectly.
    private var originalAspectRatio: Double {
        item.aspectHeight > 0 ? item.aspectWidth / item.aspectHeight : 1
    }

    /// Small top-right affordance toggling `showingFullContext`, so the
    /// capability is discoverable rather than relying only on the hidden
    /// tap-the-image gesture. Icon direction communicates which way the
    /// tap goes: outward arrows to expand into context, inward arrows to
    /// collapse back to the saved crop.
    private var contextToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { showingFullContext.toggle() }
        } label: {
            Image(systemName: showingFullContext ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.5), in: Circle())
        }
        .padding(10)
        .accessibilityLabel(showingFullContext ? "Show saved crop" : "Show full screenshot")
    }

    /// Header — Favorite lives here, next to Share, since "favorite this /
    /// share this" are peer actions about the current item. Every icon
    /// button gets an explicit 44×44 tap target.
    private var header: some View {
        HStack {
            Button {
                log("back tapped")
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.backward").font(.system(size: 20, weight: .semibold))
                    Text(item.folder?.name ?? "Back").font(ArkyvFont.mono(.medium, size: 17))
                }
                .foregroundStyle(ArkyvColor.textPrimary)
            }
            Spacer()
            // Re-crop belongs to Full Context, not the default cropped
            // view: while looking at the saved crop, the primary action
            // is simply viewing it — the option to change it only
            // surfaces once the user has expanded into the original to
            // see where it came from. Exception: a `.fullImage` item has
            // no distinct "saved crop" to default to — its default view
            // already *is* full context — so Crop must stay reachable
            // even though `showingFullContext` never becomes true for it.
            if item.kind.isMedia && (item.cropRegion.isFullImage || showingFullContext) {
                Button {
                    presentCropEditor()
                } label: {
                    Image(systemName: "crop").font(.system(size: 20))
                        .foregroundStyle(ArkyvColor.textPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Crop")
                .accessibilityHint("Opens the crop editor to change what Archive shows for this item.")
            }
            // Favorite + Share as one tight cluster. Each keeps its full
            // 44×44 hit target (accessibility-safe, non-overlapping);
            // what tightens the visual gap is *where the glyph sits
            // inside that frame* — Favorite's pinned to its frame's
            // trailing edge, Share's to its frame's leading edge.
            HStack(spacing: 14) {
                Button {
                    try? repo.toggleFavorite(item)
                } label: {
                    Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 18))
                        .foregroundStyle(item.isFavorite ? .red : ArkyvColor.textPrimary)
                        .frame(width: 44, height: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(item.isFavorite ? "Remove from favorites" : "Add to favorites")
                ShareLink(item: shareText) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 20))
                        .foregroundStyle(ArkyvColor.textPrimary)
                        .frame(width: 44, height: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Share")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(ArkyvColor.canvas)
    }

    private var shareText: String {
        item.noteBody ?? item.title ?? item.sourceURL ?? "Cherries capture"
    }

    // MARK: - Link Cherry context — quiet label, not a card

    /// `nil` renders nothing at all (an ordinary screenshot/photo has no
    /// `sourceURL`, so this block is entirely absent — no reserved
    /// space, no empty affordance). Tapping either line opens the same
    /// Source room the "Source" chip below already opens — reusing the
    /// existing editor's own "Open Source" action rather than adding a
    /// second way to leave the app.
    @ViewBuilder
    private var linkContextBlock: some View {
        if let domain = LinkCherryContext.displayDomain(sourceURL: item.sourceURL) {
            VStack(alignment: .leading, spacing: 3) {
                if let title = LinkCherryContext.displayTitle(title: item.title, sourceURL: item.sourceURL) {
                    Text(title)
                        .font(ArkyvFont.publicSans(size: 15, weight: .semibold))
                        .foregroundStyle(ArkyvColor.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                // Link Cherry Ingestion + Source Semantics 01, Section 5:
                // the domain/host line is its own separate action — it
                // opens the original webpage immediately, exactly like
                // SourceEditorView's own "Open Source" button, NOT the
                // Source room. The Source chip below (`metadataChip`)
                // still opens that room unchanged; these are two
                // distinct, deliberately non-overlapping affordances.
                Button {
                    if let sourceURL = item.sourceURL, let url = URL(string: sourceURL) {
                        openURLAction(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(domain)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(ArkyvFont.publicSans(size: 13))
                    .foregroundStyle(ArkyvColor.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(domain)
                .accessibilityHint("Opens the original webpage.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.contentHorizontalInset)
            .padding(.top, 12)
        }
    }

    // MARK: - Metadata row (Source / Tags / Folder) — pure navigation

    /// Shared with the image block above: both use this exact constant
    /// for their horizontal inset, so the metadata row's total width
    /// always matches the artifact's own width exactly — one source of
    /// truth rather than two independently-written insets that could
    /// drift apart.
    private static let contentHorizontalInset: CGFloat = 20

    /// Source / Tags / Folder + Note as one compact, self-contained
    /// control cluster — a row of three quiet chips, a smaller/lighter
    /// "+ Add note" chip beneath. Centered as a group under the image
    /// (not stretched across its width): this is meant to read as one
    /// small contextual control group, not three lonely labels spanning
    /// the room.
    private var metadataCluster: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                metadataChip("Source", hint: "Opens the Source editor.") { activeRoom = .source }
                metadataChip("Tags", hint: "Opens the Tags editor.") { activeRoom = .tags }
                metadataChip("Folder", hint: "Opens the Folder editor.") { activeRoom = .folder }
            }
            noteChip
        }
        .frame(maxWidth: .infinity)
    }

    /// +1pt letterspacing applied to every Public Sans use in this
    /// metadata/summary system.
    private static let metadataTracking: CGFloat = 1

    /// A Source/Tags/Folder navigation trigger — deliberately low
    /// contrast (`textSecondary`, not `textPrimary`), no fill/background,
    /// so the group reads as light, quiet text against the canvas rather
    /// than a row of buttons competing with the image. No populated-state
    /// cue (color/weight change, badge, count): the room itself is one
    /// tap away and shows the real state; this chip's only job is "tap
    /// here to enter it." Padding + `.frame(minHeight: 44)` still keep a
    /// generous tap target even though there's no visible chrome to
    /// anchor it to.
    private func metadataChip(_ label: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                    .font(ArkyvFont.publicSans(size: 15, weight: .semibold))
                    .tracking(Self.metadataTracking)
                    .foregroundStyle(ArkyvColor.textSecondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ArkyvColor.subdued)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }

    // MARK: - Notes — deflated to a quiet nav affordance

    private var hasNote: Bool {
        !(item.noteBody?.isEmpty ?? true)
    }

    /// Notes is latent annotation, not permanent metadata: most Cherries
    /// are saved for reasons the user already remembers, so an empty note
    /// shouldn't read as a missing field — it should ask quietly. Once a
    /// note exists, it's user-authored context and has earned a touch
    /// more visibility, so the populated state reads slightly stronger
    /// than the empty one — but this chip still stays smaller/lighter
    /// than the Source/Tags/Folder trio above it; Notes should feel
    /// secondary, not like a fourth equal sibling. Same unfilled,
    /// no-background treatment as the trio, just smaller/quieter.
    /// Tapping either state opens the unchanged Notes sideroom.
    private var noteChip: some View {
        Button { activeRoom = .notes } label: {
            Group {
                if hasNote {
                    HStack(spacing: 4) {
                        Text(item.noteBody ?? "")
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(ArkyvColor.textSecondary)
                } else {
                    Text("+ Add note")
                        .foregroundStyle(ArkyvColor.subdued)
                }
            }
            .font(ArkyvFont.publicSans(size: 12))
            .tracking(Self.metadataTracking)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Note")
        .accessibilityHint(hasNote ? "Tap to view or edit your note." : "Optional. Tap to add a note.")
    }

    private func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[ItemDetailView] \(message())")
        #endif
    }

    /// Loads this item's actual image data the same two-phase way
    /// `LocalImageView` does — `item.imageData` is a SwiftData model
    /// property and must be read on the main actor, only the resulting
    /// `Data` crosses into the detached task — then presents
    /// `CropEditorView` with it and the item's current persisted
    /// `cropRegion`, as one atomic payload (see `CropEditingSession`'s
    /// doc comment for why that matters).
    ///
    /// Crop Editor always needs the *original*-resolution decode (users
    /// crop pixel-precisely, and `image.size` here becomes the semantic
    /// coordinate space `CropRegion` is defined against) — this never
    /// requests a downsampled variant. It does check
    /// `ImageDecodeCache` first, though: the same full-resolution decode
    /// may already be sitting there from this same view's own full-screen
    /// rendering above (`LocalImageView` defaults to `.full`), in which
    /// case this reuses it instead of decoding the file a second time.
    private func presentCropEditor() {
        guard let filename = item.localFilename else {
            log("crop editor — no localFilename, nothing to show")
            return
        }
        log("crop editor — tap received")
        let cacheKey = ImageDecodeCache.key(filename: filename, maxPixelSize: nil)
        if let cached = ImageDecodeCache.shared.image(forKey: cacheKey) {
            log("crop editor — reusing cached full-resolution decode (\(Int(cached.size.width))x\(Int(cached.size.height)))")
            cropEditingSession = CropEditingSession(image: cached, region: item.cropRegion)
            return
        }
        let fallback = item.imageData
        Task {
            // Media Architecture Cutover 01: a missing MediaStore cache
            // file here is a routine cold miss, not a rare restore case —
            // `data(for:reconstructingFrom:)` materializes it (through
            // `MediaCacheCoordinator`, coalescing any concurrent request
            // for the same filename) so a subsequent re-crop or full-
            // resolution open finds it warm.
            let data = await Task.detached(priority: .userInitiated) {
                await MediaStore.shared.data(for: filename, reconstructingFrom: { fallback })
            }.value
            guard let data, let image = UIImage(data: data) else {
                log("crop editor — failed to load image data")
                return
            }
            ImageDecodeCache.shared.store(image, forKey: cacheKey)
            log("crop editor — image loaded (\(Int(image.size.width))x\(Int(image.size.height))), presenting")
            cropEditingSession = CropEditingSession(image: image, region: item.cropRegion)
        }
    }

    /// Persists the confirmed crop via the same non-destructive path
    /// established since the schema-foundation milestone — only the
    /// crop scalars change, original pixels/localFilename untouched.
    /// Returns whether the write succeeded; `CropEditorView` dismisses
    /// itself immediately on `true` — on `false` it stays open with the
    /// user's edit untouched, so a persistence failure never silently
    /// discards it. Also resets `showingFullContext` to `false` on
    /// success: returning from a re-crop should land back on the newly-
    /// saved crop (the reward/confirmation), not linger in context.
    /// Dismissal itself (`cropEditingSession = nil`) happens from
    /// `onDismiss`.
    private func confirmCrop(_ region: CropRegion) -> Bool {
        do {
            try repo.updateCropRegion(item, to: region)
            log("crop editor — confirmed and persisted \(region)")
            showingFullContext = false
            return true
        } catch {
            log("crop editor — updateCropRegion FAILED, editor stays open: \(error)")
            return false
        }
    }
}
