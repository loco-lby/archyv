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

    private enum NoteSaveState { case idle, saving, saved }

    private static let notesComposerID = "notesComposer"

    private var repo: Repository { Repository(context: context) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if item.kind.isMedia {
                        // aspectRatio now reflects the crop (see
                        // StoredItem.aspectRatio) — for a .fullImage item
                        // this equals the original's own aspect ratio, so
                        // this outer constraint is a no-op there, same as
                        // today. It only actually shapes the frame once a
                        // real crop exists, giving LocalImageView's
                        // internal GeometryReader a correctly-shaped
                        // container to fill.
                        LocalImageView(filename: item.localFilename, fallbackImageData: { item.imageData }, contentMode: .fit, cropRegion: item.cropRegion)
                            .aspectRatio(item.aspectRatio, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: ArkyvRadius.card))
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                            #if DEBUG
                            // TEMPORARY DEBUG HARNESS — exercises the real
                            // persisted crop path (Repository.updateCropRegion)
                            // on a real StoredItem, not a local rendering
                            // override, so we can physically verify the crop
                            // renders correctly before the real crop editor
                            // exists. Long-press toggles between .fullImage
                            // and a fixed centered-square test region. Remove
                            // this whole #if DEBUG block once the real editor
                            // ships.
                            .onLongPressGesture {
                                let next: CropRegion = item.cropRegion.isFullImage
                                    ? CropRegion(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
                                    : .fullImage
                                do {
                                    try repo.updateCropRegion(item, to: next)
                                    log("DEBUG harness — toggled cropRegion to \(next)")
                                } catch {
                                    log("DEBUG harness — updateCropRegion FAILED: \(error)")
                                }
                            }
                            #endif
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
