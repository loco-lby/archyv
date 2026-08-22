import XCTest
import SwiftData
@testable import ArkyvKit

final class RepositoryTests: XCTestCase {
    @MainActor
    private func makeRepo() throws -> Repository {
        let container = ArkyvStore.makeModelContainer(inMemory: true)
        return Repository(context: container.mainContext)
    }

    @MainActor
    func testSeedCreatesFiveFolders() throws {
        let repo = try makeRepo()
        // No iCloud account: seeds immediately, deterministic, no timing.
        SeedGate.evaluate(context: repo.context, hasICloudAccount: false, timedSeedPermission: .allowed, defaults: makeIsolatedDefaults())
        XCTAssertEqual(try repo.folders().count, 5)
    }

    // D4: SeedGate's CloudKit-import race guard. Each test uses a fresh,
    // isolated UserDefaults suite so tests never share or leak state
    // through the real App Group suite a device/process would use.

    @MainActor
    private func makeIsolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SeedGateTests-\(UUID().uuidString)")!
    }

    @MainActor
    func testSeedGateRecordsFirstObservationWithoutSeeding() throws {
        let repo = try makeRepo()
        let defaults = makeIsolatedDefaults()
        let seeded = SeedGate.evaluate(context: repo.context, hasICloudAccount: true, timedSeedPermission: .allowed, defaults: defaults)
        XCTAssertFalse(seeded)
        XCTAssertEqual(try repo.folders().count, 0)
    }

    @MainActor
    func testSeedGateDoesNotSeedBeforeWindowElapses() throws {
        let repo = try makeRepo()
        let defaults = makeIsolatedDefaults()
        let start = Date()
        SeedGate.evaluate(context: repo.context, hasICloudAccount: true, timedSeedPermission: .allowed, now: start, defaults: defaults)
        let stillWaiting = SeedGate.evaluate(
            context: repo.context, hasICloudAccount: true, timedSeedPermission: .allowed,
            now: start.addingTimeInterval(30), elapsedWindow: 90, defaults: defaults
        )
        XCTAssertFalse(stillWaiting)
        XCTAssertEqual(try repo.folders().count, 0)
    }

    @MainActor
    func testSeedGateSeedsAfterWindowElapsesInMainAppMode() throws {
        let repo = try makeRepo()
        let defaults = makeIsolatedDefaults()
        let start = Date()
        SeedGate.evaluate(context: repo.context, hasICloudAccount: true, timedSeedPermission: .allowed, now: start, defaults: defaults)
        let seeded = SeedGate.evaluate(
            context: repo.context, hasICloudAccount: true, timedSeedPermission: .allowed,
            now: start.addingTimeInterval(91), elapsedWindow: 90, defaults: defaults
        )
        XCTAssertTrue(seeded)
        XCTAssertEqual(try repo.folders().count, 5)
    }

    @MainActor
    func testSeedGateNeverSeedsInObserveOnlyModeRegardlessOfElapsedTime() throws {
        let repo = try makeRepo()
        let defaults = makeIsolatedDefaults()
        let start = Date()
        SeedGate.evaluate(context: repo.context, hasICloudAccount: true, timedSeedPermission: .observeOnly, now: start, defaults: defaults)
        let seeded = SeedGate.evaluate(
            context: repo.context, hasICloudAccount: true, timedSeedPermission: .observeOnly,
            now: start.addingTimeInterval(1000), elapsedWindow: 90, defaults: defaults
        )
        XCTAssertFalse(seeded)
        XCTAssertEqual(try repo.folders().count, 0)
    }

    @MainActor
    func testSeedGateCancelsPermanentlyOnceRealDataArrives() throws {
        let repo = try makeRepo()
        let defaults = makeIsolatedDefaults()
        let start = Date()
        SeedGate.evaluate(context: repo.context, hasICloudAccount: true, timedSeedPermission: .allowed, now: start, defaults: defaults)

        // Real CloudKit data lands during the window.
        try repo.createFolder(name: "Real Synced Folder", icon: .symbol("star"))

        // Even well past the window, evaluate must never seed once real
        // data exists — regardless of the persisted timestamp.
        let seeded = SeedGate.evaluate(
            context: repo.context, hasICloudAccount: true, timedSeedPermission: .allowed,
            now: start.addingTimeInterval(1000), elapsedWindow: 90, defaults: defaults
        )
        XCTAssertFalse(seeded)
        let folders = try repo.folders()
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders.first?.name, "Real Synced Folder")
    }

    @MainActor
    func testSeedGateIsIdempotentAcrossRepeatedCalls() throws {
        let repo = try makeRepo()
        let defaults = makeIsolatedDefaults()
        let start = Date()
        for tick in 0...5 {
            SeedGate.evaluate(
                context: repo.context, hasICloudAccount: true, timedSeedPermission: .allowed,
                now: start.addingTimeInterval(TimeInterval(tick) * 20), elapsedWindow: 90, defaults: defaults
            )
        }
        XCTAssertEqual(try repo.folders().count, 5)
        // Further calls after seeding are no-ops, not additional inserts.
        SeedGate.evaluate(
            context: repo.context, hasICloudAccount: true, timedSeedPermission: .allowed,
            now: start.addingTimeInterval(500), elapsedWindow: 90, defaults: defaults
        )
        XCTAssertEqual(try repo.folders().count, 5)
    }

    @MainActor
    func testSeedGateContinuesCountdownAcrossAFreshContextSimulatingARelaunch() throws {
        let repo = try makeRepo()
        let defaults = makeIsolatedDefaults()
        let start = Date()
        SeedGate.evaluate(context: repo.context, hasICloudAccount: true, timedSeedPermission: .allowed, now: start, defaults: defaults)

        // A brand-new Repository/context against the same persisted
        // defaults — simulating a fresh process launch after a
        // force-quit/crash — must continue the same countdown, not reset
        // it back to "first observation."
        let freshRepo = try makeRepo()
        let seeded = SeedGate.evaluate(
            context: freshRepo.context, hasICloudAccount: true, timedSeedPermission: .allowed,
            now: start.addingTimeInterval(91), elapsedWindow: 90, defaults: defaults
        )
        XCTAssertTrue(seeded)
    }

    @MainActor
    func testFileCaptureIncrementsReferenceCount() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Test", icon: .symbol("star"))
        XCTAssertEqual(folder.referenceCount, 0)
        try repo.fileCapture(.note("hello world"), into: folder)
        XCTAssertEqual(folder.referenceCount, 1)
    }

    // D3A: fileCapture reads the just-written MediaStore file back into
    // StoredItem.imageData (the CloudKit `.externalStorage` transport field)
    // for image-kind drafts only, without disturbing the existing
    // localFilename local-read path.
    @MainActor
    func testFileCaptureWithImageDraftPopulatesImageDataFromMediaStore() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Test", icon: .symbol("star"))
        let bytes = Data("fake-jpeg-bytes".utf8)
        let filename = try MediaStore.shared.save(data: bytes)

        let item = try repo.fileCapture(
            CaptureDraft(kind: .screenshot, localFilename: filename),
            into: folder
        )

        XCTAssertEqual(item.imageData, bytes)
        // The local read path is untouched — localFilename still resolves.
        XCTAssertEqual(item.localFilename, filename)
    }

    @MainActor
    func testFileCaptureWithNoteDraftLeavesImageDataNil() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Test", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), into: folder)
        XCTAssertNil(item.imageData)
    }

    // MARK: - Provenance Foundation 01: acquisitionOrigin persistence
    //
    // Repository.fileCapture must map CaptureDraft.acquisitionOrigin 1:1
    // into StoredItem — never infer it from kind/sourceURL. "Producer
    // assigns truth, repository preserves truth."

    @MainActor
    func testFileCaptureMapsActionCaptureOriginExactly() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Test", icon: .symbol("star"))
        let item = try repo.fileCapture(
            CaptureDraft(kind: .screenshot, acquisitionOrigin: .actionCapture),
            into: folder
        )
        XCTAssertEqual(item.acquisitionOrigin, .actionCapture)
    }

    @MainActor
    func testFileCaptureMapsPhotoLibraryImportOriginExactly() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Test", icon: .symbol("star"))
        let item = try repo.fileCapture(
            CaptureDraft(kind: .image, acquisitionOrigin: .photoLibraryImport),
            into: folder
        )
        XCTAssertEqual(item.acquisitionOrigin, .photoLibraryImport)
    }

    @MainActor
    func testFileCaptureMapsShareExtensionOriginExactly() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Test", icon: .symbol("star"))
        let item = try repo.fileCapture(
            CaptureDraft(kind: .screenshot, sourceURL: nil, acquisitionOrigin: .shareExtension),
            into: folder
        )
        XCTAssertEqual(item.acquisitionOrigin, .shareExtension)
    }

    /// Repository never inspects kind/sourceURL to guess origin — a draft
    /// with a sourceURL but an explicit non-shareExtension origin still
    /// persists exactly what the producer said, proving there's no hidden
    /// inference happening underneath the 1:1 mapping.
    @MainActor
    func testFileCaptureNeverInfersOriginFromSourceURLPresence() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Test", icon: .symbol("star"))
        let item = try repo.fileCapture(
            CaptureDraft(kind: .image, sourceURL: "https://example.com/x", acquisitionOrigin: .photoLibraryImport),
            into: folder
        )
        XCTAssertEqual(item.acquisitionOrigin, .photoLibraryImport)
        XCTAssertEqual(item.sourceURL, "https://example.com/x")
    }

    /// A draft that never states its origin (every debug/test-harness
    /// caller that predates this milestone) files as `.unknown` — the
    /// same additive-default behavior as `isEditorial`/`isFavorite`.
    @MainActor
    func testFileCaptureWithoutExplicitOriginDefaultsToUnknown() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Test", icon: .symbol("star"))
        let item = try repo.fileCapture(CaptureDraft(kind: .screenshot), into: folder)
        XCTAssertEqual(item.acquisitionOrigin, .unknown)
    }

    /// Legacy-item simulation: a StoredItem constructed the way a
    /// pre-migration CloudKit row would decode — no acquisitionOrigin
    /// ever supplied — must read back as `.unknown`, never guessed from
    /// kind or sourceURL.
    @MainActor
    func testLegacyStoredItemWithoutOriginFieldReadsAsUnknown() throws {
        let item = StoredItem(kind: .screenshot, localFilename: "legacy.jpg")
        XCTAssertEqual(item.acquisitionOrigin, .unknown)

        let itemWithURL = StoredItem(kind: .image, sourceURL: "https://example.com/legacy")
        XCTAssertEqual(itemWithURL.acquisitionOrigin, .unknown)
    }

    // MARK: - Crop foundation: CaptureDraft/Repository persistence

    /// A draft that never sets cropRegion (every current producer) files
    /// with the full-image default — the existing, unchanged behavior.
    @MainActor
    func testFileCaptureWithoutCropRegionPersistsFullImage() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Test", icon: .symbol("star"))
        let item = try repo.fileCapture(CaptureDraft(kind: .screenshot), into: folder)
        XCTAssertEqual(item.cropRegion, .fullImage)
    }

    /// An explicit, non-default crop on the draft persists onto the
    /// resulting item exactly.
    @MainActor
    func testFileCaptureWithExplicitCropRegionPersistsIt() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Test", icon: .symbol("star"))
        let region = CropRegion(x: 0.1, y: 0.15, width: 0.6, height: 0.5)
        let item = try repo.fileCapture(
            CaptureDraft(kind: .screenshot, cropRegion: region),
            into: folder
        )
        XCTAssertEqual(item.cropRegion, region)
    }

    @MainActor
    func testUpdateCropRegionPersistsANewRegion() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Test", icon: .symbol("star"))
        let item = try repo.fileCapture(CaptureDraft(kind: .screenshot), into: folder)
        XCTAssertEqual(item.cropRegion, .fullImage)

        let region = CropRegion(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        try repo.updateCropRegion(item, to: region)
        XCTAssertEqual(item.cropRegion, region)
    }

    /// Non-destructive: updating the crop never touches the original
    /// pixels/localFilename.
    @MainActor
    func testUpdateCropRegionLeavesLocalFilenameUntouched() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Test", icon: .symbol("star"))
        let bytes = Data("fake-jpeg-bytes".utf8)
        let filename = try MediaStore.shared.save(data: bytes)
        let item = try repo.fileCapture(
            CaptureDraft(kind: .screenshot, localFilename: filename),
            into: folder
        )

        try repo.updateCropRegion(item, to: CropRegion(x: 0.3, y: 0.3, width: 0.3, height: 0.3))

        XCTAssertEqual(item.localFilename, filename)
        XCTAssertEqual(item.imageData, bytes)
    }

    @MainActor
    func testUpdateCropRegionIsANoOpWhenRegionAlreadyMatches() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Test", icon: .symbol("star"))
        let item = try repo.fileCapture(CaptureDraft(kind: .screenshot), into: folder)
        let updatedAtBefore = item.updatedAt

        try repo.updateCropRegion(item, to: .fullImage)

        XCTAssertEqual(item.updatedAt, updatedAtBefore)
    }

    // MARK: - ImageBackfill (D3B)

    /// Simulates a "historical" item — the shape everything captured before
    /// D3A has: a real MediaStore file on disk, but `imageData` never
    /// populated. Inserted directly (bypassing `fileCapture`, which has
    /// populated `imageData` for new captures since D3A).
    @MainActor
    private func makeHistoricalImageItem(repo: Repository, bytes: Data = Data("historical-jpeg".utf8)) throws -> StoredItem {
        let filename = try MediaStore.shared.save(data: bytes)
        let item = StoredItem(kind: .screenshot, localFilename: filename)
        repo.context.insert(item)
        try repo.context.save()
        return item
    }

    @MainActor
    func testImageBackfillPopulatesHistoricalItemFromMediaStore() throws {
        let repo = try makeRepo()
        let bytes = Data("historical-jpeg".utf8)
        let item = try makeHistoricalImageItem(repo: repo, bytes: bytes)
        XCTAssertNil(item.imageData)

        let backfilled = ImageBackfill.runNextBatch(context: repo.context)

        XCTAssertEqual(backfilled, 1)
        XCTAssertEqual(item.imageData, bytes)
    }

    @MainActor
    func testImageBackfillNeverOverwritesPopulatedImageData() throws {
        let repo = try makeRepo()
        let sentinel = Data("do-not-touch".utf8)
        let item = try makeHistoricalImageItem(repo: repo)
        item.imageData = sentinel
        try repo.context.save()

        let backfilled = ImageBackfill.runNextBatch(context: repo.context)

        XCTAssertEqual(backfilled, 0)
        XCTAssertEqual(item.imageData, sentinel)
    }

    @MainActor
    func testImageBackfillLeavesNoteItemsUntouched() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Test", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), into: folder)

        let backfilled = ImageBackfill.runNextBatch(context: repo.context)

        XCTAssertEqual(backfilled, 0)
        XCTAssertNil(item.imageData)
    }

    @MainActor
    func testImageBackfillSkipsItemWithUnreadableMediaStoreFile() throws {
        let repo = try makeRepo()
        // A localFilename that was never actually written to MediaStore —
        // simulates a permanently missing/corrupt file.
        let item = StoredItem(kind: .screenshot, localFilename: "does-not-exist.jpg")
        repo.context.insert(item)
        try repo.context.save()

        let backfilled = ImageBackfill.runNextBatch(context: repo.context)

        XCTAssertEqual(backfilled, 0)
        XCTAssertNil(item.imageData)
    }

    @MainActor
    func testImageBackfillRespectsBatchLimit() throws {
        let repo = try makeRepo()
        for _ in 0..<5 {
            _ = try makeHistoricalImageItem(repo: repo)
        }

        let backfilled = ImageBackfill.runNextBatch(context: repo.context, limit: 2)

        XCTAssertEqual(backfilled, 2)
    }

    @MainActor
    func testImageBackfillIsIdempotentAcrossRepeatedRuns() throws {
        let repo = try makeRepo()
        for _ in 0..<3 {
            _ = try makeHistoricalImageItem(repo: repo)
        }

        let first = ImageBackfill.runNextBatch(context: repo.context, limit: 10)
        XCTAssertEqual(first, 3)

        let second = ImageBackfill.runNextBatch(context: repo.context, limit: 10)
        XCTAssertEqual(second, 0)
    }

    @MainActor
    func testSuggestionMatchesKeyword() throws {
        let repo = try makeRepo()
        SeedGate.evaluate(context: repo.context, hasICloudAccount: false, timedSeedPermission: .allowed)
        let draft = CaptureDraft(kind: .screenshot, ocrText: "Best recipes for ramen")
        let suggestion = try repo.suggestedFolder(for: draft)
        XCTAssertEqual(suggestion?.name, "Recipes")
    }

    @MainActor
    func testSearchFindsOCRText() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Test", icon: .symbol("star"))
        try repo.fileCapture(
            CaptureDraft(kind: .screenshot, ocrText: "water tower sign"),
            into: folder
        )
        XCTAssertEqual(try repo.search("water tower").count, 1)
        XCTAssertEqual(try repo.search("nonexistent").count, 0)
    }

    func testFolderIconRoundTrip() {
        XCTAssertEqual(FolderIcon(token: "sf:star"), .symbol("star"))
        XCTAssertEqual(FolderIcon(token: "emoji:🔥"), .emoji("🔥"))
        XCTAssertEqual(FolderIcon.symbol("heart").token, "sf:heart")
    }

    // MARK: - MembershipMigration (Milestone A backfill)

    @MainActor
    func testMembershipBackfillCreatesOneMembershipForLegacyFolder() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), into: folder)

        try MembershipMigration.backfillMemberships(repository: repo)

        let memberships = (item.memberships ?? []).filter { !$0.isSoftDeleted }
        XCTAssertEqual(memberships.count, 1)
        XCTAssertEqual(memberships.first?.folder?.id, folder.id)
        XCTAssertEqual(memberships.first?.item?.id, item.id)
    }

    @MainActor
    func testMembershipBackfillSkipsItemsWithNoLegacyFolder() throws {
        let repo = try makeRepo()
        // There's no "unfiled" capture path yet (Milestone B), so an
        // unfiled legacy item is simulated by inserting a StoredItem
        // directly with folder: nil — the exact shape a real never-filed
        // item already has today.
        let item = StoredItem(kind: .note, noteBody: "loose")
        repo.context.insert(item)
        try repo.context.save()

        try MembershipMigration.backfillMemberships(repository: repo)

        XCTAssertEqual((item.memberships ?? []).filter { !$0.isSoftDeleted }.count, 0)
    }

    @MainActor
    func testMembershipBackfillIsIdempotent() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        _ = try repo.fileCapture(.note("hello"), into: folder)

        try MembershipMigration.backfillMemberships(repository: repo)
        let countAfterFirst = try repo.context.fetch(FetchDescriptor<StoredFolderMembership>()).count

        // Running it again — including via a fresh Repository/second call —
        // must not create a second row for the same (item, folder) pair.
        try MembershipMigration.backfillMemberships(repository: repo)
        let countAfterSecond = try repo.context.fetch(FetchDescriptor<StoredFolderMembership>()).count

        XCTAssertEqual(countAfterFirst, 1)
        XCTAssertEqual(countAfterSecond, 1)
    }

    @MainActor
    func testMembershipBackfillSkipsWhenEquivalentMembershipAlreadyExists() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), into: folder)

        // Simulate a membership that already exists for some other reason
        // (e.g. a partially-completed prior run) before the backfill runs.
        let existing = StoredFolderMembership(item: item, folder: folder)
        repo.context.insert(existing)
        try repo.context.save()

        try MembershipMigration.backfillMemberships(repository: repo)

        XCTAssertEqual((item.memberships ?? []).filter { !$0.isSoftDeleted }.count, 1)
    }

    @MainActor
    func testMembershipBackfillGivesEachItemItsOwnMembership() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let itemA = try repo.fileCapture(.note("a"), into: folder)
        let itemB = try repo.fileCapture(.note("b"), into: folder)

        try MembershipMigration.backfillMemberships(repository: repo)

        XCTAssertEqual((itemA.memberships ?? []).filter { !$0.isSoftDeleted }.count, 1)
        XCTAssertEqual((itemB.memberships ?? []).filter { !$0.isSoftDeleted }.count, 1)
        XCTAssertNotEqual((itemA.memberships ?? []).first?.id, (itemB.memberships ?? []).first?.id)
        XCTAssertEqual((folder.memberships ?? []).filter { !$0.isSoftDeleted }.count, 2)
    }

    @MainActor
    func testMembershipBackfillDoesNotMutateItemFields() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(
            CaptureDraft(kind: .image, localFilename: "abc.jpg", noteBody: "keep me"),
            into: folder
        )
        try repo.toggleFavorite(item)
        let noteBefore = item.noteBody
        let favoriteBefore = item.isFavorite
        let filenameBefore = item.localFilename
        let createdAtBefore = item.createdAt
        let updatedAtBefore = item.updatedAt

        try MembershipMigration.backfillMemberships(repository: repo)

        XCTAssertEqual(item.noteBody, noteBefore)
        XCTAssertEqual(item.isFavorite, favoriteBefore)
        XCTAssertEqual(item.localFilename, filenameBefore)
        XCTAssertEqual(item.createdAt, createdAtBefore)
        XCTAssertEqual(item.updatedAt, updatedAtBefore)
    }

    @MainActor
    func testLegacyFolderRelationshipStillWorksAfterMigration() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), into: folder)

        try MembershipMigration.backfillMemberships(repository: repo)

        XCTAssertEqual(item.folder?.id, folder.id)
        XCTAssertEqual(try repo.items(in: folder).count, 1)
        XCTAssertEqual(folder.referenceCount, 1)
    }

    @MainActor
    func testMembershipBackfillSkipsDeletedItems() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("gone"), into: folder)
        try repo.softDelete(item)

        try MembershipMigration.backfillMemberships(repository: repo)

        XCTAssertEqual((item.memberships ?? []).filter { !$0.isSoftDeleted }.count, 0)
    }

    @MainActor
    func testMembershipBackfillSkipsItemsPointingAtADeletedFolder() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Ghost", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("orphan"), into: folder)
        // The exact "orphaned legacy assignment" shape Milestone B will
        // eventually allow (folder gone, item surviving) — the backfill
        // must not manufacture a membership into a dead folder.
        folder.deletedAt = .now
        try repo.context.save()

        try MembershipMigration.backfillMemberships(repository: repo)

        XCTAssertEqual((item.memberships ?? []).filter { !$0.isSoftDeleted }.count, 0)
    }

    // MARK: - Repository Membership API (Milestone B)

    @MainActor
    func testAddMembershipCreatesOneMembership() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [])

        try repo.addMembership(item, to: deadwest)

        XCTAssertEqual(try repo.memberships(for: item).count, 1)
        XCTAssertEqual(try repo.folders(for: item).map(\.id), [deadwest.id])
    }

    @MainActor
    func testAddMultipleMembershipsKeepsOneItemRow() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let inspiration = try repo.createFolder(name: "Inspiration", icon: .symbol("star"))
        let japan = try repo.createFolder(name: "Japan 2026", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [])

        try repo.addMembership(item, to: deadwest)
        try repo.addMembership(item, to: inspiration)
        try repo.addMembership(item, to: japan)

        XCTAssertEqual(try repo.memberships(for: item).count, 3)
        let allItems = try repo.context.fetch(FetchDescriptor<StoredItem>())
        XCTAssertEqual(allItems.filter { $0.id == item.id }.count, 1)
    }

    @MainActor
    func testAddingSameMembershipTwiceDoesNotDuplicate() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [])

        try repo.addMembership(item, to: deadwest)
        try repo.addMembership(item, to: deadwest)

        XCTAssertEqual(try repo.memberships(for: item).count, 1)
    }

    @MainActor
    func testRemovingOneMembershipPreservesOthers() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let inspiration = try repo.createFolder(name: "Inspiration", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest, inspiration])

        try repo.removeMembership(item, from: deadwest)

        let remaining = try repo.folders(for: item)
        XCTAssertEqual(remaining.map(\.id), [inspiration.id])
    }

    @MainActor
    func testRemovingFinalMembershipLeavesItemAliveAndUnfiled() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])

        try repo.removeMembership(item, from: deadwest)

        XCTAssertFalse(item.isSoftDeleted)
        XCTAssertEqual(try repo.memberships(for: item).count, 0)
    }

    // MARK: - Single-Folder Invariant Foundation 01 (closeout: legacy mirror)

    @MainActor
    func testRemoveFinalMembershipSetsLegacyFolderToNil() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])
        XCTAssertEqual(item.folder?.id, deadwest.id)

        try repo.removeMembership(item, from: deadwest)

        XCTAssertNil(item.folder, "no active membership remains — item.folder must mirror Unfiled, not the folder just removed from")
    }

    @MainActor
    func testRemoveMembershipWhileAnotherRemainsMirrorsTheRemainingWinner() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let inspiration = try repo.createFolder(name: "Inspiration", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest, inspiration])

        try repo.removeMembership(item, from: deadwest)

        XCTAssertEqual(item.folder?.id, inspiration.id, "the one remaining canonical membership must be mirrored, never independently decided")
    }

    @MainActor
    func testRemoveMembershipIsANoOpOnAlreadyStaleFieldsWhenMembershipNeverExisted() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [])
        let updatedAtBefore = item.updatedAt

        try repo.removeMembership(item, from: deadwest) // never was a member — must stay a true no-op

        XCTAssertNil(item.folder)
        XCTAssertEqual(item.updatedAt, updatedAtBefore)
    }

    @MainActor
    func testSoftDeleteFolderMakesMemberItemCanonicalUnfiledWithNilLegacyFolder() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])
        XCTAssertEqual(item.folder?.id, deadwest.id)

        try repo.softDelete(deadwest)

        XCTAssertEqual(try repo.memberships(for: item).count, 0)
        XCTAssertNil(item.folder, "the item's sole folder was deleted — item.folder must mirror Unfiled, not the now-deleted folder")
        XCTAssertFalse(item.isSoftDeleted, "the item itself must remain fully reachable — no hard delete, no cascading soft-delete")
    }

    @MainActor
    func testSoftDeleteFolderMirrorsTheRemainingCanonicalMembershipWhenOneExists() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let inspiration = try repo.createFolder(name: "Inspiration", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest, inspiration])

        try repo.softDelete(deadwest)

        XCTAssertEqual(item.folder?.id, inspiration.id, "a valid canonical membership remains — that must be mirrored, not left stale or nil")
    }

    @MainActor
    func testSoftDeleteFolderWithSeveralMemberItemsReconcilesEachIndependently() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let inspiration = try repo.createFolder(name: "Inspiration", icon: .symbol("star"))
        let soloItem = try repo.fileCapture(.note("solo"), folders: [deadwest])
        let multiItem = try repo.fileCapture(.note("multi"), folders: [deadwest, inspiration])
        let untouchedItem = try repo.fileCapture(.note("untouched"), folders: [inspiration])

        try repo.softDelete(deadwest)

        XCTAssertNil(soloItem.folder, "loses its only folder — Unfiled")
        XCTAssertEqual(multiItem.folder?.id, inspiration.id, "keeps its other valid membership")
        XCTAssertEqual(untouchedItem.folder?.id, inspiration.id, "never referenced the deleted folder — must be completely untouched")
    }

    /// Section 3: repeated operations must not produce additional writes.
    @MainActor
    func testSoftDeleteFolderIsIdempotentAndProducesNoFurtherChurnOnRepeat() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])

        try repo.softDelete(deadwest)
        XCTAssertNil(item.folder)
        let updatedAtAfterFirstDelete = item.updatedAt

        try repo.softDelete(deadwest) // already deleted — must not re-touch the item

        XCTAssertNil(item.folder)
        XCTAssertEqual(item.updatedAt, updatedAtAfterFirstDelete, "an item with no remaining active membership must not be re-touched on a repeated delete")
    }

    /// Confirms `FolderMembershipReconciler` is a true no-op after the
    /// Repository write paths above have already correctly mirrored
    /// `item.folder` — the closeout fix and the reconciler must never
    /// disagree about what "correct" looks like.
    @MainActor
    func testReconcileAllIsANoOpAfterRemoveMembershipAndSoftDeleteFolderAlreadySelfCorrected() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let inspiration = try repo.createFolder(name: "Inspiration", icon: .symbol("star"))
        let removedFromItem = try repo.fileCapture(.note("a"), folders: [deadwest, inspiration])
        let deletedFolderItem = try repo.fileCapture(.note("b"), folders: [deadwest])

        try repo.removeMembership(removedFromItem, from: deadwest)
        try repo.softDelete(deadwest)

        let summary = try FolderMembershipReconciler.reconcileAll(repository: repo)

        XCTAssertEqual(summary.itemsReconciled, [], "both write paths already self-corrected item.folder — the reconciler must find nothing left to fix")
        XCTAssertEqual(removedFromItem.folder?.id, inspiration.id)
        XCTAssertNil(deletedFolderItem.folder)
    }

    @MainActor
    func testRemovingNonexistentMembershipIsHarmlessNoOp() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [])

        try repo.removeMembership(item, from: deadwest) // never was a member

        XCTAssertEqual(try repo.memberships(for: item).count, 0)
    }

    @MainActor
    func testSetMembershipsReconcilesToExactDesiredSet() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let recipes = try repo.createFolder(name: "Recipes", icon: .symbol("star"))
        let inspiration = try repo.createFolder(name: "Inspiration", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest, recipes])

        try repo.setMemberships(item, to: [deadwest, inspiration])

        let resultIDs = Set(try repo.folders(for: item).map(\.id))
        XCTAssertEqual(resultIDs, Set([deadwest.id, inspiration.id]))
    }

    @MainActor
    func testSetMembershipsWithEmptyCollectionLeavesItemAliveAndUnfiled() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])

        try repo.setMemberships(item, to: [])

        XCTAssertFalse(item.isSoftDeleted)
        XCTAssertEqual(try repo.memberships(for: item).count, 0)
    }

    @MainActor
    func testSetMembershipsWithSameDesiredSetIsANoOp() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])
        let membershipCountBefore = try repo.context.fetch(FetchDescriptor<StoredFolderMembership>()).count
        let itemUpdatedAtBefore = item.updatedAt
        let folderUpdatedAtBefore = deadwest.updatedAt

        try repo.setMemberships(item, to: [deadwest])

        let membershipCountAfter = try repo.context.fetch(FetchDescriptor<StoredFolderMembership>()).count
        XCTAssertEqual(membershipCountAfter, membershipCountBefore)
        XCTAssertEqual(item.updatedAt, itemUpdatedAtBefore)
        XCTAssertEqual(deadwest.updatedAt, folderUpdatedAtBefore)
    }

    // MARK: - Folder Delete Semantics (Milestone B)

    @MainActor
    func testDeletingFolderDoesNotMarkItemDeleted() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])

        try repo.softDelete(deadwest)

        XCTAssertFalse(item.isSoftDeleted)
    }

    @MainActor
    func testDeletingFolderRemovesItsMemberships() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])

        try repo.softDelete(deadwest)

        XCTAssertEqual(try repo.memberships(for: item).count, 0)
    }

    @MainActor
    func testItemInTwoFoldersSurvivesDeletionOfOne() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let inspiration = try repo.createFolder(name: "Inspiration", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest, inspiration])

        try repo.softDelete(deadwest)

        let remaining = try repo.folders(for: item)
        XCTAssertEqual(remaining.map(\.id), [inspiration.id])
        XCTAssertFalse(item.isSoftDeleted)
    }

    @MainActor
    func testItemSurvivesWithZeroMembershipsWhenOnlyFolderIsDeleted() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])

        try repo.softDelete(deadwest)

        XCTAssertFalse(item.isSoftDeleted)
        XCTAssertEqual(try repo.memberships(for: item).count, 0)
    }

    /// Folder deletion still never touches an item's content fields —
    /// note, favorite, media, creation time. `item.folder`/`updatedAt` are
    /// the one deliberate exception as of Single-Folder Invariant
    /// Foundation 01's closeout: see
    /// `testSoftDeleteFolderMakesMemberItemCanonicalUnfiledWithNilLegacyFolder`
    /// for why that mutation is correct, not a regression.
    @MainActor
    func testFolderDeletionDoesNotMutateItemContentFields() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(
            CaptureDraft(kind: .image, localFilename: "abc.jpg", noteBody: "keep me"),
            folders: [deadwest]
        )
        try repo.toggleFavorite(item)
        let noteBefore = item.noteBody
        let favoriteBefore = item.isFavorite
        let filenameBefore = item.localFilename
        let createdAtBefore = item.createdAt

        try repo.softDelete(deadwest)

        XCTAssertEqual(item.noteBody, noteBefore)
        XCTAssertEqual(item.isFavorite, favoriteBefore)
        XCTAssertEqual(item.localFilename, filenameBefore)
        XCTAssertEqual(item.createdAt, createdAtBefore)
    }

    // MARK: - fileCapture with folder sets (Milestone B)

    @MainActor
    func testFileCaptureWithZeroFoldersSucceeds() throws {
        let repo = try makeRepo()
        let item = try repo.fileCapture(.note("hello"), folders: [])

        XCTAssertFalse(item.isSoftDeleted)
        XCTAssertNil(item.folder)
        XCTAssertEqual(try repo.memberships(for: item).count, 0)
    }

    @MainActor
    func testFileCaptureWithOneFolderCreatesOneMembership() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])

        XCTAssertEqual(try repo.memberships(for: item).count, 1)
        XCTAssertEqual(item.folder?.id, deadwest.id)
    }

    @MainActor
    func testFileCaptureWithMultipleFoldersCreatesOneItemAndMultipleMemberships() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let inspiration = try repo.createFolder(name: "Inspiration", icon: .symbol("star"))
        let japan = try repo.createFolder(name: "Japan 2026", icon: .symbol("star"))

        let item = try repo.fileCapture(
            CaptureDraft(kind: .image, localFilename: "shared.jpg"),
            folders: [deadwest, inspiration, japan]
        )

        XCTAssertEqual(try repo.memberships(for: item).count, 3)
        let allItems = try repo.context.fetch(FetchDescriptor<StoredItem>())
        XCTAssertEqual(allItems.filter { $0.localFilename == "shared.jpg" }.count, 1)
    }

    @MainActor
    func testFileCaptureThenMigrationDoesNotDuplicateMembership() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])

        // fileCapture already creates a membership AND (transitionally)
        // sets item.folder — confirms the Milestone A backfill sees an
        // already-satisfied item and does not add a second membership for
        // the same (item, folder) pair.
        try MembershipMigration.backfillMemberships(repository: repo)

        XCTAssertEqual(try repo.memberships(for: item).count, 1)
    }

    // MARK: - move(_:to:) membership reconciliation (Milestone B fix)

    @MainActor
    func testMoveReassignsLegacyFolderAndReconcilesMembership() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let coolShit = try repo.createFolder(name: "Cool Shit", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])

        try repo.move(item, to: coolShit)

        let resultIDs = Set(try repo.folders(for: item).map(\.id))
        XCTAssertEqual(resultIDs, Set([coolShit.id]))
        XCTAssertEqual(item.folder?.id, coolShit.id)
    }

    @MainActor
    func testMoveFromMultipleMembershipsCollapsesToSingleDestination() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let inspiration = try repo.createFolder(name: "Inspiration", icon: .symbol("star"))
        let coolShit = try repo.createFolder(name: "Cool Shit", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest, inspiration])

        try repo.move(item, to: coolShit)

        let resultIDs = Set(try repo.folders(for: item).map(\.id))
        XCTAssertEqual(resultIDs, Set([coolShit.id]))
    }

    @MainActor
    func testMoveToExistingSoleFolderIsIdempotent() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])

        try repo.move(item, to: deadwest)
        try repo.move(item, to: deadwest)

        XCTAssertEqual(try repo.memberships(for: item).count, 1)
        XCTAssertEqual(item.folder?.id, deadwest.id)
    }

    @MainActor
    func testMoveDoesNotMutateUnrelatedItemFields() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let coolShit = try repo.createFolder(name: "Cool Shit", icon: .symbol("star"))
        let item = try repo.fileCapture(
            CaptureDraft(kind: .image, localFilename: "abc.jpg", noteBody: "keep me"),
            folders: [deadwest]
        )
        try repo.toggleFavorite(item)
        let noteBefore = item.noteBody
        let favoriteBefore = item.isFavorite
        let filenameBefore = item.localFilename
        let createdAtBefore = item.createdAt

        try repo.move(item, to: coolShit)

        XCTAssertFalse(item.isSoftDeleted)
        XCTAssertEqual(item.noteBody, noteBefore)
        XCTAssertEqual(item.isFavorite, favoriteBefore)
        XCTAssertEqual(item.localFilename, filenameBefore)
        XCTAssertEqual(item.createdAt, createdAtBefore)
    }

    // MARK: - move(_:to:) exclusive reconciliation regression (Milestone B/C fix)
    //
    // Physical-device testing in Milestone C found an item moved via
    // "Move to..." remaining active in BOTH its old and new folder once
    // the Archive surface started reading membership directly — invisible
    // earlier because FolderGridView only ever read the legacy
    // StoredItem.folder relationship. Root-caused to memberships(for:)
    // trusting the SwiftData relationship array instead of fetching
    // directly; see that method's doc comment in ArkyvStore.swift.

    @MainActor
    func testMoveRemovesPreviousMembership() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let coolShit = try repo.createFolder(name: "Cool Shit", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])

        try repo.move(item, to: coolShit)

        let resultIDs = Set(try repo.folders(for: item).map(\.id))
        XCTAssertEqual(resultIDs, Set([coolShit.id]))
    }

    @MainActor
    func testMoveFromTwoMembershipsCollapsesToExactlyOneDestination() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let inspiration = try repo.createFolder(name: "Inspiration", icon: .symbol("star"))
        let coolShit = try repo.createFolder(name: "Cool Shit", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest, inspiration])

        try repo.move(item, to: coolShit)

        let resultIDs = Set(try repo.folders(for: item).map(\.id))
        XCTAssertEqual(resultIDs, Set([coolShit.id]))
        XCTAssertEqual(try repo.memberships(for: item).count, 1)
    }

    @MainActor
    func testRepeatedMoveToSameDestinationRemainsExactlyOneMembership() throws {
        let repo = try makeRepo()
        let coolShit = try repo.createFolder(name: "Cool Shit", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [coolShit])

        try repo.move(item, to: coolShit)
        try repo.move(item, to: coolShit)

        XCTAssertEqual(try repo.memberships(for: item).count, 1)
    }

    /// Directly reproduces the reported drift shape: an active membership
    /// to one folder while `item.folder` already points somewhere else
    /// entirely (neither the stale membership's folder nor the eventual
    /// destination) — the kind of state a migrated-then-partially-updated
    /// record could end up in. A correct move must still fully reconcile.
    @MainActor
    func testMoveReconcilesStaleMembershipDespiteLegacyFolderAlreadyElsewhere() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let elsewhere = try repo.createFolder(name: "Elsewhere", icon: .symbol("star"))
        let coolShit = try repo.createFolder(name: "Cool Shit", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])
        item.folder = elsewhere // simulate drift between the legacy field and membership truth

        try repo.move(item, to: coolShit)

        let resultIDs = Set(try repo.folders(for: item).map(\.id))
        XCTAssertEqual(resultIDs, Set([coolShit.id]))
        XCTAssertEqual(item.folder?.id, coolShit.id)
    }

    @MainActor
    func testOldMembershipNotReturnedByItemsInOldFolder() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let coolShit = try repo.createFolder(name: "Cool Shit", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])

        try repo.move(item, to: coolShit)

        let deadwestItems = try repo.items(in: deadwest)
        XCTAssertFalse(deadwestItems.contains(where: { $0.id == item.id }))
    }

    @MainActor
    func testDestinationReturnedByItemsInDestination() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let coolShit = try repo.createFolder(name: "Cool Shit", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])

        try repo.move(item, to: coolShit)

        let coolShitItems = try repo.items(in: coolShit)
        XCTAssertTrue(coolShitItems.contains(where: { $0.id == item.id }))
    }

    @MainActor
    func testMoveKeepsExactlyOneItemRowAndItemIsNotUnfiled() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let coolShit = try repo.createFolder(name: "Cool Shit", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])

        try repo.move(item, to: coolShit)

        let allItems = try repo.context.fetch(FetchDescriptor<StoredItem>())
        XCTAssertEqual(allItems.filter { $0.id == item.id }.count, 1)
        // Not Unfiled: it still has one active membership (Cool Shit).
        XCTAssertFalse(try repo.memberships(for: item).isEmpty)
    }

    @MainActor
    func testMoveUpdatesLegacyFolderToDestination() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let coolShit = try repo.createFolder(name: "Cool Shit", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])

        try repo.move(item, to: coolShit)

        XCTAssertEqual(item.folder?.id, coolShit.id)
    }

    @MainActor
    func testMoveNeverLeavesDuplicateActiveMemberships() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let inspiration = try repo.createFolder(name: "Inspiration", icon: .symbol("star"))
        let coolShit = try repo.createFolder(name: "Cool Shit", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest, inspiration])

        try repo.move(item, to: coolShit)
        try repo.move(item, to: coolShit)

        let allMemberships = try repo.context.fetch(FetchDescriptor<StoredFolderMembership>())
        let activeForItem = allMemberships.filter { $0.item?.id == item.id && !$0.isSoftDeleted }
        XCTAssertEqual(activeForItem.count, 1)
        XCTAssertEqual(activeForItem.first?.folder?.id, coolShit.id)
    }

    // MARK: - setMemberships root-cause regression: raw-fetch + cross-context proof
    //
    // These directly reproduce what the physical-device MembershipTrace
    // proved: reconciliation entering the DEACTIVATE branch is not
    // sufficient evidence of correctness — only a RAW fetch (not
    // `memberships(for:)`, not `item.memberships`) after `save()` proves
    // the persisted state actually changed. The second test additionally
    // reads from a second `ModelContext` on the same container — the
    // closest a unit test can get to "force-quit and relaunch" without a
    // real process boundary.

    @MainActor
    func testMoveRawFetchInSameContextShowsOldRowDeactivated() throws {
        let container = ArkyvStore.makeModelContainer(inMemory: true)
        let repo = Repository(context: container.mainContext)
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let coolShit = try repo.createFolder(name: "Cool Shit", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])

        try repo.move(item, to: coolShit)

        let rows = try container.mainContext.fetch(FetchDescriptor<StoredFolderMembership>())
            .filter { $0.item?.id == item.id }
        let deadwestRow = rows.first { $0.folder?.id == deadwest.id }
        let coolShitRow = rows.first { $0.folder?.id == coolShit.id }

        XCTAssertEqual(deadwestRow?.isSoftDeleted, true, "old membership must be deactivated by the raw store, not just in-memory")
        XCTAssertEqual(coolShitRow?.isSoftDeleted, false)
        XCTAssertEqual(rows.filter { !$0.isSoftDeleted }.count, 1)
    }

    @MainActor
    func testMoveDeactivationSurvivesAFreshModelContextOnTheSameContainer() throws {
        let container = ArkyvStore.makeModelContainer(inMemory: true)
        let repo = Repository(context: container.mainContext)
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let coolShit = try repo.createFolder(name: "Cool Shit", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])

        try repo.move(item, to: coolShit)

        // A second, independent context against the SAME container/store —
        // proves the reconciliation was actually persisted, not merely
        // mutated on objects local to the context that performed the move.
        let freshContext = ModelContext(container)
        let freshRows = try freshContext.fetch(FetchDescriptor<StoredFolderMembership>())
            .filter { $0.item?.id == item.id }
        let freshDeadwestRow = freshRows.first { $0.folder?.id == deadwest.id }
        let freshCoolShitRow = freshRows.first { $0.folder?.id == coolShit.id }

        XCTAssertEqual(freshDeadwestRow?.isSoftDeleted, true)
        XCTAssertEqual(freshCoolShitRow?.isSoftDeleted, false)
        XCTAssertEqual(freshRows.filter { !$0.isSoftDeleted }.count, 1)
    }

    // MARK: - setMemberships REACTIVATE semantics (new canonical behavior)

    @MainActor
    func testSetMembershipsReactivatesSoftDeletedRowInsteadOfDuplicating() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let coolShit = try repo.createFolder(name: "Cool Shit", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])

        try repo.move(item, to: coolShit) // Deadwest membership deactivated
        try repo.setMemberships(item, to: [deadwest]) // desire Deadwest again

        let resultIDs = Set(try repo.folders(for: item).map(\.id))
        XCTAssertEqual(resultIDs, Set([deadwest.id]))

        let allRows = try repo.context.fetch(FetchDescriptor<StoredFolderMembership>())
        let deadwestRows = allRows.filter { $0.item?.id == item.id && $0.folder?.id == deadwest.id }
        XCTAssertEqual(deadwestRows.count, 1, "the original row should be reactivated, not duplicated")
        XCTAssertEqual(deadwestRows.first?.isSoftDeleted, false)
    }

    // MARK: - Data Integrity Foundation 01

    @MainActor
    func testFileCaptureRollsBackOnSaveFailureRatherThanPoisoningTheContext() throws {
        // Two independent in-memory containers — filing into a folder
        // that belongs to a DIFFERENT container's context is a genuine
        // SwiftData save() failure ("illegal attempt to establish a
        // relationship between objects in different contexts/stores"),
        // not a mock. This is the most realistic available way to force
        // a real save failure without adding any test-only seam to
        // Repository itself.
        let repoA = try makeRepo()
        let repoB = try makeRepo()
        let foreignFolder = try repoB.createFolder(name: "Elsewhere", icon: .symbol("star"))

        XCTAssertThrowsError(try repoA.fileCapture(.note("first attempt"), folders: [foreignFolder]))

        // Without rolling back on failure, the failed attempt's pending
        // StoredItem/StoredFolderMembership would still be sitting on
        // repoA's context — poisoning the NEXT, completely unrelated
        // save on the same context, exactly what a real UI context is:
        // one long-lived context reused across many operations.
        let deadwest = try repoA.createFolder(name: "Deadwest", icon: .symbol("star"))
        let secondItem = try repoA.fileCapture(.note("second attempt"), folders: [deadwest])

        let allNotes = try repoA.context.fetch(FetchDescriptor<StoredItem>()).filter { $0.noteBody != nil }
        XCTAssertEqual(allNotes.map(\.id), [secondItem.id], "the failed first attempt must never have been persisted")
    }

    @MainActor
    func testRepeatedFileCaptureForTheSameDraftCreatesTwoDistinctItems() throws {
        // KNOWN, DEFERRED GAP (see the Data Integrity Contract in
        // README.md): `fileCapture` has no idempotency key tying a
        // `CaptureDraft` to the `StoredItem` it produces, so calling it
        // twice for the *same* draft (e.g. a caller retrying after a
        // save it couldn't confirm succeeded) creates two independent
        // items, not one. A real fix would mean persisting `draft.id`
        // (or an equivalent key) on `StoredItem` — a schema change
        // explicitly out of scope for this pass. This test documents
        // the current, accepted behavior so a future fix has a clear
        // "before" to compare against, and so this doesn't silently
        // change un-noticed.
        let repo = try makeRepo()
        let draft = CaptureDraft.note("retried capture")

        let first = try repo.fileCapture(draft)
        let second = try repo.fileCapture(draft)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(try repo.context.fetch(FetchDescriptor<StoredItem>()).count, 2)
    }

    @MainActor
    func testSoftDeletingItemDeactivatesItsOwnMemberships() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])

        try repo.softDelete(item)

        let itemRows = try repo.context.fetch(FetchDescriptor<StoredFolderMembership>())
            .filter { $0.item?.id == item.id }
        XCTAssertFalse(itemRows.isEmpty)
        XCTAssertTrue(itemRows.allSatisfy(\.isSoftDeleted), "soft-deleting an item must deactivate its own membership rows too, symmetric with softDelete(_ folder:)")
    }

    @MainActor
    func testSetMembershipsPersistsALegacyFolderCorrectionEvenWhenMembershipsAlreadyMatch() throws {
        // Reproduces the exact shape Item Detail's Folder room uses for
        // its "Unfiled" confirm path — `item.folder` mutated directly,
        // then `setMemberships` called with a desired set that (in this
        // test) already matches the active memberships. Before this
        // fix, `setMemberships` would see no membership-row changes
        // needed, take its early `guard changed else { return }` exit,
        // and never call save() at all — silently stranding the
        // `item.folder` mutation as a pending, unpersisted change.
        let container = ArkyvStore.makeModelContainer(inMemory: true)
        let repo = Repository(context: container.mainContext)
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])

        item.folder = nil // simulates a pre-existing legacy/membership disagreement

        try repo.setMemberships(item, to: [deadwest]) // desired membership set is already correct

        XCTAssertEqual(item.folder?.id, deadwest.id)

        // A second, independent context against the SAME container/store
        // — proves the correction was actually persisted, not merely
        // mutated on the object local to the context that made the call.
        let freshContext = ModelContext(container)
        let freshItem = try freshContext.fetch(FetchDescriptor<StoredItem>()).first { $0.id == item.id }
        XCTAssertEqual(freshItem?.folder?.id, deadwest.id, "the legacy folder correction must reach save(), not just the in-memory object")
    }

    // MARK: - IntegrityCheck (DEBUG-only, read-only diagnostic)

    @MainActor
    func testIntegrityCheckReportsCleanForAHealthyStore() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        _ = try repo.fileCapture(.note("hello"), folders: [deadwest])

        let report = IntegrityCheck.run(context: repo.context)

        XCTAssertTrue(report.isClean)
        XCTAssertEqual(report.itemsWithMissingMedia, [])
        XCTAssertEqual(report.folderMembershipDisagreements, [])
        XCTAssertEqual(report.duplicateActiveMemberships, [])
    }

    @MainActor
    func testIntegrityCheckDetectsFolderMembershipDisagreement() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])

        // Bypasses the Repository's own write boundary — simulates data
        // that predates the `setMemberships` fix, or was mutated by
        // something other than the Repository. `IntegrityCheck` must
        // still be able to surface this even though current Repository
        // writes can no longer produce it.
        item.folder = nil

        let report = IntegrityCheck.run(context: repo.context)

        XCTAssertEqual(report.folderMembershipDisagreements, [item.id])
        XCTAssertFalse(report.isClean)
    }

    // MARK: - Multi-Device Consistency Foundation 01

    /// Reproduces, deterministically and without any real CloudKit
    /// round-trip, the exact race confirmed on physical devices: two
    /// devices concurrently move the same item into two *different*
    /// folders. Each device's own `setMemberships` call only reconciles
    /// against rows it locally knows about, so it inserts one new,
    /// independent `StoredFolderMembership` CKRecord; CloudKit has no
    /// reason to conflict two inserts of different records, so both sync
    /// down as active on every device. Simulated here by bypassing the
    /// Repository (inserting both membership rows directly), which is
    /// exactly what two independent `setMemberships` calls converging via
    /// CloudKit look like from a single device's local store afterward.
    @MainActor
    func testIntegrityCheckDetectsItemWithMultipleActiveFolders() throws {
        let repo = try makeRepo()
        let folderA = try repo.createFolder(name: "Folder A", icon: .symbol("star"))
        let folderB = try repo.createFolder(name: "Folder B", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"))

        repo.context.insert(StoredFolderMembership(item: item, folder: folderA))
        repo.context.insert(StoredFolderMembership(item: item, folder: folderB))
        try repo.context.save()

        let report = IntegrityCheck.run(context: repo.context)

        XCTAssertEqual(report.itemsWithMultipleActiveFolders, [item.id])
        // Diagnostic only: the v0.2 schema doesn't forbid an item
        // belonging to multiple folders, and the item stays fully
        // reachable via `folders(for:)` either way — this must not be
        // conflated with genuine corruption/cleanliness failure.
        XCTAssertTrue(report.isClean, "multi-folder membership is schema-legitimate, not a cleanliness failure — it's surfaced for visibility only")
    }

    @MainActor
    func testIntegrityCheckDoesNotFlagItemWithOneActiveFolder() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Solo Folder", icon: .symbol("star"))
        _ = try repo.fileCapture(.note("hello"), folders: [folder])

        let report = IntegrityCheck.run(context: repo.context)

        XCTAssertEqual(report.itemsWithMultipleActiveFolders, [])
    }

    // MARK: - Single-Folder Invariant Foundation 01

    @MainActor
    func testReconcilerWinnerPicksTheMostRecentlyCreatedMembership() throws {
        let repo = try makeRepo()
        let folderA = try repo.createFolder(name: "Folder A", icon: .symbol("star"))
        let folderB = try repo.createFolder(name: "Folder B", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"))

        let older = StoredFolderMembership(item: item, folder: folderA, createdAt: Date(timeIntervalSince1970: 100))
        let newer = StoredFolderMembership(item: item, folder: folderB, createdAt: Date(timeIntervalSince1970: 200))

        let winner = FolderMembershipReconciler.winner(among: [older, newer])

        XCTAssertEqual(winner?.id, newer.id)
    }

    @MainActor
    func testReconcilerWinnerTieBreaksByMembershipIDWhenTimestampsMatch() throws {
        let repo = try makeRepo()
        let folderA = try repo.createFolder(name: "Folder A", icon: .symbol("star"))
        let folderB = try repo.createFolder(name: "Folder B", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"))
        let sameInstant = Date(timeIntervalSince1970: 100)

        let low = StoredFolderMembership(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, item: item, folder: folderA, createdAt: sameInstant)
        let high = StoredFolderMembership(id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!, item: item, folder: folderB, createdAt: sameInstant)

        // Order shouldn't matter — the tie-break is a pure function of the
        // IDs themselves, not of array/iteration order.
        XCTAssertEqual(FolderMembershipReconciler.winner(among: [low, high])?.id, high.id)
        XCTAssertEqual(FolderMembershipReconciler.winner(among: [high, low])?.id, high.id)
    }

    /// Section 10: the exact class of bug found in `IntegrityCheck` last
    /// milestone was non-determinism from `Dictionary`/`Set` iteration
    /// order. Proves the reconciler's winner selection is a pure function
    /// of the membership data, never of the order it's handed in.
    @MainActor
    func testReconcilerWinnerIsDeterministicRegardlessOfShuffledInputOrder() throws {
        let repo = try makeRepo()
        let folders = try (0..<5).map { try repo.createFolder(name: "Folder \($0)", icon: .symbol("star")) }
        let item = try repo.fileCapture(.note("hello"))
        let memberships = folders.enumerated().map { index, folder in
            StoredFolderMembership(item: item, folder: folder, createdAt: Date(timeIntervalSince1970: Double(index) * 10))
        }
        let expectedWinnerID = memberships.last!.id

        for _ in 0..<25 {
            let shuffled = memberships.shuffled()
            XCTAssertEqual(FolderMembershipReconciler.winner(among: shuffled)?.id, expectedWinnerID)
        }
    }

    /// Reproduces the exact real-world shape confirmed in the live
    /// archive: two devices concurrently move the same item, producing 2+
    /// simultaneously-active memberships to different folders (bypassing
    /// the Repository, matching what independent CloudKit inserts look
    /// like once synced to a single device's local store).
    @MainActor
    func testReconcileAllDeactivatesAllButTheWinnerAndReconcilesLegacyFolder() throws {
        let repo = try makeRepo()
        let folderA = try repo.createFolder(name: "Folder A", icon: .symbol("star"))
        let folderB = try repo.createFolder(name: "Folder B", icon: .symbol("star"))
        let folderC = try repo.createFolder(name: "Folder C", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"))

        repo.context.insert(StoredFolderMembership(item: item, folder: folderA, createdAt: Date(timeIntervalSince1970: 100)))
        repo.context.insert(StoredFolderMembership(item: item, folder: folderB, createdAt: Date(timeIntervalSince1970: 300)))
        repo.context.insert(StoredFolderMembership(item: item, folder: folderC, createdAt: Date(timeIntervalSince1970: 200)))
        try repo.context.save()

        let summary = try FolderMembershipReconciler.reconcileAll(repository: repo)

        XCTAssertEqual(summary.itemsReconciled.count, 1)
        XCTAssertEqual(summary.itemsReconciled.first?.winningFolderID, folderB.id, "folderB has the latest createdAt (300)")
        XCTAssertEqual(summary.itemsReconciled.first?.deactivatedMembershipIDs.count, 2)

        let activeFolders = try repo.folders(for: item)
        XCTAssertEqual(activeFolders.map(\.id), [folderB.id])
        XCTAssertEqual(item.folder?.id, folderB.id)
    }

    @MainActor
    func testReconcileAllLeavesSingleMembershipItemsCompletelyUntouched() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Solo Folder", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [folder])
        let updatedAtBefore = item.updatedAt

        let summary = try FolderMembershipReconciler.reconcileAll(repository: repo)

        XCTAssertEqual(summary.itemsReconciled, [])
        XCTAssertEqual(item.updatedAt, updatedAtBefore, "an item already satisfying the invariant must not be touched/saved at all")
    }

    /// Section 11: idempotency / loop-safety — once reconciled, running
    /// again against already-clean state must be a true no-op, not merely
    /// "produces the same result again." Two devices that each
    /// independently reconcile the same already-correct data must not
    /// generate endless sync churn reaffirming what's already true.
    @MainActor
    func testReconcileAllIsIdempotentOnAlreadyReconciledState() throws {
        let repo = try makeRepo()
        let folderA = try repo.createFolder(name: "Folder A", icon: .symbol("star"))
        let folderB = try repo.createFolder(name: "Folder B", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"))
        repo.context.insert(StoredFolderMembership(item: item, folder: folderA, createdAt: Date(timeIntervalSince1970: 100)))
        repo.context.insert(StoredFolderMembership(item: item, folder: folderB, createdAt: Date(timeIntervalSince1970: 200)))
        try repo.context.save()

        let firstRun = try FolderMembershipReconciler.reconcileAll(repository: repo)
        XCTAssertEqual(firstRun.itemsReconciled.count, 1)

        let updatedAtAfterFirstRun = item.updatedAt
        let secondRun = try FolderMembershipReconciler.reconcileAll(repository: repo)

        XCTAssertEqual(secondRun.itemsReconciled, [], "already-clean state must produce zero corrections on a repeated run")
        XCTAssertEqual(item.updatedAt, updatedAtAfterFirstRun, "a no-op reconciliation pass must not touch/save already-correct items")
    }

    @MainActor
    func testFolderMembershipPreviewMatchesReconcileAllWithoutMutatingAnything() throws {
        let repo = try makeRepo()
        let folderA = try repo.createFolder(name: "Folder A", icon: .symbol("star"))
        let folderB = try repo.createFolder(name: "Folder B", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"))
        repo.context.insert(StoredFolderMembership(item: item, folder: folderA, createdAt: Date(timeIntervalSince1970: 100)))
        repo.context.insert(StoredFolderMembership(item: item, folder: folderB, createdAt: Date(timeIntervalSince1970: 200)))
        try repo.context.save()

        let previews = try FolderMembershipReconciler.preview(repository: repo)

        XCTAssertEqual(previews.count, 1)
        let preview = previews[0]
        XCTAssertEqual(preview.itemID, item.id)
        XCTAssertEqual(preview.winningFolderName, "Folder B")
        XCTAssertEqual(preview.membershipsToDeactivate.map(\.folderName), ["Folder A"])
        XCTAssertTrue(preview.wouldChangeVisibleFolder, "item.folder was never set (nil) — Folder B is a visible change from Unfiled")

        // Read-only: the underlying data must be completely unmutated.
        let stillActive = try repo.folders(for: item)
        XCTAssertEqual(Set(stillActive.map(\.id)), Set([folderA.id, folderB.id]))
        XCTAssertNil(item.folder)
    }

    @MainActor
    func testIntegrityCheckDetectsMissingMedia() throws {
        let repo = try makeRepo()
        let draft = CaptureDraft(kind: .screenshot, localFilename: "does-not-exist-\(UUID().uuidString).jpg")
        let item = try repo.fileCapture(draft)

        let report = IntegrityCheck.run(context: repo.context)

        XCTAssertEqual(report.itemsWithMissingMedia, [item.id])
        XCTAssertFalse(report.isClean)
        // The draft's localFilename never pointed at a real file, so
        // fileCapture's own `MediaStore.shared.data(for:)` read for
        // `imageData` also came back nil — no recovery path exists for
        // this item, on this device or (per what's actually stored) any
        // other. Category C, not B — see the Report fields' doc comments.
        XCTAssertEqual(report.itemsWithRecoverableMedia, [])
        XCTAssertEqual(report.itemsWithNoKnownRecovery, [item.id])
    }

    // MARK: - Recovery/Portability Foundation 01

    @MainActor
    func testIntegrityCheckDistinguishesRecoverableFromUnrecoverableMissingMedia() throws {
        // Simulates exactly the scenario `MediaStore.data(for:
        // reconstructingFrom:)` exists to handle: a reinstall/new-device
        // StoredItem whose `imageData` synced down via CloudKit but whose
        // local MediaStore file was never written on this device.
        let repo = try makeRepo()
        let filename = "reinstalled-\(UUID().uuidString).jpg"
        let item = StoredItem(kind: .screenshot, localFilename: filename, imageData: Data("fake-jpeg-bytes".utf8))
        repo.context.insert(item)
        try repo.context.save()

        let report = IntegrityCheck.run(context: repo.context)

        XCTAssertEqual(report.itemsWithMissingMedia, [item.id])
        XCTAssertEqual(report.itemsWithRecoverableMedia, [item.id], "imageData is populated — MediaStore.data(for:reconstructingFrom:) can self-heal this on next access")
        XCTAssertEqual(report.itemsWithNoKnownRecovery, [])
        // Media Architecture Cutover 01: a recoverable cache miss is
        // HEALTHY under the declared media contract, not a cleanliness
        // failure — imageData is the authority, and it's intact.
        XCTAssertTrue(report.isClean, "a cold MediaStore cache with imageData intact must not fail cleanliness — that's the routine, expected state under the cache contract")
    }

    // MARK: - Media Cache Eviction Activation 01

    /// Section 12: after genuinely evicting a cache file (not simulating —
    /// this actually deletes the real `MediaStore` file, then reconstructs
    /// it back through the real production path), `IntegrityCheck` must
    /// report HEALTHY/CACHE MISS (recoverable, isClean), never MEDIA LOSS.
    @MainActor
    func testIntegrityCheckStaysCleanAfterARealEvictionAndReconstructsCorrectly() async throws {
        let repo = try makeRepo()
        let bytes = Data("real cache-backed bytes".utf8)
        let filename = try MediaStore.shared.save(data: bytes)
        defer { MediaStore.shared.delete(filename: filename) }
        let item = try repo.fileCapture(CaptureDraft(kind: .screenshot, localFilename: filename))
        XCTAssertEqual(item.imageData, bytes, "fileCapture must have populated imageData from the real MediaStore file")

        // Genuinely evict — delete the real cache file, exactly what
        // `MediaStore.evictIfNeeded()` would do.
        MediaStore.shared.delete(filename: filename)
        XCTAssertNil(MediaStore.shared.data(for: filename), "sanity: the file is genuinely gone")

        let reportAfterEviction = IntegrityCheck.run(context: repo.context)
        XCTAssertEqual(reportAfterEviction.itemsWithRecoverableMedia, [item.id])
        XCTAssertEqual(reportAfterEviction.itemsWithNoKnownRecovery, [], "imageData is still intact — this is a cache miss, not media loss")
        XCTAssertTrue(reportAfterEviction.isClean)

        // Reconstruct through the real production path and confirm byte
        // identity. `imageData` extracted to a plain local first — the
        // same main-actor-then-cross-into-Sendable-closure pattern
        // production call sites (e.g. ItemDetailView) already use, since
        // `StoredItem` itself isn't Sendable.
        let capturedImageData = item.imageData
        let reconstructed = await MediaStore.shared.data(for: filename, reconstructingFrom: { capturedImageData })
        XCTAssertEqual(reconstructed, bytes)

        let reportAfterReconstruction = IntegrityCheck.run(context: repo.context)
        XCTAssertTrue(reportAfterReconstruction.isClean)
        XCTAssertEqual(reportAfterReconstruction.itemsWithMissingMedia, [], "the cache is warm again")
    }

    /// Same shape, at a small scale representative of "many evicted" —
    /// every item independently stays HEALTHY, and an entire isolated
    /// cache being cleared at once doesn't change that.
    @MainActor
    func testIntegrityCheckStaysCleanWhenManyItemsCacheFilesAreEvictedAtOnce() throws {
        let repo = try makeRepo()
        var items: [(item: StoredItem, filename: String, bytes: Data)] = []
        for i in 0..<8 {
            let bytes = Data("bytes-\(i)".utf8)
            let filename = try MediaStore.shared.save(data: bytes)
            let item = try repo.fileCapture(CaptureDraft(kind: .screenshot, localFilename: filename))
            items.append((item, filename, bytes))
        }
        defer { items.forEach { MediaStore.shared.delete(filename: $0.filename) } }

        // Evict the entire isolated set at once.
        for (_, filename, _) in items {
            MediaStore.shared.delete(filename: filename)
        }

        let report = IntegrityCheck.run(context: repo.context)
        let evictedIDs = Set(items.map(\.item.id))
        XCTAssertEqual(Set(report.itemsWithRecoverableMedia), evictedIDs)
        XCTAssertTrue(report.itemsWithNoKnownRecovery.isEmpty)
        XCTAssertTrue(report.isClean, "evicting every cache file at once must still report clean — imageData is intact for all of them")
    }

    @MainActor
    func testCherryManifestExportRoundTripsThroughJSONWithoutLoss() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let cool = try repo.createFolder(name: "Cool Shit", icon: .symbol("star"))
        let item = try repo.fileCapture(
            CaptureDraft(
                kind: .screenshot,
                localFilename: "manifest-test.jpg",
                pixelSize: CGSize(width: 1170, height: 2532),
                noteBody: "A note with \"quotes\" and emoji 🍒",
                title: "A title",
                sourceURL: "https://example.com",
                tags: ["food", "travel"]
            ),
            folders: [deadwest, cool]
        )
        item.cropRegion = CropRegion(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        try repo.context.save()
        try repo.softDelete(try repo.createFolder(name: "Old Folder", icon: .symbol("star")))

        let exported = try CherryManifest.export(context: repo.context)
        let json = try CherryManifest.encodeJSON(exported)
        let decoded = try CherryManifest.decodeJSON(json)

        XCTAssertEqual(decoded, exported, "JSON round-trip must be lossless — this is the whole point of the manifest shape")

        let manifestItem = try XCTUnwrap(decoded.items.first { $0.id == item.id })
        XCTAssertEqual(manifestItem.tags, ["food", "travel"])
        XCTAssertEqual(Set(manifestItem.folderIDs), Set([deadwest.id, cool.id]))
        XCTAssertEqual(manifestItem.cropWidth, 0.3, accuracy: 0.0001)
        XCTAssertEqual(manifestItem.noteBody, "A note with \"quotes\" and emoji 🍒")

        let softDeletedFolder = try XCTUnwrap(decoded.folders.first { $0.name == "Old Folder" })
        XCTAssertNotNil(softDeletedFolder.deletedAt, "tombstones must round-trip too — a real export format shouldn't silently drop them")
    }
}
