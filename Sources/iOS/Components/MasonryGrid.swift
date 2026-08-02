import SwiftUI
import ArkyvKit

/// A simple, dependency-free masonry (Pinterest-style) grid. Items are placed
/// greedily into the currently shortest column, using each item's estimated
/// height so tiles of different aspect ratios pack tightly.
struct MasonryGrid<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let columns: Int
    let spacing: CGFloat
    let content: (Item) -> Content
    /// Estimated aspect ratio (w/h) used to reserve height before layout.
    var aspect: (Item) -> CGFloat

    init(
        items: [Item],
        columns: Int = 2,
        spacing: CGFloat = 12,
        @ViewBuilder content: @escaping (Item) -> Content
    ) where Item == StoredItem {
        self.items = items
        self.columns = columns
        self.spacing = spacing
        self.content = content
        self.aspect = { item in
            switch item.kind {
            case .screenshot, .image: return CGFloat(item.aspectRatio > 0 ? item.aspectRatio : 1)
            case .note, .text: return 1.15 // roughly square-ish text card
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let columnWidth = (geo.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
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
        }
        .frame(height: totalHeight())
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

    /// Height reservation for the outer frame (uses a nominal width estimate;
    /// GeometryReader re-lays out precisely once measured).
    private func totalHeight() -> CGFloat {
        let nominalColumnWidth: CGFloat = 179 // matches Figma column width
        var heights = Array(repeating: CGFloat(0), count: columns)
        for item in items {
            let shortest = heights.firstIndex(of: heights.min() ?? 0) ?? 0
            heights[shortest] += nominalColumnWidth / max(aspect(item), 0.2) + spacing
        }
        return (heights.max() ?? 0) + spacing
    }
}
