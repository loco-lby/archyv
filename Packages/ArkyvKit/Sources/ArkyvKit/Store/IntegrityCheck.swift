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
        /// Live (non-deleted) items with a `localFilename` that has no
        /// corresponding file in `MediaStore` — content the app would
        /// currently render as a broken/placeholder image *right now*,
        /// on this device. Split further below by whether `imageData`
        /// (the CloudKit sync transport) offers a recovery path: this
        /// count alone doesn't distinguish "will self-heal on next
        /// access" from "no known way back."
        public var itemsWithMissingMedia: [UUID] = []
        /// Subset of `itemsWithMissingMedia` that has `imageData`
        /// populated — Recovery/Portability Foundation 01's category B
        /// ("temporarily unavailable"): `MediaStore.data(for:
        /// restoringFrom:)` (the same self-healing read `LocalImageView`
        /// already uses) can materialize the file from this the next
        /// time the item is opened. Nothing to do here; informational.
        public var itemsWithRecoverableMedia: [UUID] = []
        /// Subset of `itemsWithMissingMedia` with `imageData` also `nil`
        /// — category C ("no locally-known recovery path"). Not
        /// necessarily "permanently" lost: `imageData` may simply not
        /// have synced down from CloudKit yet, or (for an item that
        /// predates D3A) `ImageBackfill` may not have reached it yet —
        /// this scan has no way to distinguish those from genuine loss,
        /// which is exactly why it only ever reports, never deletes.
        public var itemsWithNoKnownRecovery: [UUID] = []
        /// Files physically present in `MediaStore`'s directory that no
        /// live *or* soft-deleted `StoredItem.localFilename` references —
        /// candidates for the "abandoned capture" cleanup discussed in the
        /// Data Integrity Contract, never auto-deleted here.
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

        public var isClean: Bool {
            itemsWithMissingMedia.isEmpty && orphanedMediaFilenames.isEmpty
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
        let activeByItem = Dictionary(grouping: memberships.filter { !$0.isSoftDeleted && $0.folder?.isSoftDeleted == false }) { $0.item?.id }
        for item in liveItems {
            let activeFolderIDs = (activeByItem[item.id] ?? []).compactMap { $0.folder?.id }
            let expectedLegacyFolderID = activeFolderIDs.first
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

        log(report)
        return report
    }

    private static func log(_ report: Report) {
        print("[IntegrityCheck] items=\(report.itemCount) folders=\(report.folderCount) memberships=\(report.membershipCount) — " +
            "missingMedia=\(report.itemsWithMissingMedia.count) (recoverable=\(report.itemsWithRecoverableMedia.count) " +
            "noKnownRecovery=\(report.itemsWithNoKnownRecovery.count)) orphanedMedia=\(report.orphanedMediaFilenames.count) " +
            "folderDisagreements=\(report.folderMembershipDisagreements.count) duplicateMemberships=\(report.duplicateActiveMemberships.count) " +
            "— \(report.isClean ? "CLEAN" : "see counts above")")
    }
}
#endif
