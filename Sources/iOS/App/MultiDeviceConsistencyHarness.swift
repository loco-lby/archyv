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
            case "integrity-check":
                let checkReport = IntegrityCheck.run(context: context)
                print("[MDC] IntegrityCheck: isClean=\(checkReport.isClean) itemCount=\(checkReport.itemCount) folderCount=\(checkReport.folderCount) membershipCount=\(checkReport.membershipCount) missingMedia=\(checkReport.itemsWithMissingMedia.count) noKnownRecovery=\(checkReport.itemsWithNoKnownRecovery.count) orphanedMedia=\(checkReport.orphanedMediaFilenames.count) folderDisagreements=\(checkReport.folderMembershipDisagreements.count) duplicateMemberships=\(checkReport.duplicateActiveMemberships.count) multiFolderItems=\(checkReport.itemsWithMultipleActiveFolders.count)")
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
        if action != "report" && action != "integrity-check" {
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
