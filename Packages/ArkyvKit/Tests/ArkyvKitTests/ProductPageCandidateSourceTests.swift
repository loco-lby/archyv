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

    // MARK: - ProductGroup (Ecommerce ProductGroup Support 01)
    //
    // Ecommerce Link Cherry Recon 02 found `ProductGroup` — schema.org's
    // type for "a product with variants" — on 5 of 6 real ecommerce pages
    // fetched (Studio2am, Gymshark, Vibecrafts, Nike, Allbirds); only
    // Darc Sport (below) used the older bare `Product`. Fixtures here use
    // the real shapes captured during that recon.

    /// Darc Sport regression guard, using its own real captured JSON-LD
    /// shape verbatim — `Product` must keep working exactly as before.
    func testDarcSportRealProductShapeStillMatches() {
        let html = """
        <script type="application/ld+json">
        {"@context":"http://schema.org/","@type":"Product","name":"Dual Compression Shorts in Black",
         "image":"https://shop.darcsport.com/cdn/shop/files/5BOTTOMS-FOREVERcopy_1024x1024.jpg?v=1764968822"}
        </script>
        """
        let images = ProductPageCandidateSource.productImagesFromJSONLD(html: html, pageURL: pageURL)
        XCTAssertEqual(images.map(\.absoluteString), ["https://shop.darcsport.com/cdn/shop/files/5BOTTOMS-FOREVERcopy_1024x1024.jpg?v=1764968822"])
    }

    /// The real Gymshark shape: `ProductGroup`, `image` as a single-
    /// element array. `ProductGroup` was previously invisible to
    /// `isProductType`, so this returned zero images before this
    /// milestone.
    func testRealGymsharkProductGroupImageArrayParses() {
        let html = """
        <script type="application/ld+json">
        {"@context":"https://schema.org","@type":"ProductGroup","name":"Everyday Seamless Leggings",
         "productGroupID":"6805281210570","variesBy":["https://schema.org/size"],
         "image":["https://cdn.shopify.com/s/files/1/0156/6146/files/EverydaySeamlessLeggingsGSBlackB7A3L_BB2J_3950.jpg?v=1785489728"]}
        </script>
        """
        let images = ProductPageCandidateSource.productImagesFromJSONLD(html: html, pageURL: pageURL)
        XCTAssertEqual(images.map(\.absoluteString), [
            "https://cdn.shopify.com/s/files/1/0156/6146/files/EverydaySeamlessLeggingsGSBlackB7A3L_BB2J_3950.jpg?v=1785489728",
        ])
    }

    /// A `ProductGroup` with a bare-string `image` (not an array) —
    /// `imageURLs(from:)` already handles this shape for `Product`;
    /// confirms it's shared, not reimplemented.
    func testProductGroupImageStringParses() {
        let html = """
        <script type="application/ld+json">
        {"@type":"ProductGroup","name":"Thing","image":"https://shop.example.com/cdn/photo.jpg"}
        </script>
        """
        let images = ProductPageCandidateSource.productImagesFromJSONLD(html: html, pageURL: pageURL)
        XCTAssertEqual(images.map(\.absoluteString), ["https://shop.example.com/cdn/photo.jpg"])
    }

    /// A `ProductGroup` with an `ImageObject`-shaped `image` — same
    /// `imageURLs(from:)` object-handling branch `Product` already uses.
    func testProductGroupImageObjectShapeParses() {
        let html = """
        <script type="application/ld+json">
        {"@type":"ProductGroup","name":"Thing",
         "image":{"@type":"ImageObject","url":"https://shop.example.com/cdn/photo.jpg"}}
        </script>
        """
        let images = ProductPageCandidateSource.productImagesFromJSONLD(html: html, pageURL: pageURL)
        XCTAssertEqual(images.map(\.absoluteString), ["https://shop.example.com/cdn/photo.jpg"])
    }

    /// `ProductGroup` with genuinely multiple images (the shape a
    /// visually rich product would have) — candidate order must remain
    /// the array's own order, same guarantee `Product` already has.
    func testProductGroupWithMultipleImagesPreservesOrder() {
        let html = """
        <script type="application/ld+json">
        {"@type":"ProductGroup","name":"Thing",
         "image":["https://shop.example.com/a.jpg","https://shop.example.com/b.jpg","https://shop.example.com/c.jpg"]}
        </script>
        """
        let images = ProductPageCandidateSource.productImagesFromJSONLD(html: html, pageURL: pageURL)
        XCTAssertEqual(images.map(\.absoluteString), [
            "https://shop.example.com/a.jpg", "https://shop.example.com/b.jpg", "https://shop.example.com/c.jpg",
        ])
    }

    /// A `ProductGroup` with no `image` field at all (the real Vibecrafts
    /// shape — its own genuinely-different framing photos live inside
    /// `hasVariant[].image`, deliberately out of scope this pass; see
    /// `isProductType`'s own doc comment) must yield zero images, not
    /// crash or synthesize a placeholder.
    func testProductGroupWithNoTopLevelImageYieldsNoCandidates() {
        let html = """
        <script type="application/ld+json">
        {"@type":"ProductGroup","name":"Krishna and Arjuna Canvas Wall Painting",
         "hasVariant":[{"@type":"Product","name":"Ready To Hang","image":"https://vibecrafts.com/cdn/a.jpg"}]}
        </script>
        """
        XCTAssertTrue(ProductPageCandidateSource.productImagesFromJSONLD(html: html, pageURL: pageURL).isEmpty)
    }

    /// Other structured types (the real Allbirds/Vibecrafts pages also
    /// carry `WebSite`/`OnlineStore`/`BreadcrumbList` blocks alongside
    /// their real `ProductGroup`) must not accidentally match.
    func testNonProductNonProductGroupTypesStillIgnored() {
        let html = """
        <script type="application/ld+json">
        {"@type":"OnlineStore","name":"Some Shop","image":"https://shop.example.com/logo.jpg"}
        </script>
        <script type="application/ld+json">
        {"@type":"WebSite","name":"Some Shop"}
        </script>
        """
        XCTAssertTrue(ProductPageCandidateSource.productImagesFromJSONLD(html: html, pageURL: pageURL).isEmpty)
    }

    /// Nike's real shape: the top-level JSON-LD value is a bare ARRAY
    /// containing the `ProductGroup` object (not wrapped in `@graph`) —
    /// `flattenToObjects` already handles this for `Product`; confirms
    /// `ProductGroup` inherits the same handling for free.
    func testProductGroupInsideTopLevelArrayParses() {
        let html = """
        <script type="application/ld+json">
        [{"@type":"ProductGroup","name":"Nike Air Force 1 '07 Men's Shoes","image":["https://static.nike.com/a.png"]}]
        </script>
        """
        let images = ProductPageCandidateSource.productImagesFromJSONLD(html: html, pageURL: pageURL)
        XCTAssertEqual(images.map(\.absoluteString), ["https://static.nike.com/a.png"])
    }

    // MARK: - Cross-source dedupe against candidate 0 (Ecommerce
    // Cross-Source Candidate Dedupe 01)
    //
    // Candidate 0 (the generic `LPMetadataProvider` result) never reaches
    // this type at all — it has no URL Cherries can inspect. Forensic
    // tracing proved `LPMetadataProvider`'s choice is, in every real case
    // tested, exactly the page's own `og:image`, so `candidateImages`
    // filters against THAT as the practical proxy for candidate 0's
    // identity. Fixtures below use the real captured shapes (Gymshark:
    // byte-identical, only `http`/`https` differs; Allbirds: NOT byte-
    // identical, only a `width=` query parameter differs; Darc
    // Sport/Vibecrafts: a real gallery's own entry 1 duplicating its
    // cover photo).

    /// Gymshark's real shape: `og:image` and `ProductGroup.image[0]` are
    /// the identical asset (confirmed byte-for-byte via SHA-256 during
    /// forensic tracing), differing only by `http` vs `https` scheme —
    /// `dedupeKey` never inspects scheme at all.
    func testGenericCandidateWithIdenticalProductGroupURLYieldsNoExtraCandidates() {
        let html = """
        <meta property="og:image" content="http://cdn.shopify.com/s/files/1/0156/6146/files/EverydaySeamlessLeggingsGSBlackB7A3L_BB2J_3950.jpg?v=1785489728"/>
        <script type="application/ld+json">
        {"@type":"ProductGroup","image":["https://cdn.shopify.com/s/files/1/0156/6146/files/EverydaySeamlessLeggingsGSBlackB7A3L_BB2J_3950.jpg?v=1785489728"]}
        </script>
        """
        XCTAssertTrue(ProductPageCandidateSource.candidateImages(html: html, pageURL: pageURL).isEmpty)
    }

    /// Allbirds' real shape: `og:image` carries no `width=` parameter;
    /// `ProductGroup.image` entries add one. Confirmed via direct
    /// download that these are NOT byte-identical (1600×1600 vs 900×900,
    /// different SHA-256) — proving a byte-hash comparison alone would
    /// have missed this real duplicate, while `dedupeKey`'s existing
    /// query-string-ignoring normalization catches it correctly.
    func testGenericCandidateWithQueryParameterVariantURLYieldsNoExtraCandidates() {
        let html = """
        <meta property="og:image" content="https://www.allbirds.com/cdn/shop/files/photo.png?v=123"/>
        <script type="application/ld+json">
        {"@type":"ProductGroup","image":[
          "https://www.allbirds.com/cdn/shop/files/photo.png?v=123&width=100",
          "https://www.allbirds.com/cdn/shop/files/photo.png?v=123&width=900"
        ]}
        </script>
        """
        XCTAssertTrue(ProductPageCandidateSource.candidateImages(html: html, pageURL: pageURL).isEmpty)
    }

    /// The real Allbirds gap this milestone's tracing found: JSON-LD's
    /// own `>= 2` early-return path never deduped multiple array entries
    /// against EACH OTHER before this fix — four resolution variants of
    /// one photo must collapse to one, even when none of them happen to
    /// match `og:image`.
    func testDuplicateStructuredCandidatesCollapseToOne() {
        let html = """
        <meta property="og:image" content="https://shop.example.com/cdn/unrelated-cover.jpg"/>
        <script type="application/ld+json">
        {"@type":"ProductGroup","image":[
          "https://cdn.example.com/photo.jpg?width=100",
          "https://cdn.example.com/photo.jpg?width=300",
          "https://cdn.example.com/photo.jpg?width=600",
          "https://cdn.example.com/photo.jpg?width=900"
        ]}
        </script>
        """
        let images = ProductPageCandidateSource.candidateImages(html: html, pageURL: pageURL)
        XCTAssertEqual(images.count, 1)
    }

    /// A genuinely different photo (a different colorway/angle, not a
    /// resolution or scheme variant of `og:image`) must survive — this
    /// milestone dedupes IMAGES, not products.
    func testGenericCandidateWithGenuinelyDifferentProductGroupImageBothSurvive() {
        let html = """
        <meta property="og:image" content="https://shop.example.com/cdn/black-hero.jpg"/>
        <script type="application/ld+json">
        {"@type":"ProductGroup","image":["https://shop.example.com/cdn/white-colorway.jpg"]}
        </script>
        """
        let images = ProductPageCandidateSource.candidateImages(html: html, pageURL: pageURL)
        XCTAssertEqual(images.map(\.absoluteString), ["https://shop.example.com/cdn/white-colorway.jpg"])
    }

    /// Darc Sport's real shape: its own Shopify gallery lists its cover
    /// photo (identical to `og:image`) as entry 1 — this must be the
    /// ONLY entry removed; the other 12 real, genuinely different photos
    /// (represented here by 2) must remain, in order, so the multi-photo
    /// gallery picker survives.
    func testDarcSportGalleryDuplicateRemovedGenuinePhotosSurvive() {
        let html = #"""
        <meta property="og:image" content="http://shop.darcsport.com/cdn/shop/files/5BOTTOMS-FOREVERcopy.jpg?v=1764968822"/>
        <script>var meta = {"images":["\/\/shop.darcsport.com\/cdn\/shop\/files\/5BOTTOMS-FOREVERcopy.jpg?v=1764968822","\/\/shop.darcsport.com\/cdn\/shop\/files\/angle2.jpg","\/\/shop.darcsport.com\/cdn\/shop\/files\/angle3.jpg"]};</script>
        """#
        let images = ProductPageCandidateSource.candidateImages(html: html, pageURL: pageURL)
        XCTAssertEqual(images.map(\.absoluteString), [
            "https://shop.darcsport.com/cdn/shop/files/angle2.jpg",
            "https://shop.darcsport.com/cdn/shop/files/angle3.jpg",
        ])
    }

    /// Vibecrafts' real shape (no top-level JSON-LD `image`, real
    /// distinct photos only via the Shopify fallback): its own
    /// isolated-product-view vs. environmental/lifestyle-view images are
    /// genuinely different and must both remain selectable — only the
    /// cover-photo duplicate is removed.
    func testVibecraftsDistinctImagesSurvive() {
        let html = #"""
        <meta property="og:image" content="http://vibecrafts.com/cdn/shop/files/krishna-cover.jpg?v=1725034029"/>
        <script>var meta = {"images":["\/\/vibecrafts.com\/cdn\/shop\/files\/krishna-cover.jpg?v=1725034029","\/\/vibecrafts.com\/cdn\/shop\/files\/isolated-view.jpg","\/\/vibecrafts.com\/cdn\/shop\/files\/environmental-view.jpg"]};</script>
        """#
        let images = ProductPageCandidateSource.candidateImages(html: html, pageURL: pageURL)
        XCTAssertEqual(images.map(\.absoluteString), [
            "https://vibecrafts.com/cdn/shop/files/isolated-view.jpg",
            "https://vibecrafts.com/cdn/shop/files/environmental-view.jpg",
        ])
    }

    /// No `og:image` on the page at all must never crash or wrongly
    /// exclude anything — the filter is a no-op, fail-open.
    func testNoOGImageTagLeavesCandidatesUnfiltered() {
        let html = """
        <script type="application/ld+json">
        {"@type":"ProductGroup","image":["https://shop.example.com/a.jpg","https://shop.example.com/b.jpg"]}
        </script>
        """
        let images = ProductPageCandidateSource.candidateImages(html: html, pageURL: pageURL)
        XCTAssertEqual(images.map(\.absoluteString), ["https://shop.example.com/a.jpg", "https://shop.example.com/b.jpg"])
    }

    // MARK: - pageOGImageURL(html:pageURL:) attribute-order handling

    func testPageOGImageURLExtractsPropertyFirstOrder() {
        let html = #"<meta property="og:image" content="https://shop.example.com/cover.jpg"/>"#
        XCTAssertEqual(ProductPageCandidateSource.pageOGImageURL(html: html, pageURL: pageURL)?.absoluteString, "https://shop.example.com/cover.jpg")
    }

    func testPageOGImageURLExtractsContentFirstOrder() {
        let html = #"<meta content="https://shop.example.com/cover.jpg" property="og:image"/>"#
        XCTAssertEqual(ProductPageCandidateSource.pageOGImageURL(html: html, pageURL: pageURL)?.absoluteString, "https://shop.example.com/cover.jpg")
    }
}
