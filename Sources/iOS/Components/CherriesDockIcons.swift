import SwiftUI

/// Hand-drawn dock icons sourced directly from the product's Figma page
/// (file `Hz2Gg4CsM097OnNqRVC5Pr`, node 629:2 "Bottom Menu Icons") —
/// stroked outlines transcribed from the exported SVG path data, not SF
/// Symbols. Same "intentional Cherries interaction language" category as
/// `CherriesCancelControl`/`CherriesConfirmControl`. Used by `RootView`'s
/// floating dock.

struct CherriesScissorsIcon: View {
    var size: CGFloat = 20
    var color: Color = .white

    var body: some View {
        CherriesScissorsShape()
            .fill(color)
            .frame(width: size, height: size)
    }
}

struct CherriesMenuIcon: View {
    var size: CGFloat = 20
    var color: Color = .white

    var body: some View {
        CherriesMenuShape()
            .fill(color)
            .frame(width: size, height: size)
    }
}

/// Two mirrored blade groups, each transcribed directly from its own
/// exported SVG path data (`M`/`L`/`C` commands, unmodified) and
/// non-uniformly scaled to fit its own sub-rect within the icon — matching
/// Figma's own `preserveAspectRatio="none"` stretch-fit layout for this
/// icon exactly, not an approximation via a single mirrored shape.
private struct CherriesScissorsShape: Shape {
    func path(in rect: CGRect) -> Path {
        var result = Path()
        result.addPath(rightBlade(in: rect))
        result.addPath(leftBlade(in: rect))
        return result
    }

    /// Source: exported group at Figma node 629:8, viewBox 23.3462×31.6016.
    private func rightBlade(in rect: CGRect) -> Path {
        let viewBox = CGSize(width: 23.3462, height: 31.6016)
        var raw = Path()
        raw.move(to: CGPoint(x: 1.64127, y: 0.820637))
        raw.addLine(to: CGPoint(x: 11.6249, y: 20.7879))
        raw.move(to: CGPoint(x: 14.9043, y: 27.7893))
        raw.addCurve(to: CGPoint(x: 11.6253, y: 20.7883), control1: CGPoint(x: 13.5429, y: 25.5203), control2: CGPoint(x: 12.9867, y: 23.0573))
        raw.addLine(to: CGPoint(x: 13.8943, y: 20.7883))
        raw.addCurve(to: CGPoint(x: 17.9785, y: 21.6959), control1: CGPoint(x: 15.7095, y: 20.7883), control2: CGPoint(x: 16.6171, y: 20.7883))
        raw.addCurve(to: CGPoint(x: 21.1551, y: 24.4187), control1: CGPoint(x: 18.5316, y: 22.0646), control2: CGPoint(x: 19.7937, y: 22.6035))
        raw.addCurve(to: CGPoint(x: 19.3399, y: 29.4105), control1: CGPoint(x: 22.0627, y: 26.6877), control2: CGPoint(x: 21.1551, y: 28.5029))
        raw.addCurve(to: CGPoint(x: 14.8019, y: 27.5953), control1: CGPoint(x: 17.5247, y: 30.3181), control2: CGPoint(x: 15.7095, y: 29.4105))
        raw.addLine(to: CGPoint(x: 14.9043, y: 27.7893))
        raw.closeSubpath()

        let target = CGRect(
            x: rect.minX + rect.width * 0.2076,
            y: rect.minY + rect.height * 0.0338,
            width: rect.width * 0.6092,
            height: rect.height * 0.8875
        )
        return stroked(raw, viewBox: viewBox, into: target)
    }

    /// Source: exported group at Figma node 629:11, viewBox 22.8922×31.6017.
    private func leftBlade(in rect: CGRect) -> Path {
        let viewBox = CGSize(width: 22.8922, height: 31.6017)
        var raw = Path()
        raw.move(to: CGPoint(x: 21.2509, y: 0.820637))
        raw.addLine(to: CGPoint(x: 11.2673, y: 20.7879))
        raw.move(to: CGPoint(x: 8.4676, y: 27.7428))
        raw.addCurve(to: CGPoint(x: 11.721, y: 20.7884), control1: CGPoint(x: 9.829, y: 25.4738), control2: CGPoint(x: 10.3595, y: 23.0574))
        raw.addLine(to: CGPoint(x: 9.45195, y: 20.7884))
        raw.addCurve(to: CGPoint(x: 5.36774, y: 21.696), control1: CGPoint(x: 7.63674, y: 20.7884), control2: CGPoint(x: 6.72914, y: 20.7884))
        raw.addCurve(to: CGPoint(x: 2.19113, y: 24.4188), control1: CGPoint(x: 4.90647, y: 22.0035), control2: CGPoint(x: 3.55254, y: 22.6036))
        raw.addCurve(to: CGPoint(x: 4.00634, y: 29.4106), control1: CGPoint(x: 1.28353, y: 26.6878), control2: CGPoint(x: 2.19113, y: 28.503))
        raw.addCurve(to: CGPoint(x: 8.54435, y: 27.5954), control1: CGPoint(x: 5.82154, y: 30.3182), control2: CGPoint(x: 7.63674, y: 29.4106))
        raw.addLine(to: CGPoint(x: 8.4676, y: 27.7428))
        raw.closeSubpath()

        let target = CGRect(
            x: rect.minX + rect.width * 0.1688,
            y: rect.minY + rect.height * 0.0338,
            width: rect.width * 0.5954,
            height: rect.height * 0.8875
        )
        return stroked(raw, viewBox: viewBox, into: target)
    }

    /// Strokes `raw` (in its own SVG coordinate space) at the source's
    /// `stroke-width="3.67"`/butt-cap/miter-join, then non-uniformly scales
    /// + translates the result to exactly fill `target` — the same
    /// stretch-fit `preserveAspectRatio="none"` behavior the source SVGs
    /// declare, applied here explicitly rather than left implicit.
    private func stroked(_ raw: Path, viewBox: CGSize, into target: CGRect) -> Path {
        let strokedPath = raw.strokedPath(StrokeStyle(lineWidth: 3.67, lineCap: .butt, lineJoin: .miter))
        let transform = CGAffineTransform(scaleX: target.width / viewBox.width, y: target.height / viewBox.height)
            .concatenating(CGAffineTransform(translationX: target.minX, y: target.minY))
        return strokedPath.applying(transform)
    }
}

/// Three horizontal bars, normalized against the source SVG's
/// 18.0263×18.0263 canvas (stroke ~16.7% of the canvas height).
private struct CherriesMenuShape: Shape {
    func path(in rect: CGRect) -> Path {
        let rowFractions: [CGFloat] = [0.19307, 0.50630, 0.81941]
        let strokeFraction: CGFloat = 0.16681

        var path = Path()
        for rowFraction in rowFractions {
            let y = rect.minY + rect.height * rowFraction
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path.strokedPath(StrokeStyle(lineWidth: rect.height * strokeFraction, lineCap: .butt, lineJoin: .miter))
    }
}
