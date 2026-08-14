import SwiftUI
import SwiftData
import ArkyvKit

/// `screen-reference-detail`: full media, source, title, tags, notes, and the
/// move / favorite actions.
struct ItemDetailView: View {
    @Bindable var item: StoredItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    /// Tells RootView to hide its bottom nav while the note composer has
    /// focus — see `NoteFocusSignal`'s doc comment for why this is an
    /// explicit signal rather than RootView inferring it from keyboard
    /// geometry.
    @Environment(NoteFocusSignal.self) private var noteFocusSignal
    @State private var showMovePicker = false
    @State private var noteDraft = ""
    /// Drives the note composer's active state. Tapping it (or the
    /// composer's own tap gesture) sets this; the keyboard accessory's
    /// Done, or a tap outside the composer, clears it. A focus-lost
    /// transition is exactly when a pending edit gets flushed immediately
    /// rather than waiting on the debounce below.
    @FocusState private var noteFocused: Bool
    @State private var noteSaveTask: Task<Void, Never>?
    @State private var noteSaveState: NoteSaveState = .idle
    @State private var saveStateFadeTask: Task<Void, Never>?
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

    private enum NoteSaveState { case idle, saving, saved }

    private static let notesComposerID = "notesComposer"

    private var repo: Repository { Repository(context: context) }

    var body: some View {
        ScrollViewReader { proxy in
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
                        LocalImageView(
                            filename: item.localFilename,
                            fallbackImageData: { item.imageData },
                            contentMode: .fit,
                            cropRegion: showingFullContext ? .fullImage : item.cropRegion
                        )
                        .aspectRatio(showingFullContext ? originalAspectRatio : item.aspectRatio, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: ArkyvRadius.card))
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .overlay(alignment: .topTrailing) {
                            if !item.cropRegion.isFullImage {
                                contextToggleButton
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !item.cropRegion.isFullImage else { return }
                            withAnimation(.easeInOut(duration: 0.2)) { showingFullContext.toggle() }
                        }
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        if let source = item.sourceURL, !source.isEmpty {
                            Text(source)
                                .font(.arkyvCaption)
                                .foregroundStyle(ArkyvColor.textSecondary)
                        }
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.title ?? defaultTitle)
                                .font(.arkyvTitle)
                                .foregroundStyle(ArkyvColor.textPrimary)
                            Spacer()
                            Text("Saved \(item.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.arkyvCaption)
                                .foregroundStyle(ArkyvColor.textDim)
                        }

                        if !item.tags.isEmpty {
                            FlowTags(tags: item.tags)
                        }

                        Rectangle().fill(ArkyvColor.border).frame(height: 1)

                        notesSection

                        HStack {
                            Button {
                                showMovePicker = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "folder")
                                    Text("Move to...")
                                }
                                .font(ArkyvFont.mono(.medium, size: 15))
                                .foregroundStyle(ArkyvColor.textPrimary)
                            }
                            Spacer()
                            Button {
                                try? repo.toggleFavorite(item)
                            } label: {
                                Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                                    .font(.system(size: 18))
                                    .foregroundStyle(item.isFavorite ? .red : ArkyvColor.textPrimary)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding(20)
                    // Tapping anywhere in here that isn't a more specific
                    // control — the composer, "Move to...", the favorite
                    // button — dismisses the keyboard. A plain
                    // `.onTapGesture` on a container never intercepts a tap
                    // that lands directly on a child Button or the
                    // composer's own gesture; those consume the touch
                    // first. So this can't interfere with navigation or the
                    // other controls, only with genuinely empty space.
                    .onTapGesture {
                        if noteFocused {
                            log("background tap — dismissing keyboard")
                            noteFocused = false
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(ArkyvColor.background)
            .safeAreaInset(edge: .top) { header }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showMovePicker) {
                MoveToFolderView(item: item)
                    .presentationDetents([.medium, .large])
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
                noteDraft = item.noteBody ?? ""
                log("appeared for item \(item.id), noteBody length=\(item.noteBody?.count ?? 0)")
            }
            .onDisappear {
                log("disappeared — flushing pending note save")
                flushNoteSave(reason: "view-disappeared")
                // Safety net: normally focus loss fires the onChange below
                // first and this is already false, but a view can leave the
                // hierarchy without a guaranteed prior blur event, and
                // leaving this stuck true would leave RootView's bottom nav
                // permanently hidden.
                noteFocusSignal.isActive = false
            }
            .onChange(of: noteFocused) { old, new in
                noteFocusSignal.isActive = new
                if new && !old {
                    log("note focus gained")
                    withAnimation { proxy.scrollTo(Self.notesComposerID, anchor: .bottom) }
                } else if old && !new {
                    log("note focus lost")
                    flushNoteSave(reason: "focus-lost")
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase != .active else { return }
                log("scenePhase -> \(phase) — flushing pending note save")
                flushNoteSave(reason: "app-background")
            }
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

    private var defaultTitle: String {
        switch item.kind {
        case .screenshot: return "Screenshot"
        case .image: return "Image"
        case .note, .text: return "Note"
        }
    }

    private var header: some View {
        HStack {
            Button {
                log("back tapped — flushing pending note save")
                flushNoteSave(reason: "navigate-back")
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
                }
                .accessibilityLabel("Crop")
                .accessibilityHint("Opens the crop editor to change what Archive shows for this item.")
            }
            ShareLink(item: shareText) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 20))
                    .foregroundStyle(ArkyvColor.textPrimary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(ArkyvColor.background)
    }

    private var shareText: String {
        item.noteBody ?? item.title ?? item.sourceURL ?? "arkyv capture"
    }

    @ViewBuilder private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOTES")
                .font(.arkyvSection)
                .foregroundStyle(ArkyvColor.textSecondary)
            // A vertical-axis TextField, not TextEditor — this is the
            // native SwiftUI control for "auto-grows with content, caps at
            // a line count, scrolls internally past that," so there's no
            // manual height/geometry math here at all. That matters beyond
            // convenience: hand-rolled height calculations (subtracting
            // screen/keyboard geometry to size a text view) are the classic
            // source of the "Invalid frame dimension (negative or
            // non-finite)" class of warning, and this sidesteps it
            // entirely rather than risk reintroducing it.
            TextField(
                "",
                text: $noteDraft,
                prompt: Text("Add a note...")
                    .font(.arkyvBody)
                    .foregroundStyle(ArkyvColor.textDim),
                axis: .vertical
            )
            .font(.arkyvBody)
            .foregroundStyle(ArkyvColor.textPrimary)
            .lineLimit(3...6)
            .padding(12)
            .focused($noteFocused)
            .onChange(of: noteDraft) { _, _ in scheduleDebouncedSave() }
            .toolbar { ToolbarItemGroup(placement: .keyboard) { noteAccessoryBar } }
            .accessibilityLabel("Note")
            .accessibilityHint("Edits the note for this item. Saves automatically as you type.")
            .arkyvOutlinedSurface(
                stroke: noteFocused ? ArkyvColor.accent : ArkyvColor.border,
                radius: ArkyvRadius.card
            )
            .contentShape(Rectangle())
            .onTapGesture { noteFocused = true }
            .id(Self.notesComposerID)
            .animation(.easeOut(duration: 0.15), value: noteFocused)
        }
    }

    /// The note-editing accessory: one intentional bar directly above the
    /// keyboard (rendered via `.toolbar(placement: .keyboard)`, i.e. it's
    /// UIKit's own input accessory view — not something built by stacking
    /// SwiftUI content in the ordinary layout system, so it's unaffected by
    /// whatever RootView's safe areas are doing). A single custom view here
    /// — rather than separate `ToolbarItem`s — is what avoids the system's
    /// default per-item capsule/bubble chrome; this renders exactly as
    /// composed, full width, in Arkyv's own surface/border tokens.
    private var noteAccessoryBar: some View {
        HStack(spacing: 8) {
            persistenceStatusLabel
            Spacer()
            Button {
                log("keyboard Done tapped")
                noteFocused = false
            } label: {
                HStack(spacing: 4) {
                    Text("Done")
                        .font(ArkyvFont.mono(.medium, size: 15))
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(ArkyvColor.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done")
            .accessibilityHint("Dismisses the keyboard. Your note is already saving automatically.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(ArkyvColor.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(ArkyvColor.border).frame(height: 1)
        }
    }

    @ViewBuilder private var persistenceStatusLabel: some View {
        switch noteSaveState {
        case .idle:
            EmptyView()
        case .saving:
            Text("Saving…")
                .font(.arkyvCaption)
                .foregroundStyle(ArkyvColor.textDim)
                .transition(.opacity)
        case .saved:
            Text("Saved")
                .font(.arkyvCaption)
                .foregroundStyle(ArkyvColor.textDim)
                .transition(.opacity)
        }
    }

    // MARK: Note autosave
    //
    // Two paths write the note: a debounced path for ordinary typing (below),
    // and an immediate flush for anything that means "this text needs to be
    // durable right now" — focus loss, back-navigation, the app
    // backgrounding, or this view disappearing (all wired up in `body`).
    // Both funnel through `flushNoteSave`, and `Repository.updateNote`
    // no-ops on an unchanged value, so redundant flushes never double-save
    // or show a false "Saved" state.

    /// Schedules a save ~600ms out; only ever *schedules* — never assume
    /// this is the thing that guarantees persistence, since a focus loss or
    /// backgrounding can flush before it fires (and cancels it when they do).
    /// Also the single place `.saving` gets set, so the accessory shows
    /// "Saving…" for the full window a keystroke is actually pending.
    private func scheduleDebouncedSave() {
        noteSaveTask?.cancel()
        log("debounced save scheduled")
        withAnimation(.easeIn(duration: 0.15)) { noteSaveState = .saving }
        noteSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            flushNoteSave(reason: "debounce")
        }
    }

    /// Persists the current `noteDraft` immediately. Always reads the live
    /// `noteDraft` value (which reflects every keystroke synchronously,
    /// independent of when the debounced save runs), so this never loses
    /// trailing characters regardless of debounce timing.
    private func flushNoteSave(reason: String) {
        noteSaveTask?.cancel()
        noteSaveTask = nil
        let before = item.noteBody
        do {
            try repo.updateNote(item, body: noteDraft)
            if item.noteBody != before {
                log("note persistence succeeded (\(reason))")
                showSaved()
            } else {
                log("flush (\(reason)): no change, skipped")
                withAnimation(.easeOut(duration: 0.2)) { noteSaveState = .idle }
            }
        } catch {
            log("note persistence FAILED (\(reason)): \(error)")
            withAnimation(.easeOut(duration: 0.2)) { noteSaveState = .idle }
        }
    }

    /// Quiet, passive confirmation in the keyboard accessory: "Saved" for a
    /// beat, then back to nothing. Never reached on a failed or no-op save
    /// — see `flushNoteSave`, which only calls this on an actual successful
    /// write.
    private func showSaved() {
        withAnimation(.easeIn(duration: 0.15)) { noteSaveState = .saved }
        saveStateFadeTask?.cancel()
        saveStateFadeTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { noteSaveState = .idle }
        }
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
    private func presentCropEditor() {
        guard let filename = item.localFilename else {
            log("crop editor — no localFilename, nothing to show")
            return
        }
        log("crop editor — tap received")
        let fallback = item.imageData
        Task {
            let data = await Task.detached(priority: .userInitiated) {
                MediaStore.shared.data(for: filename) ?? fallback
            }.value
            guard let data, let image = UIImage(data: data) else {
                log("crop editor — failed to load image data")
                return
            }
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

/// Wrapping tag row.
struct FlowTags: View {
    let tags: [String]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { TagPill(text: $0) }
        }
    }
}

/// Folder picker used by "Move to...".
struct MoveToFolderView: View {
    @Bindable var item: StoredItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    // Unfiltered `@Query` + in-memory filter, not a `#Predicate` nil-check —
    // see ArchiveView.swift's `allFoldersRaw` doc comment: a `deletedAt ==
    // nil` predicate combined with a `sort:` argument in the same `@Query`
    // hits a SwiftData/Swift type-checker complexity limit.
    @Query(sort: \StoredFolder.sortOrder)
    private var allFoldersRaw: [StoredFolder]

    private var folders: [StoredFolder] {
        allFoldersRaw.filter { !$0.isSoftDeleted }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(folders) { folder in
                        Button {
                            try? Repository(context: context).move(item, to: folder)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                FolderIconView(icon: folder.icon, size: 18)
                                Text(folder.name).font(.arkyvLabel)
                                    .foregroundStyle(ArkyvColor.textPrimary)
                                Spacer()
                                if folder.id == item.folder?.id {
                                    Image(systemName: "checkmark").foregroundStyle(ArkyvColor.textSecondary)
                                }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .arkyvOutlinedSurface()
                        }
                    }
                }
                .padding(20)
            }
            .background(ArkyvColor.background)
            .navigationTitle("Move to...")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }
}
