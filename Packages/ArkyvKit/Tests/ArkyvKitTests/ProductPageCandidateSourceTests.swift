import XCTest
@testable import ArkyvKit

/// Link Cherry Visual Picker 01. Tests the pure HTML-parsing logic
/// against synthetic markup shaped like the real pages inspected during
/// reconnaissance (Priority Source Intelligence 01's Darc Sport findings)
/// — no network. `candidateImageURLs(for:)` itself (which does the real
/// page fetch) is exercised live on Device A instead.
final class ProductPageCandidateSourceTests: XCTestCase {
    private let pageURL = URL(string: "https://shop.example.com/products/thing")!

    // MARK: - matches

    func testMatchesAnyHTTPSURL() {
        XCTAssertTrue(ProductPageCandidateSource().matches(URL(string: "https://example.com/anything")!))
    }

    func testDoesNotMatchNonHTTPScheme() {
        XCTAssertFalse(ProductPageCandidateSource().matches(URL(string: "mailto:someone@example.com")!))
    }

    /// Pinterest Link Cherry V1 01: the real production fix. Pinterest
    /// Candidate Quality 01 proved Pinterest's `Product.image` JSON-LD is
    /// never a genuine multi-photo gallery — always the same underlying
    /// image at Pinterest's own CDN resolution/crop buckets — so it must
    /// never reach this candidate source at all, regardless of what its
    /// page content looks like.
    func testDoesNotMatchPinterestHost() {
        XCTAssertFalse(ProductPageCandidateSource().matches(URL(string: "https://www.pinterest.com/pin/772859986091581288/")!))
        XCTAssertFalse(ProductPageCandidateSource().matches(URL(string: "https://pinterest.com/pin/772859986091581288/")!))
    }

    func testDoesNotMatchPinterestRegionalSubdomain() {
        XCTAssertFalse(ProductPageCandidateSource().matches(URL(string: "https://in.pinterest.com/pin/869405903067066380/")!))
    }

    func testDoesNotMatchPinItShortlink() {
        XCTAssertFalse(ProductPageCandidateSource().matches(URL(string: "https://pin.it/abc123")!))
    }

    /// A lookalike host must not be swept up by a naive substring check.
    func testDoesNotExcludeLookalikePinterestDomain() {
        XCTAssertTrue(ProductPageCandidateSource().matches(URL(string: "https://notpinterest.com/anything")!))
    }

    /// The regression guard: ordinary ecommerce hosts (Darc Sport's own
    /// shape) must still match exactly as before — this fix is a narrow
    /// host exclusion, not a general tightening of `matches(_:)`.
    func testStillMatchesOrdinaryEcommerceHost() {
        XCTAssertTrue(ProductPageCandidateSource().matches(URL(string: "https://shop.darcsport.com/collections/forever/products/dual-compression-shorts-in-black")!))
    }

    // MARK: - JSON-LD Product.image (schema.org)

    func testSingleImageObjectProductYieldsOneCandidate() {
        let html = """
        <html><head><script type="application/ld+json">
        {"@context":"http://schema.org","@type":"Product","name":"Thing",
         "image":{"@type":"ImageObject","url":"https://shop.example.com/cdn/photo.jpg"}}
        </script></head></html>
        """
        let images = ProductPageCandidateSource.productImagesFromJSONLD(html: html, pageURL: pageURL)
        XCTAssertEqual(images.map(\.absoluteString), ["https://shop.example.com/cdn/photo.jpg"])
    }

    func testArrayOfImageStringsYieldsMultipleCandidates() {
        let html = """
        <script type="application/ld+json">
        {"@type":"Product","image":["https://shop.example.com/a.jpg","https://shop.example.com/b.jpg"]}
        </script>
        """
        let images = ProductPageCandidateSource.productImagesFromJSONLD(html: html, pageURL: pageURL)
        XCTAssertEqual(images.map(\.absoluteString), ["https://shop.example.com/a.jpg", "https://shop.example.com/b.jpg"])
    }

    func testNonProductJSONLDIsIgnored() {
        let html = """
        <script type="application/ld+json">
        {"@type":"BreadcrumbList","image":"https://shop.example.com/should-not-appear.jpg"}
        </script>
        """
        XCTAssertTrue(ProductPageCandidateSource.productImagesFromJSONLD(html: html, pageURL: pageURL).isEmpty)
    }

    func testMalformedJSONLDYieldsNoCandidatesNotAnError() {
        let html = #"<script type="application/ld+json">{ not valid json </script>"#
        XCTAssertTrue(ProductPageCandidateSource.productImagesFromJSONLD(html: html, pageURL: pageURL).isEmpty)
    }

    func testNoJSONLDAtAllYieldsNoCandidates() {
        XCTAssertTrue(ProductPageCandidateSource.productImagesFromJSONLD(html: "<html><body>hello</body></html>", pageURL: pageURL).isEmpty)
    }

    // MARK: - Narrow Shopify fallback

    func testShopifyImagesArrayParsedAndProtocolRelativeURLsResolved() {
        let html = #"""
        <script>var meta = {"images":["\/\/shop.example.com\/cdn\/a.jpg","\/\/shop.example.com\/cdn\/b.jpg"]};</script>
        """#
        let images = ProductPageCandidateSource.shopifyGalleryImages(html: html, pageURL: pageURL)
        XCTAssertEqual(images.map(\.absoluteString), ["https://shop.example.com/cdn/a.jpg", "https://shop.example.com/cdn/b.jpg"])
    }

    func testNoShopifyImagesArrayYieldsNoCandidates() {
        XCTAssertTrue(ProductPageCandidateSource.shopifyGalleryImages(html: "<html></html>", pageURL: pageURL).isEmpty)
    }
}
