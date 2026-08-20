import XCTest
@testable import ArkyvKit

/// Link Cherry Visual Picker 01. Pure, deterministic tests for candidate
/// ordering/dedup/cap — no network, no MediaStore.
final class CandidateAssemblyTests: XCTestCase {
    private func candidate(_ id: String) -> ResolvedImageCandidate {
        ResolvedImageCandidate(id: id, source: .url(URL(string: "https://example.com/\(id).jpg")!))
    }

    // MARK: - merging

    func testPrimaryCandidateAlwaysStaysFirst() {
        let merged = CandidateAssembly.merging([candidate("primary")], with: [candidate("a"), candidate("b")])
        XCTAssertEqual(merged.map(\.id), ["primary", "a", "b"])
    }

    func testDuplicateIDsAreSkipped() {
        let merged = CandidateAssembly.merging([candidate("primary")], with: [candidate("primary"), candidate("a")])
        XCTAssertEqual(merged.map(\.id), ["primary", "a"])
    }

    func testMergingRespectsMaximumCandidateCap() {
        let extras = (0..<20).map { candidate("extra-\($0)") }
        let merged = CandidateAssembly.merging([candidate("primary")], with: extras)
        XCTAssertEqual(merged.count, CandidateAssembly.maximumCandidates)
        XCTAssertEqual(merged.first?.id, "primary")
    }

    func testEmptyAdditionalCandidatesLeavesExistingUnchanged() {
        let merged = CandidateAssembly.merging([candidate("primary")], with: [])
        XCTAssertEqual(merged.map(\.id), ["primary"])
    }

    // MARK: - dedupeKey

    func testDedupeKeyIgnoresQueryString() {
        let a = URL(string: "https://cdn.example.com/photo.jpg?v=123")!
        let b = URL(string: "https://cdn.example.com/photo.jpg?v=456")!
        XCTAssertEqual(CandidateAssembly.dedupeKey(for: a), CandidateAssembly.dedupeKey(for: b))
    }

    func testDedupeKeyIgnoresShopifyStyleSizeSuffix() {
        let full = URL(string: "https://shop.example.com/cdn/shop/files/photo.jpg")!
        let sized = URL(string: "https://shop.example.com/cdn/shop/files/photo_1024x1024.jpg")!
        XCTAssertEqual(CandidateAssembly.dedupeKey(for: full), CandidateAssembly.dedupeKey(for: sized))
    }

    func testDedupeKeyDistinguishesGenuinelyDifferentImages() {
        let a = URL(string: "https://shop.example.com/cdn/shop/files/front.jpg")!
        let b = URL(string: "https://shop.example.com/cdn/shop/files/back.jpg")!
        XCTAssertNotEqual(CandidateAssembly.dedupeKey(for: a), CandidateAssembly.dedupeKey(for: b))
    }

    func testDedupeKeyIsCaseInsensitive() {
        let a = URL(string: "https://Example.com/Photo.JPG")!
        let b = URL(string: "https://example.com/Photo.JPG")!
        XCTAssertEqual(CandidateAssembly.dedupeKey(for: a), CandidateAssembly.dedupeKey(for: b))
    }
}
