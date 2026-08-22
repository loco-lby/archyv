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
            return .single(CaptureDraft(kind: .note, sourceDevice: .iOS, acquisitionOrigin: .shareExtension))
        }

        #if DEBUG
        await logShareInputDiagnostics()
        #endif

        // Image + URL Provenance Fix 01 (Provenance Foundation Implementation
        // 01): resolved BEFORE branching on image presence, so a
        // provenance-carrying URL supplied in the SAME share as an image
        // provider is never silently discarded — see
        // `extractProvenanceURL`'s own doc comment for the precedence rule.
        // This was Provenance Foundation Recon 01's "REAL BUT UNSEEN" hazard:
        // the old code returned from the image branch before the URL/
        // plain-text providers were ever inspected.
        let provenanceURL = await extractProvenanceURL(from: providers)

        let imageProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        if !imageProviders.isEmpty {
            for provider in imageProviders {
                if let draft = await imageDraft(from: provider, sourceURL: provenanceURL) { return .single(draft) }
            }
            return nil
        }

        if let provenanceURL {
            return await urlResolution(for: provenanceURL)
        }

        // No image, no recognized URL anywhere in this share — fall back to
        // ordinary arbitrary-text note behavior, unchanged from before this
        // milestone.
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                return .single(CaptureDraft(kind: .note, noteBody: text, sourceDevice: .iOS, acquisitionOrigin: .shareExtension))
            }
        }
        return .single(CaptureDraft(kind: .note, sourceDevice: .iOS, acquisitionOrigin: .shareExtension))
    }

    /// Image + URL Provenance Fix 01: deterministic URL-carrier precedence
    /// for a single logical share (Provenance Foundation Implementation 01,
    /// section 8) — `public.url` is the strongest, unambiguous signal and is
    /// tried first; `public.plain-text` is used ONLY when
    /// `PlainTextURLRecognizer` confirms its content is an exact, bare URL,
    /// never arbitrary prose. Evaluated once, independently of whether an
    /// image provider is also present, so `extractDraft()`'s image branch
    /// can attach this result to the image draft instead of discarding it.
    /// Provider array ORDER is never the discriminator — type precedence is.
    private func extractProvenanceURL(from providers: [NSItemProvider]) async -> URL? {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                return url
            }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
               let url = PlainTextURLRecognizer.recognizedURL(from: text) {
                return url
            }
        }
        return nil
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
        let resolved = await URLCherryResolver.resolveCandidates(url, sourceDevice: .iOS)
        #if DEBUG
        logResolutionDiagnostics(url: url, resolved: resolved)
        #endif
        if let resolved, !resolved.candidates.isEmpty {
            return .candidates(resolved)
        }
        return .single(CaptureDraft(kind: .text, title: url.host, sourceURL: url.absoluteString, sourceDevice: .iOS, acquisitionOrigin: .shareExtension))
    }

    #if DEBUG
    /// Link Cherry Pipeline Integrity 01: a concise, DEBUG-only trace of
    /// what `resolveCandidates` actually produced for a real share-sheet
    /// URL — same "print + append to the App Group debug log" mechanism
    /// as `logShareInputDiagnostics` above, for the same reason (a real
    /// share triggered through the system Share Sheet, not `devicectl`,
    /// has no other way to surface console output). Deliberately doesn't
    /// re-instrument `URLCherryResolver` itself (its own internal
    /// `debugLog` calls are enough for a `devicectl`-launched debug
    /// session, and adding a second logging path there risks drifting
    /// out of sync with this one) — this only reports the OUTCOME this
    /// view controller can already observe: which resolution branch was
    /// reached and how many candidates it carries, which is exactly what
    /// distinguishes "generic-only, single candidate" from "enriched/
    /// multi-candidate" from "total failure, text-only fallback."
    private func logResolutionDiagnostics(url: URL, resolved: ResolvedURLCherry?) {
        var lines: [String] = []
        func log(_ line: String) {
            print(line)
            lines.append(line)
        }
        log("[ResolveDiag] url=\(url.absoluteString)")
        if let resolved {
            log("[ResolveDiag]   candidates=\(resolved.candidates.count) title=\(resolved.title != nil ? "present" : "nil")")
            log("[ResolveDiag]   presentation=\(resolved.candidates.isEmpty ? "single(fallback, empty candidates)" : "candidates")")
        } else {
            log("[ResolveDiag]   candidates=nil (resolveCandidates returned nil)")
            log("[ResolveDiag]   presentation=single(fallback, total failure)")
        }

        let logURL = AppGroup.containerURL.appendingPathComponent("share-diag-debug.log")
        let entry = (["", "=== \(Date()) ==="] + lines).joined(separator: "\n") + "\n"
        if let existing = try? String(contentsOf: logURL, encoding: .utf8) {
            try? (existing + entry).write(to: logURL, atomically: true, encoding: .utf8)
        } else {
            try? entry.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
    #endif

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
    private func imageDraft(from provider: NSItemProvider, sourceURL: URL? = nil) async -> CaptureDraft? {
        if let draft = await jpegFastPathDraft(from: provider, sourceURL: sourceURL) { return draft }

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
            // Image + URL Provenance Fix 01: `nil` for the ordinary
            // image-only share (unchanged behavior); set only when the SAME
            // share also carried a recognized provenance URL — see
            // `extractProvenanceURL`. Never derived from image content.
            sourceURL: sourceURL?.absoluteString,
            sourceDevice: .iOS,
            acquisitionOrigin: .shareExtension
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
    private func jpegFastPathDraft(from provider: NSItemProvider, sourceURL: URL? = nil) async -> CaptureDraft? {
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
        return CaptureDraft(
            kind: .screenshot,
            localFilename: filename,
            pixelSize: pixelSize,
            sourceURL: sourceURL?.absoluteString,
            sourceDevice: .iOS,
            acquisitionOrigin: .shareExtension
        )
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
    /// Interaction refinement pass: lightweight, downsampled, in-memory-
    /// only preview images, keyed by `ResolvedImageCandidate.id` — NEVER
    /// written to `MediaStore`. This is deliberately separate from
    /// archival materialization (which now happens exactly once, for
    /// whichever candidate is selected, at save time — see
    /// `resolveDraftForSaving`): "a blank/loading candidate should never
    /// be a swipeable page," so the carousel's visible/scrollable set is
    /// built from THIS dictionary's keys, not the full candidate list —
    /// a candidate simply isn't present to swipe onto until its preview
    /// has actually finished decoding.
    @State private var previewImages: [String: UIImage] = [:]
    @State private var previewFetching: Set<String> = []
    /// Bounded background prefetch of every remaining candidate's
    /// PREVIEW (lightweight only — see `previewImages`) — cancelled on
    /// cancel/save so nothing keeps fetching after the drawer is gone.
    /// There is no separate on-demand/on-swipe fetch trigger: the
    /// carousel only ever shows candidates this prefetch has already
    /// finished (see `readyCandidates`), so swiping itself never needs
    /// to kick off a fetch.
    @State private var prefetchTask: Task<Void, Never>?
    /// Index 0 by default — "if the user never swipes, save candidate 0
    /// exactly as today." Changing folder or opening/closing the folder
    /// dropdown never touches this.
    @State private var selectedCandidateIndex = 0
    /// Mirrors `selectedCandidateIndex` for `ScrollView`'s own
    /// `.scrollPosition(id:)` binding, which requires an `Optional`.
    @State private var scrollPositionID: Int?
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

    /// The `.single` case's already-complete draft — unused for
    /// `.candidates`, where nothing is archivally ready until save time
    /// (see `resolveDraftForSaving`).
    private var singleDraft: CaptureDraft? {
        if case .single(let draft) = resolution { return draft }
        return nil
    }

    /// The attachment genuinely can take a perceptible moment to load
    /// (Photos library fetch, a large remote image) — unlike the Action
    /// Button flow's near-instant local read, this is a real wait worth
    /// showing, not a same-frame technical gate. For a candidate list,
    /// "ready" means the SELECTED candidate's lightweight preview has
    /// finished decoding — not that it's been archivally saved, which
    /// only happens once, at save time.
    private var isReady: Bool {
        switch resolution {
        case .single: return true
        case .candidates:
            guard candidates.indices.contains(selectedCandidateIndex) else { return false }
            return previewImages[candidates[selectedCandidateIndex].id] != nil
        case nil: return false
        }
    }

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
                    // Final visual pass: a smaller minimum above than
                    // below shifts the preview block slightly higher —
                    // both Spacers are still flexible, so this is a
                    // small nudge within the existing layout, not a
                    // fixed reposition.
                    Spacer(minLength: 6)
                    previewArea(width: max(geometry.size.width - 40, 0))
                    Spacer(minLength: 20)
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
                await fetchPreview(candidate: first)
                // Interaction refinement: "a blank/loading candidate
                // should never be a swipeable page" — this prefetches
                // EVERY remaining candidate's lightweight preview (never
                // all of them at full archival resolution; see
                // `fetchPreview`), sequentially and boundedly (the
                // candidate count itself is already capped), so by the
                // time a user could plausibly swipe to one, it has
                // almost always already finished. `previewArea` only
                // ever renders/allows scrolling to candidates already
                // present in `previewImages` — never a placeholder mid-
                // gesture.
                prefetchTask = Task {
                    for candidate in resolved.candidates.dropFirst() {
                        guard !Task.isCancelled else { return }
                        await fetchPreview(candidate: candidate)
                    }
                }
            }
        }
    }

    // MARK: Preview — single image (unchanged) or a WYSIWYG spatial carousel

    /// Visual Picker 01 interaction refinement: "the preview is a
    /// promise" — no candidate, active or neighbor, is ever cropped or
    /// forced into a Cherries-imposed box. The ACTIVE candidate's own
    /// aspect ratio drives this whole area's height (clamped to a usable
    /// range); every candidate is shown via `.aspectRatio(_, contentMode:
    /// .fit)` using its own real dimensions, so it always renders its
    /// true, complete composition — a very tall or very wide source
    /// simply gets more or less letterboxing, never a crop. Only
    /// candidates present in `previewImages` are ever rendered/
    /// reachable — a not-yet-ready candidate simply isn't part of the
    /// scrollable strip yet, so a swipe can never land on a blank frame.
    /// `width` is still the one fixed, concrete number everything is
    /// built from (from the geometry fix) — only the carousel's OWN
    /// height varies, animated with `ArkyvMotion.settle`, the same calm
    /// "fast hands, settle here" token the Folder selector's own
    /// selection state already uses; X/✓/folder stay pinned via the
    /// surrounding `VStack`'s `Spacer`s absorbing the difference.
    /// Link Cherry Pipeline Integrity 01: was gated on `candidates.count
    /// > 1` — meaning ANY URL whose resolution produced exactly ONE
    /// candidate (the ordinary, generic-only case: no `SourceEnricher`
    /// matched, and `ProductPageCandidateSource` found no `Product`
    /// JSON-LD/Shopify gallery to append from, e.g. Pinterest, or an
    /// ordinary product/article page without that structured data) fell
    /// through BOTH branches — `candidates.count > 1` false, and
    /// `singleDraft` also nil (`resolution` is `.candidates`, not
    /// `.single`, for any successfully-resolved URL — see
    /// `urlResolution(for:)`) — rendering nothing at all, a blank preview
    /// area above a bare X/✓/folder row that read as an old,
    /// pre-Visual-Picker screen even though it wasn't one. Darc Sport
    /// worked throughout because it happens to be the one canary URL
    /// with real `Product` JSON-LD, always producing >1 candidates; nothing
    /// else in the six-URL set does. The fix is `!ready.isEmpty` instead
    /// of `candidates.count > 1` — the exact same rendering path now
    /// handles 1 candidate exactly as gracefully as many, just without
    /// the multi-candidate-only chrome (peek neighbors, the "Choose
    /// image" selection cue, swipe) when there's only one to show. A
    /// generic-only resolution is no longer a degraded case; it's simply
    /// this same UI with the carousel-specific affordances turned off.
    @ViewBuilder
    private func previewArea(width: CGFloat) -> some View {
        let ready = readyCandidates
        if !ready.isEmpty {
            let isCarousel = candidates.count > 1
            let slotWidth = isCarousel ? width * Self.activeSlotFraction : width
            let height = carouselHeight(forWidth: slotWidth)
            // Final visual pass: a little more breathing room between the
            // carousel and the "Choose image" label beneath it (16, up
            // from 8).
            VStack(spacing: 16) {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Self.candidateSpacing) {
                        ForEach(ready, id: \.offset) { entry in
                            candidateSlot(entry.element, isActive: entry.offset == selectedCandidateIndex, slotWidth: slotWidth, height: height)
                                .id(entry.offset)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, (width - slotWidth) / 2)
                }
                .frame(width: width, height: height)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $scrollPositionID)
                .scrollDisabled(!isCarousel)
                .onChange(of: scrollPositionID) { _, newIndex in
                    guard let newIndex, candidates.indices.contains(newIndex) else { return }
                    withAnimation(ArkyvMotion.settle) { selectedCandidateIndex = newIndex }
                }
                .onAppear { scrollPositionID = selectedCandidateIndex }
                .animation(ArkyvMotion.settle, value: height)

                // Interaction refinement, Section 3: "make it clear this
                // is a selection, not a gallery." One restrained
                // semantic cue — "Choose image" + a precise "N of M"
                // position — replaces the prior plain dot row entirely,
                // since dots and an exact count would just be two
                // indicators saying the same thing. Only shown when
                // there's an actual choice to make — a single-candidate
                // result has nothing to select between, so this cue
                // would be pure noise.
                if isCarousel {
                    VStack(spacing: 1) {
                        Text("Choose image")
                            .font(ArkyvFont.publicSans(size: 11, weight: .semibold))
                            .tracking(1)
                            .foregroundStyle(ArkyvColor.textSecondary)
                        Text("\(selectedCandidateIndex + 1) of \(candidates.count)")
                            .font(ArkyvFont.publicSans(size: 10))
                            .foregroundStyle(ArkyvColor.subdued)
                    }
                }
            }
            .padding(.horizontal, 20)
        } else if let filename = singleDraft?.localFilename {
            MediaThumbnail(filename: filename)
                .frame(width: width, height: 360)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: ArkyvRadius.card))
                .padding(.horizontal, 20)
        }
    }

    /// `candidates`, filtered to those with a ready preview — the
    /// carousel's actual visible/scrollable set — paired with their
    /// ORIGINAL index (`selectedCandidateIndex`/`scrollPositionID`, and
    /// the final `resolveDraftForSaving` lookup, all key off the
    /// original candidate list, not this filtered view).
    private var readyCandidates: [(offset: Int, element: ResolvedImageCandidate)] {
        Array(candidates.enumerated()).filter { previewImages[$0.element.id] != nil }
    }

    /// Each candidate slot (active or neighbor) occupies this fraction
    /// of the available width. Physical-device feedback across three
    /// passes: 0.74, then 0.78, both still read as a sliver rather than
    /// "there's another photo right there." At 0.68 (with an 8pt gap),
    /// roughly 20% of a neighbor's OWN width is visible within the
    /// container — solved directly from the target geometry (visible
    /// peek = (containerWidth − slotWidth)/2 − spacing ≈ 0.20 ×
    /// slotWidth), matching the requested "~15–25% of the adjacent
    /// candidate visibly entering the viewport." The active slot still
    /// occupies more than 2/3 of the width, so it stays unambiguously
    /// dominant.
    private static let activeSlotFraction: CGFloat = 0.68
    private static let candidateSpacing: CGFloat = 8
    /// The carousel area itself must stay a fixed, concrete number for
    /// any given active candidate (never `.infinity`/flexible) — these
    /// are the bounds that number is clamped within, so one extreme
    /// source aspect ratio can't collapse the drawer's vertical rhythm
    /// (a very wide banner) or push X/✓ off a small screen (a very
    /// tall portrait). Within these bounds the ACTIVE candidate's own
    /// ratio is always honored exactly — clamping only ever adds
    /// letterboxing, never crops.
    private static let carouselMinHeight: CGFloat = 220
    private static let carouselMaxHeight: CGFloat = 420
    private static let carouselFallbackHeight: CGFloat = 360

    /// The active candidate's true aspect ratio, read directly from its
    /// already-decoded preview `UIImage.size` — always known by the time
    /// this is called, since only ready (preview-loaded) candidates are
    /// ever selectable. `carouselFallbackHeight` is a defensive-only
    /// fallback for the single instant before the very first preview
    /// resolves.
    private func carouselHeight(forWidth slotWidth: CGFloat) -> CGFloat {
        guard candidates.indices.contains(selectedCandidateIndex),
              let image = previewImages[candidates[selectedCandidateIndex].id],
              image.size.width > 0, image.size.height > 0 else {
            return Self.carouselFallbackHeight
        }
        let raw = slotWidth * image.size.height / image.size.width
        return min(max(raw, Self.carouselMinHeight), Self.carouselMaxHeight)
    }

    @ViewBuilder
    private func candidateSlot(_ candidate: ResolvedImageCandidate, isActive: Bool, slotWidth: CGFloat, height: CGFloat) -> some View {
        // Final visual pass, "the preview is the source image itself":
        // NO corner radius, NO background fill, NO border — those all
        // read as a Cherries-created card/viewport around the image,
        // which is exactly what's being removed. `.frame(width:height:)`
        // below is purely an invisible layout slot for the paging
        // math — it draws nothing of its own. If the source image has
        // real alpha transparency, or simply doesn't fill this
        // (invisible) slot because its own aspect ratio differs from
        // the shared box, the drawer's own black canvas shows through
        // directly — never a gray backing plate manufactured to make it
        // look like a rectangular card.
        Group {
            if let image = previewImages[candidate.id] {
                // `.fit`, never `.fill` — the candidate's own decoded
                // size drives its true aspect ratio directly, so the
                // rendered edges are the image's own edges.
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(image.size.width / max(image.size.height, 1), contentMode: .fit)
            }
        }
        .frame(width: slotWidth, height: height)
        // Reduced scale + opacity is the whole "there is another image,
        // clearly subordinate, clearly swipeable" signal — combined
        // with genuinely being partially visible at the box's own edge
        // (the point of `activeSlotFraction` < 1), this is legible
        // before the user ever touches the screen. The active slot
        // remains the ONLY one at full presence — "obviously the one ✓
        // will commit" — with no badge/checkmark drawn over the image
        // itself, keeping it visually clean.
        .scaleEffect(isActive ? 1 : 0.86)
        .opacity(isActive ? 1 : 0.4)
    }

    /// Downloads (or, for the primary candidate, decodes bytes already
    /// in hand — see `ResolvedImageCandidate.Source.bytes`) and decodes
    /// a lightweight, downsampled preview — NEVER written to
    /// `MediaStore`, NEVER the full archival fetch. Guarded against
    /// re-fetching one already ready or already in flight.
    private static let previewMaxPixelSize: CGFloat = 700

    private func fetchPreview(candidate: ResolvedImageCandidate) async {
        guard previewImages[candidate.id] == nil, !previewFetching.contains(candidate.id) else { return }
        previewFetching.insert(candidate.id)
        let data: Data?
        switch candidate.source {
        case .bytes(let existingData, _):
            data = existingData
        case .url(let url):
            data = try? await URLSession.shared.data(from: url).0
        }
        guard !Task.isCancelled else {
            previewFetching.remove(candidate.id)
            return
        }
        let targetSize = Self.previewMaxPixelSize
        let decoded = await Task.detached(priority: .userInitiated) {
            data.flatMap { ImageDecoding.decode($0, maxPixelSize: targetSize) }
        }.value
        guard !Task.isCancelled else {
            previewFetching.remove(candidate.id)
            return
        }
        previewFetching.remove(candidate.id)
        if let decoded {
            previewImages[candidate.id] = decoded
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

    /// Share Extension Visual Consistency 01: rebuilt on the shared
    /// `FolderSelectionRow` (`ArkyvKit`, moved there from the app target
    /// specifically so this separate compilation target could finally
    /// reach it) instead of this drawer's own independent, never-updated
    /// row — the orange `FolderIconView`/star-cross-triangle-circle-
    /// diamond glyphs and orange checkmark visible on physical-device QA
    /// were this exact private `folderRow`, which the app-target-only
    /// Import Cherry Drawer refinements could never have touched. Same
    /// two behavioral rules Import's own dropdown already established:
    /// "Unfiled" only appears as a row once a real folder is already
    /// selected (never pre-highlighted as a choice the user made), and
    /// tapping the already-selected row clears back to Unfiled
    /// (`FolderSelectionUX`).
    private var folderPanel: some View {
        VStack(spacing: 4) {
            if selectedFolder != nil {
                FolderSelectionRow(name: "Unfiled", isSelected: false) {
                    selectFolder(nil)
                }
            }
            if folders.isEmpty {
                Text("No folders yet")
                    .font(ArkyvFont.mono(.regular, size: 13))
                    .foregroundStyle(ArkyvColor.subdued)
                    .padding(.vertical, 10)
            } else {
                ForEach(folders) { folder in
                    FolderSelectionRow(name: folder.name, isSelected: folder.id == selectedFolder?.id) {
                        // Tapping the already-selected row clears back to
                        // Unfiled — same toggle-to-nil mechanism Item
                        // Detail's picker uses, so there's always a way
                        // back without a separate control.
                        let resultID = FolderSelectionUX.toggling(current: selectedFolder?.id, tapped: folder.id)
                        selectFolder(resultID == folder.id ? folder : nil)
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

    /// Same "fast hands, calm room" settle every other Cherries folder
    /// picker uses (`FolderEditorView.select(_:)`, the app-target Import
    /// drawer's own `selectFolder(_:)`) — the row's font/color/scale/
    /// checkmark change all ride this one `withAnimation` block, plus
    /// closing the dropdown.
    private func selectFolder(_ folder: StoredFolder?) {
        withAnimation(ArkyvMotion.settle) {
            selectedFolder = folder
        }
        showingPicker = false
    }

    // MARK: Save

    /// ✓ IS the save — the one existing `Repository.fileCapture` call.
    /// Link Cherry Visual Picker 01 interaction refinement: the carousel
    /// now operates entirely on lightweight, non-archival preview images
    /// (see `previewImages`) — nothing reaches `MediaStore` for ANY
    /// candidate until this exact moment, when whichever one is selected
    /// gets its one, real, full-fidelity archival fetch via
    /// `URLCherryResolver.materializeCandidate`. This is why confirmSave
    /// is async now (it wasn't before): for the `.single` case it
    /// resolves instantly (the draft is already complete, as always);
    /// for a multi-candidate selection it awaits that one archival
    /// fetch. `isReady`/the ✓ button's `isEnabled` only require the
    /// selected candidate's lightweight PREVIEW to be ready, not this —
    /// the button disables again (`isSaving`) for the brief window this
    /// final fetch takes, exactly like any other save.
    private func confirmSave() {
        guard isReady, !isSaving else { return }
        isSaving = true
        saveError = false
        Task {
            guard let draftToSave = await resolveDraftForSaving() else {
                isSaving = false
                saveError = true
                return
            }
            do {
                if let selectedFolder {
                    try Repository(context: context).fileCapture(draftToSave, into: selectedFolder)
                } else {
                    try Repository(context: context).fileCapture(draftToSave, folders: [])
                }
                didSave = true
                prefetchTask?.cancel()
                onDone()
            } catch {
                isSaving = false
                saveError = true
            }
        }
    }

    /// The `.single` case's draft is already complete — no archival
    /// fetch needed, matches every non-picker share exactly as before.
    /// The `.candidates` case performs the ONE real archival fetch, for
    /// the currently-selected candidate only.
    private func resolveDraftForSaving() async -> CaptureDraft? {
        switch resolution {
        case .single(let draft):
            return draft
        case .candidates(let resolved):
            guard candidates.indices.contains(selectedCandidateIndex) else { return nil }
            return await URLCherryResolver.materializeCandidate(
                candidates[selectedCandidateIndex], title: resolved.title, sourceURL: resolved.sourceURL,
                sourceDevice: .iOS, isEditorial: resolved.isEditorial, acquisitionOrigin: .shareExtension
            )
        case nil:
            return nil
        }
    }

    /// LIFECYCLE / FAULT INJECTION FOUNDATION 01: reclaims the staged
    /// MediaStore file on a genuine cancel — same reasoning as
    /// `ScreenshotCaptureFlowView`'s cancel paths. `didSave` (set only
    /// after a successful `fileCapture` in `confirmSave`) is the guard
    /// that keeps this from ever deleting a file a just-saved
    /// `StoredItem` now depends on. Link Cherry Visual Picker 01: since
    /// candidate previews are pure in-memory `UIImage`s now — never
    /// written to `MediaStore` at all — there is nothing left to reclaim
    /// for the candidates path; only the `.single` case (and, if the
    /// user was mid-save, whatever `resolveDraftForSaving` may have just
    /// written) can have a real staged file, exactly like before this
    /// milestone existed.
    private func cancelAndCleanUp() {
        prefetchTask?.cancel()
        if !didSave, case .single(let draft) = resolution, let filename = draft.localFilename {
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
    /// Link Cherry Visual Picker 01: `.fill` (the original, unchanged
    /// default) crop-to-fills the frame — right for a single already-
    /// chosen representative image. The candidate swiper passes `.fit`
    /// instead: candidates are far more likely to vary wildly in aspect
    /// ratio than one resolved image is, and physical-device QA found
    /// `.fill`'s crop looked inconsistent/awkward across candidates —
    /// `.fit` shows each candidate's whole frame, letterboxed if needed,
    /// consistently regardless of source shape.
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    /// Generous for a 360pt-tall preview even at 3x, without paying for
    /// anywhere near the original's full resolution.
    private static let maxPixelSize: CGFloat = 800

    var body: some View {
        Group {
            if let image {
                // `.background` matters specifically for `.fit`: unlike
                // `.fill` (which always covers the whole frame), a
                // letterboxed `.fit` image leaves part of the frame
                // empty, which would otherwise show the drawer's raw
                // dark canvas through — a neutral surface fill instead
                // reads as one consistent card regardless of a
                // candidate's aspect ratio.
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ArkyvColor.surface)
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
