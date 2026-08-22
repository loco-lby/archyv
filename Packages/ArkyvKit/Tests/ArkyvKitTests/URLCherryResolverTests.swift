import XCTest
import LinkPresentation
@testable import ArkyvKit

/// URL → Cherry Production Foundation 01. Exercises `URLCherryResolver`
/// entirely against a fake `LinkMetadataFetching` and an isolated
/// `MediaStore` — no network. Deliberately avoids the real
/// `LPMetadataProvider`/public internet: that path was already validated
/// empirically against all six real test URLs in Discovery Spike 01 and is
/// not something a deterministic unit test should depend on.
final class URLCherryResolverTests: XCTestCase {
    private func makeIsolatedMediaStore() -> (MediaStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("URLCherryResolverTests-\(UUID().uuidString)")
        return (MediaStore(isolatedRoot: root), root)
    }

    /// A minimal, genuinely-decodable 1x1 PNG — enough for
    /// `ImageDecoding.pixelSize(ofData:)` to succeed for real.
    private static let validPNGBytes: Data = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    private func imageProvider(bytes: Data, type: String = "public.png") -> NSItemProvider {
        NSItemProvider(item: bytes as NSData, typeIdentifier: type)
    }

    private func makeMetadata(url: URL, title: String? = nil, imageProvider: NSItemProvider? = nil) -> LPLinkMetadata {
        let metadata = LPLinkMetadata()
        metadata.originalURL = url
        metadata.url = url
        metadata.title = title
        metadata.imageProvider = imageProvider
        return metadata
    }

    // MARK: - Success path

    func testResolveSucceedsWithImageBackedDraft() async {
        let url = URL(string: "https://example.com/thing")!
        let metadata = makeMetadata(url: url, title: "A Thing", imageProvider: imageProvider(bytes: Self.validPNGBytes))
        let fetcher = FakeFetcher(result: .success(metadata))
        let (mediaStore, root) = makeIsolatedMediaStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let draft = await URLCherryResolver.resolve(url, sourceDevice: .iOS, fetcher: fetcher, mediaStore: mediaStore, editorialDetector: FakeArticleDetector(result: nil))

        XCTAssertNotNil(draft)
        XCTAssertEqual(draft?.kind, .image)
        XCTAssertNotNil(draft?.localFilename)
        XCTAssertEqual(draft?.pixelSize, CGSize(width: 1, height: 1))
        XCTAssertEqual(fetcher.callCount, 1, "resolver must fetch metadata exactly once")
    }

    func testResolvePreservesOriginalURLVerbatimIncludingQueryParams() async {
        // Instagram's img_index and YouTube's t= are exactly this shape:
        // query params a "canonical URL" would be free to drop.
        for raw in [
            "https://www.instagram.com/p/DbEB5nilGqS/?img_index=1",
            "https://www.youtube.com/watch?v=XcObGXRfKyU&t=106s",
        ] {
            let url = URL(string: raw)!
            let metadata = makeMetadata(url: url, imageProvider: imageProvider(bytes: Self.validPNGBytes))
            let fetcher = FakeFetcher(result: .success(metadata))
            let (mediaStore, root) = makeIsolatedMediaStore()
            defer { try? FileManager.default.removeItem(at: root) }

            let draft = await URLCherryResolver.resolve(url, sourceDevice: .iOS, fetcher: fetcher, mediaStore: mediaStore, editorialDetector: FakeArticleDetector(result: nil))
            XCTAssertEqual(draft?.sourceURL, raw, "original URL string must survive unchanged")
        }
    }

    /// Provenance Foundation Implementation 01 regression specimen: the
    /// exact Spotify "Playlist" share shape found during the Spotify A/B
    /// recon (`pi=` + `si=` + `utm_source=`, all real query params from a
    /// genuine device share). `resolve()`'s `sourceURL` must remain
    /// byte-for-byte identical to what was shared, even though
    /// `LPMetadataProvider`'s OWN internal `metadata.url` (set to the same
    /// value here, matching real `LPLinkMetadata` behavior in the fixture)
    /// is never read by anything that persists.
    func testResolvePreservesSpotifyStyleQueryStateExactly() async {
        let raw = "https://open.spotify.com/playlist/3zgrbZpFHQSiW1VypLCVmw?si=OyIn40MRRkS8qpaMrhANyQ&utm_source=native-share-menu&pi=Vo9m4mEkRquhv"
        let url = URL(string: raw)!
        let metadata = makeMetadata(url: url, title: ".funSucker", imageProvider: imageProvider(bytes: Self.validPNGBytes))
        let fetcher = FakeFetcher(result: .success(metadata))
        let (mediaStore, root) = makeIsolatedMediaStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let draft = await URLCherryResolver.resolve(url, sourceDevice: .iOS, fetcher: fetcher, mediaStore: mediaStore, editorialDetector: FakeArticleDetector(result: nil))
        XCTAssertEqual(draft?.sourceURL, raw, "pi=/si=/utm_source= must all survive — this exact query state carries real user intent, not just tracking noise")
    }

    func testResolveCarriesTitleThrough() async {
        let url = URL(string: "https://example.com/thing")!
        let metadata = makeMetadata(url: url, title: "Exact Title", imageProvider: imageProvider(bytes: Self.validPNGBytes))
        let fetcher = FakeFetcher(result: .success(metadata))
        let (mediaStore, root) = makeIsolatedMediaStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let draft = await URLCherryResolver.resolve(url, sourceDevice: .iOS, fetcher: fetcher, mediaStore: mediaStore, editorialDetector: FakeArticleDetector(result: nil))
        XCTAssertEqual(draft?.title, "Exact Title")
    }

    // MARK: - Failure → fallback (returns nil)

    func testMetadataFetchFailureFallsBack() async {
        let url = URL(string: "https://example.com/dead")!
        let fetcher = FakeFetcher(result: .failure(URLError(.notConnectedToInternet)))
        let (mediaStore, root) = makeIsolatedMediaStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let draft = await URLCherryResolver.resolve(url, sourceDevice: .iOS, fetcher: fetcher, mediaStore: mediaStore, editorialDetector: FakeArticleDetector(result: nil))
        XCTAssertNil(draft)
    }

    func testNoImageProviderFallsBack() async {
        let url = URL(string: "https://example.com/text-only")!
        let metadata = makeMetadata(url: url, title: "No Image Here", imageProvider: nil)
        let fetcher = FakeFetcher(result: .success(metadata))
        let (mediaStore, root) = makeIsolatedMediaStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let draft = await URLCherryResolver.resolve(url, sourceDevice: .iOS, fetcher: fetcher, mediaStore: mediaStore, editorialDetector: FakeArticleDetector(result: nil))
        XCTAssertNil(draft)
    }

    func testNonImageProviderTypeFallsBack() async {
        let url = URL(string: "https://example.com/weird")!
        // Registered type doesn't conform to .image at all.
        let provider = NSItemProvider(item: "hello" as NSString, typeIdentifier: "public.plain-text")
        let metadata = makeMetadata(url: url, imageProvider: provider)
        let fetcher = FakeFetcher(result: .success(metadata))
        let (mediaStore, root) = makeIsolatedMediaStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let draft = await URLCherryResolver.resolve(url, sourceDevice: .iOS, fetcher: fetcher, mediaStore: mediaStore, editorialDetector: FakeArticleDetector(result: nil))
        XCTAssertNil(draft)
    }

    func testInvalidImageBytesFallBackAndWriteNoFile() async {
        let url = URL(string: "https://example.com/garbage")!
        let garbage = Data("not an image".utf8)
        let metadata = makeMetadata(url: url, imageProvider: imageProvider(bytes: garbage))
        let fetcher = FakeFetcher(result: .success(metadata))
        let (mediaStore, root) = makeIsolatedMediaStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let draft = await URLCherryResolver.resolve(url, sourceDevice: .iOS, fetcher: fetcher, mediaStore: mediaStore, editorialDetector: FakeArticleDetector(result: nil))
        XCTAssertNil(draft)

        // No orphaned MediaStore write for bytes that never validated as an image.
        let filesWritten = (try? FileManager.default.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") }) ?? []
        XCTAssertTrue(filesWritten.isEmpty, "invalid image bytes must never reach MediaStore.save")
    }

    // MARK: - Timeout / cancellation

    func testTimeoutFallsBackAndDoesNotWriteAFile() async {
        let url = URL(string: "https://example.com/slow")!
        // Never resolves within the test's timeout window.
        let fetcher = FakeFetcher(result: .hang)
        let (mediaStore, root) = makeIsolatedMediaStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let start = Date()
        let draft = await URLCherryResolver.resolve(url, sourceDevice: .iOS, fetcher: fetcher, mediaStore: mediaStore, editorialDetector: FakeArticleDetector(result: nil), timeout: 0.3)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(draft)
        XCTAssertLessThan(elapsed, 2.0, "resolve() must not hang past its configured timeout")

        let filesWritten = (try? FileManager.default.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") }) ?? []
        XCTAssertTrue(filesWritten.isEmpty, "a timed-out resolution must never persist a file")
    }

    // MARK: - Source enricher fallback (Priority Source Intelligence 01)

    /// A matched enricher that always throws must never prevent the
    /// unchanged generic path from still resolving the Cherry — "no
    /// source-specific failure may prevent saving a Cherry."
    func testThrowingEnricherFallsBackToGenericResolution() async {
        let url = URL(string: "https://example.com/thing")!
        let metadata = makeMetadata(url: url, title: "Generic Title", imageProvider: imageProvider(bytes: Self.validPNGBytes))
        let fetcher = FakeFetcher(result: .success(metadata))
        let (mediaStore, root) = makeIsolatedMediaStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let enricher = FakeEnricher(matchesResult: true, result: .failure(FakeEnricher.Error.boom))

        let draft = await URLCherryResolver.resolve(url, sourceDevice: .iOS, fetcher: fetcher, mediaStore: mediaStore, enrichers: [enricher], editorialDetector: FakeArticleDetector(result: nil))

        XCTAssertNotNil(draft, "generic resolution must still succeed after enrichment fails")
        XCTAssertEqual(draft?.title, "Generic Title")
    }

    /// An enricher whose `matches(_:)` returns `false` must never be
    /// invoked at all — the generic path runs directly.
    func testNonMatchingEnricherIsNeverCalled() async {
        let url = URL(string: "https://example.com/thing")!
        let metadata = makeMetadata(url: url, title: "Generic Title", imageProvider: imageProvider(bytes: Self.validPNGBytes))
        let fetcher = FakeFetcher(result: .success(metadata))
        let (mediaStore, root) = makeIsolatedMediaStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let enricher = FakeEnricher(matchesResult: false, result: .failure(FakeEnricher.Error.boom))

        let draft = await URLCherryResolver.resolve(url, sourceDevice: .iOS, fetcher: fetcher, mediaStore: mediaStore, enrichers: [enricher], editorialDetector: FakeArticleDetector(result: nil))

        XCTAssertFalse(enricher.enrichWasCalled, "a non-matching enricher must never have enrich(_:) invoked")
        XCTAssertEqual(draft?.title, "Generic Title")
    }

    /// `CaptureDraft.title`/`EnrichedLinkContent.title` are both optional
    /// — a source that legitimately has no useful title to offer
    /// (Instagram Link Cherry V1 01: a Reel with only engagement-stat
    /// boilerplate, nothing worth surfacing — see
    /// `InstagramSourceEnricher.extractCaption`) must still produce a
    /// normal, saveable image draft. Nothing in `URLCherryResolver`/
    /// `materializeCandidate` gates on `title` being non-nil (confirmed
    /// by inspection — `title` is only ever threaded through, never
    /// branched on); exercised here via the generic path (which is
    /// properly seamed for network-free testing) since a matched
    /// enricher's OWN image fetch has no such seam and is instead
    /// verified live on Device A, same as `YouTubeOEmbedEnricherTests`.
    func testNilTitleStillProducesDraft() async {
        let url = URL(string: "https://example.com/thing")!
        let metadata = makeMetadata(url: url, title: nil, imageProvider: imageProvider(bytes: Self.validPNGBytes))
        let fetcher = FakeFetcher(result: .success(metadata))
        let (mediaStore, root) = makeIsolatedMediaStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let draft = await URLCherryResolver.resolve(url, sourceDevice: .iOS, fetcher: fetcher, mediaStore: mediaStore, editorialDetector: FakeArticleDetector(result: nil))

        XCTAssertNotNil(draft?.localFilename)
        XCTAssertNil(draft?.title)
    }

    // MARK: - resolveCandidates / materializeCandidate (Link Cherry Visual Picker 01)

    func testResolveCandidatesReturnsSingleCandidateWhenNoSourceMatches() async {
        let url = URL(string: "https://example.com/thing")!
        let metadata = makeMetadata(url: url, title: "T", imageProvider: imageProvider(bytes: Self.validPNGBytes))
        let fetcher = FakeFetcher(result: .success(metadata))

        let resolved = await URLCherryResolver.resolveCandidates(url, sourceDevice: .iOS, fetcher: fetcher, candidateSources: [], editorialDetector: FakeArticleDetector(result: nil))

        XCTAssertEqual(resolved?.candidates.count, 1)
    }

    func testResolveCandidatesOrdersPrimaryFirstAndAppendsAdditional() async {
        let url = URL(string: "https://example.com/thing")!
        let metadata = makeMetadata(url: url, title: "T", imageProvider: imageProvider(bytes: Self.validPNGBytes))
        let fetcher = FakeFetcher(result: .success(metadata))
        let extraURLs = [URL(string: "https://example.com/alt1.jpg")!, URL(string: "https://example.com/alt2.jpg")!]
        let source = FakeCandidateSource(matchesResult: true, result: .success(extraURLs))

        let resolved = await URLCherryResolver.resolveCandidates(url, sourceDevice: .iOS, fetcher: fetcher, candidateSources: [source], editorialDetector: FakeArticleDetector(result: nil))

        XCTAssertEqual(resolved?.candidates.count, 3)
        XCTAssertEqual(resolved?.candidates.first?.id, "primary")
    }

    /// Ecommerce ProductGroup Support 01: a discovered risk, documented
    /// rather than silently patched — that milestone's own scope was
    /// deliberately narrowed to JSON-LD type recognition only, pending
    /// physical-device confirmation of whether this actually manifests
    /// visibly. The generic candidate's `id` is the fixed string
    /// `"primary"`, never derived from the URL it came from — so when a
    /// `CandidateImageSource` contributes exactly ONE extra candidate
    /// that happens to be the exact same underlying photo already
    /// fetched generically (the common real shape for a `ProductGroup`
    /// with exactly one image, confirmed on Gymshark/Allbirds/Nike
    /// during Recon 02 — their `ProductGroup.image` and `og:image`
    /// resolve to the identical asset), nothing recognizes them as
    /// duplicates: `candidates.count` becomes 2, which would trip the
    /// Share Extension's own `candidates.count > 1` picker gate with the
    /// same photo in both slots. This test proves the COUNT, which is
    /// all a unit test can prove without real image bytes — whether it's
    /// actually the same photo (and therefore actually visible junk) can
    /// only be confirmed on Device A.
    func testSingleExtraCandidateIsNeverDedupedAgainstGenericPrimaryByIDAlone() async {
        let url = URL(string: "https://example.com/thing")!
        let metadata = makeMetadata(url: url, title: "T", imageProvider: imageProvider(bytes: Self.validPNGBytes))
        let fetcher = FakeFetcher(result: .success(metadata))
        let source = FakeCandidateSource(matchesResult: true, result: .success([URL(string: "https://example.com/possibly-the-same-photo.jpg")!]))

        let resolved = await URLCherryResolver.resolveCandidates(url, sourceDevice: .iOS, fetcher: fetcher, candidateSources: [source], editorialDetector: FakeArticleDetector(result: nil))

        XCTAssertEqual(
            resolved?.candidates.count, 2,
            "known risk: the generic \"primary\" candidate and a single URL-based extra candidate are never deduped against each other by ID, even if they resolve to the same underlying photo"
        )
    }

    func testResolveCandidatesFallsBackToSingleWhenCandidateSourceThrows() async {
        let url = URL(string: "https://example.com/thing")!
        let metadata = makeMetadata(url: url, title: "T", imageProvider: imageProvider(bytes: Self.validPNGBytes))
        let fetcher = FakeFetcher(result: .success(metadata))
        let source = FakeCandidateSource(matchesResult: true, result: .failure(FakeEnricher.Error.boom))

        let resolved = await URLCherryResolver.resolveCandidates(url, sourceDevice: .iOS, fetcher: fetcher, candidateSources: [source], editorialDetector: FakeArticleDetector(result: nil))

        XCTAssertEqual(resolved?.candidates.count, 1, "a throwing candidate source must never break resolution — just contribute zero extras")
    }

    /// Provenance Foundation Implementation 01, test K: a matched
    /// source-specific enricher (representative of Pinterest/Instagram/
    /// YouTube/etc.) falling back to generic resolution still preserves
    /// the exact original URL — proven directly, not just asserted, since
    /// `EnrichedLinkContent` structurally has no URL field at all (only
    /// `title`/`imageURL`), so no enricher, successful or not, can ever
    /// substitute its own URL for `attemptResolveCandidates`'s original
    /// `url` parameter. (A successfully-enriched draft's own `sourceURL`
    /// is not independently re-verifiable here without a real network
    /// fetch for the enricher's image — same limitation
    /// `testNilTitleStillProducesDraft`'s doc comment already notes for
    /// this suite; that path is confirmed on Device A instead.)
    func testMatchedButFailingEnricherFallsBackWithOriginalSourceURLIntact() async {
        let raw = "https://www.instagram.com/p/DbEB5nilGqS/?img_index=1"
        let url = URL(string: raw)!
        let metadata = makeMetadata(url: url, title: "Generic Title", imageProvider: imageProvider(bytes: Self.validPNGBytes))
        let fetcher = FakeFetcher(result: .success(metadata))
        let enricher = FakeEnricher(matchesResult: true, result: .failure(FakeEnricher.Error.boom))

        let resolved = await URLCherryResolver.resolveCandidates(
            url, sourceDevice: .iOS, fetcher: fetcher, enrichers: [enricher], candidateSources: [], editorialDetector: FakeArticleDetector(result: nil)
        )

        XCTAssertEqual(resolved?.sourceURL, url)
    }

    // MARK: - Editorial Cover V1

    /// Article Metadata hierarchy (Section 4): a clean JSON-LD headline
    /// outranks the generic `LPMetadataProvider` title, and `isEditorial`
    /// is set — the two things One Archive's rendering needs.
    func testEditorialSignalOverridesGenericTitleAndSetsIsEditorial() async {
        let url = URL(string: "https://example.com/thing")!
        let metadata = makeMetadata(url: url, title: "Generic LPMetadataProvider Title", imageProvider: imageProvider(bytes: Self.validPNGBytes))
        let fetcher = FakeFetcher(result: .success(metadata))
        let detector = FakeArticleDetector(result: EditorialSignal(headline: "The Clean JSON-LD Headline"))

        let resolved = await URLCherryResolver.resolveCandidates(url, sourceDevice: .iOS, fetcher: fetcher, candidateSources: [], editorialDetector: detector)

        XCTAssertEqual(resolved?.title, "The Clean JSON-LD Headline")
        XCTAssertEqual(resolved?.isEditorial, true)
    }

    /// The `og:type="article"` fallback case: `EditorialSignal(headline:
    /// nil)` still sets `isEditorial`, but never overrides the generic
    /// title — only a real JSON-LD `headline` is trusted for that
    /// (matches Real Life's real shape: no JSON-LD, only `og:type`).
    func testEditorialSignalWithNoHeadlineStillSetsIsEditorialButKeepsGenericTitle() async {
        let url = URL(string: "https://example.com/thing")!
        let metadata = makeMetadata(url: url, title: "Generic Title", imageProvider: imageProvider(bytes: Self.validPNGBytes))
        let fetcher = FakeFetcher(result: .success(metadata))
        let detector = FakeArticleDetector(result: EditorialSignal(headline: nil))

        let resolved = await URLCherryResolver.resolveCandidates(url, sourceDevice: .iOS, fetcher: fetcher, candidateSources: [], editorialDetector: detector)

        XCTAssertEqual(resolved?.title, "Generic Title")
        XCTAssertEqual(resolved?.isEditorial, true)
    }

    /// No editorial signal at all (the real shape for It's Nice That,
    /// National Geographic's photo gallery, and every ecommerce page
    /// tested) — `isEditorial` stays `false`, title is untouched.
    func testNoEditorialSignalLeavesGenericTitleAndIsEditorialFalse() async {
        let url = URL(string: "https://example.com/thing")!
        let metadata = makeMetadata(url: url, title: "Generic Title", imageProvider: imageProvider(bytes: Self.validPNGBytes))
        let fetcher = FakeFetcher(result: .success(metadata))
        let detector = FakeArticleDetector(result: nil)

        let resolved = await URLCherryResolver.resolveCandidates(url, sourceDevice: .iOS, fetcher: fetcher, candidateSources: [], editorialDetector: detector)

        XCTAssertEqual(resolved?.title, "Generic Title")
        XCTAssertEqual(resolved?.isEditorial, false)
    }

    /// Six-families-distinct guard: a THROWING enricher match falls
    /// through to the generic path (existing, unchanged behavior — see
    /// `testThrowingEnricherFallsBackToGenericResolution`), so the
    /// editorial detector correctly DOES run there. A successfully
    /// MATCHED-and-enriched URL never reaches that fallback at all —
    /// provable directly from `attemptResolveCandidates`'s own control
    /// flow (the enricher-success branch `return`s before the editorial
    /// detector is ever referenced), not something a network-free unit
    /// test can independently re-verify, since `fetchEnrichedImage` has
    /// no injectable seam for its own image fetch (matching every other
    /// enricher test in this codebase, which stop at the enricher's own
    /// pure `matches`/meta-parsing functions rather than a full
    /// `resolveCandidates` round-trip).
    func testEditorialDetectorStillRunsWhenEnricherThrowsAndFallsBackToGeneric() async {
        let url = URL(string: "https://example.com/thing")!
        let enricher = FakeEnricher(matchesResult: true, result: .failure(FakeEnricher.Error.boom))
        let metadata = makeMetadata(url: url, title: "Generic Title", imageProvider: imageProvider(bytes: Self.validPNGBytes))
        let fetcher = FakeFetcher(result: .success(metadata))
        let detector = FakeArticleDetector(result: EditorialSignal(headline: "Clean Headline"))

        let resolved = await URLCherryResolver.resolveCandidates(
            url, sourceDevice: .iOS, fetcher: fetcher, enrichers: [enricher], candidateSources: [], editorialDetector: detector
        )

        XCTAssertEqual(resolved?.isEditorial, true, "a failed enricher correctly falls through to the generic path, where editorial detection still applies")
        XCTAssertEqual(resolved?.title, "Clean Headline")
    }

    func testMaterializeCandidateFromBytesNeedsNoNetworkAndSavesToMediaStore() async {
        let (mediaStore, root) = makeIsolatedMediaStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = ResolvedImageCandidate(id: "primary", source: .bytes(Self.validPNGBytes, typeHint: "png"))

        let draft = await URLCherryResolver.materializeCandidate(
            candidate, title: "T", sourceURL: URL(string: "https://example.com/thing")!, sourceDevice: .iOS, mediaStore: mediaStore
        )

        XCTAssertNotNil(draft?.localFilename)
        XCTAssertEqual(draft?.sourceURL, "https://example.com/thing")
    }

    /// Provenance Foundation Implementation 01: `materializeCandidate`
    /// threads its caller-supplied `acquisitionOrigin` straight through —
    /// `ShareViewController.resolveDraftForSaving()` is the real
    /// production caller and always passes `.shareExtension`; defaults to
    /// `.unknown` for every other caller (matching every other new field's
    /// own default-value precedent) so this is opt-in, never inferred.
    func testMaterializeCandidateThreadsAcquisitionOriginThrough() async {
        let (mediaStore, root) = makeIsolatedMediaStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = ResolvedImageCandidate(id: "primary", source: .bytes(Self.validPNGBytes, typeHint: "png"))

        let draft = await URLCherryResolver.materializeCandidate(
            candidate, title: "T", sourceURL: URL(string: "https://example.com/thing")!, sourceDevice: .iOS,
            acquisitionOrigin: .shareExtension, mediaStore: mediaStore
        )

        XCTAssertEqual(draft?.acquisitionOrigin, .shareExtension)
    }

    func testMaterializeCandidateDefaultsAcquisitionOriginToUnknown() async {
        let (mediaStore, root) = makeIsolatedMediaStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = ResolvedImageCandidate(id: "primary", source: .bytes(Self.validPNGBytes, typeHint: "png"))

        let draft = await URLCherryResolver.materializeCandidate(
            candidate, title: "T", sourceURL: URL(string: "https://example.com/thing")!, sourceDevice: .iOS, mediaStore: mediaStore
        )

        XCTAssertEqual(draft?.acquisitionOrigin, .unknown)
    }
}

// MARK: - Test doubles

private final class FakeFetcher: LinkMetadataFetching, @unchecked Sendable {
    enum Result {
        case success(LPLinkMetadata)
        case failure(Error)
        /// Never completes within any reasonable test timeout — exercises
        /// `URLCherryResolver`'s own timeout race, not a fast synthetic error.
        case hang
    }

    private let result: Result
    private let lock = NSLock()
    private var _callCount = 0
    var callCount: Int { lock.withLock { _callCount } }

    init(result: Result) {
        self.result = result
    }

    func fetchMetadata(for url: URL) async throws -> LPLinkMetadata {
        lock.withLock { _callCount += 1 }
        switch result {
        case .success(let metadata):
            return metadata
        case .failure(let error):
            throw error
        case .hang:
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}

private final class FakeEnricher: SourceEnricher, @unchecked Sendable {
    enum Error: Swift.Error { case boom }

    private let matchesResult: Bool
    private let result: Result<EnrichedLinkContent, Swift.Error>
    private let lock = NSLock()
    private var _enrichWasCalled = false
    var enrichWasCalled: Bool { lock.withLock { _enrichWasCalled } }

    init(matchesResult: Bool, result: Result<EnrichedLinkContent, Swift.Error>) {
        self.matchesResult = matchesResult
        self.result = result
    }

    func matches(_ url: URL) -> Bool { matchesResult }

    func enrich(_ url: URL) async throws -> EnrichedLinkContent {
        lock.withLock { _enrichWasCalled = true }
        switch result {
        case .success(let content): return content
        case .failure(let error): throw error
        }
    }
}

/// Editorial Cover V1. `nil` (the default every pre-existing test above
/// now passes explicitly) means "no editorial signal" — matches
/// `EditorialArticleDetector`'s own real behavior for a page with no
/// article markup, and keeps every test that predates this milestone
/// from making a real, non-deterministic network call to whatever
/// `FakeFetcher` URL it happens to use.
private final class FakeArticleDetector: ArticleDetecting, @unchecked Sendable {
    private let result: EditorialSignal?

    init(result: EditorialSignal?) {
        self.result = result
    }

    func detect(for url: URL) async -> EditorialSignal? { result }
}

private final class FakeCandidateSource: CandidateImageSource, @unchecked Sendable {
    private let matchesResult: Bool
    private let result: Result<[URL], Swift.Error>

    init(matchesResult: Bool, result: Result<[URL], Swift.Error>) {
        self.matchesResult = matchesResult
        self.result = result
    }

    func matches(_ url: URL) -> Bool { matchesResult }

    func candidateImageURLs(for url: URL) async throws -> [URL] {
        switch result {
        case .success(let urls): return urls
        case .failure(let error): throw error
        }
    }
}
