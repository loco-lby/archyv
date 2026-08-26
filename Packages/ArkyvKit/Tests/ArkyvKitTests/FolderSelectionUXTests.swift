import XCTest
import SwiftData
@testable import ArkyvKit

/// Context + Single-Folder UX 01. `FolderSelectionUXTests` pins the pure
/// tap-interpretation rule shared by both folder pickers; the persistence
/// half below proves every resulting Repository write still satisfies the
/// single-folder invariant (0 or 1 active membership, `item.folder`
/// mirrors it, no duplicates, no disagreement) — the same machinery both
/// pickers already route through, unchanged by this milestone.
final class FolderSelectionUXTests: XCTestCase {
    // MARK: - Pure toggle rule

    func testSelectingDifferentFolderReplacesSelection() {
        let folderAID = UUID()
        let folderBID = UUID()
        XCTAssertEqual(FolderSelectionUX.toggling(current: folderAID, tapped: folderBID), folderBID)
    }

    func testTappingCurrentlySelectedFolderClearsToUnfiled() {
        let folderID = UUID()
        XCTAssertNil(FolderSelectionUX.toggling(current: folderID, tapped: folderID))
    }

    func testSelectingFromUnfiledSelectsThatFolder() {
        let folderID = UUID()
        XCTAssertEqual(FolderSelectionUX.toggling(current: nil, tapped: folderID), folderID)
    }

    func testRepeatedTapIsIdempotentOnceCleared() {
        let folderID = UUID()
        let afterFirstTap = FolderSelectionUX.toggling(current: folderID, tapped: folderID)
        XCTAssertNil(afterFirstTap)
        let afterSecondIdenticalCall = FolderSelectionUX.toggling(current: afterFirstTap, tapped: folderID)
        XCTAssertEqual(afterSecondIdenticalCall, folderID, "tapping again from cleared state re-selects, exactly like tapping any other Unfiled row")
    }

    // MARK: - Persistence invariants after the resulting Repository call

    @MainActor
    private func makeRepo() throws -> Repository {
        let container = try! ArkyvStore.makeModelContainer(inMemory: true)
        return Repository(context: container.mainContext)
    }

    @MainActor
    private func makeTestItem(repo: Repository) throws -> StoredItem {
        try repo.fileCapture(CaptureDraft(kind: .note, noteBody: "test"), folders: [])
    }

    @MainActor
    func testFolderAToFolderBResultsInExactlyOneActiveMembership() throws {
        let repo = try makeRepo()
        let folderA = try repo.createFolder(name: "A", icon: .symbol("star"))
        let folderB = try repo.createFolder(name: "B", icon: .symbol("star"))
        let item = try makeTestItem(repo: repo)

        try repo.move(item, to: folderA)
        try repo.move(item, to: folderB)

        let memberships = try repo.memberships(for: item)
        XCTAssertEqual(memberships.count, 1)
        XCTAssertEqual(memberships.first?.folder?.id, folderB.id)
        XCTAssertEqual(item.folder?.id, folderB.id, "item.folder must mirror the canonical membership")

        let check = IntegrityCheck.run(context: repo.context)
        XCTAssertTrue(check.isClean)
        XCTAssertEqual(check.duplicateActiveMemberships.count, 0)
        XCTAssertEqual(check.itemsWithMultipleActiveFolders.count, 0)
        XCTAssertEqual(check.folderMembershipDisagreements.count, 0)
    }

    @MainActor
    func testUnfiledToFolderThenBackToUnfiledEndsWithZeroMemberships() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "A", icon: .symbol("star"))
        let item = try makeTestItem(repo: repo)

        try repo.move(item, to: folder)
        XCTAssertEqual(try repo.memberships(for: item).count, 1)

        // "Selecting Unfiled" — same shape FolderEditorView's onConfirm
        // and the Share Extension's Unfiled row both use.
        item.folder = nil
        try repo.setMemberships(item, to: [])

        XCTAssertEqual(try repo.memberships(for: item).count, 0)
        XCTAssertNil(item.folder)

        let check = IntegrityCheck.run(context: repo.context)
        XCTAssertTrue(check.isClean)
    }

    @MainActor
    func testRepeatedMoveToSameFolderStaysAtOneMembership() throws {
        let repo = try makeRepo()
        let folder = try repo.createFolder(name: "A", icon: .symbol("star"))
        let item = try makeTestItem(repo: repo)

        try repo.move(item, to: folder)
        try repo.move(item, to: folder)
        try repo.move(item, to: folder)

        XCTAssertEqual(try repo.memberships(for: item).count, 1, "moving to the same folder repeatedly must never accumulate duplicate memberships")
        let check = IntegrityCheck.run(context: repo.context)
        XCTAssertEqual(check.duplicateActiveMemberships.count, 0)
    }
}
