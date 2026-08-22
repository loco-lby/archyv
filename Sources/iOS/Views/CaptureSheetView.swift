import SwiftUI
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

    @State private var pickerItem: PhotosPickerItem?
    @State private var isLoadingPhoto = false
    /// Set the instant a library photo is saved to `MediaStore` — from
    /// then on this view is purely a pass-through to
    /// `ScreenshotCaptureFlowView`, identical to the screenshot-capture
    /// path. `.fullImage` crop region (the `CaptureDraft` default): "the
    /// crop bars communicate agency, not an imposed transformation" — the
    /// user sees the complete incoming image and only a CropRegion other
    /// than `.fullImage` if they deliberately move a handle.
    @State private var pickedDraft: CaptureDraft?

    var body: some View {
        Group {
            switch drawer {
            case .screenshot(let draft):
                ScreenshotCaptureFlowView(draft: draft)
            case .add:
                if let pickedDraft {
                    ScreenshotCaptureFlowView(draft: pickedDraft)
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
    /// geometry." ✓ is disabled: there's nothing to save yet. The folder
    /// line reads "Unfiled ˅" but isn't interactive here — there's no
    /// image to attach a folder choice to until one exists, and real
    /// folder selection is `ScreenshotCaptureFlowView`'s own fully
    /// functional control the moment this hands off to it.
    private var makeCherryEmptyState: some View {
        VStack(spacing: 0) {
            HStack {
                CherriesCancelControl(action: { capture.dismiss() })
                Spacer()
                CherriesConfirmControl(action: {}, isEnabled: false)
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Text("Unfiled ˅")
                .font(ArkyvFont.mono(.medium, size: 16))
                .italic()
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
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

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .task(id: pickerItem) { await loadPickedPhoto() }
    }

    /// Loads the picked photo into `MediaStore`, then builds the same kind
    /// of `CaptureDraft` the screenshot detector produces — from this
    /// point on there is no distinction between the two entry paths.
    /// `refreshSuggestion` mirrors `CaptureCoordinator.present(_:)` (the
    /// screenshot path's own entry point), which always computes a fresh
    /// folder suggestion against the real image before presenting — the
    /// only reason `startAdd()` couldn't already do this is that it runs
    /// before any image exists to suggest against.
    private func loadPickedPhoto() async {
        guard let pickerItem else { return }
        isLoadingPhoto = true
        defer { isLoadingPhoto = false }
        guard let data = try? await pickerItem.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let saved = try? MediaStore.shared.save(image: image) else { return }
        let draft = CaptureDraft(kind: .image, localFilename: saved.filename, pixelSize: saved.size, sourceDevice: .iOS, acquisitionOrigin: .photoLibraryImport)
        capture.refreshSuggestion(for: draft)
        pickedDraft = draft
    }
}
