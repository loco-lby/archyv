import Foundation
import SwiftData

/// Single-Folder Invariant Foundation 01.
///
/// PRODUCT CONTRACT: a `StoredItem` may have zero active
/// `StoredFolderMembership` rows (Unfiled) or exactly one — never more.
/// `StoredFolderMembership` is the canonical relationship representation;
/// `StoredItem.folder` is a compatibility mirror that must always agree
/// with it, never an independent source of truth.
///
/// `Repository.setMemberships` already enforces this for every LOCAL
/// write in one process. It cannot enforce it across two devices: each
/// device's `setMemberships` call only reconciles rows it locally knows
/// about at call time, so two devices concurrently moving the same item
/// to two different folders can each successfully insert their own,
/// independent `StoredFolderMembership` CKRecord — CloudKit has no reason
/// to conflict two inserts of different records, so both sync down as
/// active everywhere (confirmed via Multi-Device Consistency Foundation
/// 01, and confirmed to already exist in the real archive — 11 items,
/// predating that testing).
///
/// This type is the reconciliation half: given a set of active
/// memberships that violates the invariant, it deterministically picks
/// one winner, deactivates the rest, and mirrors `item.folder` to match —
/// the same shape of "detect → correct → persist normally, let the
/// correction sync back through CloudKit" already used by
/// `setMemberships` itself, just applied after the fact instead of
/// before. No custom sync protocol, no schema change, no polling: the
/// correction is an ordinary local write like any other, and CloudKit's
/// existing last-writer-wins behavior propagates it exactly like any
/// other edit.
public enum FolderMembershipReconciler {
    /// Deterministically picks the winner among a set of active
    /// memberships for the same item: the most-recently-created row,
    /// tie-broken by `id` (largest `uuidString` wins) so the same input
    /// set always produces the same winner regardless of process, launch,
    /// or fetch order. Never depends on `Set`/`Dictionary` iteration
    /// order — the exact class of non-determinism found and fixed in
    /// `IntegrityCheck.folderMembershipDisagreements` last milestone.
    ///
    /// "Most recent wins" was chosen over an arbitrary/alphabetical
    /// tie-break because it matches ordinary last-writer-wins intuition
    /// (the newer decision reflects what the user most recently asked
    /// for) and, empirically, already agrees with `item.folder`'s
    /// independently-resolved CloudKit LWW value in 10 of the 11 real
    /// conflicted items found in the live archive — it's not an imposed
    /// rule so much as a formalization of what the data already mostly
    /// converged to on its own.
    public static func winner(among activeMemberships: [StoredFolderMembership]) -> StoredFolderMembership? {
        activeMemberships.max {
            $0.createdAt != $1.createdAt
                ? $0.createdAt < $1.createdAt
                : $0.id.uuidString < $1.id.uuidString
        }
    }

    public struct ReconciliationResult: Equatable {
        public let itemID: UUID
        public let winningFolderID: UUID?
        public let deactivatedMembershipIDs: [UUID]
        public let legacyFolderChanged: Bool
    }

    public struct Summary {
        public var itemsScanned = 0
        public var itemsReconciled: [ReconciliationResult] = []
    }

    /// Mutating. For every live item with 2+ active folder memberships,
    /// deactivates every membership except the deterministic `winner(among:)`
    /// and reconciles `item.folder` to match the winner's folder (`nil`
    /// if the winner is somehow already gone — defensive, not expected).
    /// Idempotent: an item already at 0 or 1 active membership is left
    /// completely untouched (not even `touch`ed/saved), so repeated calls
    /// against already-clean state are true no-ops — no sync churn merely
    /// to reaffirm already-correct state, and no two devices independently
    /// "reconciling" an already-single-winner item can never disagree,
    /// since there's nothing left to disagree about once one device's
    /// correction has synced.
    @discardableResult
    public static func reconcileAll(repository: Repository) throws -> Summary {
        var summary = Summary()
        let items = try repository.context.fetch(FetchDescriptor<StoredItem>())
        let liveItems = items.filter { !$0.isSoftDeleted }
        let allMemberships = try repository.context.fetch(FetchDescriptor<StoredFolderMembership>())
        let activeByItem = Dictionary(grouping: allMemberships.filter { !$0.isSoftDeleted && $0.folder?.isSoftDeleted == false }) { $0.item?.id }

        summary.itemsScanned = liveItems.count
        var touchedFolders: [UUID: StoredFolder] = [:]
        var anyChange = false

        for item in liveItems {
            let active = activeByItem[item.id] ?? []
            guard active.count > 1 else { continue }
            guard let winningMembership = winner(among: active) else { continue }

            var deactivatedIDs: [UUID] = []
            for membership in active where membership.id != winningMembership.id {
                membership.deletedAt = .now
                membership.dirty = true
                deactivatedIDs.append(membership.id)
                if let folder = membership.folder { touchedFolders[folder.id] = folder }
            }

            let legacyChanged = item.folder?.id != winningMembership.folder?.id
            if legacyChanged {
                item.folder = winningMembership.folder
            }
            if let folder = winningMembership.folder { touchedFolders[folder.id] = folder }

            item.updatedAt = .now
            item.dirty = true
            anyChange = true

            summary.itemsReconciled.append(ReconciliationResult(
                itemID: item.id,
                winningFolderID: winningMembership.folder?.id,
                deactivatedMembershipIDs: deactivatedIDs,
                legacyFolderChanged: legacyChanged
            ))
        }

        guard anyChange else { return summary }
        touchedFolders.values.forEach { $0.dirty = true; $0.updatedAt = .now }
        try repository.context.save()
        return summary
    }

    // MARK: - Read-only preview

    public struct MembershipSnapshot {
        public let membershipID: UUID
        public let folderID: UUID?
        public let folderName: String?
        public let createdAt: Date
    }

    public struct Preview {
        public let itemID: UUID
        public let currentLegacyFolderName: String?
        /// Sorted oldest-first, matching the ordering the winner rule reads.
        public let activeMemberships: [MembershipSnapshot]
        public let winningFolderName: String?
        public let membershipsToDeactivate: [MembershipSnapshot]
        public let resultingLegacyFolderName: String?
        public var wouldChangeVisibleFolder: Bool { currentLegacyFolderName != resultingLegacyFolderName }
    }

    /// READ-ONLY. Computes exactly what `reconcileAll` would do, for every
    /// live item currently violating the invariant, without mutating or
    /// saving anything. Exists so a real archive's proposed repair can be
    /// reviewed before `reconcileAll` ever runs against it.
    public static func preview(repository: Repository) throws -> [Preview] {
        let items = try repository.context.fetch(FetchDescriptor<StoredItem>())
        let liveItems = items.filter { !$0.isSoftDeleted }
        let allMemberships = try repository.context.fetch(FetchDescriptor<StoredFolderMembership>())
        let activeByItem = Dictionary(grouping: allMemberships.filter { !$0.isSoftDeleted && $0.folder?.isSoftDeleted == false }) { $0.item?.id }

        var previews: [Preview] = []
        for item in liveItems {
            let active = (activeByItem[item.id] ?? []).sorted { $0.createdAt < $1.createdAt }
            guard active.count > 1, let winningMembership = winner(among: active) else { continue }

            let snapshots = active.map {
                MembershipSnapshot(membershipID: $0.id, folderID: $0.folder?.id, folderName: $0.folder?.name, createdAt: $0.createdAt)
            }
            let toDeactivate = snapshots.filter { $0.membershipID != winningMembership.id }

            previews.append(Preview(
                itemID: item.id,
                currentLegacyFolderName: item.folder?.name,
                activeMemberships: snapshots,
                winningFolderName: winningMembership.folder?.name,
                membershipsToDeactivate: toDeactivate,
                resultingLegacyFolderName: winningMembership.folder?.name
            ))
        }
        return previews
    }
}
