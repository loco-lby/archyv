import Foundation
import SwiftData

/// D3B: incrementally backfills `StoredItem.imageData` (the CloudKit
/// `.externalStorage` transport field — populated for new captures since
/// D3A) for historical items captured before D3A shipped.
///
/// Runs in small batches, one batch per app foreground activation (see
/// `RootView`) — never drains the whole archive in one pass. Deliberately
/// has no completion flag: `imageData == nil` is the entire resumable/
/// idempotent progress marker. An item whose `MediaStore` file is
/// permanently missing/corrupt simply stays eligible forever and is
/// cheaply reconsidered every pass — rather than risk ever marking
/// backfill "done" while data silently remains unbackfilled, or adding
/// persistent bookkeeping to tell the two cases apart.
public enum ImageBackfill {
    /// Selects up to `limit` non-deleted items with a local image file
    /// that hasn't been backfilled yet, reads each file from `MediaStore`,
    /// and saves. Returns the number of items actually backfilled.
    ///
    /// Uses one unfiltered `FetchDescriptor<StoredItem>()` + in-memory
    /// filtering — the same pattern `MembershipMigration` already relies
    /// on — rather than a `#Predicate`, which has twice hit a SwiftData/
    /// Swift type-checker complexity limit elsewhere in this codebase,
    /// even for a single-condition nil-check combined with another query
    /// argument. The fetch itself is cheap regardless of archive size:
    /// SwiftData lazily faults `.externalStorage` attributes, so row
    /// metadata for thousands of items loads without touching any image
    /// bytes — only the `limit` items actually selected for this batch
    /// have their `MediaStore` file read into memory.
    ///
    /// Never overwrites a populated `imageData` — the filter excludes it.
    /// Non-throwing by design: fetch/save failures are logged (DEBUG
    /// only) and simply leave the affected items eligible for the next
    /// pass, matching `MembershipMigration.runIfNeeded`'s "retry next
    /// launch" behavior rather than propagating an error the caller would
    /// have to handle.
    ///
    /// Safe to call from a background `ModelContext` distinct from
    /// `container.mainContext` — this is the standard SwiftData
    /// multi-context pattern. Two overlapping calls (e.g. rapid
    /// foreground/background) are safe, not just non-crashing: at worst
    /// each independently re-reads and re-writes the same bytes to the
    /// same items, never creating duplicate rows or corrupting state. No
    /// reentrancy guard is added for that case — it's harmless, and
    /// guarding it would add state this milestone doesn't need.
    @discardableResult
    public static func runNextBatch(context: ModelContext, limit: Int = 20) -> Int {
        let items: [StoredItem]
        do {
            items = try context.fetch(FetchDescriptor<StoredItem>())
        } catch {
            log("runNextBatch — fetch failed, will retry next pass: \(error)")
            return 0
        }

        let eligible = items
            .filter { !$0.isSoftDeleted && $0.localFilename != nil && $0.imageData == nil }
            .prefix(limit)

        guard !eligible.isEmpty else {
            log("runNextBatch — scanned \(items.count) items, none eligible")
            return 0
        }

        var backfilled = 0
        var skippedUnreadable = 0
        for item in eligible {
            guard let filename = item.localFilename,
                  let data = MediaStore.shared.data(for: filename) else {
                skippedUnreadable += 1
                continue
            }
            item.imageData = data
            backfilled += 1
        }

        if backfilled > 0 {
            do {
                try context.save()
            } catch {
                log("runNextBatch — save failed, nothing persisted this batch, will retry next pass: \(error)")
                return 0
            }
        }

        log("runNextBatch — scanned \(items.count) items, \(eligible.count) eligible in this batch, " +
            "backfilled \(backfilled), skipped (unreadable MediaStore file) \(skippedUnreadable)")
        return backfilled
    }

    private static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[ImageBackfill] \(message())")
        #endif
    }
}
