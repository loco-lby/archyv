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
}
