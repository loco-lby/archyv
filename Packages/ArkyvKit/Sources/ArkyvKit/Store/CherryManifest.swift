import Foundation
import SwiftData

#if DEBUG
/// Recovery/Portability Foundation 01 origin: a DEBUG-only proof that the
/// current models contain enough stable information to represent a
/// complete, portable archive manifest. Extended by Pre-Launch Migration
/// Ferry 01 with a real, narrow importer and `imageData` — still DEBUG/
/// internal-only tooling, still no UI, still not the eventual public
/// export format (see this type's own scope note below); the difference
/// is this is now a genuinely complete, one-time migration tool: export
/// captures everything needed to reconstruct a Cherry independently
/// (identity, media, crop, metadata, canonical folder relationship), and
/// `importArchive` reconstructs it through the same field-level semantics
/// `Repository` uses, into an isolated destination.
///
/// `export` proves the *shape* is representable (`Codable`, round-trips
/// through JSON without loss) and is not the finished, eventual public
/// export format — this remains internal migration tooling, not a
/// shipped product feature.
public enum CherryManifest {
    public struct Folder: Codable, Equatable {
        public var id: UUID
        public var name: String
        public var iconToken: String
        public var sortOrder: Int
        public var createdAt: Date
        public var deletedAt: Date?
    }

    public struct Item: Codable, Equatable {
        public var id: UUID
        public var kind: String
        /// The filename a real export's `media/` folder would contain —
        /// `nil` for non-media kinds (`.note`/`.text`), which is exactly
        /// the same optionality `StoredItem.localFilename` already has.
        public var localFilename: String?
        /// Pre-Launch Migration Ferry 01: the authoritative media bytes
        /// themselves, embedded directly — `imageData` is the declared
        /// authoritative representation (see `StoredItem.imageData`'s own
        /// doc comment), so a migration artifact that omits it isn't a
        /// complete Cherry. `Codable` encodes `Data` as base64 by default;
        /// deliberately accepted for this one-time internal migration tool
        /// (see this file's own doc comment on export-format scope) rather
        /// than a separate `media/` package. `nil` for non-media kinds,
        /// matching `StoredItem.imageData`'s own optionality.
        public var imageData: Data?
        public var aspectWidth: Double
        public var aspectHeight: Double
        /// Non-destructive crop, verbatim from `CropRegion` — see its own
        /// doc comment. A manifest reader reconstructs
        /// `CropRegion(x:y:width:height:)` directly from these.
        public var cropX: Double
        public var cropY: Double
        public var cropWidth: Double
        public var cropHeight: Double
        public var title: String?
        public var noteBody: String?
        public var sourceURL: String?
        public var tags: [String]
        public var isFavorite: Bool
        /// Active membership folder IDs only — mirrors
        /// `Repository.folders(for:)`, not the legacy single-owner
        /// `item.folder` (which is fully derivable from this array's
        /// first element, so isn't duplicated in the manifest).
        public var folderIDs: [UUID]
        public var createdAt: Date
        public var updatedAt: Date
        public var deletedAt: Date?
    }

    public struct Archive: Codable, Equatable {
        public var formatVersion: Int
        public var exportedAt: Date
        public var folders: [Folder]
        public var items: [Item]
    }

    /// Reads every folder/item/membership straight from the store —
    /// including soft-deleted rows, deliberately: a real export format
    /// should be able to represent "this was deleted, here's when" rather
    /// than silently drop tombstones, matching this whole codebase's
    /// soft-delete-only stance. No filtering decisions are made here.
    public static func export(context: ModelContext) throws -> Archive {
        let folders = try context.fetch(FetchDescriptor<StoredFolder>())
        let items = try context.fetch(FetchDescriptor<StoredItem>())
        let memberships = try context.fetch(FetchDescriptor<StoredFolderMembership>())

        let activeFolderIDsByItem = Dictionary(grouping: memberships.filter { !$0.isSoftDeleted && $0.folder?.isSoftDeleted == false }) {
            $0.item?.id
        }.compactMapValues { rows in rows.compactMap { $0.folder?.id } }

        return Archive(
            formatVersion: 1,
            exportedAt: .now,
            folders: folders.map {
                Folder(id: $0.id, name: $0.name, iconToken: $0.iconToken, sortOrder: $0.sortOrder, createdAt: $0.createdAt, deletedAt: $0.deletedAt)
            },
            items: items.map { item in
                Item(
                    id: item.id,
                    kind: item.kindRaw,
                    localFilename: item.localFilename,
                    imageData: item.imageData,
                    aspectWidth: item.aspectWidth,
                    aspectHeight: item.aspectHeight,
                    cropX: item.cropX,
                    cropY: item.cropY,
                    cropWidth: item.cropWidth,
                    cropHeight: item.cropHeight,
                    title: item.title,
                    noteBody: item.noteBody,
                    sourceURL: item.sourceURL,
                    tags: item.tags,
                    isFavorite: item.isFavorite,
                    folderIDs: activeFolderIDsByItem[item.id] ?? [],
                    createdAt: item.createdAt,
                    updatedAt: item.updatedAt,
                    deletedAt: item.deletedAt
                )
            }
        )
    }

    public static func encodeJSON(_ archive: Archive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(archive)
    }

    public static func decodeJSON(_ data: Data) throws -> Archive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Archive.self, from: data)
    }

    // MARK: - Import (Pre-Launch Migration Ferry 01)

    public enum ImportError: Error, Equatable {
        /// Real Archive Import 01: fail-closed by design, but scoped to
        /// what actually threatens correctness — an archive item or
        /// folder id already present in the destination, which would mean
        /// overwriting or ambiguously co-owning existing data. A
        /// destination that merely has OTHER, non-colliding content
        /// (e.g. items created directly in the new environment after a
        /// technical-identity cutover, before the legacy archive was
        /// imported) is safe and explicitly allowed — this is not a
        /// general-purpose merge engine, it never modifies or reads
        /// existing unrelated rows, it only ever inserts the archive's
        /// own new ones. Superseded `destinationNotEmpty` (Pre-Launch
        /// Migration Ferry 01's original, stricter "must be totally
        /// empty" rule) once a real cutover made "empty" the wrong
        /// question to ask.
        case identityCollision(itemIDs: Set<UUID>, folderIDs: Set<UUID>)
        /// Two items in the SAME archive share an id — the archive itself
        /// is malformed; this can never happen from a real `export()`
        /// call (SwiftData ids are unique), only from a hand-edited or
        /// corrupted artifact.
        case duplicateItemIdentity(UUID)
        /// An item's `folderIDs` references a folder id absent from the
        /// archive's own `folders` array — malformed artifact.
        case missingFolderReference(itemID: UUID, folderID: UUID)
    }

    public struct ImportSummary {
        public var foldersImported = 0
        public var itemsImported = 0
        public var membershipsImported = 0
        public var totalImageDataBytes = 0
    }

    /// Reconstructs `archive` into `context`. Fail-closed on identity
    /// collision (Real Archive Import 01) — refuses if any archive item
    /// or folder id already exists in the destination — but otherwise
    /// tolerates and never touches unrelated existing content. Builds
    /// every model object in memory first and calls `context.save()`
    /// exactly once at the end — SwiftData/CoreData's `save()` is one
    /// atomic commit, so this import is all-or-nothing by construction:
    /// if it throws, nothing was persisted (existing content, colliding
    /// or not, is completely unaffected either way), and there is no
    /// window where a caller could observe a partially-reconstructed
    /// archive as if it were complete.
    ///
    /// Deliberately does NOT go through `Repository.fileCapture` — that
    /// method sources `imageData` by reading a `MediaStore` file, which is
    /// exactly backwards for a migration import (the artifact's
    /// `imageData` is the source of truth here; there is no MediaStore
    /// file yet, nor should one be created — MediaStore stays a derived
    /// cache, populated later, normally, on first real access). Every
    /// other field-level rule (crop validity via `CropRegion`'s own
    /// `init`, the "0-or-1 active membership, item.folder mirrors it"
    /// single-folder invariant) is reproduced by hand here for exactly
    /// this reason, matching `Repository`/`FolderMembershipReconciler`'s
    /// own semantics rather than inventing new ones.
    @discardableResult
    public static func importArchive(_ archive: Archive, into context: ModelContext) throws -> ImportSummary {
        let existingItemIDs = Set(try context.fetch(FetchDescriptor<StoredItem>()).map(\.id))
        let existingFolderIDs = Set(try context.fetch(FetchDescriptor<StoredFolder>()).map(\.id))
        let collidingItemIDs = existingItemIDs.intersection(archive.items.map(\.id))
        let collidingFolderIDs = existingFolderIDs.intersection(archive.folders.map(\.id))
        guard collidingItemIDs.isEmpty, collidingFolderIDs.isEmpty else {
            throw ImportError.identityCollision(itemIDs: collidingItemIDs, folderIDs: collidingFolderIDs)
        }

        var seenItemIDs = Set<UUID>()
        for item in archive.items {
            guard seenItemIDs.insert(item.id).inserted else {
                throw ImportError.duplicateItemIdentity(item.id)
            }
        }
        let folderIDs = Set(archive.folders.map(\.id))
        for item in archive.items {
            for folderID in item.folderIDs where !folderIDs.contains(folderID) {
                throw ImportError.missingFolderReference(itemID: item.id, folderID: folderID)
            }
        }

        var summary = ImportSummary()

        var newFoldersByID: [UUID: StoredFolder] = [:]
        for folder in archive.folders {
            let newFolder = StoredFolder(
                id: folder.id,
                name: folder.name,
                icon: FolderIcon(token: folder.iconToken),
                sortOrder: folder.sortOrder,
                createdAt: folder.createdAt
            )
            newFolder.deletedAt = folder.deletedAt
            context.insert(newFolder)
            newFoldersByID[folder.id] = newFolder
            summary.foldersImported += 1
        }

        for item in archive.items {
            let newItem = StoredItem(
                id: item.id,
                kind: ItemKind(rawValue: item.kind) ?? .image,
                localFilename: item.localFilename,
                imageData: item.imageData,
                noteBody: item.noteBody,
                title: item.title,
                sourceURL: item.sourceURL,
                tags: item.tags,
                isFavorite: item.isFavorite,
                aspectWidth: item.aspectWidth,
                aspectHeight: item.aspectHeight,
                createdAt: item.createdAt
            )
            newItem.updatedAt = item.updatedAt
            newItem.deletedAt = item.deletedAt
            newItem.cropRegion = CropRegion(x: item.cropX, y: item.cropY, width: item.cropWidth, height: item.cropHeight)

            // Single-folder invariant, reproduced directly (see doc
            // comment above for why this doesn't go through
            // Repository/FolderMembershipReconciler): 0 folderIDs -> nil
            // legacy mirror, Unfiled; 1 -> that membership is canonical
            // and item.folder mirrors it. `export()` only ever writes 0
            // or 1 entries under the now-approved invariant, but this
            // loop tolerates more defensively rather than assuming.
            newItem.folder = item.folderIDs.first.flatMap { newFoldersByID[$0] }
            context.insert(newItem)
            summary.itemsImported += 1
            summary.totalImageDataBytes += item.imageData?.count ?? 0

            for folderID in item.folderIDs {
                guard let newFolder = newFoldersByID[folderID] else { continue }
                context.insert(StoredFolderMembership(item: newItem, folder: newFolder, createdAt: item.createdAt))
                summary.membershipsImported += 1
            }
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return summary
    }
}
#endif
