import SwiftUI
import ArkyvKit

/// Lightweight brand glyph for the root dock's Home button — a simple
/// filled cherry-pair mark, monochrome, no illustrative detail. Same ethos
/// as ArkyvKit's existing `FolderGlyphShape` (one concrete `Shape`,
/// branching on data inside `path(in:)`, not a family of view types).
///
/// This is a code-drawn placeholder standing in for the actual Figma-
/// exported brand mark — no such asset exists in this repository yet, and
/// this milestone is scoped to product UI/navigation, not sourcing final
/// brand artwork. Local to the iOS app target (not ArkyvKit's shared
/// Design/BrandViews.swift) since it's only used on the root dock, not by
/// the Share Extension or macOS app.
struct CherryMarkView: View {
    var size: CGFloat = 22
    var color: Color = ArkyvColor.textPrimary

    var body: some View {
        CherryMarkShape()
            .fill(color)
            .frame(width: size, height: size)
    }
}

private struct CherryMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.width * 0.24
        let leftCenter = CGPoint(x: rect.minX + r * 1.15, y: rect.maxY - r * 1.1)
        let rightCenter = CGPoint(x: rect.maxX - r * 1.15, y: rect.maxY - r * 1.35)
        let stemTop = CGPoint(x: rect.midX + rect.width * 0.05, y: rect.minY)

        var path = Path()
        path.addEllipse(in: CGRect(x: leftCenter.x - r, y: leftCenter.y - r, width: r * 2, height: r * 2))
        path.addEllipse(in: CGRect(x: rightCenter.x - r, y: rightCenter.y - r, width: r * 2, height: r * 2))

        var stems = Path()
        stems.move(to: CGPoint(x: leftCenter.x, y: leftCenter.y - r))
        stems.addQuadCurve(to: stemTop, control: CGPoint(x: leftCenter.x, y: rect.minY + rect.height * 0.18))
        stems.move(to: CGPoint(x: rightCenter.x, y: rightCenter.y - r))
        stems.addQuadCurve(to: stemTop, control: CGPoint(x: rightCenter.x, y: rect.minY + rect.height * 0.12))
        path.addPath(stems.strokedPath(StrokeStyle(lineWidth: max(rect.width * 0.09, 1.5), lineCap: .round)))

        return path
    }
}
