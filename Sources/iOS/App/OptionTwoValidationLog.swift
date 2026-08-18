import Foundation
import SwiftData
import ArkyvKit

#if DEBUG
/// Option 2 Validation Gate 01 (two-device test): the single question this
/// exists to answer is whether a `StoredItem` ever becomes visible to a
/// SwiftUI `@Query` (i.e. actually rendered/renderable) BEFORE its
/// `.externalStorage` `imageData` bytes are locally readable — the one
/// remaining empirical gap blocking Option 2's production cutover.
///
/// Read-only: never mutates a `StoredItem`, never touches `MediaStore`,
/// never changes persistence behavior. Logs only — no UI. `#if DEBUG`
/// only; compiled out of release builds entirely.
enum OptionTwoValidationLog {
    /// Called from `ArchiveView`'s `.onChange(of: allItemsRaw)` — the
    /// earliest point this app's own code can observe a change to the
    /// query results, whether that change came from a local capture or a
    /// CloudKit background merge. Diffs against `seen` so only genuinely
    /// NEW items are logged (an item already present at launch is seeded
    /// into `seen` once, up front, so it's never mistaken for a live
    /// arrival).
    static func observeNewItems(_ items: [StoredItem], seen: inout Set<UUID>) {
        let newItems = items.filter { !seen.contains($0.id) }
        guard !newItems.isEmpty else { return }
        for item in newItems {
            seen.insert(item.id)
            guard item.kind.isMedia else { continue } // only media items are relevant to this question
            log(item)
        }
    }

    /// On-demand snapshot check — added specifically because the live
    /// `.onChange`-based path above can only report what it actually
    /// observed while attached (the devicectl console tunnel dropping
    /// during an Airplane Mode test is a real, expected gap, not a code
    /// bug). This reports CURRENT state for the N most-recently-created
    /// media items, regardless of whether this process was watching when
    /// they first arrived — end-state confirmation, not first-moment
    /// confirmation. Read-only: fetches from the real, already-running
    /// `modelContainer`, mutates nothing. Triggered via
    /// `--arkyv-validate-recent-media`.
    @MainActor
    static func reportMostRecentItems(container: ModelContainer, limit: Int = 5) {
        let context = container.mainContext
        let descriptor = FetchDescriptor<StoredItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        guard let items = try? context.fetch(descriptor) else {
            print("[OptionTwoValidationLog] reportMostRecentItems: fetch failed")
            return
        }
        let recent = items.filter(\.kind.isMedia).prefix(limit)
        print("[OptionTwoValidationLog] --- snapshot of \(recent.count) most recent media items (current state, not first-moment) ---")
        for item in recent {
            log(item)
        }
    }

    private static func log(_ item: StoredItem) {
        let observedAt = Date()
        let imageData = item.imageData
        let isNil = imageData == nil
        let byteCount = imageData?.count ?? -1
        // "immediate byte read succeeds" — for an externalStorage
        // attribute, the property access itself IS the read; there's no
        // separate file handle to open. A non-nil, non-empty Data means
        // the bytes are genuinely resident right now, not a placeholder.
        let readSucceeds = (imageData?.count ?? 0) > 0
        let decodeSucceeds = imageData.flatMap { ImageDecoding.decode($0, maxPixelSize: nil) } != nil

        print("""
        [OptionTwoValidationLog] ================================
        [OptionTwoValidationLog] NEW StoredItem query-visible at \(observedAt)
        [OptionTwoValidationLog]   id: \(item.id)
        [OptionTwoValidationLog]   localFilename: \(item.localFilename ?? "nil")
        [OptionTwoValidationLog]   createdAt (as synced): \(item.createdAt)
        [OptionTwoValidationLog]   aspectWidth x aspectHeight: \(item.aspectWidth) x \(item.aspectHeight)
        [OptionTwoValidationLog]   imageData nil: \(isNil)
        [OptionTwoValidationLog]   imageData byte count: \(byteCount)
        [OptionTwoValidationLog]   immediate byte read succeeds: \(readSucceeds)
        [OptionTwoValidationLog]   immediate decode succeeds: \(decodeSucceeds)
        [OptionTwoValidationLog] ================================
        """)
    }
}
#endif
