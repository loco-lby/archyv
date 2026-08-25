import SwiftUI
import UIKit
import ArkyvKit

/// A single stable anchor's offset, reported via SwiftUI's preference
/// system — used only to detect "is the archive actively scrolling right
/// now," debounced in `ArchiveView`. QA Follow-Up 02: per-cell visibility
/// used to be reported the same way (`CellFramePreferenceKey`), but real
/// device evidence proved that path silently drops a reappearing cell's
/// report whenever its geometry happens to match what was last delivered
/// (SwiftUI's `onPreferenceChange` suppresses the callback on unchanged
/// values) — see `ArchiveAnimatedCell.reportVisibility(frame:)`, which
/// replaced it with direct, unconditional coordinator calls from
/// `.onAppear`/`.onChange`. This single anchor is unaffected: cells
/// mount/unmount as they enter/leave the lazy window, which would make a
/// derived "most recent change" signal noisy exactly when it matters
/// least (a cell appearing for the first time isn't evidence of active
/// scrolling), so scroll-phase detection deliberately stays on ONE
/// always-present, never-disappearing anchor instead.
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// One Archive Motion 01: the single source of truth for "which animated
/// Cherries actually get to decode and play right now" — a hard,
/// deterministic policy layer sitting between "this cell is animated and
/// visible" and "this cell is actually spending memory/CPU on playback."
///
/// Exists as one shared coordinator (not per-cell local state) because a
/// concurrency cap and priority ordering are inherently GLOBAL properties —
/// no individual cell can know whether it should get one of N slots
/// without knowing what every other eligible cell is doing right now.
///
/// "ONE ARCHIVE MUST NOT BECOME A CASINO": this type is the entire
/// enforcement mechanism for that constraint. Everything upstream (a
/// cell's own visibility fraction, whether it's animated at all) is just
/// input; every decision about what's actually ALLOWED to move is made
/// here, once, centrally.
@Observable
final class ArchiveAnimationCoordinator {
    /// The only thing cells actually read. `@Observable` makes every
    /// reader of this property re-evaluate exactly when its VALUE changes
    /// — coarse (whole-set) rather than per-id, but with a concurrency cap
    /// this small the set changes rarely enough for that not to matter.
    private(set) var grantedIDs: Set<UUID> = []
    /// Physical QA Follow-Up §D: cells key their decode task off this
    /// alongside `grantedIDs` membership — see `resumeIfNeeded()`'s own
    /// doc comment for why membership alone isn't a reliable enough
    /// signal to force a resume.
    private(set) var resumeGeneration = 0

    private struct Candidate {
        let id: UUID
        var visibleFraction: CGFloat
        var distanceFromCenter: CGFloat
    }

    private var candidates: [UUID: Candidate] = [:]
    private var isScrollSettled = true

    func updateVisibility(id: UUID, visibleFraction: CGFloat, distanceFromCenter: CGFloat) {
        candidates[id] = Candidate(id: id, visibleFraction: visibleFraction, distanceFromCenter: distanceFromCenter)
        recomputeGrants()
    }

    func remove(id: UUID) {
        candidates.removeValue(forKey: id)
        recomputeGrants()
    }

    func setScrollSettled(_ settled: Bool) {
        guard settled != isScrollSettled else { return }
        isScrollSettled = settled
        recomputeGrants()
    }

    /// QA Follow-Up 01/02: called both when `ArchiveView` observes
    /// `scenePhase` becoming `.active` AND on every `ArchiveView.onAppear`
    /// (cold launch, Back-navigation from Item Detail, capture/import
    /// sheet dismissal — see that call site's own doc comment for why
    /// `.onAppear` is the one signal that covers all of those). Backgrounding
    /// and in-app navigation both leave layout completely unchanged
    /// (scroll position is preserved), which is exactly the case
    /// `recomputeGrants()` alone can't fix: if a
    /// cell's `grantedIDs` membership doesn't actually change (it was,
    /// and still is, eligible), a `.task(id:)` keyed only on that
    /// membership sees no edge and never re-fires — bumping
    /// `resumeGeneration` here, and folding it into that same task's id,
    /// guarantees a genuine re-trigger regardless of whether membership
    /// itself changed. Still fully respects the existing policy — this
    /// does not grant anything not already eligible under the current
    /// visibility/settle/concurrency/Low-Power state; it only forces
    /// already-eligible cells to actually resume.
    func resumeIfNeeded() {
        resumeGeneration += 1
        recomputeGrants()
    }

    /// Delegates the actual decision to `ArchiveAnimationPolicy.computeGrants`
    /// (ArkyvKit) — this method's only job is gathering this coordinator's
    /// own live state (candidates, settle state, Low Power Mode) into that
    /// pure function's inputs. This is the only place `grantedIDs` is ever
    /// written.
    private func recomputeGrants() {
        let policyCandidates = candidates.values.map {
            ArchiveAnimationPolicy.Candidate(id: $0.id, visibleFraction: Double($0.visibleFraction), distanceFromCenter: Double($0.distanceFromCenter))
        }
        let next = ArchiveAnimationPolicy.computeGrants(
            candidates: policyCandidates,
            previouslyGranted: grantedIDs,
            isScrollSettled: isScrollSettled,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        if next != grantedIDs { grantedIDs = next }
    }
}
