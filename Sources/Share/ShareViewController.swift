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

        // Ensure folders exist even on a fresh App Group container.
        let repo = Repository(context: container.mainContext)
        try? repo.seedIfEmpty()

        // ONE-TIME MIGRATION — safe to delete once all devices have run it.
        IconMigration.runIfNeeded(repository: repo)

        let root = ShareDrawerView(
            container: container,
            load: { [weak self] in await self?.extractDraft() },
            onDone: { [weak self] in self?.finish() },
            onCancel: { [weak self] in self?.cancel() }
        )
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
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
        extensionContext?.cancelRequest(withError: NSError(domain: "arkyv.share", code: 0))
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
    @Query(filter: #Predicate<StoredFolder> { !$0.isDeleted },
           sort: [SortDescriptor(\StoredFolder.sortOrder)])
    private var folders: [StoredFolder]

    @State private var draft: CaptureDraft?
    @State private var note = ""
    @State private var savingInto: UUID?

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
                Button("Cancel") { onCancel() }
                    .font(.arkyvCaption)
                    .foregroundStyle(ArkyvColor.textSecondary)
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

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(folders) { folder in
                    folderButton(folder)
                }
            }

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
        .disabled(!isReady)
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
