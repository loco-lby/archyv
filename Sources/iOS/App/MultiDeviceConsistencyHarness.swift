import Foundation
import SwiftData
import UIKit
import ArkyvKit

#if DEBUG
/// Multi-Device Consistency Foundation 01: a scripted, on-device harness
/// for exercising real SwiftData/CloudKit sync-conflict behavior across
/// Sammy's two physical devices. Deliberately operates on the REAL,
/// on-disk, CloudKit-backed container (`ArkyvApp`'s own `modelContainer`)
/// — not an isolated one — because the entire point of this milestone is
/// observing real cross-device merge behavior, which an isolated
/// `cloudKitDatabase: .none` container cannot exercise at all.
///
/// Every test Cherry/folder this creates is clearly, deterministically
/// tagged (`Self.testTag`) so it's trivially identifiable and safe to
/// manually delete afterward — never touches or resembles real existing
/// archive content. Every mutation goes through the exact same
/// `Repository` methods any real UI action would call — this is a
/// faithful exercise of the real persistence/sync layer, not a mock.
///
/// Triggered via `--arkyv-mdc <action>` (two separate launch arguments —
/// see `ArkyvApp.body`). Actions target "the test Cherry" — the most
/// recently created live item carrying `Self.testTag` — so no UUID needs
/// to be threaded through launch arguments across separate process
/// launches.
enum MultiDeviceConsistencyHarness {
    static let testTag = "mdc-test"

    static func run(action: String, container: ModelContainer) async {
        let context = ModelContext(container)
        let repo = Repository(context: context)
        print("[MDC] action=\(action)")
        do {
            switch action {
            case "container-paths":
                // Technical Identity Cutover 01, Section 9: read-only,
                // paths/identifiers only — never prints Cherry contents.
                print("[MDC] AppGroup.identifier=\(AppGroup.identifier)")
                print("[MDC] AppGroup.containerURL=\(AppGroup.containerURL.path)")
                print("[MDC] storeURL=\(AppGroup.containerURL.appendingPathComponent("arkyv.store").path)")
                print("[MDC] mediaRoot=\(MediaStore.shared.root.path)")
            case "create":
                try create(repo: repo)
            case "report":
                try report(repo: repo)
            case "favorite-true":
                try withTestItem(repo: repo) { try repo.toggleFavoriteTo(true, item: $0) }
            case "favorite-false":
                try withTestItem(repo: repo) { try repo.toggleFavoriteTo(false, item: $0) }
            case "note-a":
                try withTestItem(repo: repo) { try repo.updateNote($0, body: "NOTE-FROM-DEVICE-A") }
            case "note-b":
                try withTestItem(repo: repo) { try repo.updateNote($0, body: "NOTE-FROM-DEVICE-B") }
            case "source-a":
                try withTestItem(repo: repo) { try repo.updateSourceURL($0, to: "https://device-a.example.com") }
            case "source-b":
                try withTestItem(repo: repo) { try repo.updateSourceURL($0, to: "https://device-b.example.com") }
            case "tag-add-b":
                try withTestItem(repo: repo) { try repo.updateTags($0, to: $0.tags + ["tagB"]) }
            case "tag-add-c":
                try withTestItem(repo: repo) { try repo.updateTags($0, to: $0.tags + ["tagC"]) }
            case "tag-add-d":
                try withTestItem(repo: repo) { try repo.updateTags($0, to: $0.tags + ["tagD"]) }
            case "tag-remove-a":
                try withTestItem(repo: repo) { try repo.updateTags($0, to: $0.tags.filter { $0 != "tagA" }) }
            case "folder-a":
                let folder = try findOrCreateFolder(repo: repo, name: "MDC Folder A")
                try withTestItem(repo: repo) { try repo.move($0, to: folder) }
            case "folder-b":
                let folder = try findOrCreateFolder(repo: repo, name: "MDC Folder B")
                try withTestItem(repo: repo) { try repo.move($0, to: folder) }
            case "folder-unfiled":
                try withTestItem(repo: repo) { item in
                    item.folder = nil
                    try repo.setMemberships(item, to: [])
                }
            case "folder-delete-x":
                let folder = try findOrCreateFolder(repo: repo, name: "MDC Folder X")
                try repo.softDelete(folder)
                print("[MDC] deleted Folder X")
            case "folder-move-x":
                let folder = try findOrCreateFolder(repo: repo, name: "MDC Folder X")
                try withTestItem(repo: repo) { try repo.move($0, to: folder) }
            case "crop-a":
                try withTestItem(repo: repo) { try repo.updateCropRegion($0, to: CropRegion(x: 0.1, y: 0.1, width: 0.4, height: 0.4)) }
            case "crop-b":
                try withTestItem(repo: repo) { try repo.updateCropRegion($0, to: CropRegion(x: 0.3, y: 0.3, width: 0.5, height: 0.5)) }
            case "soft-delete":
                try withTestItem(repo: repo) { try repo.softDelete($0) }
            case "create-folder-collision":
                let folder = try repo.createFolder(name: "MDC Collision", icon: .symbol("star"))
                print("[MDC] created folder id=\(folder.id) name=\(folder.name)")
            case "evict-and-reconstruct-cache":
                try await withTestItem(repo: repo) { item in
                    guard let filename = item.localFilename else { print("[MDC] no localFilename"); return }
                    MediaStore.shared.delete(filename: filename)
                    let fallback = item.imageData
                    let reconstructed = await MediaStore.shared.data(for: filename, reconstructingFrom: { fallback })
                    print("[MDC] evicted+reconstructed cache file, bytes=\(reconstructed?.count ?? -1)")
                }
            case "batch-edit":
                try batchEdit(repo: repo)
            case "delete-proven-empty-seed-duplicates":
                // Post-Migration Folder Reconciliation 01: MUTATING.
                // Hardcoded, one-time list — proven via list-all-folders
                // (dirty=false, zero memberships/pointers) and cross-checked
                // against the migration manifest (absent) before this ran.
                // Deliberately NOT a general dedup tool — see this
                // milestone's own scope note.
                let seedDuplicateIDs: [UUID] = [
                    UUID(uuidString: "5CC899B6-79C1-46A3-A9F4-783D3DF184FC")!, // Cool Shit (seeded)
                    UUID(uuidString: "431CD4F1-BD44-477E-BD28-DF4E898C2C2F")!, // Deadwest (seeded)
                    UUID(uuidString: "929F2869-55F9-48FB-A3F0-2FD8DF774C9C")!, // Inspiration (seeded)
                    UUID(uuidString: "BCCD76CD-A9AC-4EEC-9ECF-F679433B29CA")!, // Japan 2026 (seeded)
                    UUID(uuidString: "BED2C1BD-5527-4474-B98B-1B6670336747")!, // Recipes (seeded)
                ]
                let allFolders = try repo.folders(includingDeleted: true)
                for id in seedDuplicateIDs {
                    guard let folder = allFolders.first(where: { $0.id == id }) else {
                        print("[MDC] SKIP: folder \(id) not found")
                        continue
                    }
                    guard !folder.dirty, folder.referenceCount == 0 else {
                        print("[MDC] REFUSING to delete \(id) (\(folder.name)) — safety check failed: dirty=\(folder.dirty) referenceCount=\(folder.referenceCount)")
                        continue
                    }
                    try repo.softDelete(folder)
                    print("[MDC] deleted seeded duplicate id=\(id) name=\(folder.name)")
                }
            case "delete-proven-test-residue":
                // Pre-Sync Test Residue Cleanup 01: MUTATING. Hardcoded,
                // one-time list — proven via audit-test-residue: every
                // folder is a zero-relationship exact match to this
                // harness's own hardcoded name literals; every item is
                // mdc-test-tagged, exactly 35520 bytes (this harness's
                // synthetic pink JPEG), Unfiled. Explicitly does NOT
                // include the "Test" folder or its members — confirmed
                // real user content (varying multi-hundred-KB/multi-MB
                // sizes, real camera/screenshot dimensions, zero test
                // tags) — nor the two already-soft-deleted "MDC Folder X"
                // rows, which need no further action.
                let residueFolderIDs: [UUID] = [
                    UUID(uuidString: "44135517-F45B-4D6D-98EF-33F00731E834")!, // MDC Folder A
                    UUID(uuidString: "AEC87555-F949-4FA2-94C3-22FD2BF3CFA0")!, // MDC Folder B
                    UUID(uuidString: "8355FF8A-36E7-4C3F-A7BA-53FE24421777")!, // MDC Collision
                    UUID(uuidString: "AA5D7891-C372-4CF8-9B37-1332C1A198EC")!, // MDC Collision
                ]
                let residueItemIDs: [UUID] = [
                    UUID(uuidString: "03B19185-3271-48E2-9158-F0897B8BC63C")!,
                    UUID(uuidString: "33A146EA-B6A3-4493-BF9B-23360B359EC6")!,
                    UUID(uuidString: "104B83AC-AF02-4359-8753-9B985BAE1BF9")!,
                    UUID(uuidString: "943BD6D9-1197-450E-866A-E852C3496854")!,
                    UUID(uuidString: "DB668520-A9A8-4B60-9229-69F47127AC1B")!, // CUTOVER-TEST item
                ]
                let allFolders = try repo.folders(includingDeleted: true)
                for id in residueFolderIDs {
                    guard let folder = allFolders.first(where: { $0.id == id }) else {
                        print("[MDC] SKIP folder: \(id) not found"); continue
                    }
                    guard folder.referenceCount == 0 else {
                        print("[MDC] REFUSING to delete folder \(id) (\(folder.name)) — referenceCount=\(folder.referenceCount)"); continue
                    }
                    try repo.softDelete(folder)
                    print("[MDC] deleted residue folder id=\(id) name=\(folder.name)")
                }
                let allItems = try repo.context.fetch(FetchDescriptor<StoredItem>())
                for id in residueItemIDs {
                    guard let item = allItems.first(where: { $0.id == id }) else {
                        print("[MDC] SKIP item: \(id) not found"); continue
                    }
                    guard item.tags.contains(testTag), item.imageData?.count == 35520 else {
                        print("[MDC] REFUSING to delete item \(id) — safety check failed: tags=\(item.tags) bytes=\(item.imageData?.count ?? -1)"); continue
                    }
                    try repo.softDelete(item)
                    print("[MDC] deleted residue item id=\(id)")
                }
            case "audit-test-residue":
                // Pre-Sync Test Residue Cleanup 01: READ-ONLY. Full detail
                // on every mdc-test-tagged item (regardless of which
                // folder) and every member of any folder named "Test" or
                // prefixed "MDC" — including soft-deleted rows, for a
                // complete picture before any classification/deletion.
                try auditTestResidue(repo: repo)
            case "list-all-folders":
                // Post-Migration Folder Reconciliation 01: READ-ONLY. Full
                // detail on every StoredFolder, including soft-deleted —
                // enough to distinguish SeedGate defaults (dirty=false,
                // never touched by importArchive) from imported legacy
                // folders (dirty=true) without inferring from name alone.
                try listAllFolders(repo: repo)
            case "integrity-check":
                let checkReport = IntegrityCheck.run(context: context)
                print("[MDC] IntegrityCheck: isClean=\(checkReport.isClean) itemCount=\(checkReport.itemCount) folderCount=\(checkReport.folderCount) membershipCount=\(checkReport.membershipCount) missingMedia=\(checkReport.itemsWithMissingMedia.count) noKnownRecovery=\(checkReport.itemsWithNoKnownRecovery.count) orphanedMedia=\(checkReport.orphanedMediaFilenames.count) folderDisagreements=\(checkReport.folderMembershipDisagreements.count) duplicateMemberships=\(checkReport.duplicateActiveMemberships.count) multiFolderItems=\(checkReport.itemsWithMultipleActiveFolders.count)")
            case "inspect-multi-folder":
                // Single-Folder Invariant Foundation 01, Section 12:
                // READ-ONLY. Reports full identity/context for every item
                // IntegrityCheck flags as having 2+ active folder
                // memberships, so real archive items can be told apart from
                // MDC-test fixtures before any reconciliation is written or
                // run. Never mutates.
                try inspectMultiFolderItems(repo: repo)
            case "reconcile-folders":
                // Single-Folder Invariant Foundation 01: MUTATING. Directly
                // invokes the same FolderMembershipReconciler.reconcileAll
                // that RootView's foreground-activation hook calls in
                // production — exposed here as a controllable, on-demand
                // trigger for deterministic two-device test timing.
                let summary = try FolderMembershipReconciler.reconcileAll(repository: repo)
                print("[MDC] reconcile-folders: scanned=\(summary.itemsScanned) reconciled=\(summary.itemsReconciled.count)")
                for result in summary.itemsReconciled {
                    print("[MDC]   item=\(result.itemID) winner=\(result.winningFolderID?.uuidString ?? "nil") deactivated=\(result.deactivatedMembershipIDs.count) legacyFolderChanged=\(result.legacyFolderChanged)")
                }
            case "inspect-folder-disagreements":
                // Single-Folder Invariant Foundation 01: READ-ONLY.
                // itemsWithMultipleActiveFolders dropped to 0 after
                // reconciliation, but folderMembershipDisagreements did
                // not reach 0 — this characterizes the remaining
                // disagreements, which by definition now involve items
                // with 0 or 1 active membership (not the race
                // FolderMembershipReconciler targets).
                let checkReport = IntegrityCheck.run(context: context)
                print("[MDC] --- inspect-folder-disagreements: \(checkReport.folderMembershipDisagreements.count) item(s) ---")
                let allItems = try context.fetch(FetchDescriptor<StoredItem>())
                for itemID in checkReport.folderMembershipDisagreements {
                    guard let item = allItems.first(where: { $0.id == itemID }) else { continue }
                    let activeMemberships = (try? repo.memberships(for: item)) ?? []
                    print("[MDC] item id=\(item.id) tags=\(item.tags) legacyFolder=\(item.folder?.name ?? "nil") legacyFolderDeleted=\(item.folder?.isSoftDeleted ?? false) activeMembershipCount=\(activeMemberships.count) activeMembershipFolders=\(activeMemberships.map { $0.folder?.name ?? "nil" })")
                }
                print("[MDC] --- end inspect-folder-disagreements ---")
            case "preview-folder-reconciliation":
                // Single-Folder Invariant Foundation 01, Section 3/12:
                // READ-ONLY. Computes exactly what
                // FolderMembershipReconciler.reconcileAll would do,
                // without calling it — never mutates or saves anything.
                try previewFolderReconciliation(repo: repo)
            default:
                print("[MDC] unknown action: \(action)")
            }
        } catch {
            print("[MDC] action FAILED: \(error)")
        }
        // A real, load-bearing finding from this milestone's own testing,
        // not a cosmetic delay: exiting immediately after a local write
        // gives CloudKit's background export operation no time to
        // actually transmit before the process dies, which can leave a
        // genuinely-committed local edit sitting unsynced far longer than
        // expected — see the "quick-exit-after-write" finding in the
        // final report. `report`/read-only actions skip the wait, since
        // they have nothing to flush.
        if action != "report" && action != "integrity-check" && action != "container-paths" && action != "list-all-folders" && action != "audit-test-residue" {
            print("[MDC] waiting 5s before exit to give CloudKit export a fair chance to flush...")
            try? await Task.sleep(for: .seconds(5))
        }
        // One-shot process, matching the established stress-tool pattern
        // (ImageCacheStressTest et al.) — each `--arkyv-mdc <action>`
        // launch is a single discrete operation, not a long-running
        // session, so exiting cleanly here lets the orchestrating script
        // wait on natural process termination instead of blocking forever
        // on `devicectl --console`.
        exit(0)
    }

    // MARK: - Test Cherry lifecycle

    private static func create(repo: Repository) throws {
        let size = CGSize(width: 400, height: 600)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.systemPink.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        guard let saved = try? MediaStore.shared.save(image: image) else {
            print("[MDC] failed to save synthetic test image")
            return
        }
        let draft = CaptureDraft(kind: .screenshot, localFilename: saved.filename, pixelSize: saved.size, tags: ["tagA", testTag], sourceDevice: .iOS)
        let item = try repo.fileCapture(draft)
        print("[MDC] created test item id=\(item.id) localFilename=\(item.localFilename ?? "nil") imageDataBytes=\(item.imageData?.count ?? -1)")
    }

    /// Finds the most recently created LIVE item carrying `testTag`.
    private static func latestTestItem(repo: Repository) throws -> StoredItem? {
        let descriptor = FetchDescriptor<StoredItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let items = try repo.context.fetch(descriptor)
        return items.first { !$0.isSoftDeleted && $0.tags.contains(testTag) }
    }

    private static func withTestItem(repo: Repository, _ body: (StoredItem) throws -> Void) throws {
        guard let item = try latestTestItem(repo: repo) else {
            print("[MDC] no live test item found — run `create` first")
            return
        }
        try body(item)
    }

    private static func withTestItem(repo: Repository, _ body: (StoredItem) async throws -> Void) async throws {
        guard let item = try latestTestItem(repo: repo) else {
            print("[MDC] no live test item found — run `create` first")
            return
        }
        try await body(item)
    }

    private static func findOrCreateFolder(repo: Repository, name: String) throws -> StoredFolder {
        if let existing = try repo.folders().first(where: { $0.name == name }) {
            return existing
        }
        return try repo.createFolder(name: name, icon: .symbol("star"))
    }

    /// Section 16: a realistic offline batch across several distinct
    /// items — creates 3 fresh test items and edits each differently in
    /// one call, so a single `--arkyv-mdc batch-edit` launch (while
    /// offline) produces a representative multi-item offline session.
    private static func batchEdit(repo: Repository) throws {
        for i in 0..<3 {
            let size = CGSize(width: 300, height: 400)
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { ctx in
                UIColor(hue: CGFloat(i) / 3, saturation: 0.7, brightness: 0.8, alpha: 1).setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
            }
            guard let saved = try? MediaStore.shared.save(image: image) else { continue }
            let draft = CaptureDraft(kind: .screenshot, localFilename: saved.filename, pixelSize: saved.size, tags: [testTag, "batch-\(i)"], sourceDevice: .iOS)
            let item = try repo.fileCapture(draft)
            try repo.updateNote(item, body: "batch note \(i)")
            if i == 0 { try repo.toggleFavorite(item) }
            print("[MDC] batch-created item \(i) id=\(item.id)")
        }
    }

    // MARK: - Single-Folder Invariant Foundation 01

    /// READ-ONLY. For every item `IntegrityCheck` flags with 2+ active
    /// folder memberships, prints its tags, legacy `folder`, and every
    /// active membership (folder name + membership `createdAt`, sorted
    /// oldest-first — the same ordering a deterministic "earliest wins"
    /// reconciliation rule would use) so real archive items can be told
    /// apart from `mdc-test`-tagged fixtures before any repair is written.
    private static func inspectMultiFolderItems(repo: Repository) throws {
        let checkReport = IntegrityCheck.run(context: repo.context)
        print("[MDC] --- inspect-multi-folder: \(checkReport.itemsWithMultipleActiveFolders.count) item(s) ---")
        let descriptor = FetchDescriptor<StoredItem>()
        let allItems = try repo.context.fetch(descriptor)
        for itemID in checkReport.itemsWithMultipleActiveFolders {
            guard let item = allItems.first(where: { $0.id == itemID }) else { continue }
            let isTestFixture = item.tags.contains(testTag)
            print("[MDC] item id=\(item.id) isMDCTestFixture=\(isTestFixture)")
            print("[MDC]   tags=\(item.tags) legacyFolder=\(item.folder?.name ?? "nil") createdAt=\(item.createdAt)")
            let activeMemberships = (try? repo.memberships(for: item))?.sorted { $0.createdAt < $1.createdAt } ?? []
            for membership in activeMemberships {
                print("[MDC]   membership folder=\(membership.folder?.name ?? "nil") membershipCreatedAt=\(membership.createdAt) membershipID=\(membership.id)")
            }
        }
        print("[MDC] --- end inspect-multi-folder ---")
    }

    /// READ-ONLY. Prints the exact before/after `FolderMembershipReconciler`
    /// proposes for every item currently violating the single-folder
    /// invariant — never calls `reconcileAll`, never mutates anything.
    private static func previewFolderReconciliation(repo: Repository) throws {
        let previews = try FolderMembershipReconciler.preview(repository: repo)
        print("[MDC] --- preview-folder-reconciliation: \(previews.count) item(s) ---")
        for preview in previews {
            print("[MDC] item id=\(preview.itemID)")
            print("[MDC]   currentLegacyFolder=\(preview.currentLegacyFolderName ?? "nil (Unfiled)")")
            for m in preview.activeMemberships {
                print("[MDC]   activeMembership folder=\(m.folderName ?? "nil") createdAt=\(m.createdAt) membershipID=\(m.membershipID)")
            }
            print("[MDC]   proposedWinner=\(preview.winningFolderName ?? "nil")")
            for m in preview.membershipsToDeactivate {
                print("[MDC]   wouldDeactivate folder=\(m.folderName ?? "nil") membershipID=\(m.membershipID)")
            }
            print("[MDC]   resultingLegacyFolder=\(preview.resultingLegacyFolderName ?? "nil (Unfiled)") wouldChangeVisibleFolder=\(preview.wouldChangeVisibleFolder)")
        }
        print("[MDC] --- end preview-folder-reconciliation ---")
    }

    // MARK: - Report

    private static func report(repo: Repository) throws {
        let descriptor = FetchDescriptor<StoredItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let items = try repo.context.fetch(descriptor).filter { $0.tags.contains(testTag) }
        print("[MDC] --- report: \(items.count) test item(s) ---")
        for item in items {
            let folderName = item.folder?.name ?? "Unfiled"
            let memberships = (try? repo.folders(for: item).map(\.name)) ?? []
            print("[MDC] item id=\(item.id)")
            print("[MDC]   localFilename=\(item.localFilename ?? "nil") imageDataBytes=\(item.imageData?.count ?? -1)")
            print("[MDC]   legacyFolder=\(folderName) memberships=\(memberships)")
            print("[MDC]   isFavorite=\(item.isFavorite) noteBody=\(item.noteBody ?? "nil") sourceURL=\(item.sourceURL ?? "nil")")
            print("[MDC]   tags=\(item.tags) cropRegion=\(item.cropRegion.rect)")
            print("[MDC]   isSoftDeleted=\(item.isSoftDeleted) deletedAt=\(item.deletedAt?.description ?? "nil")")
            print("[MDC]   createdAt=\(item.createdAt) updatedAt=\(item.updatedAt)")
        }
        let folders = try repo.folders(includingDeleted: true).filter { $0.name.hasPrefix("MDC") }
        for folder in folders {
            print("[MDC] folder id=\(folder.id) name=\(folder.name) isSoftDeleted=\(folder.isSoftDeleted) referenceCount=\(folder.referenceCount)")
        }
        print("[MDC] --- end report ---")
    }

    // MARK: - Post-Migration Folder Reconciliation 01

    /// READ-ONLY. Every `StoredFolder` (including soft-deleted), with
    /// enough detail to distinguish a SeedGate default from an imported
    /// legacy folder without inferring from name alone: `dirty` (SeedGate
    /// explicitly sets `false`; `importArchive` never touches it, so it
    /// stays at the constructor default `true`), active/total membership
    /// counts, and how many live items' legacy `item.folder` points at it.
    private static func listAllFolders(repo: Repository) throws {
        let allFolders = try repo.folders(includingDeleted: true)
        let allMemberships = try repo.context.fetch(FetchDescriptor<StoredFolderMembership>())
        let allItems = try repo.context.fetch(FetchDescriptor<StoredItem>())
        print("[MDC] --- list-all-folders: \(allFolders.count) folder(s) ---")
        for folder in allFolders.sorted(by: { $0.name == $1.name ? $0.createdAt < $1.createdAt : $0.name < $1.name }) {
            let membershipsForFolder = allMemberships.filter { $0.folder?.id == folder.id }
            let activeMemberships = membershipsForFolder.filter { !$0.isSoftDeleted }
            let legacyPointerCount = allItems.filter { $0.folder?.id == folder.id && !$0.isSoftDeleted }.count
            print("[MDC] folder id=\(folder.id) name=\"\(folder.name)\"")
            print("[MDC]   dirty=\(folder.dirty) isSoftDeleted=\(folder.isSoftDeleted) sortOrder=\(folder.sortOrder)")
            print("[MDC]   createdAt=\(folder.createdAt) updatedAt=\(folder.updatedAt)")
            print("[MDC]   activeMemberships=\(activeMemberships.count) totalMemberships=\(membershipsForFolder.count) legacyItemFolderPointers=\(legacyPointerCount)")
        }
        print("[MDC] --- end list-all-folders ---")
    }

    // MARK: - Pre-Sync Test Residue Cleanup 01

    /// READ-ONLY. Full detail on every `mdc-test`-tagged item (any
    /// folder, including soft-deleted) and every member — tagged or not
    /// — of any folder named "Test" or prefixed "MDC", so a folder with
    /// unexpected real content is caught rather than assumed empty.
    private static func auditTestResidue(repo: Repository) throws {
        let allItems = try repo.context.fetch(FetchDescriptor<StoredItem>())
        let allFolders = try repo.folders(includingDeleted: true)
        let allMemberships = try repo.context.fetch(FetchDescriptor<StoredFolderMembership>())

        let taggedItems = allItems.filter { $0.tags.contains(testTag) }
        print("[MDC] --- audit: \(taggedItems.count) mdc-test-tagged item(s) ---")
        for item in taggedItems.sorted(by: { $0.createdAt < $1.createdAt }) {
            let memberships = (try? repo.folders(for: item).map(\.name)) ?? []
            print("[MDC] item id=\(item.id) legacyFolder=\(item.folder?.name ?? "Unfiled") memberships=\(memberships)")
            print("[MDC]   tags=\(item.tags) title=\(item.title ?? "nil") noteBody=\(item.noteBody ?? "nil")")
            print("[MDC]   hasImageData=\(item.imageData != nil) imageDataBytes=\(item.imageData?.count ?? -1) localFilename=\(item.localFilename ?? "nil")")
            print("[MDC]   isSoftDeleted=\(item.isSoftDeleted) createdAt=\(item.createdAt)")
        }

        let suspectFolders = allFolders.filter { $0.name == "Test" || $0.name.hasPrefix("MDC") }
        print("[MDC] --- audit: \(suspectFolders.count) suspect folder(s) (name==Test or prefix MDC) ---")
        for folder in suspectFolders.sorted(by: { $0.createdAt < $1.createdAt }) {
            let members = allMemberships.filter { $0.folder?.id == folder.id && !$0.isSoftDeleted }
            print("[MDC] folder id=\(folder.id) name=\"\(folder.name)\" isSoftDeleted=\(folder.isSoftDeleted) createdAt=\(folder.createdAt) activeMembers=\(members.count)")
            for membership in members {
                guard let item = membership.item else { continue }
                print("[MDC]   member item id=\(item.id) tags=\(item.tags) isMDCTagged=\(item.tags.contains(testTag)) title=\(item.title ?? "nil") createdAt=\(item.createdAt) hasImageData=\(item.imageData != nil)")
            }
        }
        print("[MDC] --- end audit ---")
    }
}

extension Repository {
    /// Explicit set-to-value (not toggle) — needed so two devices can each
    /// deterministically drive the SAME target value without needing to
    /// know the field's current state first.
    fileprivate func toggleFavoriteTo(_ value: Bool, item: StoredItem) throws {
        if item.isFavorite != value {
            try toggleFavorite(item)
        }
    }
}
#endif
