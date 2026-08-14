import SwiftUI

/// Shared Cherries confirmation language: a bold, sharp-edged X and check,
/// hand-drawn from the product's own Figma marks (file `Hz2Gg4CsM097OnNqRVC5Pr`,
/// node 625:98 "X and Check") rather than SF Symbols' thinner, rounded
/// `xmark`/`checkmark` glyphs — deliberately squared stroke ends (SwiftUI's
/// `StrokeStyle` default `.butt` cap / `.miter` join, called out explicitly
/// below rather than left implicit) so the marks read as immediate and
/// tool-like, not a generic system button. Used by both `CropEditorView`
/// and `ScreenshotCaptureFlowView` so the confirm/cancel grammar is
/// identical across the whole capture flow.
///
/// X always cancels the current capture; check always confirms whatever
/// the current stage's job is (persisting a crop, filing the capture) —
/// callers should stay consistent with that, not repurpose either glyph's
/// meaning per-screen.

struct CherriesCancelControl: View {
    var action: () -> Void
    /// The glyph's own visible height — "approximately 28–32pt" per the
    /// design direction. Width follows from the shape's natural (square,
    /// for X) aspect ratio.
    var visibleMarkSize: CGFloat = 30
    var color: Color = .white
    /// Generous invisible tap area around the glyph — never drawn (no
    /// circle/pill/fill/border), just `contentShape`. The glyph itself
    /// stays small and precise; the tap target doesn't have to look that
    /// way to behave that way.
    var minimumHitTarget: CGFloat = 44

    var body: some View {
        Button(action: action) {
            CherriesXMarkShape()
                .fill(color)
                .frame(width: visibleMarkSize, height: visibleMarkSize)
                .frame(minWidth: minimumHitTarget, minHeight: minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct CherriesConfirmControl: View {
    var action: () -> Void
    /// Disabled state is communicated only via reduced opacity, never a
    /// different color — same convention `CropEditorView`'s Done already
    /// used before this restyle.
    var isEnabled: Bool = true
    var visibleMarkSize: CGFloat = 30
    var color: Color = .white
    var minimumHitTarget: CGFloat = 44

    /// The check's source vector isn't square (54.5617 × 37.8853) — this
    /// preserves that natural proportion at any `visibleMarkSize` rather
    /// than distorting it into a square box to match the X.
    private static let aspectRatio: CGFloat = 54.5617 / 37.8853

    var body: some View {
        Button(action: action) {
            CherriesCheckMarkShape()
                .fill(color)
                .frame(width: visibleMarkSize * Self.aspectRatio, height: visibleMarkSize)
                .frame(minWidth: minimumHitTarget, minHeight: minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Two crossing diagonals, normalized against the source SVG's 41.4569pt
/// square canvas (inset ~6.8% each side, stroke ~19.3% of the canvas).
private struct CherriesXMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let inset: CGFloat = 0.068243
        let far: CGFloat = 0.931765
        let strokeFraction: CGFloat = 0.192970

        let topLeft = CGPoint(x: rect.minX + rect.width * inset, y: rect.minY + rect.height * inset)
        let bottomRight = CGPoint(x: rect.minX + rect.width * far, y: rect.minY + rect.height * far)
        let topRight = CGPoint(x: rect.minX + rect.width * far, y: rect.minY + rect.height * inset)
        let bottomLeft = CGPoint(x: rect.minX + rect.width * inset, y: rect.minY + rect.height * far)

        var path = Path()
        path.move(to: topLeft)
        path.addLine(to: bottomRight)
        path.move(to: topRight)
        path.addLine(to: bottomLeft)

        return path.strokedPath(StrokeStyle(lineWidth: rect.width * strokeFraction, lineCap: .butt, lineJoin: .miter))
    }
}

/// A short arm meeting a long arm at the bottom vertex, normalized against
/// the source SVG's 54.5617 × 37.8853 canvas (stroke ~21.1% of the
/// canvas height).
private struct CherriesCheckMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let topRight = CGPoint(x: rect.minX + rect.width * 0.948067, y: rect.minY + rect.height * 0.074534)
        let bottomVertex = CGPoint(x: rect.minX + rect.width * 0.411057, y: rect.minY + rect.height * 0.850701)
        let midLeft = CGPoint(x: rect.minX + rect.width * 0.051841, y: rect.minY + rect.height * 0.333198)

        var path = Path()
        path.move(to: topRight)
        path.addLine(to: bottomVertex)
        path.addLine(to: midLeft)

        return path.strokedPath(StrokeStyle(lineWidth: rect.height * 0.211163, lineCap: .butt, lineJoin: .miter))
    }
}
