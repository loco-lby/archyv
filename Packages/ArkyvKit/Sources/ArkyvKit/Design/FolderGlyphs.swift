import SwiftUI

/// The Design System's folder-category icon language: geometric shapes
/// derived from the brand star motif, each mapped to a category meaning.
///   • star     — default / featured
///   • triangle — directional / priority
///   • circle   — general / misc
///   • diamond  — special / pinned
///   • cross    — new / uncategorized
/// Always filled, never stroked. No illustrative or skeuomorphic detail.
public enum FolderGlyph: String, Codable, CaseIterable, Sendable {
    case star, triangle, circle, diamond, cross
}

/// Renders a `FolderGlyph` as a filled, monochrome geometric shape.
public struct FolderGlyphView: View {
    let glyph: FolderGlyph
    var size: CGFloat
    var color: Color

    public init(glyph: FolderGlyph, size: CGFloat = 18, color: Color = ArkyvColor.subdued) {
        self.glyph = glyph
        self.size = size
        self.color = color
    }

    public var body: some View {
        FolderGlyphShape(glyph: glyph)
            .fill(color)
            .frame(width: size, height: size)
    }
}

/// A single `Shape` that draws any `FolderGlyph`.
///
/// The previous version tried to pick between five *different* `Shape`
/// types (`StarGlyphShape`, `Circle`, etc.) inside a switch marked
/// `@ShapeBuilder`. Two things broke that:
///
///   1. `@ShapeBuilder` doesn't exist — SwiftUI ships `@ViewBuilder` for
///      composing `View`s, but there's no equivalent result builder for
///      `Shape`. That attribute name simply isn't recognized by the
///      compiler, which is the root error.
///   2. Even with a real result builder, `some Shape` is an opaque return
///      type: every path through the function has to return the *same*
///      concrete type. A switch returning `StarGlyphShape` in one branch and
///      `Circle` in another can't satisfy that — this is the "incompatible
///      types" error.
///
/// The idiomatic fix is the same technique `RoundedRectangle` itself uses
/// internally: don't switch over shape *types*, switch over *data* inside a
/// single shape's `path(in:)`. `Shape`'s only real requirement is producing
/// a `Path` for a given rect, so one concrete `FolderGlyphShape` holding a
/// `FolderGlyph` value and branching inside `path(in:)` is strongly typed,
/// needs no `AnyShape`/`AnyView` erasure, and is trivially reusable anywhere
/// a `Shape` is expected (`.fill`, `.stroke`, hit-testing, etc.).
struct FolderGlyphShape: Shape {
    var glyph: FolderGlyph

    func path(in rect: CGRect) -> Path {
        switch glyph {
        case .star: return starPath(in: rect)
        case .triangle: return trianglePath(in: rect)
        case .circle: return Circle().path(in: rect)
        case .diamond: return diamondPath(in: rect)
        case .cross: return crossPath(in: rect)
        }
    }

    /// 5-pointed star on the brand's 27px inner / 50px outer radius ratio
    /// (0.54), point up.
    private func starPath(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) / 2
        let innerRadius = outerRadius * (27.0 / 50.0)
        let pointCount = 5
        var path = Path()
        for i in 0..<(pointCount * 2) {
            let angle = (Double(i) * .pi / Double(pointCount)) - .pi / 2
            let radius = i.isMultiple(of: 2) ? outerRadius : innerRadius
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// Equilateral triangle, point up.
    private func trianglePath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    /// 45°-rotated square.
    private func diamondPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }

    /// Plus / cross shape.
    private func crossPath(in rect: CGRect) -> Path {
        let armWidth = min(rect.width, rect.height) * 0.32
        var path = Path()
        path.addRect(CGRect(x: rect.midX - armWidth / 2, y: rect.minY, width: armWidth, height: rect.height))
        path.addRect(CGRect(x: rect.minX, y: rect.midY - armWidth / 2, width: rect.width, height: armWidth))
        return path
    }
}
