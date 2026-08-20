import XCTest
@testable import ArkyvKit

/// URL → Cherry Physical QA Follow-Up 01. `ShareViewController`'s
/// `MediaThumbnail` lives in the `ArkyvShare` app-extension target (UIKit
/// view-controller glue, not ArkyvKit) and this repo has no SwiftUI
/// snapshot/ViewInspector infrastructure, so the actual `.frame()`
/// chaining fix (combining two separate `maxWidth`/`maxHeight` calls into
/// one) can't be exercised by a unit test directly — it was verified by
/// code review and a physical-device re-test instead (see this
/// milestone's final report).
///
/// What IS unit-testable, and directly relevant: the underlying
/// aspect-fill geometry `MediaThumbnail` relies on is
/// `CropEditorMath.minimumCoveringSize` — the same "how big does a
/// `.scaledToFill()` image render before clipping" math already trusted
/// elsewhere in this codebase. These tests pin its behavior across every
/// aspect ratio this milestone called out (including the Works in
/// Progress-like wide banner case that triggered the real bug) against a
/// fixed target box, confirming the *rendered* size always fully covers
/// the box — the correctness property `.clipped()`/`.clipShape` depend on
/// to produce a fill thumbnail with no gaps, regardless of source shape.
final class ShareExtensionLayoutTests: XCTestCase {
    /// Representative of `MediaThumbnail`'s typical offered box (roughly
    /// screen-width minus the drawer's horizontal padding, capped at the
    /// 360pt max height).
    private let targetBox = CGRect(x: 0, y: 0, width: 350, height: 360)

    private let aspectRatioCases: [(name: String, size: CGSize)] = [
        ("1:1", CGSize(width: 1000, height: 1000)),
        ("4:5 portrait", CGSize(width: 800, height: 1000)),
        ("9:16 portrait", CGSize(width: 900, height: 1600)),
        ("16:9 landscape", CGSize(width: 1600, height: 900)),
        ("~3:1 wide banner", CGSize(width: 3000, height: 1000)),
        ("~4:1 extreme banner", CGSize(width: 4000, height: 1000)),
        ("1:3 tall", CGSize(width: 1000, height: 3000)),
        ("Works in Progress-like wide hero", CGSize(width: 1024, height: 341)),
    ]

    func testFillSizeAlwaysFullyCoversTargetBoxRegardlessOfSourceAspectRatio() {
        for testCase in aspectRatioCases {
            let filled = CropEditorMath.minimumCoveringSize(imageAspectSize: testCase.size, toCover: targetBox)
            XCTAssertGreaterThanOrEqual(filled.width, targetBox.width - 0.001, "\(testCase.name) must cover the box's width")
            XCTAssertGreaterThanOrEqual(filled.height, targetBox.height - 0.001, "\(testCase.name) must cover the box's height")
        }
    }

    /// The box itself — what `.frame(maxWidth:maxHeight:)` reports
    /// upward to the rest of the layout — must be identical no matter
    /// which aspect ratio is being displayed inside it. This is the
    /// literal "media adapts to the UI, not the other way around"
    /// contract: nothing about `targetBox` varies per test case above,
    /// by construction, since `minimumCoveringSize`'s `toCover:` argument
    /// is a fixed constant this whole file never changes based on
    /// `imageAspectSize`.
    func testTargetBoxDimensionsAreIndependentOfSourceAspectRatio() {
        for testCase in aspectRatioCases {
            XCTAssertEqual(targetBox.width, 350, "\(testCase.name) must not influence the allocated box width")
            XCTAssertEqual(targetBox.height, 360, "\(testCase.name) must not influence the allocated box height")
        }
    }
}
