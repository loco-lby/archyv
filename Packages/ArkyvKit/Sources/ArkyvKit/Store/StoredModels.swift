import Foundation
import SwiftData

/// Local-first folder record. Mirrors the `folders` table plus local-only
/// sync bookkeeping. IDs are UUIDs generated on-device so a capture can be
/// filed and referenced before it ever reaches Supabase.
@Model
public final class StoredFolder {
    @Attribute(.unique) public var id: UUID
    public var userID: UUID?
    public var name: String
    /// Encoded `FolderIcon` token, e.g. "sf:star".
    public var iconToken: String
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    // Sync bookkeeping (used from Phase 2).
    /// Local mutation not yet reflected remotely.
    public var dirty: Bool
    /// Soft-delete tombstone timestamp so the deletion can propagate before
    /// purge — `nil` means active, non-`nil` means soft-deleted at that
    /// moment.
    ///
    /// NAMING: this was originally a stored `Bool` named `isDeleted`.
    /// Renamed as a root-cause fix for a Milestone B/C persistence bug —
    /// `PersistentModel`/SwiftData's Core-Data-derived object graph
    /// reserves deletion-lifecycle semantics for exactly that identifier,
    /// and a stored application property of the same name was silently
    /// losing writes across `ModelContext.save()` specifically for that
    /// field (confirmed via physical-device trace: the assignment took
    /// effect in memory and pre-save, but reverted after a successful
    /// save, while a sibling `Bool` set the same way one line away
    /// persisted correctly). See `isSoftDeleted` below for the boolean
    /// convenience every existing call site used.
    public var deletedAt: Date?
    public var remoteSyncedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \StoredItem.folder)
    public var items: [StoredItem]

    /// v0.2 additive model: this folder's `StoredFolderMembership` rows —
    /// the new multi-folder join, living alongside (not replacing) `items`
    /// above. Cascade here only removes the membership rows themselves when
    /// a folder is hard-deleted; it does NOT cascade to `StoredItem`, so a
    /// hard-deleted folder can never take an item down through this
    /// relationship. Nothing reads this yet — see `MembershipMigration`.
    @Relationship(deleteRule: .cascade, inverse: \StoredFolderMembership.folder)
    public var memberships: [StoredFolderMembership]

    public init(
        id: UUID = UUID(),
        userID: UUID? = nil,
        name: String,
        icon: FolderIcon = .default,
        sortOrder: Int = 0,
        createdAt: Date = .now
    ) {
        self.id = id
        self.userID = userID
        self.name = name
        self.iconToken = icon.token
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.dirty = true
        self.deletedAt = nil
        self.remoteSyncedAt = nil
        self.items = []
        self.memberships = []
    }

    public var icon: FolderIcon {
        get { FolderIcon(token: iconToken) }
        set { iconToken = newValue.token }
    }

    /// `true` iff `deletedAt` is set. Kept as the boolean call sites already
    /// expect (`!folder.isSoftDeleted`, mirroring the old `!folder.isDeleted`)
    /// rather than rewriting every predicate to a nil-check by hand.
    public var isSoftDeleted: Bool { deletedAt != nil }

    /// Live count of non-deleted items ("N references" in the UI).
    public var referenceCount: Int {
        items.filter { !$0.isSoftDeleted }.count
    }
}

/// Local-first item record. Mirrors `items` plus reference-detail fields
/// (title, source URL, tags, favorite) surfaced in the Figma design, and
/// local image caching for offline use.
@Model
public final class StoredItem {
    @Attribute(.unique) public var id: UUID
    public var userID: UUID?
    public var folder: StoredFolder?

    public var kindRaw: String
    /// Remote Storage path (set after upload).
    public var storagePath: String?
    /// Local cached image filename in Application Support/Media.
    public var localFilename: String?

    public var ocrText: String?
    public var noteBody: String?
    public var title: String?
    public var sourceURL: String?
    public var tags: [String]
    public var isFavorite: Bool

    /// Aspect ratio hint for masonry layout (width/height), 0 if unknown.
    public var aspectWidth: Double
    public var aspectHeight: Double

    public var sourceDeviceRaw: String
    public var createdAt: Date
    public var updatedAt: Date

    // Sync bookkeeping.
    public var dirty: Bool
    /// Soft-delete tombstone timestamp — see `StoredFolder.deletedAt`'s doc
    /// comment for why this is a `Date?`, not a `Bool` named `isDeleted`.
    public var deletedAt: Date?
    public var remoteSyncedAt: Date?

    /// v0.2 additive model: this item's `StoredFolderMembership` rows — the
    /// new multi-folder join, living alongside (not replacing) `folder`
    /// above. `folder` remains the sole source of truth for existing
    /// behavior until Milestone B. See `MembershipMigration`.
    @Relationship(deleteRule: .cascade, inverse: \StoredFolderMembership.item)
    public var memberships: [StoredFolderMembership]

    public init(
        id: UUID = UUID(),
        userID: UUID? = nil,
        folder: StoredFolder? = nil,
        kind: ItemKind,
        storagePath: String? = nil,
        localFilename: String? = nil,
        ocrText: String? = nil,
        noteBody: String? = nil,
        title: String? = nil,
        sourceURL: String? = nil,
        tags: [String] = [],
        isFavorite: Bool = false,
        aspectWidth: Double = 0,
        aspectHeight: Double = 0,
        sourceDevice: SourcePlatform = .unknown,
        createdAt: Date = .now
    ) {
        self.id = id
        self.userID = userID
        self.folder = folder
        self.kindRaw = kind.rawValue
        self.storagePath = storagePath
        self.localFilename = localFilename
        self.ocrText = ocrText
        self.noteBody = noteBody
        self.title = title
        self.sourceURL = sourceURL
        self.tags = tags
        self.isFavorite = isFavorite
        self.aspectWidth = aspectWidth
        self.aspectHeight = aspectHeight
        self.sourceDeviceRaw = sourceDevice.rawValue
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.dirty = true
        self.deletedAt = nil
        self.remoteSyncedAt = nil
        self.memberships = []
    }

    public var kind: ItemKind {
        get { ItemKind(rawValue: kindRaw) ?? .image }
        set { kindRaw = newValue.rawValue }
    }

    public var sourceDevice: SourcePlatform {
        get { SourcePlatform(rawValue: sourceDeviceRaw) ?? .unknown }
        set { sourceDeviceRaw = newValue.rawValue }
    }

    public var aspectRatio: Double {
        guard aspectWidth > 0, aspectHeight > 0 else { return 1 }
        return aspectWidth / aspectHeight
    }

    /// `true` iff `deletedAt` is set — see `StoredFolder.isSoftDeleted`.
    public var isSoftDeleted: Bool { deletedAt != nil }
}

/// v0.2 canonical model: one row per (item, folder) membership. An item may
/// have zero, one, or many of these — the replacement for the legacy
/// single-owner `StoredItem.folder` relationship, which this type lives
/// *alongside* rather than replaces for now (see `MembershipMigration`).
/// "Unfiled" is not a stored flag — it's simply an item with zero active
/// (non-soft-deleted) memberships.
@Model
public final class StoredFolderMembership {
    @Attribute(.unique) public var id: UUID
    public var item: StoredItem?
    public var folder: StoredFolder?
    public var createdAt: Date

    // Sync bookkeeping — same shape as StoredFolder/StoredItem, for Phase 2
    // symmetry (used from Phase 2 onward).
    public var dirty: Bool
    /// Soft-delete tombstone timestamp — see `StoredFolder.deletedAt`'s doc
    /// comment. This field is exactly where the Milestone B/C "old
    /// membership survives an exclusive move" bug was root-caused: a
    /// stored `Bool` here named `isDeleted` was the property whose writes
    /// were being silently lost across `save()`.
    public var deletedAt: Date?
    public var remoteSyncedAt: Date?

    public init(
        id: UUID = UUID(),
        item: StoredItem? = nil,
        folder: StoredFolder? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.item = item
        self.folder = folder
        self.createdAt = createdAt
        self.dirty = true
        self.deletedAt = nil
        self.remoteSyncedAt = nil
    }

    /// `true` iff `deletedAt` is set — see `StoredFolder.isSoftDeleted`.
    public var isSoftDeleted: Bool { deletedAt != nil }
}
