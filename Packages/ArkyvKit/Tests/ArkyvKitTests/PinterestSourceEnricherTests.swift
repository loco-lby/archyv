import XCTest
@testable import ArkyvKit

/// Pinterest Link Cherry V1 01. Only `matches(_:)` and the pure helpers
/// (`metaContent`/`originalsUpgradeURL`) are unit-tested — deterministic,
/// no network. `enrich(_:)`'s real HTTP behavior (including the optional
/// `/originals/` upgrade's own network calls) is verified live on Device
/// A instead, the same split every other network-touching enrichment
/// path in this codebase already uses. Fixture strings are the *real*
/// meta-tag/CDN-URL shapes captured during Pinterest Candidate Quality
/// 01's recon against the actual test Pin, not synthetic examples.
final class PinterestSourceEnricherTests: XCTestCase {
    private let enricher = PinterestSourceEnricher()

    // MARK: - matches(_:)

    func testMatchesOrdinaryPinURL() {
        XCTAssertTrue(enricher.matches(URL(string: "https://www.pinterest.com/pin/772859986091581288/")!))
    }

    func testMatchesBarePinterestHost() {
        XCTAssertTrue(enricher.matches(URL(string: "https://pinterest.com/pin/772859986091581288/")!))
    }

    func testMatchesRegionalSubdomain() {
        XCTAssertTrue(enricher.matches(URL(string: "https://in.pinterest.com/pin/869405903067066380/")!))
    }

    func testMatchesPinItShortlink() {
        XCTAssertTrue(enricher.matches(URL(string: "https://pin.it/abc123")!))
    }

    func testDoesNotMatchUnrelatedDomain() {
        XCTAssertFalse(enricher.matches(URL(string: "https://example.com/pin/123")!))
    }

    func testDoesNotMatchLookalikeDomain() {
        XCTAssertFalse(enricher.matches(URL(string: "https://notpinterest.com/pin/123")!))
    }

    // MARK: - metaContent(property:in:) — Pinterest's real attribute
    // order (`content` before `property`), confirmed against the real
    // Pin page, the reverse of Instagram's.

    func testMetaContentExtractsRealPinterestOGImage() {
        let html = """
        <meta content="https://i.pinimg.com/736x/b4/3a/38/b43a38689ca103080a93036b5bca6a55.jpg" data-app="true" name="og:image" property="og:image"/>
        """
        XCTAssertEqual(
            PinterestSourceEnricher.metaContent(property: "og:image", in: html),
            "https://i.pinimg.com/736x/b4/3a/38/b43a38689ca103080a93036b5bca6a55.jpg"
        )
    }

    func testMetaContentExtractsRealPinterestOGTitle() {
        let html = """
        <meta content="GANG - Print by Ces XC | DROOL Art" data-app="true" name="og:title" property="og:title"/>
        """
        XCTAssertEqual(PinterestSourceEnricher.metaContent(property: "og:title", in: html), "GANG - Print by Ces XC | DROOL Art")
    }

    func testMetaContentReturnsNilWhenPropertyAbsent() {
        XCTAssertNil(PinterestSourceEnricher.metaContent(property: "og:image", in: "<html></html>"))
    }

    // MARK: - originalsUpgradeURL(for:) — the optional quality bonus,
    // deterministic URL conversion only (Section 3's own real fixtures:
    // the GANG print's real Pinterest CDN asset path).

    func testUpgrades736xToOriginals() {
        let url = URL(string: "https://i.pinimg.com/736x/b4/3a/38/b43a38689ca103080a93036b5bca6a55.jpg")!
        XCTAssertEqual(
            PinterestSourceEnricher.originalsUpgradeURL(for: url)?.absoluteString,
            "https://i.pinimg.com/originals/b4/3a/38/b43a38689ca103080a93036b5bca6a55.jpg"
        )
    }

    func testUpgrades236xToOriginals() {
        let url = URL(string: "https://i.pinimg.com/236x/b4/3a/38/b43a38689ca103080a93036b5bca6a55.jpg")!
        XCTAssertEqual(
            PinterestSourceEnricher.originalsUpgradeURL(for: url)?.absoluteString,
            "https://i.pinimg.com/originals/b4/3a/38/b43a38689ca103080a93036b5bca6a55.jpg"
        )
    }

    /// The thumbnail crop family must NEVER be upgraded — it's a
    /// genuinely different composition (Pinterest's own square crop),
    /// not a resolution variant of the faithful 4:5 image.
    func testDoesNotUpgradeSquareThumbnailCropFamily() {
        let url = URL(string: "https://i.pinimg.com/60x60/b4/3a/38/b43a38689ca103080a93036b5bca6a55.jpg")!
        XCTAssertNil(PinterestSourceEnricher.originalsUpgradeURL(for: url))
    }

    /// The wide social-card crop family must also never be upgraded —
    /// same reasoning, a genuinely different composition.
    func testDoesNotUpgradeWideSocialCardCropFamily() {
        let url = URL(string: "https://i.pinimg.com/600x315/b4/3a/38/b43a38689ca103080a93036b5bca6a55.jpg")!
        XCTAssertNil(PinterestSourceEnricher.originalsUpgradeURL(for: url))
    }

    func testDoesNotReUpgradeAlreadyOriginalURL() {
        let url = URL(string: "https://i.pinimg.com/originals/b4/3a/38/b43a38689ca103080a93036b5bca6a55.jpg")!
        XCTAssertNil(PinterestSourceEnricher.originalsUpgradeURL(for: url))
    }

    func testDoesNotUpgradeNonPinimgHost() {
        let url = URL(string: "https://example.com/736x/foo.jpg")!
        XCTAssertNil(PinterestSourceEnricher.originalsUpgradeURL(for: url))
    }

    // MARK: - Architecture: SourceEnricher only, never a CandidateImageSource

    func testPinterestEnricherIsRegisteredInDefaultEnrichers() {
        let matched = URLCherryResolver.defaultEnrichers.contains {
            $0.matches(URL(string: "https://www.pinterest.com/pin/772859986091581288/")!)
        }
        XCTAssertTrue(matched, "PinterestSourceEnricher must be registered in URLCherryResolver.defaultEnrichers")
    }

    func testDefaultCandidateSourcesHasNoInstagramOrPinterestEntry() {
        XCTAssertEqual(
            URLCherryResolver.defaultCandidateSources.count, 1,
            "no Instagram/Pinterest-specific CandidateImageSource should ever be added — both are enrichment-only"
        )
    }
}
