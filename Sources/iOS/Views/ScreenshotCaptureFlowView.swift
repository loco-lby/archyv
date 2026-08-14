import SwiftUI
import SwiftData
import ArkyvKit
#if canImport(UIKit)
import UIKit
#endif

/// The v0.04 capture flow — canonical destination for the Action Button /
/// Share Extension / screenshot-detector paths. One continuous capture
/// surface, no separate crop-then-folder wizard:
///
///   1. `.loadingImage` — brief, loads the original screenshot off disk so
///                        the real `CropEditorView` has pixels to work with.
///   2. `.capturing`    — the real crop editor, opened at `.fullImage`,
///                        with a folder control as an accessory in its own
///                        chrome strip. Cropping and choosing a folder are
///                        both optional; ✓ saves immediately with whatever
///                        `CropRegion`/folder are current at the moment
///                        it's tapped. There is no second screen, no
///                        artifact resize/reposition, and no second X/✓ —
///                        the capture stays on the same canvas, in the
///                        same presentation, the entire time.
///
/// X always cancels the whole capture. ✓ always saves the current capture
/// immediately — cropping and folder selection are enhancements to that
/// save, never prerequisites for it:
///
///   capture → ✓                          → full screenshot, Unfiled
///   capture → crop → ✓                    → cropped screenshot, Unfiled
///   capture → choose folder → ✓           → full screenshot, that folder
///   capture → crop + choose folder → ✓    → cropped screenshot, that folder
///
/// "Unfiled" here is the existing, already-canonical shape — zero folder
/// memberships (see `StoredModels.swift`'s doc comment on `StoredItem`) —
/// not a new concept; choosing no folder simply calls
/// `Repository.fileCapture` with no `folders:` argument, exactly like the
/// Share Extension's own Unfiled fallback already does.
struct ScreenshotCaptureFlowView: View {
    let draft: CaptureDraft

    @Environment(CaptureCoordinator.self) private var capture
    @Environment(\.modelContext) private var context

    // Unfiltered `@Query` + in-memory filter, not a `#Predicate` nil-check —
    // see ArchiveView.swift's `allFoldersRaw` doc comment: a `deletedAt ==
    // nil` predicate combined with a `sort:` argument in the same `@Query`
    // hits a SwiftData/Swift type-checker complexity limit.
    @Query(sort: [SortDescriptor(\StoredFolder.sortOrder)])
    private var allFoldersRaw: [StoredFolder]

    private var folders: [StoredFolder] {
        allFoldersRaw.filter { !$0.isSoftDeleted }
    }

    private enum Stage { case loadingImage, capturing }
    @State private var stage: Stage = .loadingImage
    /// The original screenshot's pixels, loaded once for the crop editor.
    /// Never mutated, never re-encoded — `CropEditorView` only ever reads
    /// this to compute a normalized `CropRegion`. `nil` in `.capturing`
    /// only for the rare crop-unavailable fallback below.
    @State private var sourceImage: UIImage?
    /// Disambiguates `CropEditorView`'s single `onDismiss` closure — it
    /// fires both after Cancel and right after a successful ✓. Set only
    /// right after a successful save, read only by `onDismiss`, so Cancel
    /// (discard, dismiss immediately) and a successful save (already
    /// dismissing itself on its own delay — see `confirmSave`) stay
    /// correct without `CropEditorView` needing to know which happened.
    @State private var saveSucceeded = false
    /// True only if the source image could not be decoded after retries —
    /// the fundamental invariant is that this never discards the capture,
    /// it just means the crop canvas is skipped and the whole screenshot
    /// is what gets filed (see `loadSourceImage`).
    @State private var cropUnavailable = false
    @State private var showingPicker = false
    /// Chosen in the dropdown (see `chooseFolder`), not yet saved — ✓ is
    /// what actually files the capture (see `confirmSave`). Freely
    /// reassignable: reopening the folder control and picking a different
    /// row just overwrites this, nothing to undo. `nil` means Unfiled,
    /// the existing canonical zero-membership shape — not a separate
    /// "All" concept.
    @State private var selectedFolder: StoredFolder?
    @State private var didSave = false
    @State private var saveError = false

    var body: some View {
        Group {
            switch stage {
            case .loadingImage:
                loadingLayer
            case .capturing:
                capturingLayer
            }
        }
        .animation(.easeOut(duration: 0.22), value: stage)
        .onAppear {
            log("appeared for draft \(draft.id)")
            loadSourceImage()
        }
        .onDisappear { log("disappeared for draft \(draft.id)") }
        .onChange(of: stage) { old, new in log("stage: \(old) -> \(new)") }
        .onChange(of: didSave) { old, new in log("didSave: \(old) -> \(new)") }
        .onChange(of: showingPicker) { old, new in log("showingPicker: \(old) -> \(new)") }
        .onChange(of: saveError) { old, new in log("saveError: \(old) -> \(new)") }
    }

    private func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[ScreenshotCaptureFlowView] \(message())")
        #endif
    }

    // MARK: Stage 1 — loading the source image

    private var loadingLayer: some View {
        ZStack {
            ArkyvColor.background.ignoresSafeArea()
            ProgressView().tint(ArkyvColor.textSecondary)
        }
    }

    /// Reads the just-written screenshot back off `MediaStore` for the crop
    /// editor. A couple of short retries cover the rare case of reading
    /// pixels back immediately after they were written; if it still fails,
    /// the crop canvas is skipped rather than the capture being discarded —
    /// crop failure must never become capture loss (see `capturingLayer`'s
    /// fallback branch).
    private func loadSourceImage() {
        guard let filename = draft.localFilename else {
            log("no localFilename on draft \(draft.id) — skipping crop, filing as-is")
            cropUnavailable = true
            stage = .capturing
            return
        }
        Task {
            let maxAttempts = 3
            for attempt in 1...maxAttempts {
                let data = await Task.detached(priority: .userInitiated) {
                    MediaStore.shared.data(for: filename)
                }.value
                if let data, let image = UIImage(data: data) {
                    log("source image loaded on attempt \(attempt) (\(Int(image.size.width))x\(Int(image.size.height)))")
                    sourceImage = image
                    stage = .capturing
                    return
                }
                log("source image load failed on attempt \(attempt)/\(maxAttempts)")
                if attempt < maxAttempts {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            log("source image load failed after \(maxAttempts) attempts — filing whole screenshot without crop editor")
            cropUnavailable = true
            stage = .capturing
        }
    }

    // MARK: Stage 2 — the one continuous capture surface

    private var capturingLayer: some View {
        ZStack {
            Group {
                if let sourceImage {
                    CropEditorView(
                        image: sourceImage,
                        region: draft.cropRegion,
                        onConfirm: { region in
                            let succeeded = confirmSave(cropRegion: region)
                            if succeeded { saveSucceeded = true }
                            return succeeded
                        },
                        onDismiss: {
                            if saveSucceeded {
                                // confirmSave already scheduled its own
                                // delayed capture.dismiss() so the brief
                                // "Saved" state is visible — nothing more
                                // to do here.
                            } else {
                                log("crop editor cancelled — dismissing whole capture")
                                capture.dismiss()
                            }
                        },
                        accessory: { folderAccessory }
                    )
                } else {
                    // Rare fallback: the source image couldn't be decoded
                    // after retries. There's nothing to crop, but the
                    // capture itself must still be filable — same X/✓
                    // language, no crop canvas beneath it.
                    fallbackCaptureLayer
                }
            }
            .opacity(didSave ? 0 : 1)
            .allowsHitTesting(!didSave)

            if showingPicker && !didSave {
                dropdownOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }

            if didSave {
                confirmationOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .onAppear { log("confirmationOverlay appeared") }
                    .onDisappear { log("confirmationOverlay disappeared") }
            }
        }
        .animation(.easeOut(duration: 0.18), value: showingPicker)
        .animation(.easeOut(duration: 0.22), value: didSave)
        .animation(.easeOut(duration: 0.2), value: saveError)
    }

    /// Same X/✓ positioning as `CropEditorView`'s own bar, reused directly
    /// (not duplicated by hand) since there's no crop canvas to host it in
    /// this branch.
    private var fallbackCaptureLayer: some View {
        VStack(spacing: 0) {
            HStack {
                CherriesCancelControl(action: { capture.dismiss() })
                Spacer()
                CherriesConfirmControl(action: { _ = confirmSave(cropRegion: .fullImage) })
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 12)
            folderAccessory
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }

    // MARK: Folder accessory — sits directly under the X/✓ row, on the
    // same continuous capture surface, whether that's the real crop
    // canvas or the rare no-image fallback above.

    /// Selecting a folder here only updates in-flight state (see
    /// `chooseFolder`) — it never touches the crop canvas and never saves
    /// by itself. ✓ is the only thing that saves, using whatever's
    /// selected here (or Unfiled if nothing is). Labeled "Unfiled ˅" by
    /// default rather than "Select folder ˅" so the control always states
    /// where ✓ is *actually* about to save to, since ✓ is live the whole
    /// time, not gated behind a folder choice.
    private var folderAccessory: some View {
        VStack(spacing: 4) {
            Button {
                showingPicker = true
            } label: {
                // Italic reads as "this is the default, you may change it
                // but don't have to" — roman once a folder's explicitly
                // chosen reads as settled. Same size either way.
                Text(selectedFolder.map { "\($0.name) ˅" } ?? "Unfiled ˅")
                    .font(ArkyvFont.mono(.medium, size: 16))
                    .italic(selectedFolder == nil)
                    .foregroundStyle(.white)
            }
            .disabled(showingPicker)
            if cropUnavailable {
                Text("Crop unavailable — saving full screenshot")
                    .font(ArkyvFont.mono(.regular, size: 11))
                    .foregroundStyle(ArkyvColor.textDim)
            }
            if saveError {
                Text("Couldn't save — try again")
                    .font(ArkyvFont.mono(.regular, size: 11))
                    .foregroundStyle(ArkyvColor.accent)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
    }

    // MARK: Folder dropdown — exactly the V2 storyboard's dropdown-panel

    private var dropdownOverlay: some View {
        VStack {
            // Roughly the combined height of CropEditorView's own X/✓ row
            // plus the folder accessory beneath it — an estimate to tune
            // once this is checked on device, not a measured value.
            Spacer().frame(height: 140)
            folderPanel
            Spacer()
        }
        .padding(.horizontal, 24)
        .allowsHitTesting(!didSave)
    }

    private var folderPanel: some View {
        VStack(spacing: 4) {
            ForEach(folders) { folder in
                folderRow(folder)
            }
        }
        .padding(8)
        .background(ArkyvColor.card, in: RoundedRectangle(cornerRadius: ArkyvRadius.sheet))
        .overlay(
            RoundedRectangle(cornerRadius: ArkyvRadius.sheet)
                .strokeBorder(ArkyvColor.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 12, y: 12)
    }

    private func folderRow(_ folder: StoredFolder) -> some View {
        // Emphasis may change. Position never does — `folders` is the stable
        // sortOrder query; suggestion only ever affects this row's styling.
        let isSuggested = folder.id == capture.suggestion?.id
        let isSelected = folder.id == selectedFolder?.id
        let isHighlighted = isSuggested || isSelected
        return Button {
            chooseFolder(folder)
        } label: {
            HStack(spacing: 10) {
                FolderIconView(icon: folder.icon, size: 13, color: ArkyvColor.accent)
                Text(folder.name)
                    .font(ArkyvFont.mono(isSuggested ? .bold : .regular, size: 13))
                    .foregroundStyle(ArkyvColor.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ArkyvColor.accent)
                } else if isSuggested {
                    Circle().fill(ArkyvColor.accent).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                isHighlighted ? ArkyvColor.accent.opacity(0.06) : Color.clear,
                in: RoundedRectangle(cornerRadius: ArkyvRadius.row)
            )
            .overlay(alignment: .leading) {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(ArkyvColor.accent)
                        .frame(width: 2)
                        .padding(.vertical, 2)
                }
            }
        }
        .disabled(didSave)
    }

    /// Tapping a folder row *selects* it — closes the dropdown and returns
    /// to the capture surface with that folder's name now in place of
    /// "Unfiled ˅". Nothing is persisted yet; ✓ is the actual save (see
    /// `confirmSave`), so the choice stays freely changeable right up
    /// until it's confirmed.
    private func chooseFolder(_ folder: StoredFolder) {
        selectedFolder = folder
        showingPicker = false
    }

    // MARK: Confirmation — ✓ IS the save, no separate button

    private var confirmationOverlay: some View {
        VStack(spacing: 16) {
            Text("Saved ✓")
                .font(ArkyvFont.mono(.bold, size: 20))
                .foregroundStyle(ArkyvColor.textPrimary)
            Button {
                capture.dismiss()
            } label: {
                Text("View →")
                    .font(ArkyvFont.mono(.regular, size: 13))
                    .foregroundStyle(ArkyvColor.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(ArkyvColor.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(ArkyvColor.border, lineWidth: 1))
            }
        }
    }

    // MARK: Save

    /// ✓ IS the save — no separate Save button, no dismiss-delay morph, no
    /// second confirmation step. The write is synchronous (SwiftData
    /// `context.save()`), so gating the haptic and "Saved ✓" on its actual
    /// result costs no perceptible delay — it still reads as instant, but
    /// it's now instant *and honest*: the confirmation only appears once
    /// the row is really in the database. A failed write leaves the user
    /// free to just try again (`selectedFolder` is untouched), instead of
    /// silently lying "Saved."
    ///
    /// This is the single persistence moment for the whole flow: `draft`
    /// itself is never mutated (it stays exactly what was captured), only
    /// a local copy carries `cropRegion` (whatever the crop canvas
    /// currently shows, defaulting to `.fullImage`) into
    /// `Repository.fileCapture` — the original screenshot on disk is
    /// untouched either way. `selectedFolder == nil` files with no
    /// `folders:` argument at all — the existing, already-canonical
    /// Unfiled shape, not a new code path.
    private func confirmSave(cropRegion: CropRegion) -> Bool {
        guard !didSave else { return false }
        saveError = false
        var filedDraft = draft
        filedDraft.cropRegion = cropRegion
        do {
            if let selectedFolder {
                try Repository(context: context).fileCapture(filedDraft, into: selectedFolder)
                log("repository save completed — draft \(draft.id) filed into \"\(selectedFolder.name)\" with cropRegion \(cropRegion.rect)")
            } else {
                try Repository(context: context).fileCapture(filedDraft)
                log("repository save completed — draft \(draft.id) filed Unfiled with cropRegion \(cropRegion.rect)")
            }
        } catch {
            log("repository save FAILED for draft \(draft.id): \(error)")
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            #endif
            saveError = true
            return false
        }
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
        didSave = true
        showingPicker = false
        Task {
            try? await Task.sleep(for: .milliseconds(1000))
            log("post-save delay elapsed — calling capture.dismiss()")
            capture.dismiss()
        }
        return true
    }
}
