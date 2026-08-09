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
        try repo.seedIfEmpty()
        XCTAssertEqual(try repo.folders().count, 5)
        // Idempotent.
        try repo.seedIfEmpty()
        XCTAssertEqual(try repo.folders().count, 5)
    }

    @MainActor
    func testFileCaptureIncrementsReferenceCount() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Test", icon: .symbol("star"))
        XCTAssertEqual(folder.referenceCount, 0)
        try repo.fileCapture(.note("hello world"), into: folder)
        XCTAssertEqual(folder.referenceCount, 1)
    }

    @MainActor
    func testSuggestionMatchesKeyword() throws {
        let repo = try makeRepo()
        try repo.seedIfEmpty()
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

        let memberships = item.memberships.filter { !$0.isDeleted }
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

        XCTAssertEqual(item.memberships.filter { !$0.isDeleted }.count, 0)
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

        XCTAssertEqual(item.memberships.filter { !$0.isDeleted }.count, 1)
    }

    @MainActor
    func testMembershipBackfillGivesEachItemItsOwnMembership() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let itemA = try repo.fileCapture(.note("a"), into: folder)
        let itemB = try repo.fileCapture(.note("b"), into: folder)

        try MembershipMigration.backfillMemberships(repository: repo)

        XCTAssertEqual(itemA.memberships.filter { !$0.isDeleted }.count, 1)
        XCTAssertEqual(itemB.memberships.filter { !$0.isDeleted }.count, 1)
        XCTAssertNotEqual(itemA.memberships.first?.id, itemB.memberships.first?.id)
        XCTAssertEqual(folder.memberships.filter { !$0.isDeleted }.count, 2)
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

        XCTAssertEqual(item.memberships.filter { !$0.isDeleted }.count, 0)
    }

    @MainActor
    func testMembershipBackfillSkipsItemsPointingAtADeletedFolder() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "Ghost", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("orphan"), into: folder)
        // The exact "orphaned legacy assignment" shape Milestone B will
        // eventually allow (folder gone, item surviving) — the backfill
        // must not manufacture a membership into a dead folder.
        folder.isDeleted = true
        try repo.context.save()

        try MembershipMigration.backfillMemberships(repository: repo)

        XCTAssertEqual(item.memberships.filter { !$0.isDeleted }.count, 0)
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

        XCTAssertFalse(item.isDeleted)
        XCTAssertEqual(try repo.memberships(for: item).count, 0)
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

        XCTAssertFalse(item.isDeleted)
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

        XCTAssertFalse(item.isDeleted)
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
        XCTAssertFalse(item.isDeleted)
    }

    @MainActor
    func testItemSurvivesWithZeroMembershipsWhenOnlyFolderIsDeleted() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])

        try repo.softDelete(deadwest)

        XCTAssertFalse(item.isDeleted)
        XCTAssertEqual(try repo.memberships(for: item).count, 0)
    }

    @MainActor
    func testFolderDeletionDoesNotMutateItemFields() throws {
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
        let updatedAtBefore = item.updatedAt

        try repo.softDelete(deadwest)

        XCTAssertEqual(item.noteBody, noteBefore)
        XCTAssertEqual(item.isFavorite, favoriteBefore)
        XCTAssertEqual(item.localFilename, filenameBefore)
        XCTAssertEqual(item.createdAt, createdAtBefore)
        XCTAssertEqual(item.updatedAt, updatedAtBefore)
    }

    // MARK: - fileCapture with folder sets (Milestone B)

    @MainActor
    func testFileCaptureWithZeroFoldersSucceeds() throws {
        let repo = try makeRepo()
        let item = try repo.fileCapture(.note("hello"), folders: [])

        XCTAssertFalse(item.isDeleted)
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

        XCTAssertFalse(item.isDeleted)
        XCTAssertEqual(item.noteBody, noteBefore)
        XCTAssertEqual(item.isFavorite, favoriteBefore)
        XCTAssertEqual(item.localFilename, filenameBefore)
        XCTAssertEqual(item.createdAt, createdAtBefore)
    }
}
