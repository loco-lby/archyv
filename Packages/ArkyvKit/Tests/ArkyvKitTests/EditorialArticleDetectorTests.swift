import XCTest
@testable import ArkyvKit

/// Editorial Cover V1. Exercises the pure HTML-parsing logic (no network —
/// the real fetch itself is verified live on Device A, the same split
/// every other network-touching source/enricher in this codebase already
/// uses) against real captured JSON-LD/meta-tag shapes from Editorial
/// Eden Recon 01's fixtures, not synthetic examples.
final class EditorialArticleDetectorTests: XCTestCase {
    // MARK: - jsonLDArticleHeadline(in:) — real shapes

    /// Aeon's real shape: `Article`, clean headline, no entity decoding
    /// needed.
    func testAeonRealArticleHeadlineParses() {
        let html = """
        <script type="application/ld+json">
        {"@type":"Article","headline":"History and philosophy should make us feel baffled and strange"}
        </script>
        """
        XCTAssertEqual(
            EditorialArticleDetector.jsonLDArticleHeadline(in: html),
            "History and philosophy should make us feel baffled and strange"
        )
    }

    /// The New Yorker's real shape: `NewsArticle`, not bare `Article`.
    func testNewsArticleTypeParses() {
        let html = """
        <script type="application/ld+json">
        {"@type":"NewsArticle","headline":"The Long Flight to Teach an Endangered Ibis Species to Migrate"}
        </script>
        """
        XCTAssertEqual(
            EditorialArticleDetector.jsonLDArticleHeadline(in: html),
            "The Long Flight to Teach an Endangered Ibis Species to Migrate"
        )
    }

    /// Litverse's (Substack) real shape: `BlogPosting`.
    func testBlogPostingTypeParses() {
        let html = """
        <script type="application/ld+json">
        {"@type":"BlogPosting","headline":"Drugs, Alcohol, and Existentialism"}
        </script>
        """
        XCTAssertEqual(
            EditorialArticleDetector.jsonLDArticleHeadline(in: html),
            "Drugs, Alcohol, and Existentialism"
        )
    }

    /// Works in Progress's real shape: `@type` is an array
    /// (`["Article","WebPage"]`), not a bare string.
    func testArrayTypeIncludingArticleParses() {
        let html = """
        <script type="application/ld+json">
        {"@type":["Article","WebPage"],"headline":"The housing theory of everything"}
        </script>
        """
        XCTAssertEqual(
            EditorialArticleDetector.jsonLDArticleHeadline(in: html),
            "The housing theory of everything"
        )
    }

    /// Real ecommerce types (Product/ProductGroup — confirmed against 5
    /// real ecommerce pages during verification, zero false positives)
    /// must never match.
    func testProductTypeNeverMatchesAsArticle() {
        let html = """
        <script type="application/ld+json">
        {"@type":"ProductGroup","headline":"Should never be read","name":"Some Product"}
        </script>
        """
        XCTAssertNil(EditorialArticleDetector.jsonLDArticleHeadline(in: html))
    }

    func testNoJSONLDAtAllYieldsNilHeadline() {
        XCTAssertNil(EditorialArticleDetector.jsonLDArticleHeadline(in: "<html><body>hello</body></html>"))
    }

    func testMalformedJSONLDYieldsNilNotAnError() {
        let html = #"<script type="application/ld+json">{ not valid json </script>"#
        XCTAssertNil(EditorialArticleDetector.jsonLDArticleHeadline(in: html))
    }

    /// An `Article`-typed block with no `headline` field at all must
    /// yield `nil`, not crash or synthesize a placeholder.
    func testArticleTypeWithNoHeadlineFieldYieldsNil() {
        let html = """
        <script type="application/ld+json">
        {"@type":"Article","author":"Someone"}
        </script>
        """
        XCTAssertNil(EditorialArticleDetector.jsonLDArticleHeadline(in: html))
    }

    // MARK: - og:type="article" fallback — real shape (Real Life)

    func testRealLifeOGTypeArticleFallbackDetected() {
        let html = #"<meta property="og:type" content="article"/>"#
        XCTAssertTrue(EditorialArticleDetector.hasArticleOpenGraphType(html))
    }

    /// Attribute order varies by site — the same divergence already
    /// documented between Instagram and Pinterest.
    func testOGTypeArticleFallbackDetectedContentFirstOrder() {
        let html = #"<meta content="article" property="og:type"/>"#
        XCTAssertTrue(EditorialArticleDetector.hasArticleOpenGraphType(html))
    }

    /// Real ecommerce shapes (`og:type="product"`/`"website"` — confirmed
    /// against Gymshark, Allbirds, Nike, Darc Sport) must never match.
    func testNonArticleOGTypeNotDetected() {
        XCTAssertFalse(EditorialArticleDetector.hasArticleOpenGraphType(#"<meta property="og:type" content="product"/>"#))
        XCTAssertFalse(EditorialArticleDetector.hasArticleOpenGraphType(#"<meta property="og:type" content="website"/>"#))
    }

    func testNoOGTypeAtAllNotDetected() {
        XCTAssertFalse(EditorialArticleDetector.hasArticleOpenGraphType("<html></html>"))
    }

    // MARK: - decodeHTMLEntities(_:) — real headlines this detector hit

    /// Colossal's real headline: numeric entity.
    func testDecodesNumericApostropheEntity() {
        XCTAssertEqual(
            EditorialArticleDetector.decodeHTMLEntities("This Year&#8217;s Ocean Art"),
            "This Year\u{2019}s Ocean Art"
        )
    }

    /// Wallpaper's and Magnum's real headlines: named entity, not
    /// covered by Instagram's narrower table.
    func testDecodesNamedRightSingleQuoteEntity() {
        XCTAssertEqual(
            EditorialArticleDetector.decodeHTMLEntities("Wallpaper&rsquo;s houses"),
            "Wallpaper\u{2019}s houses"
        )
    }

    func testDecodesBasicEntities() {
        XCTAssertEqual(EditorialArticleDetector.decodeHTMLEntities("Tom &amp; Jerry"), "Tom & Jerry")
        XCTAssertEqual(EditorialArticleDetector.decodeHTMLEntities("&quot;quoted&quot;"), "\"quoted\"")
    }

    func testPlainStringWithNoEntitiesUnchanged() {
        XCTAssertEqual(EditorialArticleDetector.decodeHTMLEntities("Permanent Decline"), "Permanent Decline")
    }

    // MARK: - Architecture: never a SourceEnricher or CandidateImageSource

    func testEditorialDetectorIsNotRegisteredAsEnricherOrCandidateSource() {
        XCTAssertTrue(URLCherryResolver.defaultEnrichers.allSatisfy { !($0 is EditorialArticleDetector) })
        XCTAssertEqual(URLCherryResolver.defaultCandidateSources.count, 1, "Editorial detection must never register as a CandidateImageSource")
    }
}
