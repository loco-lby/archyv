import XCTest
@testable import ArkyvKit

/// One Archive Motion 01. Tests the product invariants this milestone
/// exists to enforce — "ONE ARCHIVE MUST NOT BECOME A CASINO" — against
/// the pure `ArchiveAnimationPolicy.computeGrants` decision function, not
/// SwiftUI geometry/rendering details (which have no useful automated
/// seam — see `ArchiveAnimatedCell`/`ArchiveAnimationCoordinator`'s own
/// doc comments; verified instead by real-device and Simulator visual QA,
/// documented in this milestone's closeout report).
final class ArchiveAnimationPolicyTests: XCTestCase {
    private func candidate(_ id: UUID, visible: Double, distance: Double = 0) -> ArchiveAnimationPolicy.Candidate {
        ArchiveAnimationPolicy.Candidate(id: id, visibleFraction: visible, distanceFromCenter: distance)
    }

    // MARK: - Scroll-phase gating

    func testActiveScrollGrantsNothingRegardlessOfVisibility() {
        let id = UUID()
        let grants = ArchiveAnimationPolicy.computeGrants(
            candidates: [candidate(id, visible: 1.0)],
            previouslyGranted: [],
            isScrollSettled: false,
            isLowPowerMode: false
        )
        XCTAssertTrue(grants.isEmpty, "active/fast scroll must pause or avoid starting animation, unconditionally")
    }

    func testActiveScrollRevokesAnAlreadyGrantedCell() {
        let id = UUID()
        let grants = ArchiveAnimationPolicy.computeGrants(
            candidates: [candidate(id, visible: 1.0)],
            previouslyGranted: [id],
            isScrollSettled: false,
            isLowPowerMode: false
        )
        XCTAssertTrue(grants.isEmpty, "scrolling must revoke in-flight animations too, not just refuse new ones")
    }

    // MARK: - Visibility threshold + hysteresis

    func testBelowStartThresholdIsNotGranted() {
        let id = UUID()
        let grants = ArchiveAnimationPolicy.computeGrants(
            candidates: [candidate(id, visible: ArchiveAnimationPolicy.defaultStartThreshold - 0.01)],
            previouslyGranted: [],
            isScrollSettled: true,
            isLowPowerMode: false
        )
        XCTAssertTrue(grants.isEmpty)
    }

    func testAtOrAboveStartThresholdIsGranted() {
        let id = UUID()
        let grants = ArchiveAnimationPolicy.computeGrants(
            candidates: [candidate(id, visible: ArchiveAnimationPolicy.defaultStartThreshold)],
            previouslyGranted: [],
            isScrollSettled: true,
            isLowPowerMode: false
        )
        XCTAssertEqual(grants, [id])
    }

    /// The hysteresis case: a cell already playing should NOT drop out
    /// the moment it dips below the START threshold — only once it falls
    /// below the lower STOP threshold. Without this, a cell hovering
    /// right at the boundary during a slow scroll would flicker on/off.
    func testAlreadyGrantedCellSurvivesDippingBetweenStopAndStartThresholds() {
        let id = UUID()
        let midway = (ArchiveAnimationPolicy.defaultStartThreshold + ArchiveAnimationPolicy.defaultStopThreshold) / 2
        let grants = ArchiveAnimationPolicy.computeGrants(
            candidates: [candidate(id, visible: midway)],
            previouslyGranted: [id],
            isScrollSettled: true,
            isLowPowerMode: false
        )
        XCTAssertEqual(grants, [id], "hysteresis must keep an already-playing cell alive between the stop and start thresholds")
    }

    func testAlreadyGrantedCellIsRevokedBelowStopThreshold() {
        let id = UUID()
        let grants = ArchiveAnimationPolicy.computeGrants(
            candidates: [candidate(id, visible: ArchiveAnimationPolicy.defaultStopThreshold - 0.01)],
            previouslyGranted: [id],
            isScrollSettled: true,
            isLowPowerMode: false
        )
        XCTAssertTrue(grants.isEmpty)
    }

    func testNotYetGrantedCellNeedsFullStartThresholdEvenIfAboveStopThreshold() {
        let id = UUID()
        let midway = (ArchiveAnimationPolicy.defaultStartThreshold + ArchiveAnimationPolicy.defaultStopThreshold) / 2
        let grants = ArchiveAnimationPolicy.computeGrants(
            candidates: [candidate(id, visible: midway)],
            previouslyGranted: [],
            isScrollSettled: true,
            isLowPowerMode: false
        )
        XCTAssertTrue(grants.isEmpty, "a cell that was never playing needs the full start threshold, not just above stop")
    }

    // MARK: - Concurrency cap

    func testConcurrencyCapIsNeverExceeded() {
        let ids = (0..<10).map { _ in UUID() }
        let candidates = ids.map { candidate($0, visible: 1.0) }
        let grants = ArchiveAnimationPolicy.computeGrants(
            candidates: candidates,
            previouslyGranted: [],
            isScrollSettled: true,
            isLowPowerMode: false
        )
        XCTAssertEqual(grants.count, ArchiveAnimationPolicy.defaultMaxConcurrent, "10 fully-visible eligible candidates must still cap at the concurrency limit — this is the entire 'not a casino' guarantee")
    }

    func testFewerEligibleThanCapGrantsAllOfThem() {
        let ids = (0..<2).map { _ in UUID() }
        let candidates = ids.map { candidate($0, visible: 1.0) }
        let grants = ArchiveAnimationPolicy.computeGrants(
            candidates: candidates,
            previouslyGranted: [],
            isScrollSettled: true,
            isLowPowerMode: false
        )
        XCTAssertEqual(grants, Set(ids))
    }

    // MARK: - Deterministic priority

    func testHighestVisibleFractionWinsOverLowerWhenCapIsTight() {
        let winner = UUID()
        let loser = UUID()
        let grants = ArchiveAnimationPolicy.computeGrants(
            candidates: [candidate(winner, visible: 1.0), candidate(loser, visible: ArchiveAnimationPolicy.defaultStartThreshold)],
            previouslyGranted: [],
            isScrollSettled: true,
            isLowPowerMode: false,
            maxConcurrent: 1
        )
        XCTAssertEqual(grants, [winner])
    }

    func testEqualVisibilityBreaksTieByDistanceFromCenter() {
        let nearer = UUID()
        let farther = UUID()
        let grants = ArchiveAnimationPolicy.computeGrants(
            candidates: [candidate(nearer, visible: 1.0, distance: 10), candidate(farther, visible: 1.0, distance: 500)],
            previouslyGranted: [],
            isScrollSettled: true,
            isLowPowerMode: false,
            maxConcurrent: 1
        )
        XCTAssertEqual(grants, [nearer])
    }

    /// QA Follow-Up 03: real device evidence — six candidates all fully
    /// visible (`visibleFraction == 1.0`) and equidistant from center,
    /// competing for a cap of 3 — showed the winning set could shuffle
    /// between recomputes with no actual visibility change, because
    /// nothing broke a tie deterministically. Runs the same exact-tie
    /// input through `computeGrants` repeatedly and asserts every run
    /// produces the identical winning set.
    func testExactTiesProduceStableDeterministicWinnersAcrossRepeatedCalls() {
        let ids = (0..<6).map { _ in UUID() }
        let candidates = ids.map { candidate($0, visible: 1.0, distance: 10) }
        let first = ArchiveAnimationPolicy.computeGrants(
            candidates: candidates,
            previouslyGranted: [],
            isScrollSettled: true,
            isLowPowerMode: false
        )
        XCTAssertEqual(first.count, ArchiveAnimationPolicy.defaultMaxConcurrent)
        for _ in 0..<20 {
            let next = ArchiveAnimationPolicy.computeGrants(
                candidates: candidates,
                previouslyGranted: [],
                isScrollSettled: true,
                isLowPowerMode: false
            )
            XCTAssertEqual(next, first, "identical tied input must always produce the identical winning set")
        }
    }

    /// An already-playing candidate must win an exact tie against a new,
    /// equally-ranked arrival — preferring continuity over needless
    /// start/stop churn, the same instinct behind this policy's own
    /// hysteresis.
    func testAlreadyPlayingCandidateWinsExactTieOverNewArrival() {
        let alreadyPlaying = UUID()
        let newArrival = UUID()
        let grants = ArchiveAnimationPolicy.computeGrants(
            candidates: [candidate(alreadyPlaying, visible: 1.0, distance: 10), candidate(newArrival, visible: 1.0, distance: 10)],
            previouslyGranted: [alreadyPlaying],
            isScrollSettled: true,
            isLowPowerMode: false,
            maxConcurrent: 1
        )
        XCTAssertEqual(grants, [alreadyPlaying])
    }

    // MARK: - Low Power Mode

    func testLowPowerModeClampsConcurrency() {
        let ids = (0..<10).map { _ in UUID() }
        let candidates = ids.map { candidate($0, visible: 1.0) }
        let grants = ArchiveAnimationPolicy.computeGrants(
            candidates: candidates,
            previouslyGranted: [],
            isScrollSettled: true,
            isLowPowerMode: true
        )
        XCTAssertEqual(grants.count, ArchiveAnimationPolicy.defaultLowPowerConcurrencyCap)
    }

    func testLowPowerModeDoesNotSuppressMotionEntirely() {
        let id = UUID()
        let grants = ArchiveAnimationPolicy.computeGrants(
            candidates: [candidate(id, visible: 1.0)],
            previouslyGranted: [],
            isScrollSettled: true,
            isLowPowerMode: true
        )
        XCTAssertEqual(grants, [id], "Low Power Mode reduces concurrency, it does not suppress intentional motion entirely — see this milestone's closeout report")
    }

    // MARK: - Empty input

    func testNoCandidatesGrantsNothing() {
        XCTAssertTrue(ArchiveAnimationPolicy.computeGrants(candidates: [], previouslyGranted: [], isScrollSettled: true, isLowPowerMode: false).isEmpty)
    }
}
