import SwiftUI
import SwiftData
import ArkyvKit

/// Item Detail's four "sideroom" editors — dedicated, single-purpose
/// screens for Notes/Source/Tags/Folder, presented via
/// `ItemDetailView`'s `activeRoom` (`.fullScreenCover(item:)`). Each is
/// deliberately "dumb": it owns a local draft, never touches
/// `Repository` itself, and reports the final result to
/// `onConfirm` — `ItemDetailView` is the only place any of these four
/// properties actually get persisted, exactly mirroring how
/// `CropEditorView`'s own `onConfirm: (CropRegion) -> Bool` already
/// works. That's what makes X a genuine cancel: nothing in a room's
/// local draft ever reaches the model until its own ✓ fires.

// MARK: - Notes

struct NotesEditorView: View {
    let item: StoredItem
    let onConfirm: (String) -> Void
    let onCancel: () -> Void
    /// Core Loop Hardening 02 §4 — see `ContextEditorChrome`'s own doc
    /// comment. `ItemDetailView` sets this after a failed `onConfirm`.
    var errorMessage: String? = nil

    @State private var draft: String
    @FocusState private var focused: Bool

    init(item: StoredItem, errorMessage: String? = nil, onConfirm: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.item = item
        self.errorMessage = errorMessage
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _draft = State(initialValue: item.noteBody ?? "")
    }

    var body: some View {
        ContextEditorChrome(title: "Notes", errorMessage: errorMessage, onCancel: onCancel, onConfirm: { onConfirm(draft) }) {
            // Plain multiline TextField, not axis: .vertical — this is a
            // dedicated full-height writing surface, not a growing/
            // capped composer, so it should simply fill the available
            // room. Return inserts a newline; nothing here ever treats it
            // as submit. No keyboard accessory toolbar, no second
            // checkmark inside the field — the chrome's own ✓ above is
            // the only confirm control.
            TextField(
                "",
                text: $draft,
                prompt: Text("Add a note...")
                    .font(ArkyvFont.publicSans(size: 16))
                    .foregroundStyle(ArkyvColor.subdued),
                axis: .vertical
            )
            .font(ArkyvFont.publicSans(size: 16))
            .tracking(1)
            .foregroundStyle(ArkyvColor.textPrimary)
            .lineLimit(1...)
            .focused($focused)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .accessibilityLabel("Note")
        }
        .onAppear { focused = true }
    }
}

// MARK: - Source

struct SourceEditorView: View {
    let item: StoredItem
    let onConfirm: (String) -> Void
    let onCancel: () -> Void
    /// Core Loop Hardening 02 §4 — see `ContextEditorChrome`'s own doc
    /// comment.
    var errorMessage: String? = nil

    @State private var draft: String
    @FocusState private var focused: Bool
    @Environment(\.openURL) private var openURLAction

    init(item: StoredItem, errorMessage: String? = nil, onConfirm: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.item = item
        self.errorMessage = errorMessage
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _draft = State(initialValue: item.sourceURL ?? "")
    }

    /// Tests the *live draft*, not only the already-persisted value — so
    /// a freshly-pasted link can be verified before confirming, and the
    /// already-saved case (draft starts pre-filled with it) works the
    /// same way for free.
    private var draftURL: URL? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    var body: some View {
        ContextEditorChrome(title: "Source", errorMessage: errorMessage, onCancel: onCancel, onConfirm: { onConfirm(draft) }) {
            VStack(alignment: .leading, spacing: 16) {
                TextField(
                    "",
                    text: $draft,
                    prompt: Text("Paste a link…")
                        .font(ArkyvFont.publicSans(size: 16))
                        .foregroundStyle(ArkyvColor.subdued)
                )
                .font(ArkyvFont.publicSans(size: 16))
                .tracking(1)
                .foregroundStyle(ArkyvColor.textPrimary)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(1)
                .focused($focused)
                .padding(14)
                .arkyvOutlinedSurface(stroke: ArkyvColor.divider, radius: ArkyvRadius.row)
                .accessibilityLabel("Source link")

                // Quiet secondary action — lets the user verify/visit the
                // link without leaving the editing model ambiguous (this
                // never confirms or cancels the room by itself).
                if let draftURL {
                    Button {
                        openURLAction(draftURL)
                    } label: {
                        HStack(spacing: 6) {
                            Text("Open Source")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .font(ArkyvFont.publicSans(size: 13, weight: .medium))
                        .tracking(1)
                        .foregroundStyle(ArkyvColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .onAppear { focused = true }
    }
}

// MARK: - Tags

struct TagsEditorView: View {
    let item: StoredItem
    let onConfirm: ([String]) -> Void
    let onCancel: () -> Void
    /// Core Loop Hardening 02 §4 — see `ContextEditorChrome`'s own doc
    /// comment.
    var errorMessage: String? = nil

    @State private var draftTags: [String]
    @State private var newTagText = ""
    @FocusState private var addFieldFocused: Bool

    init(item: StoredItem, errorMessage: String? = nil, onConfirm: @escaping ([String]) -> Void, onCancel: @escaping () -> Void) {
        self.item = item
        self.errorMessage = errorMessage
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _draftTags = State(initialValue: item.tags)
    }

    private var trimmedNewTag: String {
        newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        // The chrome's own top-right ✓ means "I'm done managing tags" —
        // it reports the whole local `draftTags` set, persisted once by
        // `ItemDetailView`. The small trailing ✓ on the Add field below
        // is a *different* action ("add THIS tag") that never leaves
        // this screen — see `commitTypedTag`.
        ContextEditorChrome(title: "Tags", errorMessage: errorMessage, onCancel: onCancel, onConfirm: { onConfirm(draftTags) }) {
            VStack(alignment: .leading, spacing: 20) {
                if !draftTags.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(draftTags, id: \.self) { tag in
                            TagPill(text: tag) { removeTag(tag) }
                        }
                    }
                }

                // "Add THIS tag" lives *inside* the field itself, as a
                // trailing overlay — not a sibling control — specifically
                // so it doesn't stack visually beneath the chrome's own
                // large top-right ✓ ("checkmark under checkmark"). Same
                // small Cherries confirmation geometry as before, just
                // relocated; the field reserves 44pt of trailing padding
                // so typed text can never run underneath its hit target.
                // Dimmed (not hidden) when there's nothing to add, via
                // the control's own `isEnabled`/opacity — appearing and
                // disappearing outright would jump the field's contents.
                TextField("Add tag…", text: $newTagText)
                    .font(ArkyvFont.publicSans(size: 15))
                    .tracking(1)
                    .foregroundStyle(ArkyvColor.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($addFieldFocused)
                    .onSubmit { commitTypedTag() }
                    .padding(.leading, 14)
                    .padding(.trailing, 44)
                    .padding(.vertical, 10)
                    .arkyvOutlinedSurface(stroke: ArkyvColor.divider, radius: ArkyvRadius.row)
                    .overlay(alignment: .trailing) {
                        CherriesConfirmControl(
                            action: commitTypedTag,
                            isEnabled: !trimmedNewTag.isEmpty,
                            visibleMarkSize: 14,
                            color: ArkyvColor.textPrimary,
                            minimumHitTarget: 44
                        )
                        .padding(.trailing, 4)
                    }

                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .onAppear { addFieldFocused = true }
    }

    private func commitTypedTag() {
        let trimmed = trimmedNewTag
        newTagText = ""
        guard !trimmed.isEmpty else { return }
        guard !draftTags.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        draftTags.append(trimmed)
        // Keep the keyboard up so several tags can be added quickly.
        addFieldFocused = true
    }

    private func removeTag(_ tag: String) {
        draftTags.removeAll { $0 == tag }
    }
}

// MARK: - Folder

/// Folder-room typography deliberately borrows One Archive's own filter-
/// rail language (`ArkyvFont.mono`/`.sans`, i.e. Lora — not Public Sans)
/// rather than this room's chrome/label typeface, per explicit direction
/// to match "the folder-list language we already established in One
/// Archive" as closely as appropriate. Hierarchy is typography/spacing
/// only now — no cards, no per-folder glyphs (retired).
struct FolderEditorView: View {
    let item: StoredItem
    /// Called with the folder to move into, or `nil` for "Unfiled."
    /// `ItemDetailView` performs the actual `Repository.move`/unfile —
    /// nothing here touches persistence, so tapping a row only updates
    /// the local selection.
    let onConfirm: (StoredFolder?) -> Void
    let onCancel: () -> Void
    let modelContext: ModelContext
    /// Core Loop Hardening 02 §4 — see `ContextEditorChrome`'s own doc
    /// comment.
    var errorMessage: String? = nil

    @Query(sort: \StoredFolder.sortOrder) private var allFoldersRaw: [StoredFolder]
    @State private var selectedFolderID: UUID?
    @State private var showingNewFolder = false

    init(item: StoredItem, modelContext: ModelContext, errorMessage: String? = nil, onConfirm: @escaping (StoredFolder?) -> Void, onCancel: @escaping () -> Void) {
        self.item = item
        self.modelContext = modelContext
        self.errorMessage = errorMessage
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _selectedFolderID = State(initialValue: item.folder?.id)
    }

    private var folders: [StoredFolder] {
        allFoldersRaw.filter { !$0.isSoftDeleted }
    }

    var body: some View {
        ContextEditorChrome(
            title: "Folder",
            errorMessage: errorMessage,
            onCancel: onCancel,
            onConfirm: { onConfirm(folders.first { $0.id == selectedFolderID }) }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    // "Unfiled" is a *contextual current state*, not a
                    // permanent peer folder — it only ever appears when
                    // it's the current selection. Selecting a real folder
                    // makes it disappear; tapping the currently-selected
                    // row again (below, same mechanism for every row)
                    // clears the selection and brings it back. That reuse
                    // is deliberately the entire mechanism for "return to
                    // Unfiled" — no separate control was added for it.
                    if selectedFolderID == nil {
                        FolderSelectionRow(name: "Unfiled", isSelected: true) {
                            select(nil)
                        }
                    }
                    ForEach(folders) { folder in
                        FolderSelectionRow(name: folder.name, isSelected: folder.id == selectedFolderID) {
                            select(FolderSelectionUX.toggling(current: selectedFolderID, tapped: folder.id))
                        }
                    }

                    // A different *kind* of action from choosing a
                    // destination — lighter, italic, subdued, no
                    // card/icon — "need another place? you can make
                    // one," not another row to pick.
                    Button { showingNewFolder = true } label: {
                        Text("+ New Folder")
                            .font(ArkyvFont.publicSans(size: 14).italic())
                            .tracking(1)
                            .foregroundStyle(ArkyvColor.subdued)
                            .frame(minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 12)
                }
                .padding(20)
            }
        }
        .sheet(isPresented: $showingNewFolder) {
            NewFolderView { name, icon in
                // Folder creation itself stays immediate (see this
                // pass's report on why deferring it until the room's own
                // ✓ isn't a clean fit) — only the *move* stays staged:
                // the new folder becomes the local selection here, same
                // as picking any existing one, and isn't assigned to the
                // item until this room's ✓.
                guard let created = try? Repository(context: modelContext).createFolder(name: name, icon: icon) else { return }
                select(created.id)
            }
        }
    }

    /// Every row's tap routes through here so the local selection — and
    /// every row's resulting size/weight/color/checkmark change — settles
    /// under one coordinated "fast hands, calm room" transition
    /// (`ArkyvMotion.settle`) rather than snapping. Purely a local draft
    /// change; `Repository.move` still only happens on this room's own ✓.
    /// Row rendering itself now lives in the shared `FolderSelectionRow`
    /// (`Components/ArkyvComponents.swift`) — reused directly by the
    /// Import Cherry drawer's own folder selector so both pickers can
    /// never visually drift apart again.
    private func select(_ id: UUID?) {
        withAnimation(ArkyvMotion.settle) {
            selectedFolderID = id
        }
    }
}
