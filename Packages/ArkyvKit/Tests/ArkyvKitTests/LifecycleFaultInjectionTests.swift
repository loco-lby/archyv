import XCTest
import SwiftData
@testable import ArkyvKit

/// Lifecycle / Fault Injection Foundation 01.
///
/// Stresses `Repository.save()`'s rollback contract (added in Data
/// Integrity Foundation 01) across every representative mutation kind, not
/// just `fileCapture`/`setMemberships` (already covered in
/// RepositoryTests). No new fault-injection production code was added for
/// this — every test here reuses the same genuine, non-mocked failure
/// technique `testFileCaptureRollsBackOnSaveFailureRatherThanPoisoningTheContext`
/// already established: `ModelContext.save()` commits everything pending on
/// that context, not just what the method under test touched, so inserting
/// a relationship to an object from a DIFFERENT container's context — and
/// leaving it pending, unsaved, on the context under test — makes the
/// *next* save on that context genuinely fail, exactly as a real bug or
/// race elsewhere in the same long-lived `container.mainContext` might.
final class LifecycleFaultInjectionTests: XCTestCase {
    @MainActor
    private func makeRepo() throws -> Repository {
        let container = ArkyvStore.makeModelContainer(inMemory: true)
        return Repository(context: container.mainContext)
    }

    /// Inserts a pending, never-saved relationship from `item` to a folder
    /// that belongs to an entirely different container/context, directly
    /// on `repo`'s own context (bypassing `Repository` itself). The next
    /// `try repo.context.save()` — triggered from *any* Repository method,
    /// not just one that touches this relationship — will genuinely throw.
    @MainActor
    private func poisonContext(_ repo: Repository, item: StoredItem) throws {
        let otherRepo = try makeRepo()
        let foreignFolder = try otherRepo.createFolder(name: "Elsewhere", icon: .symbol("star"))
        repo.context.insert(StoredFolderMembership(item: item, folder: foreignFolder))
    }

    // MARK: - Representative mutation rollback

    @MainActor
    func testUpdateNoteRollsBackOnInjectedSaveFailureAndPreservesPriorValue() throws {
        let repo = try makeRepo()
        let item = try repo.fileCapture(.note("original"))
        try poisonContext(repo, item: item)

        XCTAssertThrowsError(try repo.updateNote(item, body: "should not persist"))
        XCTAssertEqual(item.noteBody, "original", "a failed save must roll the in-memory mutation back to the last-saved value, not leave the attempted edit sitting on the object")

        // Retry safety: the poisoned pending insert was itself discarded
        // by the same rollback, so a clean call on the same context now
        // succeeds normally.
        try repo.updateNote(item, body: "second attempt")
        XCTAssertEqual(item.noteBody, "second attempt")
    }

    @MainActor
    func testUpdateSourceURLRollsBackOnInjectedSaveFailure() throws {
        let repo = try makeRepo()
        let item = try repo.fileCapture(CaptureDraft(kind: .note, sourceURL: "https://original.example"))
        try poisonContext(repo, item: item)

        XCTAssertThrowsError(try repo.updateSourceURL(item, to: "https://attacker.example"))
        XCTAssertEqual(item.sourceURL, "https://original.example")

        try repo.updateSourceURL(item, to: "https://retry.example")
        XCTAssertEqual(item.sourceURL, "https://retry.example")
    }

    @MainActor
    func testUpdateTagsRollsBackOnInjectedSaveFailure() throws {
        let repo = try makeRepo()
        let item = try repo.fileCapture(CaptureDraft(kind: .note, tags: ["keep"]))
        try poisonContext(repo, item: item)

        XCTAssertThrowsError(try repo.updateTags(item, to: ["should", "not", "persist"]))
        XCTAssertEqual(item.tags, ["keep"])

        try repo.updateTags(item, to: ["kept", "and", "new"])
        XCTAssertEqual(item.tags, ["kept", "and", "new"])
    }

    @MainActor
    func testToggleFavoriteRollsBackOnInjectedSaveFailure() throws {
        let repo = try makeRepo()
        let item = try repo.fileCapture(.note("hello"))
        XCTAssertFalse(item.isFavorite)
        try poisonContext(repo, item: item)

        XCTAssertThrowsError(try repo.toggleFavorite(item))
        XCTAssertFalse(item.isFavorite, "the toggle itself must be rolled back, not just left un-saved")

        try repo.toggleFavorite(item)
        XCTAssertTrue(item.isFavorite)
    }

    /// Directly exercises Section 7 (Crop Interruption Safety) and Section
    /// 8 (rollback verification) together: a failed re-crop save must
    /// never erase the previously-valid crop.
    @MainActor
    func testUpdateCropRegionRollsBackOnInjectedSaveFailureLeavingPreviousCropIntact() throws {
        let repo = try makeRepo()
        let originalRegion = CropRegion(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let item = try repo.fileCapture(CaptureDraft(kind: .screenshot, cropRegion: originalRegion))
        try poisonContext(repo, item: item)

        let attemptedRegion = CropRegion(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        XCTAssertThrowsError(try repo.updateCropRegion(item, to: attemptedRegion))
        XCTAssertEqual(item.cropRegion, originalRegion, "a failed re-crop save must leave the previous valid crop exactly as it was — never a partially-applied or blank region")

        try repo.updateCropRegion(item, to: attemptedRegion)
        XCTAssertEqual(item.cropRegion, attemptedRegion)
    }

    @MainActor
    func testSoftDeleteItemRollsBackOnInjectedSaveFailure() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])
        try poisonContext(repo, item: item)

        XCTAssertThrowsError(try repo.softDelete(item))
        XCTAssertFalse(item.isSoftDeleted, "a failed soft-delete save must not leave the item half-deleted")
        XCTAssertEqual(try repo.memberships(for: item).count, 1, "memberships must not be deactivated either — the whole mutation is one unit")

        try repo.softDelete(item)
        XCTAssertTrue(item.isSoftDeleted)
    }

    /// `move` naturally exercises the SAME failure technique as its own
    /// direct trigger (the destination folder itself is the foreign
    /// object), rather than needing `poisonContext`'s indirection — this
    /// is the original Data Integrity Foundation 01 shape, included here
    /// for completeness alongside the other mutation kinds.
    @MainActor
    func testMoveRollsBackOnInjectedSaveFailureLeavingPriorMembershipIntact() throws {
        let repo = try makeRepo()
        let otherRepo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let foreignFolder = try otherRepo.createFolder(name: "Elsewhere", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])

        XCTAssertThrowsError(try repo.move(item, to: foreignFolder))
        let resultIDs = try repo.folders(for: item).map(\.id)
        XCTAssertEqual(resultIDs, [deadwest.id], "the item must still be exactly where it was before the failed move")
        XCTAssertEqual(item.folder?.id, deadwest.id)
    }

    // MARK: - Section 6: Folder room's direct-mutation-plus-setMemberships shape
    //
    // Reproduces exactly what ItemDetailView's Folder room does for
    // "Unfiled": `item.folder` is mutated directly, THEN `setMemberships`
    // is called. Proves the specific invariant the fix in ItemDetailView
    // relies on: when setMemberships's own save() fails, ITS rollback
    // reverts every pending change on the shared context — including the
    // direct `item.folder = nil` mutation made just before it was called,
    // not only the membership-row changes setMemberships itself made.

    @MainActor
    func testDirectFolderMutationRollsBackTogetherWithAFailedSetMembershipsCall() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])
        try poisonContext(repo, item: item)

        item.folder = nil // the direct mutation the Folder room's "Unfiled" path performs
        XCTAssertThrowsError(try repo.setMemberships(item, to: []))

        XCTAssertEqual(item.folder?.id, deadwest.id, "setMemberships's rollback must revert the OUTER item.folder mutation too, not just its own membership-row changes — otherwise a failed 'Unfiled' confirm would silently half-apply")
        XCTAssertEqual(try repo.memberships(for: item).count, 1)
    }

    // MARK: - Section 9: relaunch integrity

    /// A confirmed crop must survive being read from a completely fresh
    /// `ModelContext` on the same container — the closest a unit test can
    /// get to "force-quit and relaunch" without a real process boundary.
    @MainActor
    func testConfirmedCropSurvivesAFreshModelContextRelaunch() throws {
        let container = ArkyvStore.makeModelContainer(inMemory: true)
        let repo = Repository(context: container.mainContext)
        let region = CropRegion(x: 0.15, y: 0.15, width: 0.4, height: 0.4)
        let item = try repo.fileCapture(CaptureDraft(kind: .screenshot))
        try repo.updateCropRegion(item, to: region)

        let freshContext = ModelContext(container)
        let freshItem = try XCTUnwrap(try freshContext.fetch(FetchDescriptor<StoredItem>()).first { $0.id == item.id })
        XCTAssertEqual(freshItem.cropRegion, region)
    }

    /// Combines a genuinely failed mutation (rolled back, per the tests
    /// above) with the existing DEBUG `IntegrityCheck` — Section 9's
    /// explicit ask to reuse that scan as the "did relaunch see a clean
    /// store" check rather than duplicating its logic here. A rolled-back
    /// failure must leave nothing behind for it to flag.
    @MainActor
    func testIntegrityCheckStaysCleanAfterAFailedMutationRollsBack() throws {
        let repo = try makeRepo()
        let deadwest = try repo.createFolder(name: "Deadwest", icon: .symbol("star"))
        let item = try repo.fileCapture(.note("hello"), folders: [deadwest])
        try poisonContext(repo, item: item)

        XCTAssertThrowsError(try repo.updateTags(item, to: ["poisoned-attempt"]))

        let report = IntegrityCheck.run(context: repo.context)
        XCTAssertTrue(report.isClean, "a rolled-back failure must leave no trace an integrity scan would flag")
        XCTAssertEqual(report.itemCount, 1)
        XCTAssertEqual(report.membershipCount, 1)
    }
}
