import UIKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import ArkyvKit

/// Link Cherry Visual Picker 01: what `extractDraft()` hands to the
/// drawer — either an already-complete single draft (every non-URL
/// share, and any URL share that only ever produces one candidate), or
/// an unmaterialized, ordered candidate list for `ShareDrawerContent` to
/// page through. Kept as a plain two-case enum, not a unified "always a
/// candidate list" shape, so the overwhelmingly common single-image path
/// (screenshots, photos, most links) never pays for candidate-list
/// bookkeeping it doesn't need.
private enum ShareDraftResolution {
    case single(CaptureDraft)
    case candidates(ResolvedURLCherry)
}

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
    private func extractDraft() async -> ShareDraftResolution? {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let providers = item.attachments else {
            return .single(CaptureDraft(kind: .note, sourceDevice: .iOS))
        }

        #if DEBUG
        await logShareInputDiagnostics()
        #endif

        let imageProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        if !imageProviders.isEmpty {
            for provider in imageProviders {
                if let draft = await imageDraft(from: provider) { return .single(draft) }
            }
            return nil
        }

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                return await urlResolution(for: url)
            }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                // Link Cherry Ingestion + Source Semantics 01: some apps'
                // native Share Sheet (confirmed for YouTube) hand this
                // extension the link as plain text rather than a
                // URL-typed attachment — a bare URL with nothing else in
                // the payload is treated exactly as if it HAD arrived
                // URL-typed. Any surrounding text falls through to the
                // existing note behavior unchanged, below.
                if let url = PlainTextURLRecognizer.recognizedURL(from: text) {
                    return await urlResolution(for: url)
                }
                return .single(CaptureDraft(kind: .note, noteBody: text, sourceDevice: .iOS))
            }
        }
        return .single(CaptureDraft(kind: .note, sourceDevice: .iOS))
    }

    /// Link Cherry Visual Picker 01: "a user does not save a link, they
    /// save the thing it points to" — and now, when a page genuinely
    /// offers more than one trustworthy visual, they get to say WHICH
    /// thing. Candidate 0 is always the same single best guess the
    /// pre-picker flow would have produced; a page with only one
    /// trustworthy candidate behaves completely unchanged (no paging UI
    /// — see `ShareDrawerContent`). Any failure (no network, timeout, no
    /// image at all) falls back to the exact same text-only draft this
    /// codebase has always produced for a bare URL.
    private func urlResolution(for url: URL) async -> ShareDraftResolution {
        if let resolved = await URLCherryResolver.resolveCandidates(url, sourceDevice: .iOS), !resolved.candidates.isEmpty {
            return .candidates(resolved)
        }
        return .single(CaptureDraft(kind: .text, title: url.host, sourceURL: url.absoluteString, sourceDevice: .iOS))
    }

    #if DEBUG
    /// URL → Cherry Physical QA Follow-Up 01, Section 5: characterizes
    /// exactly what a share's input items/providers look like — built to
    /// answer, empirically and without guessing, whether Instagram hands
    /// the Share Extension the exact visible carousel image, a
    /// slide-identifying URL, or only a post-level URL with no
    /// selected-slide information. DEBUG-only; never runs in a production
    /// build. Deliberately logs only type identifiers and the shared
    /// URL's own structure (query items, since that's exactly where a
    /// carousel index would live) — no caption/account/user content is
    /// ever available to this method in the first place, since the Share
    /// Extension is only ever handed `NSExtensionItem`/`NSItemProvider`
    /// attachments, not Instagram's app-internal state.
    private func logShareInputDiagnostics() async {
        // `devicectl` has no way to stream console output from a process
        // the OS launches (only from ones this tooling launches itself),
        // so a real Instagram share triggered through the system Share
        // Sheet can't be observed via `print()` alone — these same lines
        // are also appended to a small DEBUG-only file in the App Group
        // container so they can be pulled back afterward via `devicectl
        // device copy from`. Never written in a Release build; never
        // synced (plain local file, outside MediaStore/SwiftData).
        var lines: [String] = []
        func log(_ line: String) {
            print(line)
            lines.append(line)
        }

        let allItems = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        log("[ShareDiag] inputItems=\(allItems.count)")
        for (itemIndex, item) in allItems.enumerated() {
            let providers = item.attachments ?? []
            log("[ShareDiag] item[\(itemIndex)] providers=\(providers.count)")
            for (providerIndex, provider) in providers.enumerated() {
                let types = provider.registeredTypeIdentifiers
                let conformsURL = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                let conformsImage = provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                let conformsJPEG = provider.hasItemConformingToTypeIdentifier(UTType.jpeg.identifier)
                let conformsPNG = provider.hasItemConformingToTypeIdentifier(UTType.png.identifier)
                let conformsHEIC = provider.hasItemConformingToTypeIdentifier("public.heic")
                log("[ShareDiag]   provider[\(providerIndex)] types=\(types) url=\(conformsURL) image=\(conformsImage) jpeg=\(conformsJPEG) png=\(conformsPNG) heic=\(conformsHEIC)")

                if conformsURL, let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    let queryItems = components?.queryItems ?? []
                    log("[ShareDiag]   provider[\(providerIndex)] url.path=\(url.path) url.host=\(url.host ?? "nil")")
                    log("[ShareDiag]   provider[\(providerIndex)] url.queryItems=\(queryItems.map { "\($0.name)=\($0.value ?? "")" })")
                }
            }
        }
        log("[ShareDiag] --- end ---")

        let logURL = AppGroup.containerURL.appendingPathComponent("share-diag-debug.log")
        let entry = (["", "=== \(Date()) ==="] + lines).joined(separator: "\n") + "\n"
        if let existing = try? String(contentsOf: logURL, encoding: .utf8) {
            try? (existing + entry).write(to: logURL, atomically: true, encoding: .utf8)
        } else {
            try? entry.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
    #endif

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
    let load: () async -> ShareDraftResolution?
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
    let load: () async -> ShareDraftResolution?
    let onDone: () -> Void
    let onCancel: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURLAction
    // Unfiltered `@Query` + in-memory filter, not a `#Predicate` nil-check —
    // see ArchiveView.swift's `allFoldersRaw` doc comment: a `deletedAt ==
    // nil` predicate combined with a `sort:` argument in the same `@Query`
    // hits a SwiftData/Swift type-checker complexity limit.
    @Query(sort: [SortDescriptor(\StoredFolder.sortOrder)])
    private var allFoldersRaw: [StoredFolder]

    private var folders: [StoredFolder] {
        allFoldersRaw.filter { !$0.isSoftDeleted }
    }

    /// Link Cherry Visual Picker 01: `nil` while loading, then either a
    /// complete single draft or an unmaterialized candidate list — see
    /// `ShareDraftResolution`'s own doc comment.
    @State private var resolution: ShareDraftResolution?
    /// Every candidate actually fetched+`MediaStore`-saved so far, keyed
    /// by `ResolvedImageCandidate.id`. Candidates the user never swipes
    /// to are never added here at all; candidates added here but not
    /// ultimately selected are deleted from `MediaStore` in
    /// `cancelAndCleanUp`/`confirmSave` — "unselected candidates are NOT
    /// permanently archived."
    @State private var materialized: [String: CaptureDraft] = [:]
    @State private var materializing: Set<String> = []
    /// The currently-materializing candidate's task, so rapidly swiping
    /// past several unfetched candidates cancels the stale in-flight
    /// fetch for one the user has already moved past, rather than
    /// letting fetches pile up.
    @State private var materializeTask: Task<Void, Never>?
    /// Index 0 by default — "if the user never swipes, save candidate 0
    /// exactly as today." Changing folder/note or opening/closing the
    /// folder dropdown never touches this.
    @State private var selectedCandidateIndex = 0
    @State private var note = ""
    @State private var showingPicker = false
    /// Chosen in the dropdown (see `folderPanel`'s row actions), not yet
    /// saved — ✓ is what actually files the share (see `confirmSave`).
    /// `nil` means Unfiled, the existing canonical zero-membership shape.
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
    /// from "still loading" (`resolution == nil && !loadFailed`, shows
    /// "Preparing…") so this state gets its own explicit message rather
    /// than silently presenting as a normal, saveable, content-free
    /// draft — `isReady` already correctly keeps ✓ disabled either way,
    /// so this only changes what the user is told, not what they're
    /// permitted to do.
    @State private var loadFailed = false

    private var candidates: [ResolvedImageCandidate] {
        if case .candidates(let resolved) = resolution { return resolved.candidates }
        return []
    }

    /// The draft that would actually be saved right now: the single
    /// complete draft directly, or — for a candidate list — the
    /// currently-selected candidate's draft ONLY once it has actually
    /// been materialized (downloaded + saved). While a selected
    /// candidate is still fetching, this is `nil`, which correctly keeps
    /// ✓ disabled via `isReady` below — the same "Preparing…" gate the
    /// initial load has always used, reused for a mid-swipe fetch too.
    private var currentDraft: CaptureDraft? {
        switch resolution {
        case .single(let draft):
            return draft
        case .candidates:
            guard candidates.indices.contains(selectedCandidateIndex) else { return nil }
            return materialized[candidates[selectedCandidateIndex].id]
        case nil:
            return nil
        }
    }

    /// The attachment genuinely can take a perceptible moment to load
    /// (Photos library fetch, a large remote image) — unlike the Action
    /// Button flow's near-instant local read, this is a real wait worth
    /// showing, not a same-frame technical gate.
    private var isReady: Bool { currentDraft != nil }

    var body: some View {
        // URL → Cherry Physical QA Follow-Up 01: a very wide representative
        // image (the Works in Progress hero) was found to push the whole
        // drawer's reported width past the true screen bounds even after
        // giving MediaThumbnail its own `.frame(maxWidth: .infinity,
        // maxHeight: 360)` — flexible (`.infinity`/`max`) sizing is a
        // NEGOTIATION between parent and child, and something in this
        // chain was still letting an outsized child win that negotiation
        // for the whole drawer, not just the thumbnail. `GeometryReader`
        // sidesteps the negotiation entirely: it reports the one
        // concrete size actually offered by the hosting controller
        // (which IS pinned via Auto Layout to the extension's real screen
        // bounds), and every child below is given an absolute number
        // instead of a hint — there is no longer any flexible sizing left
        // for an unusual aspect ratio to exploit.
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: 0) {
                    actionBar
                    folderAccessory
                    Spacer(minLength: 12)
                    previewArea(width: max(geometry.size.width - 40, 0))
                    Spacer(minLength: 12)
                    noteField
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .opacity(showingPicker ? 0.3 : 1)
                .allowsHitTesting(!showingPicker)

                if showingPicker {
                    dropdownOverlay
                        .frame(width: geometry.size.width)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(ArkyvColor.canvas.ignoresSafeArea())
        .ignoresSafeArea(edges: .bottom)
        .animation(.easeOut(duration: 0.18), value: showingPicker)
        .task {
            let result = await load()
            resolution = result
            loadFailed = (result == nil)
            if case .candidates(let resolved) = result, let first = resolved.candidates.first {
                await materialize(candidate: first, resolved: resolved)
            }
        }
    }

    // MARK: Preview — single image (unchanged) or a paged candidate swiper

    /// Link Cherry Visual Picker 01: identical box either way (the same
    /// `width`/360-height frame the geometry fix already established),
    /// so no candidate's aspect ratio can affect layout — only WHICH
    /// view fills that box changes. A single candidate/draft renders
    /// exactly as before: no `TabView`, no dots, no picker machinery at
    /// all. Multiple candidates get native horizontal paging with a
    /// small, quiet page-dot row beneath — shown ONLY when there's
    /// genuinely a choice to make.
    @ViewBuilder
    private func previewArea(width: CGFloat) -> some View {
        if candidates.count > 1 {
            VStack(spacing: 10) {
                TabView(selection: $selectedCandidateIndex) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        candidatePreview(candidate)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(width: width, height: 360)
                .clipShape(RoundedRectangle(cornerRadius: ArkyvRadius.card))
                .onChange(of: selectedCandidateIndex) { _, newIndex in
                    guard candidates.indices.contains(newIndex) else { return }
                    let candidate = candidates[newIndex]
                    guard case .candidates(let resolved) = resolution else { return }
                    materializeTask?.cancel()
                    materializeTask = Task { await materialize(candidate: candidate, resolved: resolved) }
                }

                HStack(spacing: 6) {
                    ForEach(candidates.indices, id: \.self) { index in
                        Circle()
                            .fill(ArkyvColor.textPrimary)
                            .opacity(index == selectedCandidateIndex ? 1 : 0.25)
                            .frame(width: 5, height: 5)
                    }
                }
            }
            .padding(.horizontal, 20)
        } else if let filename = currentDraft?.localFilename {
            MediaThumbnail(filename: filename)
                .frame(width: width, height: 360)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: ArkyvRadius.card))
                .padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private func candidatePreview(_ candidate: ResolvedImageCandidate) -> some View {
        if let filename = materialized[candidate.id]?.localFilename {
            MediaThumbnail(filename: filename)
        } else {
            ArkyvColor.surface
                .overlay {
                    if materializing.contains(candidate.id) {
                        ProgressView().tint(ArkyvColor.textPrimary)
                    }
                }
        }
    }

    /// Downloads + `MediaStore`-saves one candidate, guarded against
    /// re-fetching one already materialized or already in flight.
    private func materialize(candidate: ResolvedImageCandidate, resolved: ResolvedURLCherry) async {
        guard materialized[candidate.id] == nil, !materializing.contains(candidate.id) else { return }
        materializing.insert(candidate.id)
        let draft = await URLCherryResolver.materializeCandidate(
            candidate, title: resolved.title, sourceURL: resolved.sourceURL, sourceDevice: .iOS
        )
        guard !Task.isCancelled else {
            materializing.remove(candidate.id)
            return
        }
        materializing.remove(candidate.id)
        if let draft {
            materialized[candidate.id] = draft
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
            // Context + Single-Folder UX 01, Section 10: "Unfiled" is not
            // another `StoredFolder` — it only appears as a selectable row
            // once a real folder is chosen, so there's a way back to it
            // (previously there was none: this dropdown only ever listed
            // real folders, and re-tapping the selected one just re-chose
            // itself). Same reuse-the-tap-target pattern Item Detail's
            // FolderEditorView already established for this.
            if selectedFolder != nil {
                folderRow(icon: nil, name: "Unfiled", isSelected: false) {
                    selectedFolder = nil
                    showingPicker = false
                }
            }
            if folders.isEmpty {
                Text("No folders yet")
                    .font(ArkyvFont.mono(.regular, size: 13))
                    .foregroundStyle(ArkyvColor.subdued)
                    .padding(.vertical, 10)
            } else {
                ForEach(folders) { folder in
                    folderRow(icon: folder.icon, name: folder.name, isSelected: folder.id == selectedFolder?.id) {
                        // Tapping the already-selected row clears back to
                        // Unfiled — same toggle-to-nil mechanism Item
                        // Detail's picker uses, so there's always a way
                        // back without a separate control.
                        let resultID = FolderSelectionUX.toggling(current: selectedFolder?.id, tapped: folder.id)
                        selectedFolder = resultID == folder.id ? folder : nil
                        showingPicker = false
                    }
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

    /// Context + Single-Folder UX 01, Section 9: exactly ONE selection
    /// cue — a trailing checkmark — replacing the prior combination of
    /// checkmark + tinted background + leading accent bar, which put
    /// three simultaneous, independently-styled signals on a single
    /// state. A Cherry is always in zero or one folder (never more), and
    /// only one row is ever `isSelected` at a time by construction
    /// (`selectedFolder` is a single optional, never a set) — the
    /// simplification is about removing redundant/competing visual
    /// language, not fixing a multi-selection bug at the state level.
    /// `icon == nil` (the synthetic "Unfiled" row) simply omits the
    /// leading glyph rather than inventing a placeholder one.
    private func folderRow(icon: FolderIcon?, name: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon {
                    FolderIconView(icon: icon, size: 13, color: ArkyvColor.accent)
                }
                Text(name)
                    .font(ArkyvFont.mono(.regular, size: 13))
                    .foregroundStyle(isSelected ? ArkyvColor.textPrimary : ArkyvColor.textPrimary.opacity(0.75))
                    .italic(icon == nil)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    /// failed write leaves the user free to just try again. Link Cherry
    /// Visual Picker 01: `currentDraft` is the currently-selected
    /// candidate's already-materialized draft (or the plain single
    /// draft) — `isReady`/the ✓ button's own `isEnabled` already keep
    /// this from ever firing before that candidate has finished
    /// downloading, so this stays fully synchronous, exactly as before.
    /// After a successful save, every OTHER materialized candidate is
    /// deleted from `MediaStore` — only the selected visual's bytes ever
    /// remain referenced by anything.
    private func confirmSave() {
        guard var draftToSave = currentDraft, isReady, !isSaving else { return }
        isSaving = true
        saveError = false
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { draftToSave.noteBody = trimmed }
        do {
            if let selectedFolder {
                try Repository(context: context).fileCapture(draftToSave, into: selectedFolder)
            } else {
                try Repository(context: context).fileCapture(draftToSave, folders: [])
            }
            didSave = true
            deleteUnselectedMaterializedCandidates(keeping: draftToSave.localFilename)
            onDone()
        } catch {
            isSaving = false
            saveError = true
        }
    }

    /// LIFECYCLE / FAULT INJECTION FOUNDATION 01: reclaims the staged
    /// MediaStore file on a genuine cancel — same reasoning as
    /// `ScreenshotCaptureFlowView`'s cancel paths. `didSave` (set only
    /// after a successful `fileCapture` in `confirmSave`) is the guard
    /// that keeps this from ever deleting a file a just-saved
    /// `StoredItem` now depends on. Link Cherry Visual Picker 01: also
    /// cancels any still-in-flight candidate fetch and reclaims every
    /// candidate materialized so far — "unselected candidates are NOT
    /// permanently archived" applies just as much to a cancelled share
    /// as to one where a different candidate ended up selected.
    private func cancelAndCleanUp() {
        materializeTask?.cancel()
        if !didSave {
            if case .single(let draft) = resolution, let filename = draft.localFilename {
                MediaStore.shared.delete(filename: filename)
            }
            deleteUnselectedMaterializedCandidates(keeping: nil)
        }
        onCancel()
    }

    /// Deletes every materialized candidate's `MediaStore` file except
    /// `keptFilename` (the one that just became `StoredItem.localFilename`,
    /// or `nil` on a full cancel where nothing is kept).
    private func deleteUnselectedMaterializedCandidates(keeping keptFilename: String?) {
        for draft in materialized.values {
            guard let filename = draft.localFilename, filename != keptFilename else { continue }
            MediaStore.shared.delete(filename: filename)
        }
        materialized.removeAll()
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
