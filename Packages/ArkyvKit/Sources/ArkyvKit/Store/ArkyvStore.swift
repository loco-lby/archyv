import Foundation
import SwiftData

/// Owns the SwiftData `ModelContainer` and exposes CRUD used by the app, the
/// Share Extension, and (later) the sync engine. The container lives in the
/// App Group so every process reads/writes the same local database.
public enum ArkyvStore {
    public static let schema = Schema([StoredFolder.self, StoredItem.self])

    /// Shared on-disk container. Falls back to an in-memory store if the
    /// on-disk store can't be opened, so the UI never hard-crashes at launch.
    public static func makeModelContainer(inMemory: Bool = false) -> ModelContainer {
        let url = AppGroup.containerURL.appendingPathComponent("arkyv.store")
        let config = inMemory
            ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            : ModelConfiguration(schema: schema, url: url)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            let mem = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            // If even this throws we genuinely can't run; crashing here is correct.
            return try! ModelContainer(for: schema, configurations: [mem])
        }
    }
}

/// Stateless helpers over a `ModelContext`. Kept as free functions so they can
/// be called from views (`@Environment(\.modelContext)`) and background actors.
public struct Repository {
    public var context: ModelContext
    public init(context: ModelContext) { self.context = context }

    // MARK: Folders

    public func folders(includingDeleted: Bool = false) throws -> [StoredFolder] {
        let descriptor = FetchDescriptor<StoredFolder>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        )
        let all = try context.fetch(descriptor)
        return includingDeleted ? all : all.filter { !$0.isDeleted }
    }

    @discardableResult
    public func createFolder(name: String, icon: FolderIcon, userID: UUID? = nil) throws -> StoredFolder {
        let nextOrder = (try folders().map(\.sortOrder).max() ?? -1) + 1
        let folder = StoredFolder(userID: userID, name: name, icon: icon, sortOrder: nextOrder)
        context.insert(folder)
        try context.save()
        return folder
    }

    public func rename(_ folder: StoredFolder, to name: String) throws {
        folder.name = name
        touch(folder)
        try context.save()
    }

    public func softDelete(_ folder: StoredFolder) throws {
        folder.isDeleted = true
        touch(folder)
        for item in folder.items { item.isDeleted = true; touch(item) }
        try context.save()
    }

    // MARK: Items

    public func items(in folder: StoredFolder) throws -> [StoredItem] {
        folder.items
            .filter { !$0.isDeleted }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Files a capture into a folder. This is the "one tap saves it" path.
    @discardableResult
    public func fileCapture(_ draft: CaptureDraft, into folder: StoredFolder) throws -> StoredItem {
        let item = StoredItem(
            userID: folder.userID,
            folder: folder,
            kind: draft.kind,
            localFilename: draft.localFilename,
            ocrText: draft.ocrText,
            noteBody: draft.noteBody,
            title: draft.title,
            sourceURL: draft.sourceURL,
            tags: draft.tags,
            aspectWidth: draft.pixelSize.map { Double($0.width) } ?? 0,
            aspectHeight: draft.pixelSize.map { Double($0.height) } ?? 0,
            sourceDevice: draft.sourceDevice
        )
        context.insert(item)
        touch(folder)
        try context.save()
        return item
    }

    public func move(_ item: StoredItem, to folder: StoredFolder) throws {
        let old = item.folder
        item.folder = folder
        touch(item); touch(folder)
        if let old { touch(old) }
        try context.save()
    }

    public func toggleFavorite(_ item: StoredItem) throws {
        item.isFavorite.toggle()
        touch(item)
        try context.save()
    }

    public func softDelete(_ item: StoredItem) throws {
        item.isDeleted = true
        touch(item)
        if let folder = item.folder { touch(folder) }
        try context.save()
    }

    /// Full-text-ish local search across title, notes, OCR text, tags, source.
    public func search(_ query: String) throws -> [StoredItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let descriptor = FetchDescriptor<StoredItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return try context.fetch(descriptor).filter { item in
            guard !item.isDeleted else { return false }
            let haystack = [item.title, item.noteBody, item.ocrText, item.sourceURL]
                .compactMap { $0 } + item.tags
            return haystack.contains { $0.lowercased().contains(q) }
        }
    }

    // MARK: Suggestion (rule-based for MVP; AI later)

    /// Picks the folder to pin at the top of the capture sheet. Rule-based:
    /// prefer a keyword match from OCR/title/source, else the most recently
    /// updated folder, else the first.
    public func suggestedFolder(for draft: CaptureDraft) throws -> StoredFolder? {
        let all = try folders()
        guard !all.isEmpty else { return nil }
        let text = [draft.ocrText, draft.title, draft.sourceURL, draft.noteBody]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        if !text.isEmpty {
            let scored = all
                .map { folder -> (StoredFolder, Int) in
                    let name = folder.name.lowercased()
                    var score = 0
                    if text.contains(name) { score += 5 }
                    for word in name.split(separator: " ") where word.count > 2 {
                        if text.contains(word) { score += 2 }
                    }
                    return (folder, score)
                }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
            if let best = scored.first?.0 { return best }
        }
        return all.max(by: { $0.updatedAt < $1.updatedAt }) ?? all.first
    }

    // MARK: Seeding

    /// Seeds the folders shown in the Figma design on first run.
    public func seedIfEmpty() throws {
        guard try folders(includingDeleted: true).isEmpty else { return }
        let seeds: [(String, FolderIcon)] = [
            ("Deadwest", .symbol("star")),
            ("Cool Shit", .symbol("face.smiling")),
            ("Recipes", .symbol("fork.knife")),
            ("Japan 2026", .symbol("airplane")),
            ("Inspiration", .symbol("paintpalette")),
        ]
        for (index, seed) in seeds.enumerated() {
            let folder = StoredFolder(name: seed.0, icon: seed.1, sortOrder: index)
            folder.dirty = false // seeded folders aren't "user changes" to push
            context.insert(folder)
        }
        try context.save()
    }

    // MARK: Helpers

    private func touch(_ folder: StoredFolder) {
        folder.updatedAt = .now
        folder.dirty = true
    }
    private func touch(_ item: StoredItem) {
        item.updatedAt = .now
        item.dirty = true
    }
}
