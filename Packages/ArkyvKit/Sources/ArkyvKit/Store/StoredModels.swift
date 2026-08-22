import Foundation
import SwiftData

/// Local-first folder record. IDs are UUIDs generated on-device so a
/// capture can be filed and referenced immediately, before it's synced to
/// CloudKit.
@Model
public final class StoredFolder {
    /// CLOUDKIT READINESS (D1): no longer `@Attribute(.unique)`. SwiftData's
    /// CloudKit sync doesn't support unique constraints — CloudKit is an
    /// eventually-consistent, multi-device system with no cross-device
    /// transactional uniqueness check. Nothing replaces this at the
    /// database level; we rely on UUID collision-improbability, which is
    /// already the actual mechanism (every `init()` here already generates
    /// a fresh random `UUID()` — nothing has ever relied on `.unique`
    /// catching a real collision). CloudKit itself is NOT enabled by this
    /// change; this is schema-shape prep only.
    public var id: UUID = UUID()
    public var userID: UUID?
    /// CLOUDKIT READINESS (D1): every non-optional property below now
    /// carries an inline default value, in addition to (not instead of)
    /// the existing `init()` parameter defaults. This is required because
    /// CloudKit's own materialization path does not go through our custom
    /// `init()` — a property needs its own default at the declaration site
    /// to be CloudKit-compatible, or it must be Optional. These inline
    /// defaults don't change any existing call site's behavior: `init()`
    /// still explicitly assigns every one of them, same as before.
    public var name: String = ""
    /// Encoded `FolderIcon` token, e.g. "sf:star".
    public var iconToken: String = FolderIcon.default.token
    public var sortOrder: Int = 0
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    // Sync bookkeeping (used from Phase 2).
    /// Local mutation not yet reflected remotely.
    public var dirty: Bool = true
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

    /// CLOUDKIT READINESS (D2): `Optional`, not a plain `[StoredItem]`.
    /// SwiftData's CloudKit integration rejected the original non-optional
    /// array at container-open time with "CloudKit integration requires
    /// that all relationships be optional" — to-many relationships need
    /// this too, not just to-one. This is a schema-declaration change only;
    /// it doesn't change what's physically stored (child rows and their
    /// foreign keys are unaffected), so every read site below coalesces
    /// with `?? []` to preserve exact prior behavior.
    @Relationship(deleteRule: .cascade, inverse: \StoredItem.folder)
    public var items: [StoredItem]?

    /// v0.2 additive model: this folder's `StoredFolderMembership` rows —
    /// the new multi-folder join, living alongside (not replacing) `items`
    /// above. Cascade here only removes the membership rows themselves when
    /// a folder is hard-deleted; it does NOT cascade to `StoredItem`, so a
    /// hard-deleted folder can never take an item down through this
    /// relationship. Nothing reads this yet — see `MembershipMigration`.
    ///
    /// CLOUDKIT READINESS (D2): `Optional` for the same reason as `items`
    /// above.
    @Relationship(deleteRule: .cascade, inverse: \StoredFolderMembership.folder)
    public var memberships: [StoredFolderMembership]?

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
        (items ?? []).filter { !$0.isSoftDeleted }.count
    }
}

/// Local-first item record. Mirrors `items` plus reference-detail fields
/// (title, source URL, tags, favorite) surfaced in the Figma design, and
/// local image caching for offline use.
@Model
public final class StoredItem {
    /// CLOUDKIT READINESS (D1): no longer `@Attribute(.unique)` — see
    /// `StoredFolder.id`'s doc comment for why.
    public var id: UUID = UUID()
    public var userID: UUID?
    public var folder: StoredFolder?

    public var kindRaw: String = ItemKind.image.rawValue
    /// Remote Storage path (set after upload).
    public var storagePath: String?
    /// Local filename in `MediaStore`'s directory. Media Architecture
    /// Cutover 01: `MediaStore` is now a derived, disposable LOCAL
    /// WORKING CACHE, not a permanent original — see `imageData` below
    /// for the actual declared authority. `localFilename` remains the
    /// fast local read path every render tries first (unchanged); it's
    /// simply no longer required to exist for the Cherry to be safe.
    public var localFilename: String?

    /// **The declared authoritative durable media representation** —
    /// both locally (this is what a failed/evicted/never-written
    /// `MediaStore` cache reconstructs FROM) and remotely (`.externalStorage`
    /// is the same mechanism SwiftData's CloudKit integration maps to a
    /// `CKAsset`, so this field is what actually carries original media
    /// bytes to the user's private iCloud and back).
    ///
    /// Populated synchronously inside `Repository.fileCapture`, the exact
    /// same call that inserts and saves the `StoredItem` — the instant
    /// that `save()` returns successfully, this is durable (SQLite's ACID
    /// commit) independent of CloudKit upload timing, independent of
    /// network state, and independent of whether `MediaStore`'s file
    /// still exists. `ImageBackfill` populates it in small batches for
    /// historical items that predate D3A. `MediaStore.data(for:
    /// reconstructingFrom:)` is the routine, expected read path whenever
    /// the local cache is cold — not an emergency restore — reconstructing
    /// a byte-identical working file from this field, coalesced across
    /// concurrent requests by `MediaCacheCoordinator`.
    ///
    /// This authority model was validated empirically against real
    /// two-device CloudKit sync (Option 2 Validation Gate 01): a
    /// `StoredItem` never became query-visible on a receiving device
    /// without this field already being fully present, byte-readable,
    /// and decodable.
    @Attribute(.externalStorage) public var imageData: Data?

    public var ocrText: String?
    public var noteBody: String?
    public var title: String?
    public var sourceURL: String?
    public var tags: [String] = []
    public var isFavorite: Bool = false
    /// Editorial Cover V1: `true` only when `URLCherryResolver` found a
    /// real, standards-based article signal for this item's `sourceURL`
    /// at capture time — see `CaptureDraft.isEditorial` and
    /// `EditorialArticleDetector`. Same additive shape as `isFavorite`
    /// above: an inline default value at declaration, no new
    /// `VersionedSchema`/migration stage, every pre-existing item reads
    /// as `false` (correctly — no old item was ever classified). One
    /// Archive's masonry (`MasonryGrid`'s `aspect` closure) and cell
    /// rendering (`ArchiveView`) are the only readers; `ItemDetailView`
    /// deliberately never reads this — Item Detail always shows the
    /// original hero image regardless.
    public var isEditorial: Bool = false

    /// Aspect ratio hint for masonry layout (width/height), 0 if unknown.
    public var aspectWidth: Double = 0
    public var aspectHeight: Double = 0

    /// Non-destructive crop model: the original image (`localFilename`/
    /// `imageData` above) is always the canonical source and is never
    /// modified by cropping. These four fields are the user's normalized
    /// "point of view" into it — see `CropRegion`. Defaults of
    /// (0, 0, 1, 1) mean "full image, no crop," which is both the correct
    /// default for brand-new items and, not incidentally, the correct
    /// *existing* value for every item that predates this field: no
    /// backfill is needed, since "no crop stored" already means exactly
    /// what every pre-existing screenshot actually is.
    ///
    /// Plain scalar fields rather than a nested/Codable type, matching
    /// this file's existing convention (`iconToken`→`icon`, `kindRaw`→
    /// `kind`) — the safe, already-proven shape for a CloudKit-synced
    /// computed convenience property.
    public var cropX: Double = 0
    public var cropY: Double = 0
    public var cropWidth: Double = 1
    public var cropHeight: Double = 1

    public var sourceDeviceRaw: String = SourcePlatform.unknown.rawValue
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    // Sync bookkeeping.
    public var dirty: Bool = true
    /// Soft-delete tombstone timestamp — see `StoredFolder.deletedAt`'s doc
    /// comment for why this is a `Date?`, not a `Bool` named `isDeleted`.
    public var deletedAt: Date?
    public var remoteSyncedAt: Date?

    /// v0.2 additive model: this item's `StoredFolderMembership` rows — the
    /// new multi-folder join, living alongside (not replacing) `folder`
    /// above. `folder` remains the sole source of truth for existing
    /// behavior until Milestone B. See `MembershipMigration`.
    ///
    /// CLOUDKIT READINESS (D2): `Optional` — see `StoredFolder.items`'s doc
    /// comment for why.
    @Relationship(deleteRule: .cascade, inverse: \StoredFolderMembership.item)
    public var memberships: [StoredFolderMembership]?

    public init(
        id: UUID = UUID(),
        userID: UUID? = nil,
        folder: StoredFolder? = nil,
        kind: ItemKind,
        storagePath: String? = nil,
        localFilename: String? = nil,
        imageData: Data? = nil,
        ocrText: String? = nil,
        noteBody: String? = nil,
        title: String? = nil,
        sourceURL: String? = nil,
        tags: [String] = [],
        isFavorite: Bool = false,
        isEditorial: Bool = false,
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
        self.imageData = imageData
        self.ocrText = ocrText
        self.noteBody = noteBody
        self.title = title
        self.sourceURL = sourceURL
        self.tags = tags
        self.isFavorite = isFavorite
        self.isEditorial = isEditorial
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

    /// Convenience wrapper over `cropX`/`cropY`/`cropWidth`/`cropHeight`
    /// — see their doc comment. Not yet written to by `fileCapture` or
    /// read by any rendering code; that threading is a later, separate
    /// milestone. Every item currently reads as `.fullImage`.
    public var cropRegion: CropRegion {
        get { CropRegion(x: cropX, y: cropY, width: cropWidth, height: cropHeight) }
        set {
            cropX = newValue.rect.minX
            cropY = newValue.rect.minY
            cropWidth = newValue.rect.width
            cropHeight = newValue.rect.height
        }
    }

    public var sourceDevice: SourcePlatform {
        get { SourcePlatform(rawValue: sourceDeviceRaw) ?? .unknown }
        set { sourceDeviceRaw = newValue.rawValue }
    }

    /// The *cropped* aspect ratio — factors in `cropRegion` so grid/detail
    /// layout sizes to what's actually rendered (the crop), not the
    /// original's raw dimensions. For every item with the default
    /// `.fullImage` crop (`cropWidth == cropHeight == 1`), this reduces
    /// to exactly `aspectWidth / aspectHeight` — the same value this
    /// property has always returned — so existing items are unaffected.
    public var aspectRatio: Double {
        guard aspectWidth > 0, aspectHeight > 0, cropWidth > 0, cropHeight > 0 else { return 1 }
        return (aspectWidth * cropWidth) / (aspectHeight * cropHeight)
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
    /// CLOUDKIT READINESS (D1): no longer `@Attribute(.unique)` — see
    /// `StoredFolder.id`'s doc comment for why.
    public var id: UUID = UUID()
    public var item: StoredItem?
    public var folder: StoredFolder?
    public var createdAt: Date = Date.now

    // Sync bookkeeping — same shape as StoredFolder/StoredItem, for Phase 2
    // symmetry (used from Phase 2 onward).
    public var dirty: Bool = true
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
