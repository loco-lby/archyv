import Foundation
import SwiftData

/// D4: decides whether to seed the default folders shown in the Figma
/// design on first run, without ever racing CloudKit's asynchronous
/// initial import on a fresh device/install.
///
/// Replaces an earlier, since-removed `Repository.seedIfEmpty()` that
/// used a single blocking sleep-then-recheck at launch — real-device
/// testing showed that approach genuinely fails: a 3-second grace period
/// was not long enough for one real CloudKit import, and the store got
/// seeded with 5 duplicate default folders that then synced out
/// alongside the real data.
///
/// This replacement removes the blocking wait entirely. `evaluate(...)`
/// is a plain, synchronous, idempotent check — call it repeatedly (once
/// per app foreground activation, and periodically while the app stays
/// foregrounded — see `RootView`) rather than once at launch. The only
/// state that needs to persist across calls/process launches is the
/// timestamp of the first time an empty store was observed; elapsed real
/// wall-clock time since then, not in-process uptime, is what's compared
/// against `elapsedWindow`. This is still a heuristic, not a guarantee —
/// an unusually slow or large initial import could still in principle
/// exceed the window — but removing the launch-blocking constraint lets
/// the window be far more generous (90s here, vs. the 3s that failed)
/// with zero cost to app launch speed.
public enum SeedGate {
    /// Whether this call site may conclude "enough time has passed,
    /// seed the defaults now." The main app's recurring per-activation
    /// check (`RootView`) is `.allowed`. The Share Extension's one-shot
    /// launch call is `.observeOnly` — it can still record the shared
    /// first-observed-empty timestamp, and can still seed immediately in
    /// the zero-ambiguity no-iCloud-account case, but never itself makes
    /// the timed decision. Deliberately required (no default) so every
    /// call site states its intent explicitly.
    public enum TimedSeedPermission {
        case allowed
        case observeOnly
    }

    private static let firstObservedEmptyAtKey = "com.arkyv.seedGate.firstObservedEmptyAt"

    /// Evaluates once and seeds if appropriate. Returns `true` iff this
    /// call actually inserted the default folders — purely informational
    /// for logging/tests, not required for correct repeated calling.
    ///
    /// - `defaults` is injectable (not just `hasICloudAccount`/`now`) so
    ///   tests never touch the real App Group `UserDefaults` suite that
    ///   a real device/process would share.
    @discardableResult
    public static func evaluate(
        context: ModelContext,
        hasICloudAccount: Bool = FileManager.default.ubiquityIdentityToken != nil,
        timedSeedPermission: TimedSeedPermission,
        now: Date = .now,
        elapsedWindow: TimeInterval = 90,
        defaults: UserDefaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
    ) -> Bool {
        guard let isEmpty = try? Repository(context: context).folders(includingDeleted: true).isEmpty, isEmpty else {
            // Already has data (or the fetch itself failed) — nothing to
            // do either way; a fetch failure should never be treated as
            // "empty, therefore seed."
            return false
        }

        guard hasICloudAccount else {
            log("evaluate — no iCloud account, seeding immediately (no import is possible)")
            seed(context: context)
            return true
        }

        guard let firstObservedEmptyAt = defaults.object(forKey: firstObservedEmptyAtKey) as? Date else {
            defaults.set(now, forKey: firstObservedEmptyAtKey)
            log("evaluate — first time observing an empty store with iCloud present; recording \(now)")
            return false
        }

        guard timedSeedPermission == .allowed else {
            log("evaluate — observe-only caller, not deciding the timed case")
            return false
        }

        let elapsed = now.timeIntervalSince(firstObservedEmptyAt)
        guard elapsed >= elapsedWindow else {
            log("evaluate — only \(elapsed)s elapsed of \(elapsedWindow)s, waiting")
            return false
        }

        log("evaluate — \(elapsed)s elapsed with the store still empty, seeding")
        seed(context: context)
        return true
    }

    private static func seed(context: ModelContext) {
        let seeds: [(String, FolderIcon)] = [
            ("Deadwest", .glyph(.star)),
            ("Cool Shit", .glyph(.cross)),
            ("Recipes", .glyph(.triangle)),
            ("Japan 2026", .glyph(.circle)),
            ("Inspiration", .glyph(.diamond)),
        ]
        for (index, seed) in seeds.enumerated() {
            let folder = StoredFolder(name: seed.0, icon: seed.1, sortOrder: index)
            folder.dirty = false // seeded folders aren't "user changes" to push
            context.insert(folder)
        }
        try? context.save()
    }

    private static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[SeedGate] \(message())")
        #endif
    }
}
