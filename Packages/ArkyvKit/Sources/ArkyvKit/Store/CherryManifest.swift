import Foundation
import SwiftData

#if DEBUG
/// Recovery/Portability Foundation 01: a DEBUG-only, read-only proof that
/// the current models contain enough stable information to represent a
/// complete, portable archive manifest — the Phase 4 question this exists
/// to answer. NOT a shipped export feature: no UI, no import path, no
/// product behavior change. `Repository.fileCapture`/`updateNote`/etc. are
/// never called from here; this only ever *reads*.
///
/// Deliberately narrow: this proves the *shape* is representable
/// (`Codable`, round-trips through JSON without loss) — it is not a
/// finished export format, doesn't touch media bytes (a manifest entry
/// references `localFilename`, matching a real future `media/` folder in
/// the archive-package shape sketched in the Recovery/Portability
/// Contract), and doesn't decide product UX for a future export feature.
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
}
#endif
