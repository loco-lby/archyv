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

        let draft = await URLCherryResolver.resolve(url, sourceDevice: .iOS, fetcher: fetcher, mediaStore: mediaStore)

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

            let draft = await URLCherryResolver.resolve(url, sourceDevice: .iOS, fetcher: fetcher, mediaStore: mediaStore)
            XCTAssertEqual(draft?.sourceURL, raw, "original URL string must survive unchanged")
        }
    }

    func testResolveCarriesTitleThrough() async {
        let url = URL(string: "https://example.com/thing")!
        let metadata = makeMetadata(url: url, title: "Exact Title", imageProvider: imageProvider(bytes: Self.validPNGBytes))
        let fetcher = FakeFetcher(result: .success(metadata))
        let (mediaStore, root) = makeIsolatedMediaStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let draft = await URLCherryResolver.resolve(url, sourceDevice: .iOS, fetcher: fetcher, mediaStore: mediaStore)
        XCTAssertEqual(draft?.title, "Exact Title")
    }

    // MARK: - Failure → fallback (returns nil)

    func testMetadataFetchFailureFallsBack() async {
        let url = URL(string: "https://example.com/dead")!
        let fetcher = FakeFetcher(result: .failure(URLError(.notConnectedToInternet)))
        let (mediaStore, root) = makeIsolatedMediaStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let draft = await URLCherryResolver.resolve(url, sourceDevice: .iOS, fetcher: fetcher, mediaStore: mediaStore)
        XCTAssertNil(draft)
    }

    func testNoImageProviderFallsBack() async {
        let url = URL(string: "https://example.com/text-only")!
        let metadata = makeMetadata(url: url, title: "No Image Here", imageProvider: nil)
        let fetcher = FakeFetcher(result: .success(metadata))
        let (mediaStore, root) = makeIsolatedMediaStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let draft = await URLCherryResolver.resolve(url, sourceDevice: .iOS, fetcher: fetcher, mediaStore: mediaStore)
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

        let draft = await URLCherryResolver.resolve(url, sourceDevice: .iOS, fetcher: fetcher, mediaStore: mediaStore)
        XCTAssertNil(draft)
    }

    func testInvalidImageBytesFallBackAndWriteNoFile() async {
        let url = URL(string: "https://example.com/garbage")!
        let garbage = Data("not an image".utf8)
        let metadata = makeMetadata(url: url, imageProvider: imageProvider(bytes: garbage))
        let fetcher = FakeFetcher(result: .success(metadata))
        let (mediaStore, root) = makeIsolatedMediaStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let draft = await URLCherryResolver.resolve(url, sourceDevice: .iOS, fetcher: fetcher, mediaStore: mediaStore)
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
        let draft = await URLCherryResolver.resolve(url, sourceDevice: .iOS, fetcher: fetcher, mediaStore: mediaStore, timeout: 0.3)
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

        let draft = await URLCherryResolver.resolve(url, sourceDevice: .iOS, fetcher: fetcher, mediaStore: mediaStore, enrichers: [enricher])

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

        let draft = await URLCherryResolver.resolve(url, sourceDevice: .iOS, fetcher: fetcher, mediaStore: mediaStore, enrichers: [enricher])

        XCTAssertFalse(enricher.enrichWasCalled, "a non-matching enricher must never have enrich(_:) invoked")
        XCTAssertEqual(draft?.title, "Generic Title")
    }

    // MARK: - resolveCandidates / materializeCandidate (Link Cherry Visual Picker 01)

    func testResolveCandidatesReturnsSingleCandidateWhenNoSourceMatches() async {
        let url = URL(string: "https://example.com/thing")!
        let metadata = makeMetadata(url: url, title: "T", imageProvider: imageProvider(bytes: Self.validPNGBytes))
        let fetcher = FakeFetcher(result: .success(metadata))

        let resolved = await URLCherryResolver.resolveCandidates(url, sourceDevice: .iOS, fetcher: fetcher, candidateSources: [])

        XCTAssertEqual(resolved?.candidates.count, 1)
    }

    func testResolveCandidatesOrdersPrimaryFirstAndAppendsAdditional() async {
        let url = URL(string: "https://example.com/thing")!
        let metadata = makeMetadata(url: url, title: "T", imageProvider: imageProvider(bytes: Self.validPNGBytes))
        let fetcher = FakeFetcher(result: .success(metadata))
        let extraURLs = [URL(string: "https://example.com/alt1.jpg")!, URL(string: "https://example.com/alt2.jpg")!]
        let source = FakeCandidateSource(matchesResult: true, result: .success(extraURLs))

        let resolved = await URLCherryResolver.resolveCandidates(url, sourceDevice: .iOS, fetcher: fetcher, candidateSources: [source])

        XCTAssertEqual(resolved?.candidates.count, 3)
        XCTAssertEqual(resolved?.candidates.first?.id, "primary")
    }

    func testResolveCandidatesFallsBackToSingleWhenCandidateSourceThrows() async {
        let url = URL(string: "https://example.com/thing")!
        let metadata = makeMetadata(url: url, title: "T", imageProvider: imageProvider(bytes: Self.validPNGBytes))
        let fetcher = FakeFetcher(result: .success(metadata))
        let source = FakeCandidateSource(matchesResult: true, result: .failure(FakeEnricher.Error.boom))

        let resolved = await URLCherryResolver.resolveCandidates(url, sourceDevice: .iOS, fetcher: fetcher, candidateSources: [source])

        XCTAssertEqual(resolved?.candidates.count, 1, "a throwing candidate source must never break resolution — just contribute zero extras")
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
