import SwiftUI
import ArkyvKit

/// Brand glyph for the root dock's Home button, transcribed directly from
/// the product's Figma page (file `Hz2Gg4CsM097OnNqRVC5Pr`, node 629:2
/// "Bottom Menu Icons" → "cherries-logo-mark") — four open stroked curves,
/// not the earlier code-drawn placeholder (two filled ellipses + stems)
/// this replaces. Local to the iOS app target (not ArkyvKit's shared
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
        let viewBox = CGSize(width: 22.1782, height: 21.7754)

        var raw = Path()

        // Right loop.
        raw.move(to: CGPoint(x: 13.2104, y: 16.9306))
        raw.addCurve(to: CGPoint(x: 21.1766, y: 13.4551), control1: CGPoint(x: 16.4935, y: 19.6665), control2: CGPoint(x: 21.2792, y: 18.0719))
        raw.addCurve(to: CGPoint(x: 13.3451, y: 9.96683), control1: CGPoint(x: 21.0398, y: 8.56468), control2: CGPoint(x: 16.8676, y: 8.35948))
        raw.addCurve(to: CGPoint(x: 13.1399, y: 16.875), control1: CGPoint(x: 10.5066, y: 11.2322), control2: CGPoint(x: 11.088, y: 15.165))
        raw.addLine(to: CGPoint(x: 13.2104, y: 16.9306))
        raw.closeSubpath()

        // Left loop.
        raw.move(to: CGPoint(x: 11.6011, y: 11.8135))
        raw.addCurve(to: CGPoint(x: 4.89812, y: 11.8135), control1: CGPoint(x: 11.1565, y: 11.6767), control2: CGPoint(x: 7.80501, y: 11.1295))
        raw.addCurve(to: CGPoint(x: 3.56436, y: 14.5152), control1: CGPoint(x: 3.87215, y: 12.6342), control2: CGPoint(x: 3.66696, y: 13.9338))
        raw.addCurve(to: CGPoint(x: 5.82148, y: 20.0554), control1: CGPoint(x: 3.56436, y: 14.6861), control2: CGPoint(x: 3.01718, y: 18.3112))
        raw.addCurve(to: CGPoint(x: 11.3959, y: 19.8844), control1: CGPoint(x: 7.63402, y: 21.1839), control2: CGPoint(x: 9.85694, y: 20.8761))
        raw.addCurve(to: CGPoint(x: 13.482, y: 17.1485), control1: CGPoint(x: 12.7638, y: 18.961), control2: CGPoint(x: 13.2768, y: 17.6614))

        // Upper-left stem/branch.
        raw.move(to: CGPoint(x: 9.65229, y: 5.0423))
        raw.addCurve(to: CGPoint(x: 1, y: 1.79341), control1: CGPoint(x: 6.16402, y: 6.47865), control2: CGPoint(x: 2.98353, y: 4.80291))
        raw.addLine(to: CGPoint(x: 1, y: 1.65662))
        raw.addCurve(to: CGPoint(x: 5.34325, y: 1.04104), control1: CGPoint(x: 2.40215, y: 1.10944), control2: CGPoint(x: 3.9069, y: 0.904244))
        raw.addCurve(to: CGPoint(x: 9.4129, y: 2.64838), control1: CGPoint(x: 7.05318, y: 1.21203), control2: CGPoint(x: 8.48953, y: 1.86181))
        raw.addCurve(to: CGPoint(x: 11.2938, y: 4.32412), control1: CGPoint(x: 10.3363, y: 3.43495), control2: CGPoint(x: 10.5073, y: 3.57175))
        raw.addCurve(to: CGPoint(x: 15.5687, y: 10.9587), control1: CGPoint(x: 13.6535, y: 6.54704), control2: CGPoint(x: 14.9531, y: 9.38554))

        // Upper-right stem/branch.
        raw.move(to: CGPoint(x: 15.8075, y: 1.62235))
        raw.addCurve(to: CGPoint(x: 10.5408, y: 6.64958), control1: CGPoint(x: 14.6789, y: 2.23793), control2: CGPoint(x: 12.3192, y: 3.74268))
        raw.addCurve(to: CGPoint(x: 8.45472, y: 13.3867), control1: CGPoint(x: 8.8309, y: 9.45388), control2: CGPoint(x: 8.52311, y: 12.1214))

        let strokedPath = raw.strokedPath(StrokeStyle(lineWidth: 2, lineCap: .butt, lineJoin: .miter))
        let transform = CGAffineTransform(scaleX: rect.width / viewBox.width, y: rect.height / viewBox.height)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
        return strokedPath.applying(transform)
    }
}
