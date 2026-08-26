import XCTest
import SwiftData
@testable import ArkyvKit

/// Pre-Launch Migration Ferry 01: deterministic, synthetic-data coverage
/// for `CherryManifest.export`/`importArchive`. Real-archive verification
/// (round-trip against Sammy's actual ~84-item archive, on physical
/// devices) happens separately via the on-device migration harness —
/// these tests exist to pin down the importer's correctness/safety
/// contract with fast, isolated, repeatable cases, especially the failure
/// modes that are impractical to provoke reliably against real data.
///
/// Named to sort alphabetically before `LifecycleFaultInjectionTests` —
/// see this repo's own `swift test` CLI note (README "Build" section):
/// on this machine's toolchain, `swift test` crashes (signal 5) partway
/// through that file regardless of filtering, so tests in files that
/// sort after it never get a chance to run from the CLI. This file's
/// name is a deliberate, documented workaround, not an accident.
final class ArchiveExportImportTests: XCTestCase {
    @MainActor
    private func makeRepo(inMemory: Bool = true) throws -> Repository {
        let container = try! ArkyvStore.makeModelContainer(inMemory: inMemory)
        return Repository(context: container.mainContext)
    }

    @MainActor
    private func makeEmptyContext() -> ModelContext {
        try! ArkyvStore.makeModelContainer(inMemory: true).mainContext
    }

    // MARK: - Export round-trip (extends Recovery/Portability Foundation 01)

    @MainActor
    func testExportRoundTripsThroughJSONIncludingImageData() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let imageBytes = Data("fake-jpeg-bytes".utf8)
        let item = try repo.fileCapture(
            CaptureDraft(kind: .image, localFilename: "abc.jpg", noteBody: "hello", sourceURL: "https://example.com", tags: ["a", "b"]),
            folders: [folder]
        )
        item.imageData = imageBytes
        try repo.context.save()

        let archive = try CherryManifest.export(context: repo.context)
        let json = try CherryManifest.encodeJSON(archive)
        let decoded = try CherryManifest.decodeJSON(json)

        XCTAssertEqual(decoded, archive, "JSON round-trip, including imageData, must be lossless")
        XCTAssertEqual(decoded.items.first(where: { $0.id == item.id })?.imageData, imageBytes)
    }

    // MARK: - Import correctness

    @MainActor
    func testImportReconstructsFolderItemAndMembershipFromArchive() throws {
        let sourceRepo = try makeRepo()
        let folder = try sourceRepo.createFolder(name: "Recipes", icon: .symbol("star"))
        let item = try sourceRepo.fileCapture(.note("hello"), folders: [folder])
        let archive = try CherryManifest.export(context: sourceRepo.context)

        let destContext = makeEmptyContext()
        let summary = try CherryManifest.importArchive(archive, into: destContext)

        XCTAssertEqual(summary.foldersImported, 1)
        XCTAssertEqual(summary.itemsImported, 1)
        XCTAssertEqual(summary.membershipsImported, 1)

        let importedItems = try destContext.fetch(FetchDescriptor<StoredItem>())
        let importedFolders = try destContext.fetch(FetchDescriptor<StoredFolder>())
        XCTAssertEqual(importedItems.map(\.id), [item.id], "stable item identity must be preserved")
        XCTAssertEqual(importedFolders.map(\.id), [folder.id], "stable folder identity must be preserved")
    }

    @MainActor
    func testImportPreservesTimestampsAndSoftDeleteState() throws {
        let sourceRepo = try makeRepo()
        let item = try sourceRepo.fileCapture(.note("hello"))
        try sourceRepo.updateNote(item, body: "edited") // advances updatedAt away from createdAt
        try sourceRepo.softDelete(item)
        let archive = try CherryManifest.export(context: sourceRepo.context)

        let destContext = makeEmptyContext()
        try CherryManifest.importArchive(archive, into: destContext)

        let imported = try destContext.fetch(FetchDescriptor<StoredItem>()).first!
        XCTAssertEqual(imported.createdAt, item.createdAt)
        XCTAssertEqual(imported.updatedAt, item.updatedAt)
        XCTAssertEqual(imported.deletedAt, item.deletedAt)
        XCTAssertTrue(imported.isSoftDeleted)
    }

    @MainActor
    func testImportPreservesImageDataByteIdentity() throws {
        let sourceRepo = try makeRepo()
        let bytes = Data((0..<10_000).map { UInt8($0 % 256) }) // non-trivial, non-repeating payload
        let item = try sourceRepo.fileCapture(.note("hello"))
        item.imageData = bytes
        try sourceRepo.context.save()
        let archive = try CherryManifest.export(context: sourceRepo.context)

        let destContext = makeEmptyContext()
        try CherryManifest.importArchive(archive, into: destContext)

        let imported = try destContext.fetch(FetchDescriptor<StoredItem>()).first!
        XCTAssertEqual(imported.imageData, bytes, "byte-for-byte Data equality, not just size")
    }

    @MainActor
    func testImportPreservesCropRegionExactly() throws {
        let sourceRepo = try makeRepo()
        let item = try sourceRepo.fileCapture(.note("hello"))
        let region = CropRegion(x: 0.12, y: 0.34, width: 0.5, height: 0.4)
        try sourceRepo.updateCropRegion(item, to: region)
        let archive = try CherryManifest.export(context: sourceRepo.context)

        let destContext = makeEmptyContext()
        try CherryManifest.importArchive(archive, into: destContext)

        let imported = try destContext.fetch(FetchDescriptor<StoredItem>()).first!
        XCTAssertEqual(imported.cropRegion, region)
    }

    @MainActor
    func testImportEnforcesSingleFolderInvariantForUnfiledItem() throws {
        let sourceRepo = try makeRepo()
        _ = try sourceRepo.fileCapture(.note("hello"), folders: [])
        let archive = try CherryManifest.export(context: sourceRepo.context)

        let destContext = makeEmptyContext()
        try CherryManifest.importArchive(archive, into: destContext)

        let imported = try destContext.fetch(FetchDescriptor<StoredItem>()).first!
        XCTAssertNil(imported.folder)
        XCTAssertEqual(try Repository(context: destContext).memberships(for: imported).count, 0)
    }

    @MainActor
    func testImportEnforcesSingleFolderInvariantForFiledItem() throws {
        let sourceRepo = try makeRepo()
        let folder = try sourceRepo.createFolder(name: "Japan 2026", icon: .symbol("star"))
        _ = try sourceRepo.fileCapture(.note("hello"), folders: [folder])
        let archive = try CherryManifest.export(context: sourceRepo.context)

        let destContext = makeEmptyContext()
        try CherryManifest.importArchive(archive, into: destContext)

        let destRepo = Repository(context: destContext)
        let imported = try destContext.fetch(FetchDescriptor<StoredItem>()).first!
        XCTAssertEqual(imported.folder?.id, folder.id)
        let active = try destRepo.memberships(for: imported)
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.folder?.id, folder.id)
    }

    @MainActor
    func testImportedArchivePassesIntegrityCheckCleanly() throws {
        let sourceRepo = try makeRepo()
        let folderA = try sourceRepo.createFolder(name: "A", icon: .symbol("star"))
        let folderB = try sourceRepo.createFolder(name: "B", icon: .symbol("star"))
        _ = try sourceRepo.fileCapture(.note("unfiled"))
        _ = try sourceRepo.fileCapture(.note("in a"), folders: [folderA])
        let taggedItem = try sourceRepo.fileCapture(CaptureDraft(kind: .image, localFilename: "x.jpg", tags: ["t"]), folders: [folderB])
        taggedItem.imageData = Data("bytes".utf8)
        try sourceRepo.context.save()
        let archive = try CherryManifest.export(context: sourceRepo.context)

        let destContext = makeEmptyContext()
        try CherryManifest.importArchive(archive, into: destContext)

        let report = IntegrityCheck.run(context: destContext)
        XCTAssertEqual(report.itemsWithMultipleActiveFolders, [])
        XCTAssertEqual(report.folderMembershipDisagreements, [])
        XCTAssertEqual(report.duplicateActiveMemberships, [])
        XCTAssertEqual(report.itemsWithNoKnownRecovery, [])
    }

    // MARK: - Failure modes (Section 11)

    /// Real Archive Import 01: unrelated existing content — e.g. items
    /// created directly in a newly-cutover environment before the legacy
    /// archive is imported — must NOT block the import. Only an actual
    /// id collision should.
    @MainActor
    func testImportSucceedsAlongsideUnrelatedNonCollidingDestinationContent() throws {
        let sourceRepo = try makeRepo()
        let folder = try sourceRepo.createFolder(name: "Deadwest", icon: .symbol("star"))
        _ = try sourceRepo.fileCapture(.note("legacy"), folders: [folder])
        let archive = try CherryManifest.export(context: sourceRepo.context)

        let destContext = makeEmptyContext()
        let destRepo = Repository(context: destContext)
        let preExisting = try destRepo.fileCapture(.note("post-cutover, unrelated"))

        let summary = try CherryManifest.importArchive(archive, into: destContext)

        XCTAssertEqual(summary.itemsImported, 1)
        XCTAssertEqual(summary.foldersImported, 1)
        let allItems = try destContext.fetch(FetchDescriptor<StoredItem>())
        XCTAssertEqual(allItems.count, 2, "the pre-existing unrelated item must survive untouched, alongside the newly-imported one")
        XCTAssertTrue(allItems.contains { $0.id == preExisting.id })
        XCTAssertEqual(preExisting.noteBody, "post-cutover, unrelated", "the importer must never read or modify unrelated existing rows")
    }

    @MainActor
    func testImportRefusesOnActualIdentityCollision() throws {
        let sourceRepo = try makeRepo()
        let collidingItem = try sourceRepo.fileCapture(.note("legacy version"))
        let archive = try CherryManifest.export(context: sourceRepo.context)

        let destContext = makeEmptyContext()
        // Simulates the destination already containing a row whose id
        // matches an archive item — the one case that must be refused.
        let colliding = StoredItem(id: collidingItem.id, kind: .note, noteBody: "already exists in destination")
        destContext.insert(colliding)
        try destContext.save()

        XCTAssertThrowsError(try CherryManifest.importArchive(archive, into: destContext)) { error in
            guard case CherryManifest.ImportError.identityCollision(let itemIDs, let folderIDs) = error else {
                return XCTFail("expected .identityCollision, got \(error)")
            }
            XCTAssertEqual(itemIDs, [collidingItem.id])
            XCTAssertEqual(folderIDs, [])
        }

        // Unaffected by the failed attempt.
        XCTAssertEqual(colliding.noteBody, "already exists in destination")
    }

    @MainActor
    func testImportThrowsOnDuplicateItemIdentityWithinArchive() throws {
        let sharedID = UUID()
        let item1 = CherryManifest.Item(
            id: sharedID, kind: "note", localFilename: nil, imageData: nil, aspectWidth: 0, aspectHeight: 0,
            cropX: 0, cropY: 0, cropWidth: 1, cropHeight: 1, title: nil, noteBody: "one", sourceURL: nil,
            tags: [], isFavorite: false, folderIDs: [], createdAt: .now, updatedAt: .now, deletedAt: nil
        )
        let item2 = item1 // same id, matching CherryManifest.Item's Equatable/Codable shape exactly
        let archive = CherryManifest.Archive(formatVersion: 1, exportedAt: .now, folders: [], items: [item1, item2])

        XCTAssertThrowsError(try CherryManifest.importArchive(archive, into: makeEmptyContext())) { error in
            XCTAssertEqual(error as? CherryManifest.ImportError, .duplicateItemIdentity(sharedID))
        }
    }

    @MainActor
    func testImportThrowsOnMissingFolderReference() throws {
        let danglingFolderID = UUID()
        let item = CherryManifest.Item(
            id: UUID(), kind: "note", localFilename: nil, imageData: nil, aspectWidth: 0, aspectHeight: 0,
            cropX: 0, cropY: 0, cropWidth: 1, cropHeight: 1, title: nil, noteBody: nil, sourceURL: nil,
            tags: [], isFavorite: false, folderIDs: [danglingFolderID], createdAt: .now, updatedAt: .now, deletedAt: nil
        )
        let archive = CherryManifest.Archive(formatVersion: 1, exportedAt: .now, folders: [], items: [item])

        XCTAssertThrowsError(try CherryManifest.importArchive(archive, into: makeEmptyContext())) { error in
            XCTAssertEqual(error as? CherryManifest.ImportError, .missingFolderReference(itemID: item.id, folderID: danglingFolderID))
        }
    }

    @MainActor
    func testImportToleratesTruncatedOrEmptyImageDataWithoutCrashing() throws {
        let item = CherryManifest.Item(
            id: UUID(), kind: "image", localFilename: "broken.jpg", imageData: Data([0x01, 0x02]), // not a valid JPEG — must not be validated here
            aspectWidth: 100, aspectHeight: 100,
            cropX: 0, cropY: 0, cropWidth: 1, cropHeight: 1, title: nil, noteBody: nil, sourceURL: nil,
            tags: [], isFavorite: false, folderIDs: [], createdAt: .now, updatedAt: .now, deletedAt: nil
        )
        let archive = CherryManifest.Archive(formatVersion: 1, exportedAt: .now, folders: [], items: [item])

        let destContext = makeEmptyContext()
        let summary = try CherryManifest.importArchive(archive, into: destContext)

        XCTAssertEqual(summary.itemsImported, 1)
        let imported = try destContext.fetch(FetchDescriptor<StoredItem>()).first!
        XCTAssertEqual(imported.imageData, Data([0x01, 0x02]), "the importer stores exactly the bytes given — validating image decodability is a separate, existing rendering-path concern, not this migration tool's job")
    }

    /// Section 11: the importer must never report success for a partial
    /// reconstruction. Reuses the exact genuine (non-mocked) fault
    /// technique `LifecycleFaultInjectionTests.poisonContext` established:
    /// a pending relationship to an object from a DIFFERENT container's
    /// context, left unsaved on the context under test, makes THAT
    /// context's next `save()` genuinely throw.
    @MainActor
    func testImportRollsBackCompletelyOnInjectedSaveFailureLeavingDestinationEmpty() throws {
        let sourceRepo = try makeRepo()
        let folder = try sourceRepo.createFolder(name: "Deadwest", icon: .symbol("star"))
        _ = try sourceRepo.fileCapture(.note("hello"), folders: [folder])
        let archive = try CherryManifest.export(context: sourceRepo.context)

        let destContext = makeEmptyContext()
        // Poison the destination context exactly like LifecycleFaultInjectionTests
        // does: a pending relationship to a foreign container's object.
        let foreignRepo = try makeRepo()
        let foreignItem = try foreignRepo.fileCapture(.note("elsewhere"))
        destContext.insert(StoredFolderMembership(item: foreignItem, folder: nil))

        XCTAssertThrowsError(try CherryManifest.importArchive(archive, into: destContext))

        // The poisoned pending object itself doesn't count as "real"
        // archive content for this assertion — what matters is that none
        // of the ARCHIVE's own folders/items were left half-persisted.
        let items = try destContext.fetch(FetchDescriptor<StoredItem>()).filter { $0.id != foreignItem.id }
        let folders = try destContext.fetch(FetchDescriptor<StoredFolder>())
        XCTAssertEqual(items, [], "a failed import must leave zero archive items behind")
        XCTAssertEqual(folders, [], "a failed import must leave zero archive folders behind")
    }

    @MainActor
    func testImportIsSafeToRetryAfterAFailedCollisionAttempt() throws {
        let sourceRepo = try makeRepo()
        let item = try sourceRepo.fileCapture(.note("hello"))
        let archive = try CherryManifest.export(context: sourceRepo.context)

        let destContext = makeEmptyContext()
        let colliding = StoredItem(id: item.id, kind: .note, noteBody: "blocker")
        destContext.insert(colliding)
        try destContext.save()
        XCTAssertThrowsError(try CherryManifest.importArchive(archive, into: destContext))

        // Removing the actual colliding row (not merely soft-deleting —
        // its id would still collide) allows a subsequent import to
        // succeed cleanly.
        destContext.delete(colliding)
        try destContext.save()
        let summary = try CherryManifest.importArchive(archive, into: destContext)
        XCTAssertEqual(summary.itemsImported, 1)
    }
}
