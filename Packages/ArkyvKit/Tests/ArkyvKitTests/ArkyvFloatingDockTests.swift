import XCTest
@testable import ArkyvKit

/// One Archive Bottom Scroll / Safe Area 01. `ArkyvFloatingDock` is the
/// single shared source of truth for the floating root dock's geometry —
/// both `RootView` (which positions the dock) and `ArchiveView` (which
/// reserves scroll clearance for it) read these same constants, so this
/// pins the arithmetic relationship and the values themselves against
/// silent drift. Genuine on-screen layout (whether the reserved space
/// actually renders correctly) is verified physically on Device A, not
/// here — this is the deterministic, non-UI half: the contract that
/// `totalHeight` really is derived from the same numbers `RootView` uses
/// to place the dock, not an independently-guessed constant like the
/// hardcoded `96` this milestone replaced.
final class ArkyvFloatingDockTests: XCTestCase {
    func testTotalHeightIsDiameterPlusBottomClearance() {
        XCTAssertEqual(ArkyvFloatingDock.totalHeight, ArkyvFloatingDock.diameter + ArkyvFloatingDock.bottomClearance)
    }

    func testDiameterIsPositiveAndReasonableForATapTarget() {
        // Apple's documented minimum comfortable hit target is 44pt;
        // the dock's fixed circle is intentionally larger than that.
        XCTAssertGreaterThanOrEqual(ArkyvFloatingDock.diameter, 44)
    }

    func testTotalHeightStaysASmallFloatingFootprintNotABar() {
        // `ArchiveView` adds this directly (plus one spacing token) as
        // real scrollable clearance — pinning a sane upper bound
        // guards against this silently ballooning into "hundreds of
        // points" of blank scroll space for short Archives.
        XCTAssertGreaterThan(ArkyvFloatingDock.totalHeight, 0)
        XCTAssertLessThan(ArkyvFloatingDock.totalHeight, 200)
    }
}
