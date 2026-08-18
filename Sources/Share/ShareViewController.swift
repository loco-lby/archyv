import UIKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import ArkyvKit

/// Principal class for the Share Extension.
///
/// `@objc(ShareViewController)` is REQUIRED: `NSExtensionPrincipalClass` in the
/// Info.plist is resolved via `NSClassFromString("ShareViewController")`, which
/// only finds the class if its Objective-C name matches exactly (otherwise it's
/// module-mangled to `ArkyvShare.ShareViewController` and the extension loads a
/// blank view).
///
/// The drawer UI is shown IMMEDIATELY; the shared attachment loads in parallel
/// so folders appear instantly and one tap files the capture.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let container = ArkyvStore.makeModelContainer()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let repo = Repository(context: container.mainContext)

        // D4: one-shot, restricted-mode SeedGate check. Records the
        // shared "first observed empty" timestamp and still handles the
        // zero-ambiguity no-iCloud-account case immediately, but never
        // itself concludes "the window has elapsed" — RootView's
        // recurring hook in the main app owns that decision. See
        // SeedGate.TimedSeedPermission and ShareDrawerContent's Unfiled
        // fallback below for what happens here while unresolved.
        SeedGate.evaluate(context: container.mainContext, timedSeedPermission: .observeOnly)

        // ONE-TIME MIGRATION — safe to delete once all devices have run it.
        IconMigration.runIfNeeded(repository: repo)

        // ONE-TIME BACKFILL — additive only, safe to delete once all
        // devices have run it. See MembershipMigration.swift.
        MembershipMigration.runIfNeeded(repository: repo)

        let root = ShareDrawerView(
            container: container,
            load: { [weak self] in await self?.extractDraft() },
            onDone: { [weak self] in self?.finish() },
            onCancel: { [weak self] in self?.cancel() }
        )
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        addChild(host)
        // Was a one-time `host.view.frame = view.bounds` + autoresizing
        // mask — that snapshot is taken in viewDidLoad(), before this
        // view controller's own view has necessarily received its final
        // size from the extension's presentation system, and the
        // touch-delivery bug traced back to exactly that: content
        // rendered correctly (autoresizing kept the *visual* layer
        // tracking later size changes) while the hosting view's actual
        // hit-testable frame didn't reliably follow. Auto Layout
        // constraints pin the hosting view to the parent continuously,
        // not as a single snapshot, which removes that gap entirely.
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    /// Pulls the first useful attachment into a draft (image → URL → text).
    ///
    /// Storage/Disk Pressure Foundation 01: `nil` return means "an image
    /// WAS shared, but every attempt to turn it into a draft failed" —
    /// most plausibly a disk-full `MediaStore` write. This is
    /// deliberately NOT treated the same as "no image was shared at
    /// all": before this fix, an image-save failure fell straight
    /// through to the URL/text branches below and, finding nothing
    /// there either, ultimately returned a contentless
    /// `CaptureDraft(kind: .note)` — which `ShareDrawerContent` then
    /// presented as a perfectly normal, *ready-to-save* draft (no
    /// preview, but `isReady` was still `true`). A user tapping ✓ in
    /// that state would successfully file an empty note while their
    /// actual photo silently vanished — exactly the "silently claim
    /// success for an incomplete save" failure mode this milestone
    /// exists to close. Scoped to the image path specifically: it's the
    /// only one of the three that writes substantial bytes to disk, so
    /// it's the only one with this failure shape. See
    /// `ShareDrawerContent`'s `loadFailed` for the corresponding UI
    /// state (disabled ✓, an explicit "couldn't load" message instead
    /// of a silently-ready empty draft).
    private func extractDraft() async -> CaptureDraft? {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let providers = item.attachments else {
            return CaptureDraft(kind: .note, sourceDevice: .iOS)
        }

        let imageProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        if !imageProviders.isEmpty {
            for provider in imageProviders {
                if let draft = await imageDraft(from: provider) { return draft }
            }
            return nil
        }

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                return CaptureDraft(kind: .text, title: url.host, sourceURL: url.absoluteString, sourceDevice: .iOS)
            }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                return CaptureDraft(kind: .note, noteBody: text, sourceDevice: .iOS)
            }
        }
        return CaptureDraft(kind: .note, sourceDevice: .iOS)
    }

    /// Share/Capture Reliability Foundation 01: prefers a decode-free
    /// fast path (`jpegFastPathDraft`) when the shared attachment is
    /// already a JPEG, and only falls back to the original
    /// decode-then-re-encode path for anything else (HEIC, PNG, an
    /// already-decoded `UIImage` handed back directly, or if the fast
    /// path couldn't get usable bytes for any reason). See
    /// `jpegFastPathDraft`'s own doc comment for why this matters —
    /// this function's *behavior* (what ends up filed) is unchanged;
    /// only how it gets there for the common JPEG case is narrower.
    private func imageDraft(from provider: NSItemProvider) async -> CaptureDraft? {
        if let draft = await jpegFastPathDraft(from: provider) { return draft }

        let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier)
        var image: UIImage?
        switch loaded {
        case let url as URL: image = UIImage(contentsOfFile: url.path)
        case let data as Data: image = UIImage(data: data)
        case let img as UIImage: image = img
        default: break
        }
        guard let image, let saved = try? MediaStore.shared.save(image: image) else { return nil }
        return CaptureDraft(
            kind: .screenshot,
            localFilename: saved.filename,
            pixelSize: saved.size,
            sourceDevice: .iOS
        )
    }

    /// A large modern photo (24-48MP is common) decoded to a full bitmap
    /// just to be immediately re-encoded back to JPEG costs real peak
    /// memory in a Share Extension's much tighter memory ceiling than
    /// the main app has — and, since `UIImage.jpegData` re-compresses,
    /// it also throws away the original bytes/metadata for no reason
    /// when the source was already a JPEG. When the provider can hand
    /// back JPEG bytes directly, this copies/writes them completely
    /// unmodified (original fidelity, including EXIF orientation, exactly
    /// preserved — more faithfully than the decode/re-encode path even
    /// does today) and reads only the pixel dimensions from the file's
    /// header via `ImageDecoding.pixelSize` — no bitmap ever
    /// materializes. Returns `nil` (never throws) on anything short of
    /// full success, so `imageDraft(from:)` can fall back to the
    /// original path with no special-casing.
    private func jpegFastPathDraft(from provider: NSItemProvider) async -> CaptureDraft? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.jpeg.identifier),
              let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.jpeg.identifier) else {
            return nil
        }

        let filename: String?
        let pixelSize: CGSize?
        switch loaded {
        case let url as URL:
            filename = try? MediaStore.shared.save(copyingFileAt: url)
            pixelSize = ImageDecoding.pixelSize(ofFileAt: url)
        case let data as Data:
            filename = try? MediaStore.shared.save(data: data)
            pixelSize = ImageDecoding.pixelSize(ofData: data)
        default:
            filename = nil
            pixelSize = nil
        }

        guard let filename, let pixelSize else { return nil }
        return CaptureDraft(kind: .screenshot, localFilename: filename, pixelSize: pixelSize, sourceDevice: .iOS)
    }

    /// Share/Capture Reliability Foundation 01: `didComplete` guards
    /// `completeRequest` to exactly one call for this extension's
    /// lifetime, no matter which of `finish()`/`cancel()` fires or how
    /// many times — e.g. a stray tap landing in the brief window between
    /// a successful save calling `finish()` and the system actually
    /// tearing the extension down. `NSExtensionContext.completeRequest`
    /// tolerating repeat calls isn't documented API contract, so this
    /// doesn't rely on that; it's a plain, cheap, always-correct guard.
    private var didComplete = false

    private func finish() {
        guard !didComplete else { return }
        didComplete = true
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
    private func cancel() {
        guard !didComplete else { return }
        didComplete = true
        // Was cancelRequest(withError:) — that API is meant for reporting
        // a genuine failure back to the host, not routine user
        // cancellation, and didn't reliably dismiss the extension.
        // completeRequest with no items is the same mechanism the normal
        // save path already uses successfully.
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}

/// The share drawer. The folder control and ✓ show instantly; the shared
/// attachment loads in the background — ✓ is only live once it's ready.
private struct ShareDrawerView: View {
    let container: ModelContainer
    let load: () async -> CaptureDraft?
    let onDone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ShareDrawerContent(load: load, onDone: onDone, onCancel: onCancel)
            .modelContainer(container)
            .environment(\.modelContext, container.mainContext)
    }
}

/// Same Cherries single-surface language as the Action Capture flow
/// (`ScreenshotCaptureFlowView`): full-bleed dark canvas, X always cancels,
/// ✓ always performs the one save — folder selection is an optional
/// enhancement to that save, never a prerequisite. No crop editor here yet
/// (see the Share Extension parity milestone notes) — the preview is a
/// plain, non-interactive thumbnail of the untouched original.
private struct ShareDrawerContent: View {
    let load: () async -> CaptureDraft?
    let onDone: () -> Void
    let onCancel: () -> Void

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

    @State private var draft: CaptureDraft?
    @State private var note = ""
    @State private var showingPicker = false
    /// Chosen in the dropdown (see `chooseFolder`), not yet saved — ✓ is
    /// what actually files the share (see `confirmSave`). `nil` means
    /// Unfiled, the existing canonical zero-membership shape.
    @State private var selectedFolder: StoredFolder?
    @State private var isSaving = false
    @State private var saveError = false
    /// LIFECYCLE / FAULT INJECTION FOUNDATION 01: set right after
    /// `confirmSave()`'s `fileCapture` call returns successfully — guards
    /// `cancelAndCleanUp()` against deleting a file that a just-saved
    /// `StoredItem` now depends on. `confirmSave` is fully synchronous (no
    /// delay/Task between the save call and this flag being set), so by
    /// the time any Cancel tap's handler can run, this flag already
    /// accurately reflects whether the save happened — there is no window
    /// where a save could still be "about to happen" underneath it.
    @State private var didSave = false
    /// Storage/Disk Pressure Foundation 01: `true` once `load()` has
    /// resolved to `nil` — see `ShareViewController.extractDraft()`'s
    /// doc comment for exactly what that means (an image was shared but
    /// couldn't be processed/saved, most plausibly disk-full). Distinct
    /// from "still loading" (`draft == nil && !loadFailed`, shows
    /// "Preparing…") so this state gets its own explicit message rather
    /// than silently presenting as a normal, saveable, content-free
    /// draft — `isReady` already correctly keeps ✓ disabled either way
    /// (`draft` stays `nil`), so this only changes what the user is
    /// told, not what they're permitted to do.
    @State private var loadFailed = false

    /// The attachment genuinely can take a perceptible moment to load
    /// (Photos library fetch, a large remote image) — unlike the Action
    /// Button flow's near-instant local read, this is a real wait worth
    /// showing, not a same-frame technical gate.
    private var isReady: Bool { draft != nil }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                actionBar
                folderAccessory
                Spacer(minLength: 12)
                if let preview = draft?.localFilename {
                    MediaThumbnail(filename: preview)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 360)
                        .clipShape(RoundedRectangle(cornerRadius: ArkyvRadius.card))
                        .padding(.horizontal, 20)
                }
                Spacer(minLength: 12)
                noteField
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
            .opacity(showingPicker ? 0.3 : 1)
            .allowsHitTesting(!showingPicker)

            if showingPicker {
                dropdownOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ArkyvColor.canvas.ignoresSafeArea())
        .ignoresSafeArea(edges: .bottom)
        .animation(.easeOut(duration: 0.18), value: showingPicker)
        .task {
            let result = await load()
            draft = result
            loadFailed = (result == nil)
        }
    }

    // MARK: X / ✓ — same shared Cherries controls the app's capture flow
    // uses, same positioning. Unlike CropEditorView/ScreenshotCaptureFlowView
    // this drawer is NOT a darkroom exception — its canvas is adaptive, so
    // (unlike those two) the marks must use the adaptive `textPrimary`
    // color explicitly rather than the controls' fixed-white default,
    // which would be illegible in Light mode.
    private var actionBar: some View {
        HStack {
            CherriesCancelControl(action: cancelAndCleanUp, color: ArkyvColor.textPrimary)
            Spacer()
            CherriesConfirmControl(action: confirmSave, isEnabled: isReady && !isSaving, color: ArkyvColor.textPrimary)
        }
        .padding(.horizontal, 32)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    // MARK: Folder accessory — "Unfiled ˅" (italic) until a folder is
    // explicitly chosen, then that folder's name (roman). Selecting a
    // folder only updates in-flight state; ✓ is the only thing that saves.

    private var folderAccessory: some View {
        VStack(spacing: 4) {
            Button {
                showingPicker = true
            } label: {
                Text(selectedFolder.map { "\($0.name) ˅" } ?? "Unfiled ˅")
                    .font(ArkyvFont.mono(.medium, size: 16))
                    .italic(selectedFolder == nil)
                    .foregroundStyle(ArkyvColor.textPrimary)
            }
            .disabled(showingPicker)
            if loadFailed {
                Text("Couldn't load — nothing to save")
                    .font(ArkyvFont.mono(.regular, size: 11))
                    .foregroundStyle(ArkyvColor.accent)
            } else if !isReady {
                Text("Preparing…")
                    .font(ArkyvFont.mono(.regular, size: 11))
                    .foregroundStyle(ArkyvColor.subdued)
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

    // MARK: Folder dropdown

    private var dropdownOverlay: some View {
        VStack {
            Spacer().frame(height: 110)
            folderPanel
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private var folderPanel: some View {
        VStack(spacing: 4) {
            if folders.isEmpty {
                Text("No folders yet")
                    .font(ArkyvFont.mono(.regular, size: 13))
                    .foregroundStyle(ArkyvColor.subdued)
                    .padding(.vertical, 10)
            } else {
                ForEach(folders) { folder in
                    folderRow(folder)
                }
            }
        }
        .padding(8)
        .background(ArkyvColor.surface, in: RoundedRectangle(cornerRadius: ArkyvRadius.sheet))
        .overlay(
            RoundedRectangle(cornerRadius: ArkyvRadius.sheet)
                .strokeBorder(ArkyvColor.divider, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 12, y: 12)
    }

    private func folderRow(_ folder: StoredFolder) -> some View {
        let isSelected = folder.id == selectedFolder?.id
        return Button {
            chooseFolder(folder)
        } label: {
            HStack(spacing: 10) {
                FolderIconView(icon: folder.icon, size: 13, color: ArkyvColor.accent)
                Text(folder.name)
                    .font(ArkyvFont.mono(.regular, size: 13))
                    .foregroundStyle(ArkyvColor.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ArkyvColor.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                isSelected ? ArkyvColor.accent.opacity(0.06) : Color.clear,
                in: RoundedRectangle(cornerRadius: ArkyvRadius.row)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(ArkyvColor.accent)
                        .frame(width: 2)
                        .padding(.vertical, 2)
                }
            }
        }
    }

    /// Tapping a folder row *selects* it — closes the dropdown and returns
    /// to the drawer with that folder's name now in place of "Unfiled ˅".
    /// Nothing is persisted yet; ✓ is the actual save (see `confirmSave`).
    private func chooseFolder(_ folder: StoredFolder) {
        selectedFolder = folder
        showingPicker = false
    }

    private var noteField: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.cursor").foregroundStyle(ArkyvColor.subdued).font(.system(size: 13))
            TextField("Add note (optional)...", text: $note, axis: .vertical)
                .font(.arkyvBody)
                .foregroundStyle(ArkyvColor.textPrimary)
                .lineLimit(1...2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .arkyvOutlinedSurface(fill: ArkyvColor.surface, stroke: ArkyvColor.divider)
    }

    // MARK: Save

    /// ✓ IS the save — the one existing `Repository.fileCapture` call,
    /// unchanged from before this restyle, just no longer triggered by
    /// tapping a folder row directly. `selectedFolder == nil` files with
    /// no `folders:` argument at all — the existing, already-canonical
    /// Unfiled shape. Dismisses (`onDone`, which calls
    /// `extensionContext.completeRequest`) immediately on success; a
    /// failed write leaves the user free to just try again.
    private func confirmSave() {
        guard var draft, isReady, !isSaving else { return }
        isSaving = true
        saveError = false
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { draft.noteBody = trimmed }
        do {
            if let selectedFolder {
                try Repository(context: context).fileCapture(draft, into: selectedFolder)
            } else {
                try Repository(context: context).fileCapture(draft, folders: [])
            }
            didSave = true
            onDone()
        } catch {
            isSaving = false
            saveError = true
        }
    }

    /// LIFECYCLE / FAULT INJECTION FOUNDATION 01: reclaims the staged
    /// MediaStore file on a genuine cancel — same reasoning as
    /// `ScreenshotCaptureFlowView`'s cancel paths. `didSave` (set only
    /// after a successful `fileCapture` above) is the guard that keeps
    /// this from ever deleting a file a just-saved `StoredItem` now
    /// depends on.
    private func cancelAndCleanUp() {
        if !didSave, let filename = draft?.localFilename {
            MediaStore.shared.delete(filename: filename)
        }
        onCancel()
    }
}

/// Minimal MediaStore-backed thumbnail for the Share Extension (the app's
/// `LocalImageView` lives in the iOS app target, not this one).
///
/// Share/Capture Reliability Foundation 01: decodes via
/// `ImageDecoding.decode(_:maxPixelSize:)` at a small target rather than
/// a bare `UIImage(data:)` full decode — this preview only ever renders
/// at up to 360pt tall (see its `.frame(maxHeight: 360)` call site), so
/// decoding a 24-48MP original in full just to shrink it on-screen was
/// exactly the same wasted-decode-for-a-small-render cost Performance
/// Foundation 01 already fixed for the main app's masonry grid — this
/// extension's own preview had never picked that up since it predates
/// `ImageDecodeCache`/`ImageDecoding` and lives in a separate target.
/// Not cached (`ImageDecodeCache.shared` would work fine here too, but
/// this view is shown at most once per share session, so there's
/// nothing to reuse a cache entry for).
private struct MediaThumbnail: View {
    let filename: String
    @State private var image: UIImage?

    /// Generous for a 360pt-tall preview even at 3x, without paying for
    /// anywhere near the original's full resolution.
    private static let maxPixelSize: CGFloat = 800

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ArkyvColor.surface
            }
        }
        .task(id: filename) {
            let targetPixelSize = Self.maxPixelSize
            let decoded = await Task.detached {
                MediaStore.shared.data(for: filename).flatMap {
                    ImageDecoding.decode($0, maxPixelSize: targetPixelSize)
                }
            }.value
            if let decoded { image = decoded }
        }
    }
}
