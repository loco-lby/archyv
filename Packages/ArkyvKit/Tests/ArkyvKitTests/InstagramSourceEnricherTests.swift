import XCTest
@testable import ArkyvKit

/// Instagram Link Cherry V1 01. Only `matches(_:)` and the pure parsing
/// helpers (`extractCaption`/`metaContent`/`decodeHTMLEntities`) are unit-
/// tested — deterministic, no network. `enrich(_:)`'s real HTTP behavior
/// is verified live on Device A instead, the same split
/// `YouTubeOEmbedEnricherTests` already established for network-dependent
/// enrichment. Fixture strings below are the *real* `og:description`
/// values captured during Instagram Link Cherry Recon 01 against the
/// actual test carousel post and a real Reel, byte-for-byte (still HTML-
/// entity-encoded, matching what a real response looks like on the wire).
final class InstagramSourceEnricherTests: XCTestCase {
    private let enricher = InstagramSourceEnricher()

    // MARK: - matches(_:)

    func testMatchesOrdinaryPostPath() {
        XCTAssertTrue(enricher.matches(URL(string: "https://www.instagram.com/p/DbEB5nilGqS/?img_index=1")!))
    }

    func testMatchesReelPath() {
        XCTAssertTrue(enricher.matches(URL(string: "https://www.instagram.com/reel/DcGQ3_5I1ya/")!))
    }

    func testMatchesReelsPluralPath() {
        XCTAssertTrue(enricher.matches(URL(string: "https://www.instagram.com/reels/DcGQ3_5I1ya/")!))
    }

    func testMatchesBareInstagramHost() {
        XCTAssertTrue(enricher.matches(URL(string: "https://instagram.com/p/DbEB5nilGqS/")!))
    }

    func testDoesNotMatchInstagramHostWithUnrecognizedPath() {
        // The profile root / explore / any non-post/reel shape — nothing
        // here for a title/image enrichment to attach to.
        XCTAssertFalse(enricher.matches(URL(string: "https://www.instagram.com/forthosewhosin/")!))
        XCTAssertFalse(enricher.matches(URL(string: "https://www.instagram.com/explore/")!))
    }

    func testDoesNotMatchUnrelatedDomain() {
        XCTAssertFalse(enricher.matches(URL(string: "https://example.com/p/abc/")!))
    }

    func testDoesNotMatchLookalikeDomain() {
        XCTAssertFalse(enricher.matches(URL(string: "https://notinstagram.com/p/abc/")!))
    }

    // MARK: - decodeHTMLEntities

    func testDecodesCommonNamedEntities() {
        XCTAssertEqual(InstagramSourceEnricher.decodeHTMLEntities("&quot;hi&quot; &amp; bye"), "\"hi\" & bye")
    }

    func testDecodesNumericCharacterReference() {
        // &#x2014; is an em dash, the exact entity Instagram's real
        // caption text used (recon fixture below).
        XCTAssertEqual(InstagramSourceEnricher.decodeHTMLEntities("a &#x2014; b"), "a \u{2014} b")
    }

    // MARK: - metaContent(property:in:)

    func testMetaContentExtractsAndDecodesRealCarouselDescription() {
        let html = """
        <html><head>
        <meta property="og:description" content="forthosewhosin on July 21, 2026: &quot;Our best-selling hats with a little Jewlery on the bill &#x2014; hand studded in our FTWS design studio in Los Angeles &#x2014; limited quantities available.&quot;. " />
        </head></html>
        """
        let content = InstagramSourceEnricher.metaContent(property: "og:description", in: html)
        XCTAssertEqual(
            content,
            "forthosewhosin on July 21, 2026: \"Our best-selling hats with a little Jewlery on the bill \u{2014} hand studded in our FTWS design studio in Los Angeles \u{2014} limited quantities available.\". "
        )
    }

    func testMetaContentReturnsNilWhenPropertyAbsent() {
        XCTAssertNil(InstagramSourceEnricher.metaContent(property: "og:image", in: "<html></html>"))
    }

    // MARK: - extractCaption(fromDescription:) — the actual product logic

    /// The real carousel post's `og:description` (Recon 01): a real,
    /// useful caption exists behind a "<handle> on <date>:" boilerplate
    /// prefix — this is exactly the case `LinkCherryContext.displayTitle`
    /// would otherwise nuke if the boilerplate prefix (containing
    /// "Instagram," in `og:title`'s equivalent shape) were stored
    /// verbatim.
    func testExtractsRealCaptionFromCarouselDescription() {
        let description = "forthosewhosin on July 21, 2026: \"Our best-selling hats with a little Jewlery on the bill \u{2014} hand studded in our FTWS design studio in Los Angeles \u{2014} limited quantities available.\". "
        XCTAssertEqual(
            InstagramSourceEnricher.extractCaption(fromDescription: description),
            "Our best-selling hats with a little Jewlery on the bill \u{2014} hand studded in our FTWS design studio in Los Angeles \u{2014} limited quantities available."
        )
    }

    /// The real Reel's `og:description` (Recon 01): pure engagement-stat
    /// boilerplate, no quoted caption section at all — nothing worth
    /// surfacing, so the result must be `nil`, never the boilerplate
    /// sentence itself.
    func testReturnsNilForEngagementOnlyReelDescription() {
        let description = "70 likes, 6 comments - nirezo_youtube on August 16, 2026"
        XCTAssertNil(InstagramSourceEnricher.extractCaption(fromDescription: description))
    }

    func testReturnsNilForNilDescription() {
        XCTAssertNil(InstagramSourceEnricher.extractCaption(fromDescription: nil))
    }

    func testReturnsNilForEmptyQuotedCaption() {
        // A degenerate "<prefix>: "" " shape (empty caption) must not
        // surface an empty-but-non-nil title.
        XCTAssertNil(InstagramSourceEnricher.extractCaption(fromDescription: "someone on Jan 1, 2026: \"\"."))
    }

    // MARK: - Architecture: SourceEnricher only, never a CandidateImageSource

    /// Instagram is wired into `defaultEnrichers` (title/image
    /// enrichment)...
    func testInstagramEnricherIsRegisteredInDefaultEnrichers() {
        let matched = URLCherryResolver.defaultEnrichers.contains {
            $0.matches(URL(string: "https://www.instagram.com/p/DbEB5nilGqS/")!)
        }
        XCTAssertTrue(matched, "InstagramSourceEnricher must be registered in URLCherryResolver.defaultEnrichers")
    }

    /// ...and deliberately has NO counterpart in `defaultCandidateSources`
    /// — Recon 01 established there is only ever one publicly
    /// discoverable representative image, so there is nothing for a
    /// candidate list to be built from. `URLCherryResolver`'s own control
    /// flow additionally guarantees candidate sources are never even
    /// consulted once a matched enricher succeeds (see
    /// `attemptResolveCandidates`'s early return) — this test guards the
    /// static wiring; that early-return behavior is exercised by the
    /// existing `testResolveCandidatesReturnsSingleCandidateWhenNoSourceMatches`-
    /// style coverage in `URLCherryResolverTests`.
    func testDefaultCandidateSourcesHasNoInstagramEntry() {
        XCTAssertEqual(
            URLCherryResolver.defaultCandidateSources.count, 1,
            "no Instagram-specific CandidateImageSource should ever be added — Instagram is enrichment-only"
        )
    }

    // MARK: - validatedThumbnailURL(fromOEmbedJSON:) — Optional Thumbnail
    // Enhancement 01's acceptance rule, the pure/network-free half.
    // `fetchValidatedThumbnail`'s own real-network behavior (the actual
    // HTTP calls, the 2.5s timeout race, undecodable image bytes) has no
    // injectable seam — same constraint `enrich(_:)` itself already has —
    // and is verified live on Device A instead, same split as every other
    // network-touching enrichment path in this codebase. What's fully
    // testable here, deterministically: does a given oEmbed JSON payload
    // pass or fail the acceptance rule.

    /// A real, successful oEmbed response shape (Feasibility 01's own
    /// Reel sample) — a present `thumbnail_url` with positive reported
    /// dimensions must be accepted.
    func testValidatedThumbnailURLAcceptsWellFormedResponse() {
        let json = """
        {"thumbnail_url":"https://scontent.cdninstagram.com/v/thumb.jpg","thumbnail_width":640,"thumbnail_height":1138}
        """.data(using: .utf8)!
        XCTAssertEqual(
            InstagramSourceEnricher.validatedThumbnailURL(fromOEmbedJSON: json),
            URL(string: "https://scontent.cdninstagram.com/v/thumb.jpg")
        )
    }

    /// Malformed JSON (Section 4's own listed failure mode) — the real
    /// endpoint returns this shape when a required query param is
    /// missing (an HTML 404 page, not JSON at all — confirmed during
    /// Feasibility 01's own failure-mode testing).
    func testValidatedThumbnailURLReturnsNilForMalformedJSON() {
        let notJSON = "<!DOCTYPE html><html>Page Not Found</html>".data(using: .utf8)!
        XCTAssertNil(InstagramSourceEnricher.validatedThumbnailURL(fromOEmbedJSON: notJSON))
    }

    /// Well-formed JSON, but no `thumbnail_url` field at all (Section 4's
    /// own listed failure mode) — must not crash or synthesize one.
    func testValidatedThumbnailURLReturnsNilWhenThumbnailURLMissing() {
        let json = """
        {"title":"Some caption","author_name":"someone"}
        """.data(using: .utf8)!
        XCTAssertNil(InstagramSourceEnricher.validatedThumbnailURL(fromOEmbedJSON: json))
    }

    /// `thumbnail_url` present but not a parseable URL string.
    func testValidatedThumbnailURLReturnsNilForInvalidURLString() {
        let json = """
        {"thumbnail_url":"","thumbnail_width":640,"thumbnail_height":800}
        """.data(using: .utf8)!
        XCTAssertNil(InstagramSourceEnricher.validatedThumbnailURL(fromOEmbedJSON: json))
    }

    /// Zero/negative reported dimensions must never pass the acceptance
    /// rule, even with an otherwise-valid `thumbnail_url`.
    func testValidatedThumbnailURLReturnsNilForZeroDimensions() {
        let json = """
        {"thumbnail_url":"https://scontent.cdninstagram.com/v/thumb.jpg","thumbnail_width":0,"thumbnail_height":0}
        """.data(using: .utf8)!
        XCTAssertNil(InstagramSourceEnricher.validatedThumbnailURL(fromOEmbedJSON: json))
    }

    /// Dimension fields entirely absent from an otherwise well-formed
    /// response — same as missing, must not default to "valid."
    func testValidatedThumbnailURLReturnsNilWhenDimensionsMissing() {
        let json = """
        {"thumbnail_url":"https://scontent.cdninstagram.com/v/thumb.jpg"}
        """.data(using: .utf8)!
        XCTAssertNil(InstagramSourceEnricher.validatedThumbnailURL(fromOEmbedJSON: json))
    }
}
