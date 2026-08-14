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
        // Fonts register automatically via UIAppFonts — this just confirms
        // it worked in this process too, in Debug builds only.
        #if DEBUG
        ArkyvFont.verifyFontsAvailable()
        #endif
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
    private func extractDraft() async -> CaptureDraft {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let providers = item.attachments else {
            return CaptureDraft(kind: .note, sourceDevice: .iOS)
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            if let draft = await imageDraft(from: provider) { return draft }
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

    private func imageDraft(from provider: NSItemProvider) async -> CaptureDraft? {
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

    private func finish() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
    private func cancel() {
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
            .preferredColorScheme(.dark)
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
        .background(ArkyvColor.background.ignoresSafeArea())
        .ignoresSafeArea(edges: .bottom)
        .animation(.easeOut(duration: 0.18), value: showingPicker)
        .task {
            draft = await load()
        }
    }

    // MARK: X / ✓ — same shared Cherries controls the app's capture flow
    // uses, same positioning.

    private var actionBar: some View {
        HStack {
            CherriesCancelControl(action: onCancel)
            Spacer()
            CherriesConfirmControl(action: confirmSave, isEnabled: isReady && !isSaving)
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
                    .foregroundStyle(.white)
            }
            .disabled(showingPicker)
            if !isReady {
                Text("Preparing…")
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
                    .foregroundStyle(ArkyvColor.textDim)
                    .padding(.vertical, 10)
            } else {
                ForEach(folders) { folder in
                    folderRow(folder)
                }
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
            Image(systemName: "text.cursor").foregroundStyle(ArkyvColor.textDim).font(.system(size: 13))
            TextField("Add note (optional)...", text: $note, axis: .vertical)
                .font(.arkyvBody)
                .foregroundStyle(ArkyvColor.textPrimary)
                .lineLimit(1...2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .arkyvOutlinedSurface(fill: ArkyvColor.card, stroke: ArkyvColor.border)
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
            onDone()
        } catch {
            isSaving = false
            saveError = true
        }
    }
}

/// Minimal MediaStore-backed thumbnail for the Share Extension (the app's
/// `LocalImageView` lives in the iOS app target, not this one).
private struct MediaThumbnail: View {
    let filename: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ArkyvColor.card
            }
        }
        .task(id: filename) {
            let data = await Task.detached { MediaStore.shared.data(for: filename) }.value
            if let data { image = UIImage(data: data) }
        }
    }
}
