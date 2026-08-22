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

    // MARK: - Link Cherry Title Quality Repair 01
    //
    // Editorial Eden Recon 01 found the previous rule — suppress
    // whenever the registrable domain name appears ANYWHERE in the
    // title — silently dropped two entirely real, useful headlines
    // (Aeon, Nautilus) purely because their publication's short,
    // single-word name happened to sit inside its own ordinary
    // "Headline | Publication" suffix. Fixtures below are the exact
    // real titles captured during that recon.

    /// The exact real bug: "Aeon" (the 4-char registrable name) is a
    /// literal substring of "Aeon Essays" — previously suppressed the
    /// entire headline. Must now survive, suffix intact (this milestone
    /// is suppression-only, not stripping — see `testSuffixIsNotStripped`).
    func testAeonRealHeadlineSurvives() {
        let title = LinkCherryContext.displayTitle(
            title: "History and philosophy should make us feel baffled and strange | Aeon Essays",
            sourceURL: "https://aeon.co/essays/history-and-philosophy-should-make-us-feel-baffled-and-strange"
        )
        XCTAssertEqual(title, "History and philosophy should make us feel baffled and strange | Aeon Essays")
    }

    /// The exact real bug: "nautil" (the 6-char registrable name) is a
    /// literal substring of "Nautilus" — previously suppressed the
    /// entire headline.
    func testNautilusRealHeadlineSurvives() {
        let title = LinkCherryContext.displayTitle(
            title: "The New Flight of the Ibis - Nautilus",
            sourceURL: "https://nautil.us/the-new-flight-of-the-ibis-234418"
        )
        XCTAssertEqual(title, "The New Flight of the Ibis - Nautilus")
    }

    /// Never regressed, but confirms the fix doesn't disturb it: the
    /// suffix survives verbatim, unstripped.
    func testSuffixIsNotStripped() {
        let title = LinkCherryContext.displayTitle(
            title: "Permanent Decline | The Point Magazine",
            sourceURL: "https://thepointmag.com/examined-life/permanent-decline/"
        )
        XCTAssertEqual(title, "Permanent Decline | The Point Magazine", "this milestone stops wrong suppression only — it does not strip suffixes")
    }

    /// Real Life's real title — already survived before this fix (its
    /// registrable name "reallifemag" never matched "Real Life" as a
    /// substring), but the em dash exercises the new separator set too.
    func testRealLifeSuffixedTitleSurvives() {
        let title = LinkCherryContext.displayTitle(
            title: "Roving Eyes — Real Life",
            sourceURL: "https://reallifemag.com/roving-eyes/"
        )
        XCTAssertEqual(title, "Roving Eyes — Real Life")
    }

    /// Magnum's real title has a literal duplicated-suffix bug in their
    /// own template ("Magnum Photos Magnum Photos") — still must survive
    /// unchanged; this milestone never rewrites titles, only decides
    /// whether to show them.
    func testMagnumBuggyDuplicateSuffixTitleSurvives() {
        let title = LinkCherryContext.displayTitle(
            title: "The Photographers' Selection: 2025 | Magnum Photos Magnum Photos",
            sourceURL: "https://www.magnumphotos.com/arts-culture/the-photographers-selection-2025/"
        )
        XCTAssertEqual(title, "The Photographers' Selection: 2025 | Magnum Photos Magnum Photos")
    }

    /// Emergence Magazine's real title suffixes the AUTHOR, not the
    /// publication — no registrable-name match occurs at all here, so
    /// this exercises the unaffected early-return path.
    func testEmergenceAuthorSuffixedTitleSurvives() {
        let title = LinkCherryContext.displayTitle(
            title: "The Fault of Time – Erica Berry",
            sourceURL: "https://emergencemagazine.org/essay/the-fault-of-time/"
        )
        XCTAssertEqual(title, "The Fault of Time – Erica Berry")
    }

    /// The regression this whole fix must never weaken: Instagram's real
    /// generic per-post template has the site's name fused directly into
    /// a content-free sentence, with NO title/publication separator
    /// anywhere — structurally nothing like Aeon/Nautilus's real
    /// "Headline | Publication" shape — so it must remain suppressed.
    func testInstagramGenericTemplateStillSuppressed() {
        let title = LinkCherryContext.displayTitle(
            title: "Analogue Documented on Instagram",
            sourceURL: "https://www.instagram.com/p/DcJWBONjd3-/?img_index=2"
        )
        XCTAssertNil(title, "a title with no separator, fused directly into the site's own name, must still be treated as boilerplate")
    }

    /// The regression this whole fix must never weaken: Pinterest's real
    /// 118-character keyword-stuffed title stays suppressed via the
    /// unrelated, untouched length check.
    func testPinterestKeywordStuffedTitleStillOmitted() {
        let title = LinkCherryContext.displayTitle(
            title: "GANG - Print by Ces XC | DROOL Art | Funny horse photos, Horse and motorcycle, Cowboy on horse photography",
            sourceURL: "https://pin.it/7zmCUuxsH"
        )
        XCTAssertNil(title)
    }

    /// A hypothetical short-prefix boilerplate shape (a bare app/site
    /// name immediately followed by its own suffix) — a separator is
    /// present, but there isn't enough real content before it to call
    /// this a genuine headline, so it must still be suppressed.
    func testSeparatorPresentButPrefixTooThinStillSuppressed() {
        let title = LinkCherryContext.displayTitle(title: "App - Instagram", sourceURL: "https://www.instagram.com/p/x")
        XCTAssertNil(title)
    }

    /// The site's name mentioned mid-sentence with no separator at all —
    /// still the boilerplate shape, not the suffix shape — must stay
    /// suppressed even though real words surround it.
    func testNameFusedMidSentenceWithNoSeparatorStillSuppressed() {
        let title = LinkCherryContext.displayTitle(title: "Welcome to the official Aeon homepage", sourceURL: "https://aeon.co/x")
        XCTAssertNil(title)
    }

    // MARK: - Vice Editorial Title Anomaly 01
    //
    // Link Cherry Title Quality Repair 01 only recognized the
    // registrable name as a TRAILING suffix ("Headline | Publication").
    // Vice's real JSON-LD headline puts the name LEADING instead — real
    // editorial house style, not decorative boilerplate — and was still
    // being wrongly suppressed.

    /// The exact real bug: Vice's real JSON-LD `headline`, confirmed via
    /// direct fetch of the real page — previously suppressed the entire
    /// title because "vice" (the registrable name) leads the sentence
    /// with no separator for the existing trailing-suffix check to find.
    func testViceRealHeadlineSurvives() {
        let title = LinkCherryContext.displayTitle(
            title: "VICE Album Reviews, August 21: Brandon Flowers, Sam Smith, GB and More",
            sourceURL: "https://www.vice.com/en/article/vice-album-reviews-august-21-brandon-flowers-sam-smith-gb-and-more/"
        )
        XCTAssertEqual(title, "VICE Album Reviews, August 21: Brandon Flowers, Sam Smith, GB and More")
    }

    /// A bare site name with nothing after it must still be suppressed —
    /// the length check on the remaining content after the leading name
    /// is what tells "VICE" (alone) apart from "VICE Album Reviews...".
    func testBareSiteNameAloneStillSuppressed() {
        XCTAssertNil(LinkCherryContext.displayTitle(title: "VICE", sourceURL: "https://www.vice.com/x"))
    }

    /// A leading site name followed by only a tiny fragment must still
    /// be suppressed — the same `minimumSuffixPrefixLength` threshold
    /// the trailing-suffix case already uses, applied symmetrically.
    func testLeadingSiteNamePlusTinyFragmentStillSuppressed() {
        XCTAssertNil(LinkCherryContext.displayTitle(title: "VICE - Home", sourceURL: "https://www.vice.com/x"))
    }

    /// Word-boundary guard: the registrable name must lead as a whole
    /// word, not merely as a prefix substring of a longer word.
    func testLeadingNameMustBeWholeWordNotPrefixOfLongerWord() {
        XCTAssertNil(LinkCherryContext.displayTitle(
            title: "Vicereine's Guide to Everything Wonderful and Strange",
            sourceURL: "https://www.vice.com/x"
        ))
    }
}
