import SwiftUI
import SwiftData
import PhotosUI
import ArkyvKit

/// Dispatcher for the two drawer modes — they no longer share a layout:
///   • screenshot — hands off entirely to `ScreenshotCaptureFlowView`, the
///     v0.02 capture choreography (prompt → isolate → folder dropdown → save).
///   • add — the in-app "+" entry: photo picker + note field, still the
///     original translucent-panel-over-backdrop layout, unchanged.
/// Presented full-screen (`.large` detent, see `RootView`).
struct CaptureSheetView: View {
    let drawer: CaptureCoordinator.Drawer

    @Environment(CaptureCoordinator.self) private var capture
    @Environment(\.modelContext) private var context

    @Query(filter: #Predicate<StoredFolder> { !$0.isDeleted },
           sort: [SortDescriptor(\StoredFolder.sortOrder)])
    private var folders: [StoredFolder]

    @State private var note = ""
    @State private var pickerItem: PhotosPickerItem?
    /// Photo staged in add-mode: (filename in MediaStore, pixel size).
    @State private var stagedPhoto: (filename: String, size: CGSize)?
    @State private var isLoadingPhoto = false
    /// Folder mid-confirmation: haptic + checkmark fire immediately, then the
    /// actual file+dismiss happens after `confirmDelay` so the tap always
    /// reads as "that registered" before the sheet disappears.
    @State private var confirmingFolderID: UUID?
    private let confirmDelay: Duration = .milliseconds(180)
    /// The suggested folder is present from frame one; everything else in the
    /// grid settles in a beat later. No label, no color — just arrival order.
    /// Keyed off a single bool today, but the concept (how much of the grid
    /// waits vs. arrives instantly) is the same lever a future confidence
    /// score would drive.
    @State private var gridSettled = false

    private var isAdd: Bool { drawer.isAdd }

    /// The screenshot actually being filed, so the panel floats over the real
    /// thing instead of a flat background.
    private var screenshotFilename: String? {
        if case .screenshot(let draft) = drawer { return draft.localFilename }
        return nil
    }

    /// Something is stageable to save (add-mode needs a photo or note text).
    private var canSave: Bool {
        if isAdd { return stagedPhoto != nil || !note.trimmingCharacters(in: .whitespaces).isEmpty }
        return true
    }

    var body: some View {
        Group {
            switch drawer {
            case .screenshot(let draft):
                // v0.02 flow — see ScreenshotCaptureFlowView. Add-mode below
                // is untouched; the two are different enough now (no photo to
                // isolate, a note field, an explicit "choose from library"
                // step) that they don't share a body.
                ScreenshotCaptureFlowView(draft: draft)
            case .add:
                addModeBody
            }
        }
        .preferredColorScheme(.dark)
    }

    private var addModeBody: some View {
        ZStack(alignment: .bottom) {
            backdrop
            actionPanel
        }
        .sensoryFeedback(.impact(weight: .light), trigger: confirmingFolderID) { _, new in
            new != nil
        }
        .task(id: pickerItem) { await loadPickedPhoto() }
    }

    // MARK: Backdrop — the screenshot is the hero, the UI is just the frame

    /// Full-bleed: the actual screenshot fills the whole screen behind the
    /// panel. Falls back to the flat background when there's nothing to show
    /// yet (add-mode, before a photo's staged).
    private var backdrop: some View {
        Group {
            if let filename = screenshotFilename {
                LocalImageView(filename: filename, contentMode: .fill)
            } else {
                ArkyvColor.background
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .ignoresSafeArea()
    }

    // MARK: Action panel — translucent, floats over the screenshot

    private var actionPanel: some View {
        VStack(spacing: ArkyvSpacing.sheetSection) {
            ArkyvMarkView(height: 47, color: ArkyvColor.textPrimary)

            if isAdd {
                photoPicker
                quickNoteField
            }

            folderGrid
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(ArkyvColor.sheetScrim)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: ArkyvRadius.sheet, topTrailingRadius: ArkyvRadius.sheet))
        .overlay(alignment: .topTrailing) {
            dismissButton
                .padding(.trailing, 20)
                .padding(.top, 24)
        }
    }

    private var dismissButton: some View {
        Button {
            capture.dismiss()
        } label: {
            // icon-dismiss: 32×32 tap target, X drawn at 12×12 — the circle is
            // the invisible tap area, not a drawn stroke, so the mark stays
            // quiet against the sheet.
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ArkyvColor.iconDefault)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
    }

    // MARK: Add-mode photo picker

    private var photoPicker: some View {
        Group {
            if let staged = stagedPhoto {
                ZStack(alignment: .topTrailing) {
                    LocalImageView(filename: staged.filename, contentMode: .fill)
                        .frame(height: 150)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: ArkyvRadius.card))
                    Button {
                        MediaStore.shared.delete(filename: staged.filename)
                        stagedPhoto = nil
                        pickerItem = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white, .black.opacity(0.5))
                            .padding(8)
                    }
                }
            } else {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    HStack(spacing: 10) {
                        if isLoadingPhoto {
                            ProgressView().tint(ArkyvColor.textSecondary)
                        } else {
                            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 18))
                        }
                        Text(isLoadingPhoto ? "Loading..." : "Choose from library")
                            .font(.arkyvLabel)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(ArkyvColor.textPrimary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .arkyvOutlinedSurface()
                }
            }
        }
    }

    // MARK: Folder grid

    private var folderGrid: some View {
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(folders) { folder in
                folderButton(folder)
            }
        }
        .onAppear {
            guard !gridSettled else { return }
            withAnimation(.easeOut(duration: 0.22).delay(0.09)) {
                gridSettled = true
            }
        }
    }

    private func folderButton(_ folder: StoredFolder) -> some View {
        let isSuggested = folder.id == capture.suggestion?.id && canSave
        let isConfirming = confirmingFolderID == folder.id
        let isLocked = confirmingFolderID != nil && !isConfirming
        let isHighlighted = isSuggested || isConfirming
        return Button {
            confirm(folder)
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    FolderIconView(icon: folder.icon, size: 18, color: ArkyvColor.accent)
                        .opacity(isConfirming ? 0 : 1)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(ArkyvColor.textPrimary)
                        .opacity(isConfirming ? 1 : 0)
                        .scaleEffect(isConfirming ? 1 : 0.6)
                }
                .frame(width: 20, height: 20)
                Text(folder.name)
                    .font(.arkyvLabel)
                    .foregroundStyle(ArkyvColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .arkyvOutlinedSurface(
                fill: isHighlighted ? ArkyvColor.surface : ArkyvColor.card,
                stroke: isHighlighted ? ArkyvColor.textPrimary : ArkyvColor.border,
                lineWidth: isHighlighted ? 1.5 : 1
            )
            .scaleEffect(isConfirming ? 0.97 : 1)
        }
        .disabled(!canSave || isLocked)
        .opacity(isLocked ? 0.4 : (canSave ? 1 : 0.5))
        .animation(.easeOut(duration: 0.15), value: isConfirming)
        // Arrival order, not styling: the suggested folder is simply already
        // there; everything else settles in a beat behind it.
        .opacity(isSuggested || gridSettled ? 1 : 0)
        .offset(y: isSuggested || gridSettled ? 0 : 6)
        .animation(.easeOut(duration: 0.22), value: gridSettled)
    }

    // MARK: Add-mode note field

    private var quickNoteField: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.cursor").foregroundStyle(ArkyvColor.textDim).font(.system(size: 13))
            TextField(
                "Add a note (optional)...",
                text: $note,
                axis: .vertical
            )
            .font(.arkyvBody)
            .foregroundStyle(ArkyvColor.textPrimary)
            .lineLimit(1...3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .arkyvOutlinedSurface(fill: ArkyvColor.card, stroke: ArkyvColor.border)
    }

    /// Locks in a folder tap: haptic + checkmark fire immediately (via the
    /// `confirmingFolderID` state change), then the real file+dismiss follows
    /// after `confirmDelay` so the confirmation is actually seen.
    private func confirm(_ folder: StoredFolder) {
        guard canSave, confirmingFolderID == nil else { return }
        confirmingFolderID = folder.id
        Task {
            try? await Task.sleep(for: confirmDelay)
            capture.file(effectiveDraft(), into: folder)
        }
    }

    // MARK: Draft assembly

    /// Builds the draft to file from the current mode + staged content.
    private func effectiveDraft() -> CaptureDraft {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty ? nil : trimmed

        switch drawer {
        case .screenshot(var draft):
            draft.noteBody = body ?? draft.noteBody
            return draft
        case .add:
            if let staged = stagedPhoto {
                return CaptureDraft(
                    kind: .image,
                    localFilename: staged.filename,
                    pixelSize: staged.size,
                    noteBody: body,
                    sourceDevice: .iOS
                )
            }
            return CaptureDraft(kind: .note, noteBody: body, sourceDevice: .iOS)
        }
    }

    private func loadPickedPhoto() async {
        guard let pickerItem else { return }
        isLoadingPhoto = true
        defer { isLoadingPhoto = false }
        guard let data = try? await pickerItem.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let saved = try? MediaStore.shared.save(image: image) else { return }
        stagedPhoto = (saved.filename, saved.size)
        capture.refreshSuggestion(for: CaptureDraft(kind: .image, localFilename: saved.filename))
    }
}
