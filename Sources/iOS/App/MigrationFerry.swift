import Foundation
import SwiftData
import CryptoKit
import ArkyvKit

#if DEBUG
/// Pre-Launch Migration Ferry 01: a DEBUG-only, on-device proof that
/// `CherryManifest.export`/`importArchive` can faithfully reconstruct
/// Sammy's real archive into a completely isolated store, before any
/// technical-identity cutover is attempted for real.
///
/// Deliberately mirrors `MultiDeviceConsistencyHarness`'s own posture:
/// the EXPORT half reads the real, on-disk, CloudKit-backed container
/// (`ArkyvApp`'s own `modelContainer`) — read-only, never mutates it —
/// because the whole point is proving reconstruction of Sammy's actual
/// data, not synthetic data. The IMPORT half only ever writes into a
/// fresh, isolated, in-memory `ModelContainer` (`cloudKitDatabase: .none`)
/// that never touches the real App Group or CloudKit container. The
/// migration artifact itself is written to this app's own Documents
/// directory — NOT the App Group — so it's trivially distinguishable
/// from real archive storage and never at risk of being confused with it.
///
/// Triggered via `--arkyv-migration <action>` — see `ArkyvApp.body`.
enum MigrationFerry {
    static func run(action: String, realContainer: ModelContainer) async {
        print("[Ferry] action=\(action)")
        do {
            switch action {
            case "full-cycle":
                try await runFullCycle(realContainer: realContainer)
            case "import-real-archive":
                // Real Archive Import 01: MUTATING, and the one action in
                // this file that writes into the REAL container — every
                // other action here is read-only against it. Reads the
                // verified migration artifact from this app's own
                // Documents directory (pushed there via `devicectl copy
                // to` ahead of this call — never the App Group, never
                // CloudKit directly) and imports it through
                // CherryManifest.importArchive's identity-collision-safe
                // path.
                try importRealArchive(realContainer: realContainer)
            case "verify-real-archive":
                try verifyRealArchive(realContainer: realContainer)
            default:
                print("[Ferry] unknown action: \(action)")
            }
        } catch {
            print("[Ferry] action FAILED: \(error)")
        }
        exit(0)
    }

    // MARK: - Full cycle: export real archive -> disk -> isolated import -> compare

    private static func runFullCycle(realContainer: ModelContainer) async throws {
        let realContext = ModelContext(realContainer)

        // 1. EXPORT (read-only against the real container).
        let exportStart = Date()
        let archive = try CherryManifest.export(context: realContext)
        let json = try CherryManifest.encodeJSON(archive)
        let exportDuration = Date().timeIntervalSince(exportStart)

        let artifactURL = migrationArtifactURL()
        try json.write(to: artifactURL, options: .atomic)
        let checksum = SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined()

        printSourceInventory(archive, jsonByteCount: json.count, checksum: checksum, exportDuration: exportDuration, artifactURL: artifactURL)

        // 2. Read the artifact back from disk (genuine round-trip through
        // the filesystem, not an in-memory shortcut) and decode it.
        let rereadJSON = try Data(contentsOf: artifactURL)
        guard rereadJSON == json else {
            print("[Ferry] FATAL: artifact re-read from disk does not match what was written — aborting before import")
            return
        }
        let decodedArchive = try CherryManifest.decodeJSON(rereadJSON)

        // 3. IMPORT into a fresh, fully isolated in-memory store — never
        // the real App Group, never any CloudKit container.
        let isolatedContainer = ArkyvStore.makeModelContainer(inMemory: true)
        let isolatedContext = ModelContext(isolatedContainer)

        let importStart = Date()
        let residentBefore = residentMemoryMB()
        let summary = try CherryManifest.importArchive(decodedArchive, into: isolatedContext)
        let residentAfter = residentMemoryMB()
        let importDuration = Date().timeIntervalSince(importStart)

        print("[Ferry] import complete: folders=\(summary.foldersImported) items=\(summary.itemsImported) memberships=\(summary.membershipsImported) imageDataBytes=\(summary.totalImageDataBytes)")
        print("[Ferry] export took \(String(format: "%.2f", exportDuration))s, import took \(String(format: "%.2f", importDuration))s, resident memory before=\(String(format: "%.1f", residentBefore))MB after=\(String(format: "%.1f", residentAfter))MB")

        // 4. Round-trip comparison: SOURCE (re-fetched fresh from the real
        // container) vs. IMPORTED (isolated container).
        try compare(sourceArchive: decodedArchive, isolatedContext: isolatedContext)

        // 5. IntegrityCheck against the reconstructed isolated archive.
        let report = IntegrityCheck.run(context: isolatedContext)
        print("[Ferry] IntegrityCheck (isolated): isClean=\(report.isClean) itemsWithMultipleActiveFolders=\(report.itemsWithMultipleActiveFolders.count) folderMembershipDisagreements=\(report.folderMembershipDisagreements.count) duplicateActiveMemberships=\(report.duplicateActiveMemberships.count) itemsWithNoKnownRecovery=\(report.itemsWithNoKnownRecovery.count)")

        // 6. Confirm the real container is untouched: re-fetch counts and
        // compare against the export snapshot taken in step 1.
        let postItems = try realContext.fetch(FetchDescriptor<StoredItem>()).count
        let postFolders = try realContext.fetch(FetchDescriptor<StoredFolder>()).count
        print("[Ferry] real-archive sanity: itemCount before=\(archive.items.count) after=\(postItems), folderCount before=\(archive.folders.count) after=\(postFolders) — \(postItems == archive.items.count && postFolders == archive.folders.count ? "UNCHANGED" : "MISMATCH — investigate")")
    }

    // MARK: - Real import (Real Archive Import 01)

    private static func importRealArchive(realContainer: ModelContainer) throws {
        let artifactURL = migrationArtifactURL()
        guard FileManager.default.fileExists(atPath: artifactURL.path) else {
            print("[Ferry] FATAL: migration artifact not found at \(artifactURL.path) — push it via `devicectl device copy to` first")
            return
        }
        let json = try Data(contentsOf: artifactURL)
        let checksum = SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined()
        print("[Ferry] artifact: path=\(artifactURL.path) jsonBytes=\(json.count) sha256=\(checksum)")

        let archive = try CherryManifest.decodeJSON(json)
        printSourceInventory(archive, jsonByteCount: json.count, checksum: checksum, exportDuration: 0, artifactURL: artifactURL)

        let realContext = ModelContext(realContainer)
        let preExistingItems = try realContext.fetch(FetchDescriptor<StoredItem>())
        let preExistingFolders = try realContext.fetch(FetchDescriptor<StoredFolder>())
        print("[Ferry] pre-import destination state: items=\(preExistingItems.count) folders=\(preExistingFolders.count)")

        let importStart = Date()
        let summary = try CherryManifest.importArchive(archive, into: realContext)
        let importDuration = Date().timeIntervalSince(importStart)
        print("[Ferry] IMPORT SUCCEEDED: folders=\(summary.foldersImported) items=\(summary.itemsImported) memberships=\(summary.membershipsImported) imageDataBytes=\(summary.totalImageDataBytes) duration=\(String(format: "%.2f", importDuration))s")

        try compare(sourceArchive: archive, isolatedContext: realContext)

        let report = IntegrityCheck.run(context: realContext)
        print("[Ferry] IntegrityCheck (post-import, real container): isClean=\(report.isClean) itemsWithMultipleActiveFolders=\(report.itemsWithMultipleActiveFolders.count) folderMembershipDisagreements=\(report.folderMembershipDisagreements.count) duplicateActiveMemberships=\(report.duplicateActiveMemberships.count) itemsWithNoKnownRecovery=\(report.itemsWithNoKnownRecovery.count) missingMedia=\(report.itemsWithMissingMedia.count)")

        let postItems = try realContext.fetch(FetchDescriptor<StoredItem>())
        let postFolders = try realContext.fetch(FetchDescriptor<StoredFolder>())
        print("[Ferry] post-import total: items=\(postItems.count) folders=\(postFolders.count) (pre-existing \(preExistingItems.count)/\(preExistingFolders.count) + imported \(summary.itemsImported)/\(summary.foldersImported))")
    }

    /// READ-ONLY re-verification against the REAL container's current
    /// state — does not call `importArchive` again (which would now
    /// correctly refuse via identity collision, since the legacy items
    /// already exist). Re-runs the same comparison/IntegrityCheck logic
    /// `import-real-archive` already ran inline, so the corrected
    /// subset-based comparison can be confirmed clean without needing to
    /// mutate anything again.
    private static func verifyRealArchive(realContainer: ModelContainer) throws {
        let artifactURL = migrationArtifactURL()
        let json = try Data(contentsOf: artifactURL)
        let archive = try CherryManifest.decodeJSON(json)
        let realContext = ModelContext(realContainer)

        try compare(sourceArchive: archive, isolatedContext: realContext)

        let report = IntegrityCheck.run(context: realContext)
        print("[Ferry] IntegrityCheck (verify pass, real container): isClean=\(report.isClean) itemsWithMultipleActiveFolders=\(report.itemsWithMultipleActiveFolders.count) folderMembershipDisagreements=\(report.folderMembershipDisagreements.count) duplicateActiveMemberships=\(report.duplicateActiveMemberships.count) itemsWithNoKnownRecovery=\(report.itemsWithNoKnownRecovery.count) missingMedia=\(report.itemsWithMissingMedia.count) orphanedMedia=\(report.orphanedMediaFilenames.count)")
    }

    // MARK: - Inventory

    private static func printSourceInventory(_ archive: CherryManifest.Archive, jsonByteCount: Int, checksum: String, exportDuration: TimeInterval, artifactURL: URL) {
        let items = archive.items
        let active = items.filter { $0.deletedAt == nil }
        let softDeleted = items.filter { $0.deletedAt != nil }
        let withMedia = items.filter { $0.imageData != nil }
        let totalImageBytes = items.compactMap { $0.imageData?.count }.reduce(0, +)
        let favorites = items.filter(\.isFavorite)
        let withNotes = items.filter { ($0.noteBody?.isEmpty == false) }
        let withSourceURL = items.filter { ($0.sourceURL?.isEmpty == false) }
        let tagged = items.filter { !$0.tags.isEmpty }
        let totalTags = items.reduce(0) { $0 + $1.tags.count }
        let cropped = items.filter { $0.cropX != 0 || $0.cropY != 0 || $0.cropWidth != 1 || $0.cropHeight != 1 }
        let totalMemberships = items.reduce(0) { $0 + $1.folderIDs.count }

        print("[Ferry] --- source archive inventory ---")
        print("[Ferry] totalItems=\(items.count) active=\(active.count) softDeleted=\(softDeleted.count) folders=\(archive.folders.count) memberships=\(totalMemberships)")
        print("[Ferry] itemsWithMedia=\(withMedia.count) totalImageDataBytes=\(totalImageBytes)")
        print("[Ferry] favorites=\(favorites.count) withNotes=\(withNotes.count) withSourceURL=\(withSourceURL.count) taggedItems=\(tagged.count) totalTags=\(totalTags) croppedItems=\(cropped.count)")
        print("[Ferry] artifact: path=\(artifactURL.path) jsonBytes=\(jsonByteCount) sha256=\(checksum) exportDuration=\(String(format: "%.2f", exportDuration))s")
        print("[Ferry] --- end inventory ---")
    }

    // MARK: - Round-trip comparison

    private static func compare(sourceArchive: CherryManifest.Archive, isolatedContext: ModelContext) throws {
        let importedItems = try isolatedContext.fetch(FetchDescriptor<StoredItem>())
        let importedFolders = try isolatedContext.fetch(FetchDescriptor<StoredFolder>())
        let importedMemberships = try isolatedContext.fetch(FetchDescriptor<StoredFolderMembership>())
        let importedByID = Dictionary(uniqueKeysWithValues: importedItems.map { ($0.id, $0) })

        var mismatches: [String] = []

        // Subset checks, not exact-count equality: the destination may
        // legitimately contain unrelated pre-existing content (e.g. items
        // created directly in a newly-cutover environment before the
        // legacy archive was imported) — that's expected and correct, not
        // a mismatch. What actually matters is that every archive id is
        // present in the destination.
        let importedItemIDs = Set(importedItems.map(\.id))
        let sourceItemIDs = Set(sourceArchive.items.map(\.id))
        if !sourceItemIDs.isSubset(of: importedItemIDs) {
            mismatches.append("missing archive item ids: \(sourceItemIDs.subtracting(importedItemIDs).count)")
        }
        print("[Ferry] item counts: source=\(sourceArchive.items.count) destination-total=\(importedItems.count) (destination may legitimately include pre-existing unrelated items)")
        print("[Ferry] folder counts: source=\(sourceArchive.folders.count) destination-total=\(importedFolders.count) (destination may legitimately include pre-existing unrelated folders)")

        var imageDataMismatches = 0
        var cropMismatches = 0
        var metadataMismatches = 0
        var membershipMismatches = 0

        for sourceItem in sourceArchive.items {
            guard let imported = importedByID[sourceItem.id] else {
                mismatches.append("item \(sourceItem.id) missing from imported archive")
                continue
            }
            if imported.imageData != sourceItem.imageData {
                imageDataMismatches += 1
            }
            let sourceCrop = CropRegion(x: sourceItem.cropX, y: sourceItem.cropY, width: sourceItem.cropWidth, height: sourceItem.cropHeight)
            if imported.cropRegion != sourceCrop {
                cropMismatches += 1
            }
            if imported.noteBody != sourceItem.noteBody
                || imported.sourceURL != sourceItem.sourceURL
                || imported.tags != sourceItem.tags
                || imported.isFavorite != sourceItem.isFavorite
                || imported.createdAt != sourceItem.createdAt
                || imported.updatedAt != sourceItem.updatedAt
                || imported.deletedAt != sourceItem.deletedAt {
                metadataMismatches += 1
            }
            let expectedFolderID = sourceItem.folderIDs.first
            if imported.folder?.id != expectedFolderID {
                membershipMismatches += 1
            }
        }

        let sourceFolderIDs = Set(sourceArchive.folders.map(\.id))
        let importedFolderIDs = Set(importedFolders.map(\.id))
        if !sourceFolderIDs.isSubset(of: importedFolderIDs) {
            mismatches.append("missing archive folder ids: \(sourceFolderIDs.subtracting(importedFolderIDs).count)")
        }

        print("[Ferry] --- round-trip comparison ---")
        print("[Ferry] imageDataMismatches=\(imageDataMismatches) cropMismatches=\(cropMismatches) metadataMismatches=\(metadataMismatches) membershipMismatches=\(membershipMismatches)")
        print("[Ferry] totalActiveMembershipRowsImported=\(importedMemberships.filter { !$0.isSoftDeleted }.count)")
        if mismatches.isEmpty && imageDataMismatches == 0 && cropMismatches == 0 && metadataMismatches == 0 && membershipMismatches == 0 {
            print("[Ferry] ROUND-TRIP: EXACT MATCH")
        } else {
            print("[Ferry] ROUND-TRIP: MISMATCHES FOUND — \(mismatches.joined(separator: "; "))")
        }
        print("[Ferry] --- end comparison ---")
    }

    // MARK: - Helpers

    private static func migrationArtifactURL() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("cherries-migration-export.json")
    }

    /// Same Darwin `task_info` call `ImageCacheStressTest`/`IngestionStressTest`
    /// already use — diagnostic only, not exact.
    private static func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.resident_size) / 1024 / 1024
    }
}
#endif
