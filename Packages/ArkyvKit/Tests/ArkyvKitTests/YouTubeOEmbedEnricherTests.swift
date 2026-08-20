import XCTest
@testable import ArkyvKit

/// Priority Source Intelligence 01. Only `matches(_:)` is unit-tested —
/// pure, deterministic, no network. `enrich(_:)` hits YouTube's real
/// oEmbed endpoint by design (see this type's own doc comment for why
/// that's the right, narrow mechanism) and is verified live on Device A
/// instead, the same split this codebase has used throughout for
/// network-dependent behavior.
final class YouTubeOEmbedEnricherTests: XCTestCase {
    private let enricher = YouTubeOEmbedEnricher()

    func testMatchesBareYouTubeDomain() {
        XCTAssertTrue(enricher.matches(URL(string: "https://youtube.com/watch?v=abc")!))
    }

    func testMatchesWWWYouTubeDomain() {
        XCTAssertTrue(enricher.matches(URL(string: "https://www.youtube.com/watch?v=abc")!))
    }

    func testMatchesMobileYouTubeSubdomain() {
        XCTAssertTrue(enricher.matches(URL(string: "https://m.youtube.com/watch?v=abc")!))
    }

    func testMatchesYoutuDotBeShortLink() {
        XCTAssertTrue(enricher.matches(URL(string: "https://youtu.be/abc")!))
    }

    func testDoesNotMatchUnrelatedDomain() {
        XCTAssertFalse(enricher.matches(URL(string: "https://example.com/watch?v=abc")!))
    }

    func testDoesNotMatchLookalikeDomain() {
        // A domain that merely contains "youtube" must not match — only
        // youtube.com itself and its subdomains, plus youtu.be.
        XCTAssertFalse(enricher.matches(URL(string: "https://notyoutube.com/watch?v=abc")!))
    }
}
