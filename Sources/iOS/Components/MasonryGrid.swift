import SwiftUI
import ArkyvKit

/// A simple, dependency-free masonry (Pinterest-style) grid. Items are placed
/// greedily into the currently shortest column, using each item's estimated
/// height so tiles of different aspect ratios pack tightly.
///
/// One Archive Bottom Scroll / Safe Area 01: this view has to give its own
/// content an explicit `.frame(height:)` (a `ScrollView` offers its content
/// unbounded height, so an inner `GeometryReader` computing real layout
/// would otherwise try to expand to fill that) — the height REQUIRES
/// knowing the column width first, which used to be estimated with a
/// hardcoded `nominalColumnWidth: CGFloat = 179` guess, separate from the
/// REAL column width an inner `GeometryReader` computed for actual layout.
/// Whenever those two diverged (any width other than exactly 179 minus
/// insets — i.e. on the actual device tested), the reserved frame fell
/// short of the grid's real rendered height, silently overflowing/clipping
/// part of the real content beyond what `ScrollView` believed was
/// scrollable — no amount of padding placed *after* this view could ever
/// reveal that overflow, since it happened *inside* this view's own
/// under-reserved bounds. `availableWidth` is now provided explicitly by
/// the caller (which already measures it once, for its own purposes) and
/// used for BOTH the estimate and the real layout — the same single
/// source of truth, so they can never diverge again.
struct MasonryGrid<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let columns: Int
    let spacing: CGFloat
    /// The real, measured width this grid has to lay out within — from
    /// the caller, not re-derived from a separate, potentially-stale
    /// `GeometryReader` pass of this view's own.
    let availableWidth: CGFloat
    let content: (Item) -> Content
    /// Estimated aspect ratio (w/h) used to reserve height before layout.
    var aspect: (Item) -> CGFloat

    init(
        items: [Item],
        columns: Int = 2,
        spacing: CGFloat = 12,
        availableWidth: CGFloat,
        @ViewBuilder content: @escaping (Item) -> Content
    ) where Item == StoredItem {
        self.items = items
        self.columns = columns
        self.spacing = spacing
        self.availableWidth = availableWidth
        self.content = content
        self.aspect = { item in
            switch item.kind {
            case .screenshot, .image: return CGFloat(item.aspectRatio > 0 ? item.aspectRatio : 1)
            case .note, .text: return 1.15 // roughly square-ish text card
            }
        }
    }

    private var columnWidth: CGFloat {
        max((availableWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns), 0)
    }

    var body: some View {
        let buckets = distribute(columnWidth: columnWidth)
        HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<columns, id: \.self) { col in
                LazyVStack(spacing: spacing) {
                    ForEach(buckets[col]) { item in
                        content(item)
                    }
                }
            }
        }
        // One Archive Bottom Scroll / Safe Area 01 follow-up: a bare
        // `.frame(height:)` defaults to CENTERING its content within that
        // height — invisible while the estimate underestimated (the old
        // bug: content simply clipped at the bottom, no visible gap,
        // since the natural content was already taller than the frame).
        // Once `totalHeight()` became accurate (this milestone's own
        // fix), any small remaining over-estimate versus the HStack's
        // real natural height — from `max(aspect(item), 0.2)`'s clamping
        // or ordinary floating-point drift between this estimate and
        // SwiftUI's own real layout pass — now pushes content DOWN by
        // half that difference instead of clipping it, which is exactly
        // the "huge empty region before the first row" regression.
        // Explicit top alignment is the mathematically correct fix, not
        // a magic offset: the reserved frame's origin should always BE
        // where content starts.
        .frame(height: totalHeight(), alignment: .top)
    }

    /// Greedy shortest-column distribution.
    private func distribute(columnWidth: CGFloat) -> [[Item]] {
        var buckets = Array(repeating: [Item](), count: columns)
        var heights = Array(repeating: CGFloat(0), count: columns)
        for item in items {
            let shortest = heights.firstIndex(of: heights.min() ?? 0) ?? 0
            buckets[shortest].append(item)
            heights[shortest] += columnWidth / max(aspect(item), 0.2) + spacing
        }
        return buckets
    }

    /// Height reservation for the outer frame — the SAME `columnWidth`
    /// (from `availableWidth`) the real layout above uses, so this can
    /// never under- or over-estimate relative to what actually renders.
    private func totalHeight() -> CGFloat {
        var heights = Array(repeating: CGFloat(0), count: columns)
        for item in items {
            let shortest = heights.firstIndex(of: heights.min() ?? 0) ?? 0
            heights[shortest] += columnWidth / max(aspect(item), 0.2) + spacing
        }
        return (heights.max() ?? 0) + spacing
    }
}
