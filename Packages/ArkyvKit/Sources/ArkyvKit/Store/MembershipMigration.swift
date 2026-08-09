import Foundation
import SwiftData

/// ONE-TIME BACKFILL. Safe to delete once every real device has run it —
/// same lifecycle as `IconMigration`.
///
/// v0.2 introduces `StoredFolderMembership`, the new multi-folder join,
/// living *alongside* the legacy single-owner `StoredItem.folder`
/// relationship (nothing about `folder` changes in this milestone — see
/// `StoredModels.swift`). This backfills one membership row for every
/// existing item's legacy folder assignment, so `StoredFolderMembership`
/// data exists for the app's real, already-captured heartbeat items before
/// any UI ever reads it.
///
/// To remove: delete this file, and the two
/// `MembershipMigration.runIfNeeded(...)` call sites (`ArkyvApp.swift`,
/// `ShareViewController.swift`) — same removal shape as `IconMigration`.
public enum MembershipMigration {
    /// App Group flag so the fast (already-done) path is a single
    /// `UserDefaults` read across every process that might call this at
    /// launch. Purely a launch-time optimization — `backfillMemberships`
    /// itself is idempotent independent of this flag (see its doc comment),
    /// so losing or resetting the flag just means a harmless full rescan,
    /// never a duplicate.
    private static let hasRunKey = "com.arkyv.migration.folderMembershipBackfill.v1"

    /// Runs the backfill if it hasn't already succeeded. Cheap to call from
    /// every process's launch path — a single `UserDefaults` read in the
    /// common case where it's already done.
    public static func runIfNeeded(repository: Repository) {
        let defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
        guard !defaults.bool(forKey: hasRunKey) else {
            log("runIfNeeded — already flagged done, skipping")
            return
        }
        log("runIfNeeded — not yet flagged done, running backfill")
        do {
            try backfillMemberships(repository: repository)
            defaults.set(true, forKey: hasRunKey)
            log("runIfNeeded — backfill succeeded, flag set")
        } catch {
            // Leave the flag unset so we retry next launch instead of
            // silently stranding legacy items without their membership row.
            log("runIfNeeded — backfill FAILED, flag left unset for retry: \(error)")
        }
    }

    /// For every non-deleted item with a non-deleted legacy `folder`,
    /// ensures exactly one active `StoredFolderMembership(item, folder)`
    /// row exists — creating one only if an equivalent active membership
    /// isn't already there.
    ///
    /// Idempotent on its own merits, independent of `runIfNeeded`'s flag:
    /// every item is checked for an existing active membership to the same
    /// folder before one is created, so calling this directly, repeatedly,
    /// in any order, on a store that's already partially or fully migrated,
    /// never produces a duplicate. This is deliberate — it's what makes the
    /// migration safe to re-run on a real device with no way to inspect
    /// whether a prior run completed cleanly.
    ///
    /// Items with `folder == nil`, or whose `folder` is itself soft-deleted,
    /// are left with zero memberships — there is no "obviously
    /// deleted/orphaned" legacy assignment worth resurrecting here. Deleted
    /// items are skipped entirely. Only `StoredFolderMembership` rows are
    /// inserted; `StoredItem`/`StoredFolder` fields (including `dirty` /
    /// `updatedAt`) are never touched.
    public static func backfillMemberships(repository: Repository) throws {
        let items = try repository.context.fetch(FetchDescriptor<StoredItem>())
        var created = 0
        var skippedDeletedItem = 0
        var skippedNoFolder = 0
        var skippedDeletedFolder = 0
        var skippedAlreadyMember = 0

        for item in items {
            guard !item.isSoftDeleted else { skippedDeletedItem += 1; continue }
            guard let folder = item.folder else { skippedNoFolder += 1; continue }
            guard !folder.isSoftDeleted else { skippedDeletedFolder += 1; continue }

            let alreadyMember = item.memberships.contains {
                !$0.isSoftDeleted && $0.folder?.id == folder.id
            }
            guard !alreadyMember else { skippedAlreadyMember += 1; continue }

            let membership = StoredFolderMembership(item: item, folder: folder)
            // Backfilled from state that already existed, not a new local
            // mutation to push — same reasoning as `seedIfEmpty` marking
            // seeded folders `dirty = false`.
            membership.dirty = false
            repository.context.insert(membership)
            created += 1
        }

        if created > 0 {
            try repository.context.save()
        }
        log("backfillMemberships — scanned \(items.count) items: created \(created), " +
            "skipped (deleted item) \(skippedDeletedItem), skipped (no legacy folder) \(skippedNoFolder), " +
            "skipped (deleted folder) \(skippedDeletedFolder), skipped (already member) \(skippedAlreadyMember)")
    }

    private static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[MembershipMigration] \(message())")
        #endif
    }
}
