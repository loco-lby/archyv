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

/// The share drawer. Folders show instantly; the shared attachment loads in the
/// background and enables one-tap filing the moment it's ready.
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
    @State private var savingInto: UUID?
    /// D4: separate in-flight marker for the Unfiled fallback, shown
    /// only while `folders` is empty — see `unfiledButton`/`fileUnfiled`.
    @State private var savingUnfiled = false

    private var isReady: Bool { draft != nil }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            drawer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.35).ignoresSafeArea())
        .task {
            draft = await load()
        }
    }

    private var drawer: some View {
        VStack(spacing: 16) {
            HStack {
                // Cancel used to live here — relocated below the
                // folder/Unfiled section, into the region proven
                // reliably interactive by diagnostic testing. This row
                // (and the mark/title below) never need to be
                // interactive, so leaving them here is harmless even
                // though this area doesn't receive touches reliably.
                Spacer()
                Text(isReady ? readyLabel : "Preparing…")
                    .font(.arkyvCaption)
                    .foregroundStyle(ArkyvColor.textDim)
            }

            ArkyvMarkView(height: 36, color: ArkyvColor.textPrimary)
            Text("Save to arkyv")
                .font(ArkyvFont.mono(.bold, size: 24))
                .foregroundStyle(ArkyvColor.textPrimary)

            if let preview = draft?.localFilename {
                MediaThumbnail(filename: preview)
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: ArkyvRadius.card))
            }

            // D4: while folders is empty — either genuinely no folders
            // exist yet, or SeedGate hasn't resolved whether this is a
            // fresh account or an in-flight CloudKit restore — show a
            // fallback that can still save the capture, rather than an
            // unusable empty grid. SeedGate itself is never triggered
            // from here; this only reads the current (reactive) folder
            // list, same as `folderButton` below.
            if folders.isEmpty {
                unfiledButton()
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(folders) { folder in
                        folderButton(folder)
                    }
                }
            }

            // Relocated from the top-left row — diagnostic testing
            // (a temporary button wired to this exact same onCancel
            // closure, placed here) proved this position reliably
            // receives touches, while the original top-row position did
            // not, for reasons isolated to hit-testing/layout in that
            // area, not the dismissal logic itself. Same callback,
            // same completeRequest-based dismissal — only the position
            // and visual styling changed.
            Button("Cancel") { onCancel() }
                .font(.arkyvCaption)
                .foregroundStyle(ArkyvColor.textSecondary)

            noteField
        }
        .padding(20)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(ArkyvColor.background)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: ArkyvRadius.sheet, topTrailingRadius: ArkyvRadius.sheet))
        .ignoresSafeArea(edges: .bottom)
    }

    private var readyLabel: String {
        switch draft?.kind {
        case .screenshot, .image: return "Photo ready"
        case .text: return "Link ready"
        default: return "Note ready"
        }
    }

    private func folderButton(_ folder: StoredFolder) -> some View {
        Button {
            file(into: folder)
        } label: {
            HStack(spacing: 8) {
                if savingInto == folder.id {
                    ProgressView().tint(ArkyvColor.textPrimary)
                } else {
                    FolderIconView(icon: folder.icon, size: 18)
                }
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
            .arkyvOutlinedSurface()
        }
        .disabled(!isReady || savingUnfiled)
        .opacity(isReady ? 1 : 0.4)
    }

    /// D4: the folder-picker's fallback while `folders` is empty — files
    /// the capture with zero folder memberships, the existing, already
    /// fully-supported "Unfiled" shape (`fileCapture`'s `folders`
    /// parameter defaults to `[]`). No new data-layer capability, no
    /// folders created — this never seeds anything itself.
    private func unfiledButton() -> some View {
        Button {
            fileUnfiled()
        } label: {
            HStack(spacing: 8) {
                if savingUnfiled {
                    ProgressView().tint(ArkyvColor.textPrimary)
                } else {
                    Image(systemName: "tray")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(ArkyvColor.textPrimary)
                }
                Text("Save without a folder")
                    .font(.arkyvLabel)
                    .foregroundStyle(ArkyvColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .arkyvOutlinedSurface()
        }
        .disabled(!isReady || savingInto != nil)
        .opacity(isReady ? 1 : 0.4)
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

    private func file(into folder: StoredFolder) {
        guard var draft, savingInto == nil else { return }
        savingInto = folder.id
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { draft.noteBody = trimmed }
        do {
            try Repository(context: context).fileCapture(draft, into: folder)
            onDone()
        } catch {
            savingInto = nil
        }
    }

    private func fileUnfiled() {
        guard var draft, savingInto == nil, !savingUnfiled else { return }
        savingUnfiled = true
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { draft.noteBody = trimmed }
        do {
            try Repository(context: context).fileCapture(draft, folders: [])
            onDone()
        } catch {
            savingUnfiled = false
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
