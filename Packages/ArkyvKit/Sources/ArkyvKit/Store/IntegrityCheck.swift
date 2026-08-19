import Foundation
import SwiftData

#if DEBUG
/// DEBUG-only, read-only integrity scan (Data Integrity Foundation 01).
/// Detects the specific disagreement/orphan shapes the persistence-lifecycle
/// audit identified as *possible* (even where nothing in the current app
/// actually produces them) and reports counts — it never mutates or
/// deletes anything. "Detect → log/report → preserve," never "detect →
/// delete": a media file that looks orphaned gets the benefit of the
/// doubt, since this scan has no way to know whether it's mid-capture, a
/// staged-but-not-yet-filed draft, or genuinely abandoned.
///
/// Not wired into any app launch path — deliberately opt-in (call it from
/// a debug menu / Xcode console / a future diagnostics screen) rather than
/// adding new default-on startup I/O that scales with archive size.
public enum IntegrityCheck {
    public struct Report {
        public var itemCount = 0
        public var folderCount = 0
        public var membershipCount = 0
        /// Media Architecture Cutover 01: under the declared media
        /// contract, `StoredItem.imageData` is the durable authority and
        /// `MediaStore` is a derived, disposable cache — so a live
        /// (non-deleted) item with a `localFilename` that has no
        /// corresponding `MediaStore` file is, by itself, **HEALTHY /
        /// CACHE MISS**: routine, expected, self-healing on next access,
        /// and NOT counted against `isClean` (see below). Kept as a
        /// field because it's still a useful population count (e.g. "how
        /// cold is the cache right now"), just no longer a cleanliness
        /// signal on its own. Split further below by whether `imageData`
        /// actually offers a recovery path — that split is what
        /// determines real cleanliness, not this count alone.
        public var itemsWithMissingMedia: [UUID] = []
        /// Subset of `itemsWithMissingMedia` that has `imageData`
        /// populated — **CACHE MISS** (imageData exists, MediaStore
        /// absent — normal) or, if a just-attempted materialization
        /// failed to persist, **CACHE WRITE FAILURE** (imageData still
        /// readable, MediaStore absent because the write couldn't
        /// complete — recoverable/non-corrupt either way, see
        /// `MediaStore.data(for:reconstructingFrom:)`'s own product-rule
        /// doc comment). This scan can't distinguish the two from
        /// filesystem state alone, and doesn't need to: both render fine
        /// from `imageData` and neither is a cleanliness failure.
        public var itemsWithRecoverableMedia: [UUID] = []
        /// Subset of `itemsWithMissingMedia` with `imageData` also `nil`
        /// — **MEDIA LOSS**: imageData absent and no valid authoritative
        /// media remains. The ONLY missing-media category `isClean`
        /// depends on. Not necessarily "permanently" lost: `imageData`
        /// may simply not have synced down from CloudKit yet, or (for an
        /// item that predates D3A) `ImageBackfill` may not have reached
        /// it yet — this scan has no way to distinguish those from
        /// genuine loss, which is exactly why it only ever reports,
        /// never deletes.
        public var itemsWithNoKnownRecovery: [UUID] = []
        /// Files physically present in `MediaStore`'s directory that no
        /// live *or* soft-deleted `StoredItem.localFilename` references —
        /// candidates for the "abandoned capture" cleanup discussed in the
        /// Data Integrity Contract, never auto-deleted here. Under the
        /// cache contract (Media Architecture Cutover 01), this is purely
        /// diagnostic, not a GC prerequisite — `MediaStore.evictIfNeeded()`
        /// reclaims space by cache-cap/recency alone and has no need to
        /// know whether a given file is "orphaned" in this sense.
        public var orphanedMediaFilenames: [String] = []
        /// Live items whose legacy `item.folder` doesn't match their
        /// active membership set's "first" convention (see
        /// `Repository.setMemberships`'s doc comment). Writes going
        /// through `move`/`setMemberships` can no longer produce this;
        /// this catches rows that predate that fix or were touched by
        /// something outside the Repository.
        public var folderMembershipDisagreements: [UUID] = []
        /// (item, folder) pairs with more than one simultaneously-active
        /// `StoredFolderMembership` row — `setMemberships`/`addMembership`
        /// reactivate rather than duplicate, so this should always be
        /// empty; a non-empty result means something inserted a
        /// membership row without going through the Repository.
        public var duplicateActiveMemberships: [String] = []
        /// Multi-Device Consistency Foundation 01: live items with active
        /// memberships to 2+ *distinct* folders simultaneously — not to be
        /// confused with `duplicateActiveMemberships` (same item+folder
        /// pair duplicated). `setMemberships`'s "exclusive" reconciliation
        /// only sees rows its own device knows about at call time; two
        /// devices independently moving the same item to two different
        /// folders each insert one new, distinct `StoredFolderMembership`
        /// CKRecord, and CloudKit has no reason to conflict those (they're
        /// different records) — both sync down as active. Confirmed via
        /// direct two-device testing. The v0.2 schema doesn't forbid an
        /// item belonging to multiple folders, so this isn't corruption —
        /// the item stays fully reachable via `folders(for:)` — but it's
        /// almost always an unintended race rather than a deliberate
        /// multi-select, so it's surfaced here for visibility. Diagnostic
        /// only: NOT part of `isClean`, and nothing here auto-resolves it —
        /// a real fix would mean picking a winner across devices, which is
        /// exactly the kind of custom conflict protocol this milestone is
        /// scoped to avoid building.
        public var itemsWithMultipleActiveFolders: [UUID] = []

        /// Media Architecture Cutover 01: deliberately depends on
        /// `itemsWithNoKnownRecovery` (real MEDIA LOSS), NOT
        /// `itemsWithMissingMedia` — a cold `MediaStore` cache for an
        /// item whose `imageData` is intact is HEALTHY under the
        /// declared media contract, not a cleanliness failure. Before
        /// this milestone, `itemsWithMissingMedia` (which included every
        /// recoverable cache miss) counted against `isClean`; that was
        /// correct when `MediaStore` was the sole/permanent original, and
        /// is actively wrong now that it's a disposable cache expected to
        /// run cold routinely.
        public var isClean: Bool {
            itemsWithNoKnownRecovery.isEmpty && orphanedMediaFilenames.isEmpty
                && folderMembershipDisagreements.isEmpty && duplicateActiveMemberships.isEmpty
        }
    }

    public static func run(context: ModelContext) -> Report {
        var report = Report()

        let items = (try? context.fetch(FetchDescriptor<StoredItem>())) ?? []
        let folders = (try? context.fetch(FetchDescriptor<StoredFolder>())) ?? []
        let memberships = (try? context.fetch(FetchDescriptor<StoredFolderMembership>())) ?? []
        report.itemCount = items.count
        report.folderCount = folders.count
        report.membershipCount = memberships.count

        let liveItems = items.filter { !$0.isSoftDeleted }

        // Missing media: a live item claims a local file that isn't there.
        // Further split by whether `imageData` offers a recovery path —
        // see the Report fields' own doc comments for what B vs. C means.
        for item in liveItems {
            guard let filename = item.localFilename else { continue }
            if !FileManager.default.fileExists(atPath: MediaStore.shared.url(for: filename).path) {
                report.itemsWithMissingMedia.append(item.id)
                if item.imageData != nil {
                    report.itemsWithRecoverableMedia.append(item.id)
                } else {
                    report.itemsWithNoKnownRecovery.append(item.id)
                }
            }
        }

        // Orphaned media: a file on disk no item (live OR soft-deleted —
        // a soft-deleted item's media is still "claimed," just pending
        // eventual cleanup outside this scan's concern) references at all.
        let referencedFilenames = Set(items.compactMap(\.localFilename))
        if let diskFilenames = try? FileManager.default.contentsOfDirectory(atPath: MediaStore.shared.root.path) {
            report.orphanedMediaFilenames = diskFilenames.filter { !referencedFilenames.contains($0) }
        }

        // Legacy folder / membership disagreement.
        //
        // Multi-Device Consistency Foundation 01: for an item with 2+
        // simultaneously-active memberships (see
        // `itemsWithMultipleActiveFolders` above — confirmed to happen via
        // a real cross-device race), which one counts as "expected" here
        // must be picked deterministically. It previously read `.first` off
        // an array built via `Dictionary(grouping:)`, whose iteration order
        // is randomized per-process (Swift's Set/Dictionary hashing is
        // seeded per-launch) — so two devices scanning *identical* synced
        // data could each pick a different "first" folder and disagree on
        // this count for reasons that have nothing to do with their actual
        // data. Confirmed directly: two devices with matching
        // itemCount/folderCount/membershipCount/itemsWithMultipleActiveFolders
        // reported different folderMembershipDisagreements counts (16 vs.
        // 11) purely from this. Sorting by `createdAt` (earliest active
        // membership wins, tie-broken by `id`) makes the pick a pure
        // function of the data, not of process-local iteration order — a
        // diagnostic-only fix, no schema/sync change.
        let activeByItem = Dictionary(grouping: memberships.filter { !$0.isSoftDeleted && $0.folder?.isSoftDeleted == false }) { $0.item?.id }
        for item in liveItems {
            let activeMemberships = (activeByItem[item.id] ?? []).sorted {
                $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id.uuidString < $1.id.uuidString
            }
            let expectedLegacyFolderID = activeMemberships.first?.folder?.id
            if item.folder?.id != expectedLegacyFolderID {
                report.folderMembershipDisagreements.append(item.id)
            }
        }

        // Duplicate active memberships for the same (item, folder) pair.
        var seen = Set<String>()
        var duplicateKeys = Set<String>()
        for membership in memberships where !membership.isSoftDeleted {
            guard let itemID = membership.item?.id, let folderID = membership.folder?.id else { continue }
            let key = "\(itemID)|\(folderID)"
            if !seen.insert(key).inserted { duplicateKeys.insert(key) }
        }
        report.duplicateActiveMemberships = Array(duplicateKeys)

        // Items with active memberships to 2+ distinct folders at once.
        report.itemsWithMultipleActiveFolders = activeByItem.compactMap { itemID, rows in
            guard let itemID else { return nil }
            let distinctFolderIDs = Set(rows.compactMap { $0.folder?.id })
            return distinctFolderIDs.count > 1 ? itemID : nil
        }

        log(report)
        return report
    }

    private static func log(_ report: Report) {
        print("[IntegrityCheck] items=\(report.itemCount) folders=\(report.folderCount) memberships=\(report.membershipCount) — " +
            "missingMedia=\(report.itemsWithMissingMedia.count) (recoverable=\(report.itemsWithRecoverableMedia.count) " +
            "noKnownRecovery=\(report.itemsWithNoKnownRecovery.count)) orphanedMedia=\(report.orphanedMediaFilenames.count) " +
            "folderDisagreements=\(report.folderMembershipDisagreements.count) duplicateMemberships=\(report.duplicateActiveMemberships.count) " +
            "multiFolderItems=\(report.itemsWithMultipleActiveFolders.count) " +
            "— \(report.isClean ? "CLEAN" : "see counts above")")
    }
}
#endif
