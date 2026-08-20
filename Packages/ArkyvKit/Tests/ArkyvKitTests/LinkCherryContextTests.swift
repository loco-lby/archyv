import XCTest
@testable import ArkyvKit

/// Context + Single-Folder UX 01. Exercises `LinkCherryContext` against
/// both synthetic edge cases and the exact stored values captured from
/// real URL → Cherry physical QA (Studio2am/Natify, Pinterest, Instagram,
/// Works in Progress, Darc Sport) — the same rule, no per-source
/// branching.
final class LinkCherryContextTests: XCTestCase {
    // MARK: - displayDomain

    func testDisplayDomainStripsWWWPrefix() {
        XCTAssertEqual(LinkCherryContext.displayDomain(sourceURL: "https://www.instagram.com/p/abc/"), "instagram.com")
    }

    func testDisplayDomainReturnsNilForNilSourceURL() {
        XCTAssertNil(LinkCherryContext.displayDomain(sourceURL: nil))
    }

    func testDisplayDomainReturnsNilForUnparsableSourceURL() {
        XCTAssertNil(LinkCherryContext.displayDomain(sourceURL: "not a url"))
    }

    // MARK: - displayTitle: real captured data

    func testNatifyTitleShown() {
        let title = LinkCherryContext.displayTitle(
            title: "GC Natify – Bold Modern Sans",
            sourceURL: "https://studio2am.co/products/gc-natify-bold-modern-sans"
        )
        XCTAssertEqual(title, "GC Natify – Bold Modern Sans")
    }

    func testWorksInProgressTitleShown() {
        let title = LinkCherryContext.displayTitle(
            title: "How the Glorious Revolution crushed the NIMBYs",
            sourceURL: "https://worksinprogress.co/issue/how-abolishing-the-stakeholder-state-caused-the-industrial-revolution/"
        )
        XCTAssertEqual(title, "How the Glorious Revolution crushed the NIMBYs")
    }

    func testDarcSportTitleShown() {
        let title = LinkCherryContext.displayTitle(
            title: "Dual Compression Shorts in Black",
            sourceURL: "https://shop.darcsport.com/products/dual-compression-shorts-in-black"
        )
        XCTAssertEqual(title, "Dual Compression Shorts in Black")
    }

    func testPinterestKeywordStuffedTitleOmitted() {
        // Real stored title: 118 characters of pipe-separated keywords.
        let title = LinkCherryContext.displayTitle(
            title: "GANG - Print by Ces XC | DROOL Art | Funny horse photos, Horse and motorcycle, Cowboy on horse photography",
            sourceURL: "https://pin.it/7zmCUuxsH"
        )
        XCTAssertNil(title, "excessively long titles must be omitted, not shown as confident nonsense")
    }

    func testInstagramGenericTemplateTitleOmitted() {
        // Real stored title: Instagram's own generic per-post template,
        // not content-specific — contains the site's own name.
        let title = LinkCherryContext.displayTitle(
            title: "Analogue Documented on Instagram",
            sourceURL: "https://www.instagram.com/p/DcJWBONjd3-/?img_index=2"
        )
        XCTAssertNil(title, "a title that just restates the platform's own name must be omitted")
    }

    func testYouTubeWithNoSourceURLHasNoDomainOrTitle() {
        // Real captured item: this specific share never reached
        // URLCherryResolver at all (title=nil, sourceURL=nil) — no link
        // context is derivable, and that's the correct outcome.
        XCTAssertNil(LinkCherryContext.displayDomain(sourceURL: nil))
        XCTAssertNil(LinkCherryContext.displayTitle(title: nil, sourceURL: nil))
    }

    // MARK: - displayTitle: rule edge cases

    func testEmptyTitleOmitted() {
        XCTAssertNil(LinkCherryContext.displayTitle(title: "", sourceURL: "https://example.com/thing"))
        XCTAssertNil(LinkCherryContext.displayTitle(title: "   ", sourceURL: "https://example.com/thing"))
    }

    func testNilTitleOmitted() {
        XCTAssertNil(LinkCherryContext.displayTitle(title: nil, sourceURL: "https://example.com/thing"))
    }

    func testTitleIdenticalToDomainOmitted() {
        XCTAssertNil(LinkCherryContext.displayTitle(title: "example.com", sourceURL: "https://example.com/thing"))
    }

    func testNoSourceURLMeansNoTitleEvenIfGood() {
        XCTAssertNil(LinkCherryContext.displayTitle(title: "A perfectly good title", sourceURL: nil))
    }

    func testOrdinaryScreenshotWithoutSourceURLHasNoLinkContext() {
        XCTAssertNil(LinkCherryContext.displayDomain(sourceURL: nil))
        XCTAssertNil(LinkCherryContext.displayTitle(title: nil, sourceURL: nil))
    }
}
