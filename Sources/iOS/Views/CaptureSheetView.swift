import SwiftUI
import SwiftData
import PhotosUI
import ArkyvKit

/// Dispatcher for the two ways a capture drawer gets presented:
///   • screenshot — Action Button / screenshot detection. An image draft
///     already exists; hands off directly to `ScreenshotCaptureFlowView`.
///   • add — the in-app "+" entry. No image exists yet.
///
/// Make Cherry Unification 01: `+`/Photo Library import and Action Button
/// capture are the SAME conceptual flow — "Make Cherry" — differing only
/// in how the source image arrives. Earlier milestones (Import Cherry
/// Drawer 01, Refinements 01–03) built add-mode as its own bespoke drawer
/// with its own crop affordance, its own image-local X, and its own
/// presentation architecture; physical-device QA showed that this created
/// exactly the "two different Cherry-creation interfaces" the product
/// direction now explicitly rejects. That entire bespoke presentation is
/// gone: add-mode now shows a small, common "Make Cherry" empty state
/// (below) only until an image is chosen, and the instant one is,
/// `pickedDraft` becomes non-nil and this view hands off to the exact same
/// `ScreenshotCaptureFlowView` Action Button capture already uses — same
/// crop bars, same crop interaction, same X/✓/folder hierarchy, same
/// motion, same save/cancel/original-image semantics. There is no
/// remaining Import-specific crop UI, folder UI, or save path — by
/// construction, since it's the identical view either way.
/// Presented full-screen, no drawer chrome — see `RootView`'s
/// `.presentationDetents`.
struct CaptureSheetView: View {
    let drawer: CaptureCoordinator.Drawer

    @Environment(CaptureCoordinator.self) private var capture
    @Environment(\.modelContext) private var context

    // Bug Squash 02: Pre-Import Folder Selection — same unfiltered
    // `@Query` + in-memory filter pattern `ScreenshotCaptureFlowView`
    // already uses, for the same type-checker-complexity reason (see its
    // own `allFoldersRaw` doc comment).
    @Query(sort: [SortDescriptor(\StoredFolder.sortOrder)])
    private var allFoldersRaw: [StoredFolder]

    private var folders: [StoredFolder] {
        allFoldersRaw.filter { !$0.isSoftDeleted }
    }

    @State private var pickerItem: PhotosPickerItem?
    @State private var isLoadingPhoto = false
    /// Core Loop Hardening 02 §6: before this, every failure path in
    /// `loadPickedPhoto()` (transferable load failure, undecodable data,
    /// `MediaStore.save` failure) ended the same way — `isLoadingPhoto`
    /// flips back to false and the button silently returns to "Choose
    /// from Photos" with zero signal that anything went wrong. A user
    /// who tapped a photo and watched it do nothing had no way to tell
    /// that from "I didn't actually tap the button." This is the same
    /// transient-inline-text pattern as `ItemDetailView`'s
    /// `favoriteErrorVisible`, not a new toast framework.
    @State private var importFailed = false
    /// Set the instant a library photo is saved to `MediaStore` — from
    /// then on this view is purely a pass-through to
    /// `ScreenshotCaptureFlowView`, identical to the screenshot-capture
    /// path. `.fullImage` crop region (the `CaptureDraft` default): "the
    /// crop bars communicate agency, not an imposed transformation" — the
    /// user sees the complete incoming image and only a CropRegion other
    /// than `.fullImage` if they deliberately move a handle.
    @State private var pickedDraft: CaptureDraft?
    /// Bug Squash 02: Pre-Import Folder Selection — folder destination and
    /// media selection are independent choices; a folder picked here,
    /// before any photo exists, must survive into `ScreenshotCaptureFlowView`
    /// once one is chosen (passed as `initialFolder` below), not silently
    /// reset to Unfiled.
    @State private var preSelectedFolder: StoredFolder?
    @State private var showingPreImportPicker = false
    @State private var showingNewFolder = false

    var body: some View {
        Group {
            switch drawer {
            case .screenshot(let draft):
                ScreenshotCaptureFlowView(draft: draft)
            case .add:
                if let pickedDraft {
                    ScreenshotCaptureFlowView(draft: pickedDraft, initialFolder: preSelectedFolder)
                } else {
                    makeCherryEmptyState
                }
            }
        }
    }

    // MARK: Empty Make Cherry state — "+" before an image exists

    /// Deliberately mirrors `ScreenshotCaptureFlowView.fallbackCaptureLayer`'s
    /// own geometry (same darkroom black canvas, same X/✓ row padding) —
    /// "the precise spacing should follow current Action Capture
    /// geometry." ✓ is disabled: there's nothing to save yet.
    ///
    /// Bug Squash 02: Pre-Import Folder Selection — the "Unfiled ˅" line
    /// used to be inert `Text` here (see the removed doc comment this
    /// replaced: "isn't interactive here"), while the visually-identical
    /// control became a real `Button` the instant a photo was picked —
    /// same label, two different pieces of UI, so it looked broken before
    /// a photo existed. Folder destination and media selection are
    /// independent choices the user can make in either order; this is
    /// now a fully working selector matching `ScreenshotCaptureFlowView`'s
    /// own folder accessory/dropdown/create-folder contract exactly
    /// (`FolderSelectionUX`/`NewFolderView`), just against
    /// `preSelectedFolder` instead of that view's own `selectedFolder` —
    /// which then survives the hand-off once a photo is picked (see
    /// `body` above).
    private var makeCherryEmptyState: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack {
                    CherriesCancelControl(action: { capture.dismiss() })
                    Spacer()
                    CherriesConfirmControl(action: {}, isEnabled: false)
                }
                .padding(.horizontal, 32)
                .padding(.top, 20)
                .padding(.bottom, 12)

                Button {
                    showingPreImportPicker.toggle()
                } label: {
                    Text(preSelectedFolder.map { "\($0.name) ˅" } ?? "Unfiled ˅")
                        .font(ArkyvFont.mono(.medium, size: 16))
                        .italic(preSelectedFolder == nil)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                }
                .padding(.bottom, 12)

                // Empty-state refinement: a bare `Spacer()` above and below
                // split remaining height evenly, centering the row — physical
                // QA read that as too low/bottom-heavy. Capping only the
                // LEADING spacer's growth (the trailing one stays unbounded)
                // means it stops absorbing space once it hits that cap, so
                // every bit of height beyond it goes to the trailing spacer
                // instead — the row sits roughly halfway between its old
                // centered position and `Unfiled` above it, without needing
                // exact geometry math for what's a one-time cosmetic nudge.
                Spacer(minLength: 16).frame(maxHeight: 90)

                PhotosPicker(selection: $pickerItem, matching: .images) {
                    HStack(spacing: 4) {
                        if isLoadingPhoto {
                            ProgressView().tint(.white.opacity(0.6))
                        }
                        // Public Sans — the utility/action face, not the
                        // editorial one — matching Item Detail's own
                        // affordances (see ArkyvFont.swift's doc comment).
                        // "Choose from Photos," not "Import from library" —
                        // physical QA found "library" ambiguous (Cherries
                        // library? local files? Photos?); naming the actual
                        // source removes the ambiguity. Not "Upload" either —
                        // that implies sending media to a server, the wrong
                        // mental model here.
                        Text(isLoadingPhoto ? "Loading..." : "Choose from Photos")
                            .font(ArkyvFont.publicSans(size: 15, weight: .medium))
                        if !isLoadingPhoto {
                            // Same micro-arrow family/scale as Item Detail's
                            // Link Cherry source-URL button (`arrow.up.right`,
                            // same `HStack(spacing: 4)`, same 10pt semibold
                            // scale) — a plain "up" reads most naturally as
                            // "bring this up into Cherries" (a prior down-left
                            // pass didn't read cleanly at this size).
                            Image(systemName: "arrow.up")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white)
                }
                .disabled(isLoadingPhoto)

                if importFailed {
                    Text("Couldn't import that photo — try again")
                        .font(ArkyvFont.mono(.regular, size: 12))
                        .foregroundStyle(ArkyvColor.accent)
                        .padding(.top, 10)
                        .transition(.opacity)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .animation(.easeOut(duration: 0.2), value: importFailed)
            .task(id: pickerItem) { await loadPickedPhoto() }

            if showingPreImportPicker {
                preImportDropdownOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: showingPreImportPicker)
        .sheet(isPresented: $showingNewFolder) {
            NewFolderView { name, icon in
                guard let created = try? Repository(context: context).createFolder(name: name, icon: icon) else { return }
                preSelectedFolder = created
                showingPreImportPicker = false
            }
        }
    }

    /// Bug Squash 02: same tap-outside-to-dismiss + Unfiled/folders/
    /// Create-folder contract `ScreenshotCaptureFlowView.dropdownOverlay`/
    /// `.folderPanel` established in Bug Squash 01 — a third copy of the
    /// same now-proven pattern (matching this codebase's existing
    /// precedent of `ScreenshotCaptureFlowView` and `ShareViewController`
    /// each owning their own private folder-picker UI), not a new
    /// architecture.
    private var preImportDropdownOverlay: some View {
        VStack {
            Spacer()
                .frame(height: 140)
                .contentShape(Rectangle())
                .onTapGesture { showingPreImportPicker = false }
            preImportFolderPanel
            Spacer()
                .contentShape(Rectangle())
                .onTapGesture { showingPreImportPicker = false }
        }
        .padding(.horizontal, 24)
    }

    private var preImportFolderPanel: some View {
        VStack(spacing: 4) {
            if preSelectedFolder == nil {
                FolderSelectionRow(name: "Unfiled", isSelected: true, foregroundColor: .white) {
                    showingPreImportPicker = false
                }
            }
            ForEach(folders) { folder in
                FolderSelectionRow(
                    name: folder.name,
                    isSelected: folder.id == preSelectedFolder?.id,
                    isSuggested: folder.id == capture.suggestion?.id,
                    foregroundColor: .white
                ) {
                    let resultID = FolderSelectionUX.toggling(current: preSelectedFolder?.id, tapped: folder.id)
                    preSelectedFolder = (resultID == folder.id) ? folder : nil
                    showingPreImportPicker = false
                }
            }
            Button {
                showingNewFolder = true
            } label: {
                Text("+ Create folder")
                    .font(ArkyvFont.publicSans(size: 14).italic())
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(8)
        .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: ArkyvRadius.sheet))
        .overlay(
            RoundedRectangle(cornerRadius: ArkyvRadius.sheet)
                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 12, y: 12)
    }

    /// Loads the picked photo into `MediaStore`, then builds the same kind
    /// of `CaptureDraft` the screenshot detector produces — from this
    /// point on there is no distinction between the two entry paths.
    /// `refreshSuggestion` mirrors `CaptureCoordinator.present(_:)` (the
    /// screenshot path's own entry point), which always computes a fresh
    /// folder suggestion against the real image before presenting — the
    /// only reason `startAdd()` couldn't already do this is that it runs
    /// before any image exists to suggest against.
    ///
    /// Media Preservation Foundation 01: `pickerItem.loadTransferable(type:
    /// Data.self)` was already loading Photos' own real encoded bytes —
    /// this previously decoded them to `UIImage` only to immediately
    /// discard them and re-encode as JPEG via `MediaStore.save(image:)`,
    /// silently flattening an animated GIF to its first frame or stripping
    /// a transparent PNG's alpha (Long Tail · Universal Capture Recon 01,
    /// confirmed on Device A). Now persists exactly what Photos handed
    /// over, unmodified, via `MediaStore.save(data:)`, with the real
    /// extension read from the bytes themselves
    /// (`ImageDecoding.fileExtension(ofData:)`) rather than assumed. This
    /// does not claim byte-identity with the user's original Camera Roll
    /// asset — only that Cherries no longer re-encodes what it was
    /// actually given. Falls back to the previous decode-then-JPEG path
    /// only if the bytes are genuinely undecodable as an image at all
    /// (`ImageDecoding.pixelSize(ofData:)` returning `nil`) — the safest
    /// existing behavior, not a new one.
    private func loadPickedPhoto() async {
        guard let pickerItem else { return }
        isLoadingPhoto = true
        importFailed = false
        defer { isLoadingPhoto = false }

        guard let data = try? await pickerItem.loadTransferable(type: Data.self) else {
            log("photo import FAILED: loadTransferable returned nil")
            reportImportFailure()
            return
        }

        let draft: CaptureDraft?
        if let pixelSize = ImageDecoding.pixelSize(ofData: data) {
            let ext = ImageDecoding.fileExtension(ofData: data)
            if let filename = try? MediaStore.shared.save(data: data, ext: ext) {
                draft = CaptureDraft(kind: .image, localFilename: filename, pixelSize: pixelSize, sourceDevice: .iOS, acquisitionOrigin: .photoLibraryImport)
            } else {
                draft = nil
            }
        } else if let image = UIImage(data: data), let saved = try? MediaStore.shared.save(image: image) {
            // Safest existing fallback — only reached when ImageIO can't
            // read dimensions from what Photos supplied at all.
            draft = CaptureDraft(kind: .image, localFilename: saved.filename, pixelSize: saved.size, sourceDevice: .iOS, acquisitionOrigin: .photoLibraryImport)
        } else {
            draft = nil
        }

        guard let draft else {
            log("photo import FAILED: could not decode or store picked photo data")
            reportImportFailure()
            return
        }
        capture.refreshSuggestion(for: draft)
        pickedDraft = draft
    }

    private func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[CaptureSheetView] \(message())")
        #endif
    }

    private func reportImportFailure() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
        importFailed = true
        // Clears the picker selection so tapping "Choose from Photos"
        // again — even for the same photo — gives `.task(id: pickerItem)`
        // a real state change to fire on, rather than leaving a stale
        // failed `PhotosPickerItem` sitting in `$pickerItem`.
        pickerItem = nil
    }
}
