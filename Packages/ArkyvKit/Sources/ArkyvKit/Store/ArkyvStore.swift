import Foundation
import SwiftData

/// Owns the SwiftData `ModelContainer` and exposes CRUD used by the app, the
/// Share Extension, and (later) the sync engine. The container lives in the
/// App Group so every process reads/writes the same local database.
public enum ArkyvStore {
    /// CLOUDKIT READINESS (D1): now derived from `ArkyvSchemaV1` rather than
    /// a flat, unversioned `Schema([...])` — see `ArkyvSchema.swift`. The
    /// set of models and their shape is unchanged by this; only how the
    /// schema is declared changed.
    public static let schema = Schema(versionedSchema: ArkyvSchemaV1.self)

    /// D2: the CloudKit private database this store mirrors to, once opened
    /// with `cloudKitDatabase:` below. Registered under the app's iCloud
    /// container entitlement — see `Arkyv.entitlements` /
    /// `ArkyvShare.entitlements`. CloudKit sync is opportunistic and
    /// entirely background: SwiftData still reads/writes the local on-disk
    /// store first and immediately, the same as before this milestone, so
    /// the app has no new dependency on network/iCloud availability for any
    /// existing read or write path.
    private static let cloudKitContainerID = "iCloud.com.expatinsurance.arkyv"

    /// Shared on-disk container. Falls back to an in-memory store if the
    /// on-disk store can't be opened, so the UI never hard-crashes at launch.
    public static func makeModelContainer(inMemory: Bool = false) -> ModelContainer {
        let url = AppGroup.containerURL.appendingPathComponent("arkyv.store")
        let config = inMemory
            ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            : ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .private(cloudKitContainerID))
        do {
            return try ModelContainer(for: schema, migrationPlan: ArkyvMigrationPlan.self, configurations: [config])
        } catch {
            #if DEBUG
            print("[ArkyvStore] CloudKit-backed container failed to open, falling back to IN-MEMORY store (existing on-disk data is untouched): \(error)")
            #endif
            // In-memory only: CloudKit mirroring requires a persistent
            // store, so this fallback is never CloudKit-backed regardless
            // of why the primary container above failed.
            let mem = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            // If even this throws we genuinely can't run; crashing here is correct.
            return try! ModelContainer(for: schema, migrationPlan: ArkyvMigrationPlan.self, configurations: [mem])
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
        return includingDeleted ? all : all.filter { !$0.isSoftDeleted }
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

    /// Soft-deletes `folder`. As of v0.2 this NEVER touches `StoredItem` —
    /// only the folder itself and its `StoredFolderMembership` rows are
    /// deactivated. A reference that was only in this folder survives with
    /// zero active memberships (naturally "Unfiled" — see
    /// `StoredFolderMembership`'s doc comment); a reference also in other
    /// folders keeps those memberships untouched. Notes, favorites, media
    /// files, and every other item field are never touched here.
    ///
    /// This replaces the pre-v0.2 behavior, which iterated `folder.items`
    /// and marked every one of them deleted too — i.e. deleting a folder
    /// used to destroy its contents. That's exactly what the new Archive
    /// model forbids ("removing a folder membership never deletes the
    /// reference"), so it's gone as of this milestone.
    public func softDelete(_ folder: StoredFolder) throws {
        folder.deletedAt = .now
        touch(folder)
        for membership in folder.memberships ?? [] where !membership.isSoftDeleted {
            membership.deletedAt = .now
            membership.dirty = true
        }
        try context.save()
    }

    // MARK: Items

    /// Items currently in `folder`, derived from active
    /// `StoredFolderMembership` rows — the v0.2 canonical read. Same
    /// signature/behavior contract as before (non-deleted items, newest
    /// first); only what it consults internally has changed, so existing
    /// callers don't need to change.
    public func items(in folder: StoredFolder) throws -> [StoredItem] {
        (folder.memberships ?? [])
            .filter { !$0.isSoftDeleted }
            .compactMap { $0.item }
            .filter { !$0.isSoftDeleted }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Files a capture, creating one `StoredFolderMembership` per folder
    /// supplied — zero, one, or many, per the v0.2 canonical model. This is
    /// the repository's source of truth for membership going forward.
    /// Deleted folders are ignored; duplicate folders in `folders` produce
    /// exactly one membership each.
    ///
    /// TRANSITIONAL COMPATIBILITY DEBT: every current UI surface (HomeView's
    /// folder list, FolderGridView's masonry grid, ItemDetailView's header)
    /// still reads the *legacy* `StoredFolder.items` / `StoredItem.folder`
    /// relationship, not memberships — nothing reads memberships yet (see
    /// Milestone A). So this also sets `item.folder` to the first folder in
    /// `folders` (or `nil` if empty), purely so an item filed today still
    /// shows up wherever the current UI already expects to find it. This is
    /// NOT bidirectional sync with the full membership set: if more than
    /// one folder is passed, `item.folder` reflects only the first, and the
    /// legacy relationship is never consulted or corrected again after this
    /// call. Remove this assignment once the UI that reads `folder`/`items`
    /// is replaced by membership-aware views (later milestone).
    @discardableResult
    public func fileCapture(_ draft: CaptureDraft, folders: [StoredFolder] = []) throws -> StoredItem {
        let validFolders = folders.filter { !$0.isSoftDeleted }
        // D3A: read the just-written JPEG back from MediaStore and carry it
        // into `imageData` (the CloudKit `.externalStorage` transport field
        // added in D1, unused until now) so newly captured images actually
        // sync — not just their metadata rows (proven in D2). `localFilename`
        // stays the only local read path; this is a second, CloudKit-only
        // copy, deliberately redundant on-device storage for now. `nil` for
        // non-image drafts (no `localFilename`) and for every item that
        // predates this milestone — no backfill happens here.
        let imageData = draft.localFilename.flatMap { MediaStore.shared.data(for: $0) }
        let item = StoredItem(
            userID: validFolders.first?.userID,
            folder: validFolders.first,
            kind: draft.kind,
            localFilename: draft.localFilename,
            imageData: imageData,
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

        var seenFolderIDs = Set<UUID>()
        for folder in validFolders where seenFolderIDs.insert(folder.id).inserted {
            context.insert(StoredFolderMembership(item: item, folder: folder))
            touch(folder)
        }

        try context.save()
        return item
    }

    /// Legacy single-folder convenience — still the "one tap saves it" path
    /// every current UI call site uses (`ScreenshotCaptureFlowView`,
    /// `CaptureCoordinator`, the Share Extension). Internally just
    /// `fileCapture(_:folders:)` with a one-element array, so none of those
    /// call sites need to change shape for this milestone.
    @discardableResult
    public func fileCapture(_ draft: CaptureDraft, into folder: StoredFolder) throws -> StoredItem {
        try fileCapture(draft, folders: [folder])
    }

    /// Reassigns `item`'s legacy single destination folder — the semantics
    /// Item Detail's "Move to..." UI already expects, unchanged from the
    /// caller's point of view.
    ///
    /// FIX: `items(in:)` became membership-backed in Milestone B, but this
    /// method originally only reassigned the legacy `item.folder` field —
    /// so a moved item could still show up in its *old* folder (via its
    /// stale membership row) and not its new one. This now also reconciles
    /// membership via `setMemberships`, so after this call the active
    /// membership set is exactly `{ folder }`, matching what "Move to..."
    /// visibly does. `item.folder = folder` remains as transitional legacy
    /// compatibility (same debt already documented on `fileCapture`) — the
    /// future membership popover replaces this single-destination UX
    /// entirely and will call `setMemberships` directly.
    ///
    /// No-ops (ignores) if `item` or `folder` is deleted, consistent with
    /// `addMembership`/`removeMembership`. Idempotent: moving to the
    /// already-current sole folder touches nothing and saves nothing,
    /// because `setMemberships` itself no-ops when the desired set already
    /// matches.
    public func move(_ item: StoredItem, to folder: StoredFolder) throws {
        guard !item.isSoftDeleted, !folder.isSoftDeleted else { return }
        item.folder = folder
        try setMemberships(item, to: [folder])
    }

    public func toggleFavorite(_ item: StoredItem) throws {
        item.isFavorite.toggle()
        touch(item)
        try context.save()
    }

    /// Updates an item's note body. Whitespace-only text normalizes to
    /// `nil` — there's no value in persisting a note that's just spaces,
    /// and this keeps "cleared the note" and "never wrote one" the same
    /// state rather than two representations of "empty." No-ops (skips the
    /// write entirely) when the normalized value already matches, so
    /// callers doing autosave with multiple flush triggers (debounce, focus
    /// loss, backgrounding, etc.) can call this redundantly without
    /// generating pointless `dirty`/`updatedAt` churn.
    public func updateNote(_ item: StoredItem, body: String?) throws {
        let trimmed = body?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard normalized != item.noteBody else { return }
        item.noteBody = normalized
        touch(item)
        try context.save()
    }

    public func softDelete(_ item: StoredItem) throws {
        item.deletedAt = .now
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
            guard !item.isSoftDeleted else { return false }
            let haystack = [item.title, item.noteBody, item.ocrText, item.sourceURL]
                .compactMap { $0 } + item.tags
            return haystack.contains { $0.lowercased().contains(q) }
        }
    }

    // MARK: Folder Memberships (v0.2 canonical model)
    //
    // The repository-level source of truth for "which folders is this item
    // in" going forward. Nothing in the current UI reads these yet (see
    // Milestone A) — this section exists so the future Shared Save Screen
    // and membership-editing UI have a stable API to build on, without this
    // milestone touching any view.

    /// Active memberships for `item` — non-deleted rows pointing at a
    /// non-deleted folder. An item with an empty result here is Unfiled;
    /// that's derived, never a stored flag.
    ///
    /// Fetches every `StoredFolderMembership` row straight from the store
    /// and filters by `item.id` in plain Swift, rather than reading
    /// `item.memberships` (the relationship array) — the result is
    /// authoritative regardless of how, when, or in which process/session
    /// a given row was created.
    public func memberships(for item: StoredItem) throws -> [StoredFolderMembership] {
        let itemID = item.id
        let all = try context.fetch(FetchDescriptor<StoredFolderMembership>())
        return all.filter { membership in
            membership.item?.id == itemID && !membership.isSoftDeleted && membership.folder?.isSoftDeleted == false
        }
    }

    /// The folders `item` currently belongs to, derived from active
    /// memberships.
    public func folders(for item: StoredItem) throws -> [StoredFolder] {
        try memberships(for: item).compactMap(\.folder)
    }

    /// Adds `item` to `folder` if it isn't already an active member.
    /// Idempotent: a no-op (not an error) if the membership already exists,
    /// or if either side is deleted.
    public func addMembership(_ item: StoredItem, to folder: StoredFolder) throws {
        guard !item.isSoftDeleted, !folder.isSoftDeleted else { return }
        let alreadyMember = try memberships(for: item).contains { $0.folder?.id == folder.id }
        guard !alreadyMember else { return }
        context.insert(StoredFolderMembership(item: item, folder: folder))
        touch(item)
        touch(folder)
        try context.save()
    }

    /// Removes `item` from `folder` if an active membership exists.
    /// Idempotent: a harmless no-op if it doesn't — removing a nonexistent
    /// membership is not an error. Never touches `item`'s own soft-delete
    /// state; an item losing its last membership here simply becomes
    /// Unfiled.
    public func removeMembership(_ item: StoredItem, from folder: StoredFolder) throws {
        let matches = try memberships(for: item).filter { $0.folder?.id == folder.id }
        guard !matches.isEmpty else { return }
        for membership in matches {
            membership.deletedAt = .now
            membership.dirty = true
        }
        touch(item)
        touch(folder)
        try context.save()
    }

    /// Reconciles `item`'s membership set to exactly `folders` — adds
    /// whatever's missing, reactivates any matching soft-deleted row,
    /// deactivates whatever's no longer desired, and otherwise leaves
    /// everything alone. Passing an empty array removes every membership,
    /// leaving the item alive and Unfiled. Calling this again with an
    /// equivalent desired set is a no-op: no new rows, and nothing (item,
    /// folder, or any membership) gets touched or saved.
    ///
    /// Fetches every `StoredFolderMembership` row for `item` directly from
    /// the store in one pass — unfiltered by soft-delete state, so
    /// previously-deactivated rows are visible for reactivation — and
    /// mutates those exact row instances straight through to `save()`. (An
    /// earlier version computed its working set via a separate accessor
    /// call and was found, via physical-device tracing, to let a stale
    /// membership survive an otherwise-correct "exclusive" move — root-
    /// caused to `StoredFolder`/`StoredItem`/`StoredFolderMembership`
    /// previously naming their soft-delete flag `isDeleted`, which collides
    /// with SwiftData's own reserved deletion-lifecycle semantics for that
    /// identifier and silently dropped writes to it across `save()`. Fixed
    /// by renaming the stored field to `deletedAt: Date?` — see
    /// `StoredModels.swift` — and confirmed on physical device.)
    public func setMemberships(_ item: StoredItem, to folders: [StoredFolder]) throws {
        let itemID = item.id
        let validDesired = folders.filter { !$0.isSoftDeleted }
        let desiredIDs = Set(validDesired.map(\.id))
        let foldersByID = Dictionary(validDesired.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let allRows = try context.fetch(FetchDescriptor<StoredFolderMembership>())
            .filter { $0.item?.id == itemID }

        var seenFolderIDs = Set<UUID>()
        var changed = false
        var touchedFolders: [UUID: StoredFolder] = [:]

        for row in allRows {
            guard let folder = row.folder else { continue }
            let wanted = desiredIDs.contains(folder.id) && !folder.isSoftDeleted

            if wanted {
                seenFolderIDs.insert(folder.id)
                if row.isSoftDeleted {
                    row.deletedAt = nil
                    row.dirty = true
                    touchedFolders[folder.id] = folder
                    changed = true
                }
                // else: already active and desired — nothing to do.
            } else if !row.isSoftDeleted {
                row.deletedAt = .now
                row.dirty = true
                touchedFolders[folder.id] = folder
                changed = true
            }
            // else: already inactive and not desired — nothing to do.
        }

        for id in desiredIDs.subtracting(seenFolderIDs) {
            guard let folder = foldersByID[id] else { continue }
            context.insert(StoredFolderMembership(item: item, folder: folder))
            touchedFolders[folder.id] = folder
            changed = true
        }

        guard changed else { return }

        touchedFolders.values.forEach { touch($0) }
        touch(item)
        try context.save()
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
