import Foundation

/// One Archive Motion 01: the pure decision logic behind "which animated
/// Cherries actually get to decode and play right now" — deliberately
/// extracted from `ArchiveAnimationCoordinator` (Sources/iOS, `@Observable`
/// UI state) into a plain, UIKit/SwiftUI-independent function so the
/// product invariants this milestone cares about most — the concurrency
/// cap, the visibility threshold, hysteresis, deterministic priority,
/// scroll-settle gating, Low Power Mode's effect on concurrency — are
/// directly unit-testable, the same engine/presentation split
/// `AnimatedImageDecoding`/`AnimatedLocalImageView` already established.
///
/// "ONE ARCHIVE MUST NOT BECOME A CASINO": this is the entire enforcement
/// mechanism for that constraint, in one pure function with no hidden
/// state — given the same inputs, it always returns the same answer.
public enum ArchiveAnimationPolicy {
    public struct Candidate: Sendable {
        public let id: UUID
        /// 0...1 — fraction of the cell's own tile currently inside the
        /// viewport.
        public let visibleFraction: Double
        /// Absolute distance (in points) from the cell's center to the
        /// viewport's center — only ever used for relative ranking.
        public let distanceFromCenter: Double

        public init(id: UUID, visibleFraction: Double, distanceFromCenter: Double) {
            self.id = id
            self.visibleFraction = visibleFraction
            self.distanceFromCenter = distanceFromCenter
        }
    }

    /// Pinterest's own reported starting hypothesis (see this milestone's
    /// brief) — a cell becomes eligible once at least this fraction of its
    /// tile is inside the viewport.
    public static let defaultStartThreshold: Double = 0.55
    /// Deliberately below `defaultStartThreshold` — modest hysteresis so a
    /// cell hovering right at the boundary during a slow scroll doesn't
    /// flicker in and out of eligibility every few points of movement.
    /// Not "sacred 50%": chosen because masonry cells routinely straddle a
    /// column boundary mid-scroll, which is exactly the chatter case
    /// hysteresis exists for.
    public static let defaultStopThreshold: Double = 0.40
    /// The product hypothesis stated in the brief: "2–3 simultaneous
    /// animations may be enough for One Archive to feel alive." See the
    /// milestone's closeout report for the physical-QA reasoning behind
    /// this exact number.
    public static let defaultMaxConcurrent = 3
    /// Low Power Mode reduces concurrency rather than fully suppressing
    /// motion — see the closeout report's own Low Power Mode reasoning.
    public static let defaultLowPowerConcurrencyCap = 1

    /// The only place this policy is ever decided. Given the same
    /// candidates/state, always returns the same grant set — no hidden
    /// state, no randomness, no time-dependence beyond what the caller
    /// passes in.
    ///
    /// - `isScrollSettled == false` grants nothing at all — "ACTIVE / FAST
    ///   SCROLL → animations pause or avoid starting," unconditionally.
    /// - Otherwise, candidates are filtered by hysteresis (already-granted
    ///   ones need only stay above `stopThreshold`; new ones need
    ///   `startThreshold`), ranked by the brief's own deterministic
    ///   signal — highest visible percentage, then nearest viewport
    ///   center — and only the top `effectiveMaxConcurrent` are granted.
    public static func computeGrants(
        candidates: [Candidate],
        previouslyGranted: Set<UUID>,
        isScrollSettled: Bool,
        isLowPowerMode: Bool,
        startThreshold: Double = defaultStartThreshold,
        stopThreshold: Double = defaultStopThreshold,
        maxConcurrent: Int = defaultMaxConcurrent,
        lowPowerConcurrencyCap: Int = defaultLowPowerConcurrencyCap
    ) -> Set<UUID> {
        guard isScrollSettled else { return [] }

        let eligible = candidates.filter { candidate in
            if previouslyGranted.contains(candidate.id) {
                return candidate.visibleFraction >= stopThreshold
            }
            return candidate.visibleFraction >= startThreshold
        }
        // QA Follow-Up 03: real device evidence (six simultaneously fully-
        // visible animated candidates, competing for 3 slots) showed the
        // winning set could shuffle between recomputes even though
        // nothing about visibility had actually changed — because
        // `candidates` arrives as an unordered `[Candidate]` (built from a
        // `Dictionary`'s `.values`, whose iteration order Swift never
        // guarantees), a plain two-key sort has no defined outcome among
        // EXACT ties, and `sorted(by:)` itself isn't guaranteed stable.
        // Two extra, fully deterministic tiebreakers fix that: an
        // already-playing candidate wins a tie outright (continuity over
        // an equally-ranked newcomer — the same "avoid twitchy start/stop"
        // instinct behind this policy's own hysteresis), then a stable
        // id-string comparison as the final fallback, so the SAME input
        // always produces the SAME winners.
        let ranked = eligible.sorted { lhs, rhs in
            if lhs.visibleFraction != rhs.visibleFraction { return lhs.visibleFraction > rhs.visibleFraction }
            if lhs.distanceFromCenter != rhs.distanceFromCenter { return lhs.distanceFromCenter < rhs.distanceFromCenter }
            let lhsPlaying = previouslyGranted.contains(lhs.id)
            let rhsPlaying = previouslyGranted.contains(rhs.id)
            if lhsPlaying != rhsPlaying { return lhsPlaying }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        let effectiveMax = isLowPowerMode ? min(maxConcurrent, lowPowerConcurrencyCap) : maxConcurrent
        return Set(ranked.prefix(max(effectiveMax, 0)).map(\.id))
    }
}
