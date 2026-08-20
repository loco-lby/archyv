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
