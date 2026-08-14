import SwiftUI
import UIKit
import ArkyvKit

// MARK: - imageDisplayRect write-path diagnostics (temporary)
//
// Every mutation of `imageDisplayRect` — init, pan, pinch, or anything
// else — routes through `CropEditorView.commitImageDisplayRect(_:mutation:)`,
// the one chokepoint, so every writer is observable from a single place
// rather than trusting each call site individually. Purely diagnostic:
// `commitImageDisplayRect` performs the exact same assignment any direct
// write would have, and only #if DEBUG code paths differ from before.

private enum ImageRectMutationSource: String {
    case initialization
    case pan
    case pinch
}

private struct ImageRectMutation {
    let source: ImageRectMutationSource
    let owner: String
    let recognizerState: String
    let gestureStartRect: CGRect?
    let rawProposedRect: CGRect?
    let translationDelta: CGSize?
    let pinchScale: CGFloat?
    let startingCentroid: CGPoint?
    let currentCentroid: CGPoint?
    let touchCount: Int?

    static func initialization(rect: CGRect) -> ImageRectMutation {
        ImageRectMutation(source: .initialization, owner: "none", recognizerState: "n/a", gestureStartRect: nil, rawProposedRect: rect, translationDelta: nil, pinchScale: nil, startingCentroid: nil, currentCentroid: nil, touchCount: nil)
    }
}

/// Stage 3 (revised) of the crop editor: a fixed viewport, with the source
/// image manipulated underneath it. All math delegated to `CropEditorMath`,
/// kept pure and unit-tested independent of this view.
///
/// Two independent pieces of screen-space state:
/// - `frameRect` — the crop window. Changed only by corner/edge gestures.
/// - `imageDisplayRect` — where the full image currently renders. Changed
///   only by pan (one finger) and pinch (two fingers) *inside* the frame.
///
/// `CropRegion` is never stored during editing — it's resolved on demand
/// via `CropEditorMath.region(for: frameRect, in: imageDisplayRect)`, the
/// same inverse-mapping function used since Stage 1. That's what keeps the
/// persistence contract unchanged regardless of how the editor represents
/// its own in-progress interaction state.
///
/// Deliberately knows nothing about `StoredItem`, `CaptureDraft`, or
/// persistence — an image and a starting region in, nothing saved out yet.
struct CropEditorView: View {
    let image: UIImage
    private let initialRegion: CropRegion

    init(image: UIImage, region: CropRegion) {
        self.image = image
        self.initialRegion = region
    }

    /// Breathing room between the raw presentation surface and the
    /// aspect-fit source image at editor entry. Deliberately generous — a
    /// wide surrounding workspace is what makes the image read as a
    /// deliberately isolated object of attention. Also defines the hard
    /// bound corner/edge resize is clamped against: the frame can never be
    /// resized so a control would land outside this inset viewport.
    ///
    /// Split by axis, not uniform: the vertical isolation reads well at
    /// 56pt, but the same inset on the horizontal axis left too little
    /// usable crop width — left/right handles hit it as a noticeable
    /// hidden wall. All frame/coverage clamping already keys off this
    /// value at each call site (`CGRect.insetBy(dx:dy:)` naturally applies
    /// each axis independently), so nothing downstream assumes a single
    /// uniform inset.
    private static let viewportInsetHorizontal: CGFloat = 26
    private static let viewportInsetVertical: CGFloat = 56
    private static let handleArmLength: CGFloat = 20
    private static let railHalfLength: CGFloat = 11
    private static let controlLineWidth: CGFloat = 4
    private static let cornerTouchTargetSize: CGFloat = 44
    private static let edgeTouchTargetLength: CGFloat = 64
    private static let edgeTouchTargetThickness: CGFloat = 44

    /// "Traction" — a deliberately small, explicit damping of interior
    /// pan/pinch responsiveness (see `CropEditorMath.dampedTranslation`/
    /// `dampedScaleFactor`, both pure stateless multiplies of the current
    /// gesture value; no smoothing, delayed following, or inertia). `1.0`
    /// would be raw/undamped. `fileprivate`, not `private` — read
    /// directly by `ImagePanZoomSurface.Coordinator` below. Tune these
    /// two independently after physical testing.
    fileprivate static let panTranslationSensitivity: CGFloat = 0.92
    fileprivate static let pinchScaleSensitivity: CGFloat = 0.94

    /// Diagnostic-only: a single `.changed` write moving `imageDisplayRect`'s
    /// origin by more than this many points, with no corresponding
    /// gradual finger-driven motion to explain it, is not ordinary
    /// gesture sensitivity — it's flagged with 🚨 in the console.
    private static let jumpDetectionThreshold: CGFloat = 40

    /// Focus-presentation tuning — independent from imageDisplayRect's
    /// own pinch-zoom cap (`pinchTransformImage`'s `maximumScaleMultiplier`):
    /// this scales the crop's on-screen *presentation*, never the
    /// underlying image content. A tiny crop can enlarge substantially;
    /// this is the ceiling.
    private static let maximumFocusScale: CGFloat = 7
    /// How long an interaction must stay fully quiet before the focus
    /// enlargement begins.
    private static let focusSettleDelay: Duration = .milliseconds(120)
    /// Target duration for the ease-in-out focus transition.
    private static let focusAnimationDuration: TimeInterval = 0.34
    /// Tick interval for the self-driven focus-animation loop (~60fps).
    private static let focusAnimationFrameInterval: Duration = .milliseconds(16)

    @State private var frameRect: CGRect = .zero
    @State private var imageDisplayRect: CGRect = .zero
    @State private var hasInitializedLayout = false

    /// Presentation-only visual state — see
    /// `CropEditorMath.PresentationTransform`'s doc comment. `.identity`
    /// means the crop renders and is touched exactly where its real
    /// geometry (`frameRect`/`imageDisplayRect`) says; a non-identity
    /// value is purely a "camera" repositioning that never touches real
    /// geometry, so `CropRegion` resolution is unaffected by it.
    @State private var presentationTransform: CropEditorMath.PresentationTransform = .identity
    /// The pending "did interaction really stop" debounce — same
    /// cancel-and-reschedule pattern as `ItemDetailView`'s note autosave.
    @State private var settleCheckTask: Task<Void, Never>?
    /// The in-flight focus-animation tick loop, if any. Deliberately NOT
    /// driven by SwiftUI's `withAnimation` — that sets `@State` to its
    /// final target the instant it's called, with no reliable way to
    /// query the value actually on screen mid-transition, and a touch
    /// landing during the animation needs exactly that on-screen value to
    /// continue from without a jump. This loop writes its own
    /// interpolated result into `presentationTransform` every ~16ms
    /// instead, so that property is *always* exactly what's currently
    /// rendered. Cancelling it (a new gesture beginning) simply stops the
    /// writes, leaving `presentationTransform` at whatever it last wrote
    /// — no snap to either the old or the target transform.
    @State private var focusAnimationTask: Task<Void, Never>?

    /// Which frame control (if any) the in-progress corner/edge drag
    /// belongs to. Pan/pinch no longer live here — they're UIKit gesture
    /// recognizers in `ImagePanZoomSurface` below, with their own
    /// snapshot-at-gesture-start state, since they need touch-count-based
    /// exclusivity (`UIPanGestureRecognizer.maximumNumberOfTouches`) that
    /// SwiftUI's `DragGesture` can't express.
    private enum FrameInteraction: Equatable {
        case corner(CropEditorMath.Corner)
        case edge(CropEditorMath.Edge)
    }
    @State private var activeFrameInteraction: FrameInteraction?
    /// `frameRect` snapshotted at the start of the current corner/edge
    /// drag — every `onChanged` call applies that gesture's *cumulative*
    /// translation to this fixed snapshot, never to the continuously-
    /// mutating `frameRect` itself, or translations would compound.
    @State private var frameRectAtDragStart: CGRect = .zero

    var body: some View {
        GeometryReader { geometry in
            Group {
                if hasInitializedLayout {
                    editorContent(containerSize: geometry.size)
                } else {
                    Color.black
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onAppear {
                guard !hasInitializedLayout else { return }
                let viewport = CGRect(origin: .zero, size: geometry.size).insetBy(dx: Self.viewportInsetHorizontal, dy: Self.viewportInsetVertical)
                let baseDisplayed = CropEditorMath
                    .displayedImageRect(imageSize: image.size, containerSize: viewport.size)
                    .offsetBy(dx: viewport.minX, dy: viewport.minY)
                commitImageDisplayRect(baseDisplayed, mutation: .initialization(rect: baseDisplayed))
                frameRect = CropEditorMath.rect(for: initialRegion, in: baseDisplayed)
                hasInitializedLayout = true
            }
        }
        .onDisappear {
            cancelPendingFocusTransition()
        }
    }

    private func editorContent(containerSize: CGSize) -> some View {
        let viewport = CGRect(origin: .zero, size: containerSize).insetBy(dx: Self.viewportInsetHorizontal, dy: Self.viewportInsetVertical)
        // Real geometry (frameRect/imageDisplayRect) never changes for
        // presentation — only what gets drawn/touched does. Everything
        // visual below reads these *presented* rects instead of the real
        // ones; decorative mark SIZES (bracket arm length, rail length,
        // stroke width) and touch-target SIZES stay fixed screen-point
        // constants regardless of presentationTransform.scale — only
        // their POSITIONS follow the transformed frame.
        let presentedFrameRect = presentationTransform.apply(to: frameRect)
        let presentedImageRect = presentationTransform.apply(to: imageDisplayRect)

        return ZStack {
            Color.black

            Image(uiImage: image)
                .resizable()
                .frame(width: presentedImageRect.width, height: presentedImageRect.height)
                .position(x: presentedImageRect.midX, y: presentedImageRect.midY)

            dimMask(containerSize: containerSize, cropRect: presentedFrameRect)
            cropBoundary(presentedFrameRect)
            handles(presentedFrameRect)
            edgeRails(presentedFrameRect)

            // Interior pan/pinch surface sits below the frame's own
            // corner/edge hit targets in z-order, so a touch landing on a
            // control is claimed by that control (SwiftUI hit-tests the
            // topmost view first) rather than the broader interior
            // surface beneath it. Spans the *entire* container — see
            // ImagePanZoomSurface's doc comment for why, and how it still
            // restricts interaction to inside the frame.
            ImagePanZoomSurface(
                imageAspectSize: image.size,
                frameRect: frameRect,
                imageDisplayRect: imageDisplayRect,
                presentationTransform: presentationTransform,
                commitImageDisplayRect: commitImageDisplayRect,
                notifyGestureBegan: { cancelPendingFocusTransition() },
                notifyGestureEnded: { scheduleFocusSettleCheck(viewport: viewport) }
            )
            .frame(width: containerSize.width, height: containerSize.height)

            edgeHitTargets(presentedFrameRect, viewport: viewport)
            cornerHitTargets(presentedFrameRect, viewport: viewport)
        }
        .frame(width: containerSize.width, height: containerSize.height)
    }

    // MARK: - imageDisplayRect write chokepoint (diagnostic)

    /// The ONLY place `imageDisplayRect` is assigned — init, pan, and
    /// pinch all route through here (see `ImageRectMutation`'s doc
    /// comment at the top of the file). Performs the exact same
    /// assignment a direct write would; the #if DEBUG block below is the
    /// only difference from before.
    private func commitImageDisplayRect(_ newRect: CGRect, mutation: ImageRectMutation) {
        let previous = imageDisplayRect
        #if DEBUG
        let delta = CGSize(width: newRect.minX - previous.minX, height: newRect.minY - previous.minY)
        let magnitude = hypot(delta.width, delta.height)

        var lines = [
            "[CropEditorView] imageDisplayRect WRITE — source=\(mutation.source.rawValue) owner=\(mutation.owner) recognizerState=\(mutation.recognizerState)",
            "  previous(rendered)=\(previous)",
        ]
        if let start = mutation.gestureStartRect { lines.append("  gestureStartRect=\(start)") }
        if let raw = mutation.rawProposedRect { lines.append("  rawProposedRect(beforeClamp)=\(raw)") }
        lines.append("  final(clamped)=\(newRect)")
        if let translation = mutation.translationDelta { lines.append("  translationDelta=\(translation)") }
        if let scale = mutation.pinchScale { lines.append("  pinchScale=\(scale)") }
        if let starting = mutation.startingCentroid { lines.append("  startingCentroid=\(starting)") }
        if let current = mutation.currentCentroid { lines.append("  currentCentroid=\(current)") }
        if let touchCount = mutation.touchCount { lines.append("  numberOfTouches=\(touchCount)") }
        lines.append("  frameToFrameDelta=\(delta) magnitude=\(magnitude)")

        if magnitude > Self.jumpDetectionThreshold {
            lines.append("🚨 IMAGE RECT JUMP — magnitude \(magnitude) exceeds threshold \(Self.jumpDetectionThreshold), with no gesture-input change of that size")
        }
        print(lines.joined(separator: "\n"))
        #endif
        imageDisplayRect = newRect
    }

    // MARK: - Focus presentation (settle-then-enlarge)

    /// Called at the start of any edit gesture (corner, edge, pan, or
    /// pinch). Cancels whatever focus-related activity is pending or
    /// in-flight, covering both cases: a touch during the 120ms quiet
    /// period cancels the pending enlargement outright; a touch during
    /// the animation itself freezes it at exactly its current on-screen
    /// value — `presentationTransform` simply stops changing, and since
    /// the animation loop was the only thing writing it, that's already
    /// snap-free (see `focusAnimationTask`'s doc comment).
    private func cancelPendingFocusTransition() {
        settleCheckTask?.cancel()
        settleCheckTask = nil
        focusAnimationTask?.cancel()
        focusAnimationTask = nil
    }

    /// Called at the end of any edit gesture. If nothing else starts
    /// within the quiet period, animates to the ideal focus presentation
    /// for whatever `frameRect` looks like *then* — always recomputed
    /// fresh at settle time, so further edits made while already
    /// enlarged settle into a new, correctly-sized target rather than
    /// reusing a stale one.
    private func scheduleFocusSettleCheck(viewport: CGRect) {
        settleCheckTask?.cancel()
        settleCheckTask = Task {
            try? await Task.sleep(for: Self.focusSettleDelay)
            guard !Task.isCancelled else { return }
            let target = CropEditorMath.idealPresentationTransform(for: frameRect, fitting: viewport, maximumScale: Self.maximumFocusScale)
            beginFocusAnimation(to: target)
        }
    }

    /// Explicit, self-driven interpolation — not `withAnimation`. Eased
    /// (no spring/overshoot), ~`focusAnimationDuration` seconds, ticking
    /// at `focusAnimationFrameInterval`. Writes every intermediate value
    /// directly into `presentationTransform`, the same property gesture
    /// code reads, so there is never a gap between "what's rendered" and
    /// "what a new gesture would compute against."
    private func beginFocusAnimation(to target: CropEditorMath.PresentationTransform) {
        focusAnimationTask?.cancel()
        let start = presentationTransform
        let startTime = Date()
        focusAnimationTask = Task {
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(startTime)
                let rawProgress = min(elapsed / Self.focusAnimationDuration, 1)
                presentationTransform = CropEditorMath.PresentationTransform.interpolate(
                    from: start,
                    to: target,
                    progress: CropEditorMath.easedProgress(rawProgress)
                )
                if rawProgress >= 1 { break }
                try? await Task.sleep(for: Self.focusAnimationFrameInterval)
            }
            if !Task.isCancelled {
                presentationTransform = target
            }
            focusAnimationTask = nil
        }
    }

    // MARK: - Frame gestures (corner/edge resize)

    private func frameDragGesture(_ interaction: FrameInteraction, viewport: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if activeFrameInteraction != interaction {
                    activeFrameInteraction = interaction
                    frameRectAtDragStart = frameRect
                    cancelPendingFocusTransition()
                }
                // The frame must stay over real image pixels AND inside
                // the visible viewport (so every handle stays reachable),
                // even once the image has been zoomed well beyond the
                // viewport's own bounds. Intersecting the two rects and
                // using that as the resize's reference container enforces
                // both at once, via the same [0,1]-normalized clamp
                // `resize`/`resizeEdge` already apply — no new resize math
                // needed.
                let coverage = imageDisplayRect.intersection(viewport)
                let startRegion = CropEditorMath.region(for: frameRectAtDragStart, in: coverage)
                // The hit target is positioned/drawn at the *presented*
                // frame, so a raw drag's translation is measured in
                // presented (screen) terms — convert it back to real
                // units before it reaches CropEditorMath, which knows
                // nothing about presentation. This division is also what
                // makes the enlarged state an actual precision aid: the
                // same finger travel now moves the real frame less.
                let realTranslation = presentationTransform.inverseDelta(value.translation)
                let newRegion: CropRegion
                switch interaction {
                case .corner(let corner):
                    newRegion = CropEditorMath.resize(startRegion, corner: corner, by: realTranslation, displayedImageRect: coverage)
                case .edge(let edge):
                    newRegion = CropEditorMath.resizeEdge(startRegion, edge: edge, by: realTranslation, displayedImageRect: coverage)
                }
                frameRect = CropEditorMath.rect(for: newRegion, in: coverage)
            }
            .onEnded { _ in
                activeFrameInteraction = nil
                scheduleFocusSettleCheck(viewport: viewport)
            }
    }

    private func cornerHitTargets(_ cropRect: CGRect, viewport: CGRect) -> some View {
        ForEach(CropEditorMath.Corner.allCases, id: \.self) { corner in
            Rectangle()
                .fill(Color.clear)
                .frame(width: Self.cornerTouchTargetSize, height: Self.cornerTouchTargetSize)
                .contentShape(Rectangle())
                .position(Self.point(for: corner, in: cropRect))
                .gesture(frameDragGesture(.corner(corner), viewport: viewport))
        }
    }

    private func edgeHitTargets(_ cropRect: CGRect, viewport: CGRect) -> some View {
        ForEach(CropEditorMath.Edge.allCases, id: \.self) { edge in
            let size = Self.touchTargetSize(for: edge)
            Rectangle()
                .fill(Color.clear)
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .position(Self.midpoint(for: edge, in: cropRect))
                .gesture(frameDragGesture(.edge(edge), viewport: viewport))
        }
    }

    // MARK: - Visuals

    /// Full raw container, minus the crop rect, via an even-odd fill —
    /// dims everything outside the crop, including the inset margin and
    /// any letterbox bars (both always outside the displayed image, hence
    /// always outside the crop too).
    private func dimMask(containerSize: CGSize, cropRect: CGRect) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: containerSize))
            path.addRect(cropRect)
        }
        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    /// The connecting boundary — deliberately quiet (low opacity, no
    /// shadow) so it reads as a mutable guide the corner/edge controls
    /// belong to, not a finished border in its own right.
    private func cropBoundary(_ cropRect: CGRect) -> some View {
        Rectangle()
            .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
            .frame(width: cropRect.width, height: cropRect.height)
            .position(x: cropRect.midX, y: cropRect.midY)
            .allowsHitTesting(false)
    }

    /// Corner brackets — two short arms meeting exactly at each crop-rect
    /// corner and running inward along its edges, reading as belonging to
    /// the frame itself rather than four detached dots. Purely decorative
    /// — the invisible `cornerHitTargets` above handle interaction.
    private func handles(_ cropRect: CGRect) -> some View {
        let arm = min(Self.handleArmLength, cropRect.width / 2, cropRect.height / 2)
        return Path { path in
            for corner in CropEditorMath.Corner.allCases {
                let point = Self.point(for: corner, in: cropRect)
                let direction = Self.armDirection(for: corner)
                path.move(to: CGPoint(x: point.x, y: point.y + direction.dy * arm))
                path.addLine(to: point)
                path.addLine(to: CGPoint(x: point.x + direction.dx * arm, y: point.y))
            }
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: Self.controlLineWidth, lineCap: .round, lineJoin: .round))
        .shadow(color: .black.opacity(0.45), radius: 1.5)
        .allowsHitTesting(false)
    }

    /// Short straight rails centered on each edge's midpoint, lying along
    /// the edge. Purely decorative — the invisible `edgeHitTargets` above
    /// handle interaction.
    private func edgeRails(_ cropRect: CGRect) -> some View {
        Path { path in
            for edge in CropEditorMath.Edge.allCases {
                let (start, end) = Self.segment(for: edge, in: cropRect)
                path.move(to: start)
                path.addLine(to: end)
            }
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: Self.controlLineWidth, lineCap: .round))
        .shadow(color: .black.opacity(0.45), radius: 1.5)
        .allowsHitTesting(false)
    }

    // MARK: - Shared geometry helpers
    //
    // `static` (and `fileprivate` where used outside this type) so
    // `ImagePanZoomSurface.Coordinator` below can compute the same
    // touch-target rects without needing a `CropEditorView` instance.

    fileprivate static func point(for corner: CropEditorMath.Corner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    /// Which direction each bracket's two arms travel from its corner
    /// point — always inward, along the crop rect's own edges.
    private static func armDirection(for corner: CropEditorMath.Corner) -> (dx: CGFloat, dy: CGFloat) {
        switch corner {
        case .topLeft: return (1, 1)
        case .topRight: return (-1, 1)
        case .bottomLeft: return (1, -1)
        case .bottomRight: return (-1, -1)
        }
    }

    fileprivate static func midpoint(for edge: CropEditorMath.Edge, in rect: CGRect) -> CGPoint {
        switch edge {
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        }
    }

    fileprivate static func touchTargetSize(for edge: CropEditorMath.Edge) -> CGSize {
        switch edge {
        case .top, .bottom: return CGSize(width: edgeTouchTargetLength, height: edgeTouchTargetThickness)
        case .left, .right: return CGSize(width: edgeTouchTargetThickness, height: edgeTouchTargetLength)
        }
    }

    private static func segment(for edge: CropEditorMath.Edge, in rect: CGRect) -> (CGPoint, CGPoint) {
        let half = min(railHalfLength, rect.width / 2, rect.height / 2)
        switch edge {
        case .top:
            return (CGPoint(x: rect.midX - half, y: rect.minY), CGPoint(x: rect.midX + half, y: rect.minY))
        case .bottom:
            return (CGPoint(x: rect.midX - half, y: rect.maxY), CGPoint(x: rect.midX + half, y: rect.maxY))
        case .left:
            return (CGPoint(x: rect.minX, y: rect.midY - half), CGPoint(x: rect.minX, y: rect.midY + half))
        case .right:
            return (CGPoint(x: rect.maxX, y: rect.midY - half), CGPoint(x: rect.maxX, y: rect.midY + half))
        }
    }

    fileprivate static func cornerTouchRect(_ corner: CropEditorMath.Corner, in frame: CGRect) -> CGRect {
        let center = point(for: corner, in: frame)
        return CGRect(x: center.x - cornerTouchTargetSize / 2, y: center.y - cornerTouchTargetSize / 2, width: cornerTouchTargetSize, height: cornerTouchTargetSize)
    }

    fileprivate static func edgeTouchRect(_ edge: CropEditorMath.Edge, in frame: CGRect) -> CGRect {
        let center = midpoint(for: edge, in: frame)
        let size = touchTargetSize(for: edge)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }
}

/// UIKit bridge for the interior pan/pinch gestures — SwiftUI's native
/// `MagnificationGesture` reports only a scale factor, never a continuous
/// location, so it can't express "zoom centered on the pinch's own
/// centroid." `UIPinchGestureRecognizer` does (`location(in:)`, updated
/// live). Also hosts the one-finger pan as a `UIPanGestureRecognizer`
/// capped to one touch — rather than mixing a SwiftUI `DragGesture` with a
/// UIKit pinch recognizer, keeping both as UIKit recognizers on the same
/// view lets `maximumNumberOfTouches` hand off the touch cleanly the
/// moment a second finger lands: pan fails/ends, pinch (which needs
/// exactly 2 touches) begins, with no custom simultaneous-recognition
/// logic required.
///
/// Sized to the *entire* GeometryReader container (not just `frameRect`)
/// so `location(in:)`/`translation(in:)` land directly in
/// CropEditorView-local coordinates — the same space `frameRect` and
/// `imageDisplayRect` already live in — with zero manual conversion.
/// Restricting interaction to "inside the frame" is done via
/// `shouldReceive touch:` instead of view bounds.
private struct ImagePanZoomSurface: UIViewRepresentable {
    let imageAspectSize: CGSize
    let frameRect: CGRect
    /// Current value, refreshed every SwiftUI render via `updateUIView` —
    /// only ever *read* here (at gesture `.began`, to snapshot). Not a
    /// `@Binding`: writes go through `commitImageDisplayRect` instead, so
    /// every write is observable at one chokepoint regardless of which
    /// recognizer produced it.
    let imageDisplayRect: CGRect
    /// The presentation transform active *right now* — read fresh on
    /// every gesture callback (not snapshotted once at `.began`) since
    /// `cancelPendingFocusTransition`, called at gesture start, always
    /// stops it changing before any callback that reads it runs, so it's
    /// stable for the gesture's whole duration regardless.
    let presentationTransform: CropEditorMath.PresentationTransform
    let commitImageDisplayRect: (CGRect, ImageRectMutation) -> Void
    /// Called once at the start of any pan/pinch gesture — cancels
    /// whatever focus-presentation activity is pending/in-flight.
    let notifyGestureBegan: () -> Void
    /// Called once when a pan/pinch gesture genuinely ends (not on a
    /// suppressed stale callback) — schedules the 120ms settle check.
    let notifyGestureEnded: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator
        view.addGestureRecognizer(pinch)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ImagePanZoomSurface

        /// Explicit session ownership over the shared, live
        /// `parent.imageDisplayRect`. Separating pan/pinch's *snapshots*
        /// (below) stopped one concrete stale-snapshot bug, but it didn't
        /// stop a late `.changed` callback from the *outgoing* recognizer
        /// from still WRITING to the shared live rect after the incoming
        /// recognizer had already taken over and written its own, correct
        /// values — nothing previously checked "is my recognizer still
        /// the current one" before writing. That produced exactly the
        /// observed symptom: a smooth pinch/pan progression, then an
        /// abrupt, unrelated snap to a stale value computed from an old
        /// gesture's own base + a translation/scale that no longer means
        /// what it did when the write actually lands.
        ///
        /// Only the recognizer that currently owns the session is allowed
        /// to write in `.changed`; `.began` always claims ownership
        /// unconditionally (a real new gesture legitimately starting);
        /// `.ended`/`.cancelled`/`.failed` only release ownership if this
        /// recognizer still holds it, so a late release from an already-
        /// superseded recognizer can't clear the new owner's session.
        private enum GestureOwner: Equatable {
            case pan
            case pinch
        }
        private var owner: GestureOwner?

        /// `imageDisplayRect` snapshotted at gesture start — both
        /// `UIPanGestureRecognizer.translation` and
        /// `UIPinchGestureRecognizer.scale` are cumulative since gesture
        /// start, so each `.changed` callback re-applies that cumulative
        /// value to this fixed snapshot rather than to the continuously-
        /// mutating live rect. Deliberately two separate properties, one
        /// per recognizer, so an incoming recognizer's fresh snapshot can
        /// never be contaminated by the outgoing one's — though with
        /// `owner` gating writes, the outgoing recognizer can no longer
        /// mutate shared state at all once superseded, which is now the
        /// primary guarantee; this separation is a second, independent
        /// layer of safety.
        private var panImageDisplayRectAtGestureStart: CGRect = .zero
        private var pinchImageDisplayRectAtGestureStart: CGRect = .zero
        /// The pinch's own centroid at `.began` — needed alongside
        /// `pinchImageDisplayRectAtGestureStart` so `.changed` can separate
        /// "scale around where the fingers started" from "translate by
        /// how far the fingers, as a pair, have moved since." Using the
        /// *current* (moving) centroid as the scale anchor on every frame
        /// — the earlier, buggy approach — cancels out pure two-finger
        /// translation entirely, since it re-derives "which image point
        /// is under the fingers" fresh each frame instead of tracking one
        /// fixed point.
        private var pinchCentroidAtGestureStart: CGPoint = .zero
        /// Set when a `.changed` callback observes `numberOfTouches != 2`
        /// mid-pinch — UIKit momentarily dropping/reclassifying one touch
        /// while the recognizer keeps emitting `.changed`, confirmed by a
        /// physical-device trace: `scale` stayed bit-for-bit identical
        /// across two consecutive callbacks while `location(in:)`
        /// teleported, the signature of the touch SET underlying the
        /// centroid changing without the distance-based scale accumulator
        /// moving. Such a sample is never committed (so it can never
        /// become a future `gestureStartRect`); the *next* valid 2-touch
        /// sample rebases from the current rendered rect and a fresh
        /// centroid instead of continuing from the pre-drop session.
        private var pinchTouchContinuityBroken = false

        init(parent: ImagePanZoomSurface) {
            self.parent = parent
        }

        /// Restricts both recognizers to touches that land inside the
        /// current frame and outside any corner/edge control's own touch
        /// target. The corner/edge exclusion is mostly a defensive
        /// backstop — those SwiftUI-rendered targets sit above this view
        /// in z-order and should already claim their own touches first —
        /// but it costs little and guards against any edge-pixel
        /// ambiguity right at a UIViewRepresentable boundary.
        ///
        /// Tests against the *presented* frame, not the real one — that's
        /// where the crop is actually drawn, so that's what the user is
        /// actually touching.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view = gestureRecognizer.view else { return true }
            let point = touch.location(in: view)
            let frame = parent.presentationTransform.apply(to: parent.frameRect)
            guard frame.contains(point) else { return false }
            for corner in CropEditorMath.Corner.allCases {
                if CropEditorView.cornerTouchRect(corner, in: frame).contains(point) { return false }
            }
            for edge in CropEditorMath.Edge.allCases {
                if CropEditorView.edgeTouchRect(edge, in: frame).contains(point) { return false }
            }
            return true
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                owner = .pan
                panImageDisplayRectAtGestureStart = parent.imageDisplayRect
                parent.notifyGestureBegan()
            case .changed:
                guard owner == .pan else {
                    #if DEBUG
                    print("[ImagePanZoomSurface] suppressed stale pan .changed — owner is \(String(describing: owner))")
                    #endif
                    return
                }
                let translation = recognizer.translation(in: recognizer.view)
                let rawScreenDelta = CGSize(width: translation.x, height: translation.y)
                // rawScreenDelta is measured against the *presented*
                // surface (that's what's on screen and what the finger is
                // actually moving across) — convert to real units before
                // it reaches CropEditorMath, which knows nothing about
                // presentation. Same division that makes the enlarged
                // state an actual precision aid, not just a visual one.
                let realDelta = parent.presentationTransform.inverseDelta(rawScreenDelta)
                let delta = CropEditorMath.dampedTranslation(realDelta, sensitivity: CropEditorView.panTranslationSensitivity)
                let rawProposed = panImageDisplayRectAtGestureStart.offsetBy(dx: delta.width, dy: delta.height)
                let finalRect = CropEditorMath.panImage(panImageDisplayRectAtGestureStart, by: delta, coveringFrame: parent.frameRect)
                parent.commitImageDisplayRect(finalRect, ImageRectMutation(
                    source: .pan,
                    owner: "pan",
                    recognizerState: "changed",
                    gestureStartRect: panImageDisplayRectAtGestureStart,
                    rawProposedRect: rawProposed,
                    translationDelta: delta,
                    pinchScale: nil,
                    startingCentroid: nil,
                    currentCentroid: nil,
                    touchCount: nil
                ))
            case .ended, .cancelled, .failed:
                if owner == .pan {
                    owner = nil
                    parent.notifyGestureEnded()
                }
            default:
                break
            }
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                owner = .pinch
                pinchImageDisplayRectAtGestureStart = parent.imageDisplayRect
                // Raw location is in presented (screen) terms; pinchTransformImage
                // computes fractions/deltas against real imageDisplayRect,
                // so the centroid snapshot itself must already be in real
                // space too.
                pinchCentroidAtGestureStart = parent.presentationTransform.inverse(recognizer.location(in: recognizer.view))
                pinchTouchContinuityBroken = false
                parent.notifyGestureBegan()
            case .changed:
                guard owner == .pinch else {
                    #if DEBUG
                    print("[ImagePanZoomSurface] suppressed stale pinch .changed — owner is \(String(describing: owner))")
                    #endif
                    return
                }

                let touchCount = recognizer.numberOfTouches
                guard touchCount == 2 else {
                    // A touch-membership change must never itself create
                    // image motion. Ignore this sample entirely — it never
                    // reaches commitImageDisplayRect, so it can never
                    // become a future gestureStartRect — and mark
                    // continuity broken so the next valid 2-touch sample
                    // rebases instead of computing against this session's
                    // now-unreliable starting centroid.
                    #if DEBUG
                    print("[ImagePanZoomSurface] pinch touch-count discontinuity — numberOfTouches=\(touchCount), sample ignored")
                    #endif
                    pinchTouchContinuityBroken = true
                    return
                }

                if pinchTouchContinuityBroken {
                    // Resume from the last committed (rendered) rect and a
                    // fresh centroid, not from the pre-drop session.
                    // recognizer.scale is reset too — it's cumulative
                    // since the recognizer's own .began, not since this
                    // rebase point, so leaving it alone would double-count
                    // whatever scale change is already baked into the
                    // rebased starting rect.
                    pinchImageDisplayRectAtGestureStart = parent.imageDisplayRect
                    pinchCentroidAtGestureStart = parent.presentationTransform.inverse(recognizer.location(in: recognizer.view))
                    recognizer.scale = 1
                    pinchTouchContinuityBroken = false
                    #if DEBUG
                    print("[ImagePanZoomSurface] pinch continuity resumed — rebased from rendered rect \(parent.imageDisplayRect), new centroid \(pinchCentroidAtGestureStart)")
                    #endif
                }

                let currentCentroid = parent.presentationTransform.inverse(recognizer.location(in: recognizer.view))
                let dampedScale = CropEditorMath.dampedScaleFactor(recognizer.scale, sensitivity: CropEditorView.pinchScaleSensitivity)
                // Same "translation response" damping pan uses, applied
                // to the centroid's own movement — the two-finger pair
                // moving together is still translation, just reported via
                // a centroid instead of DragGesture.translation. Damping
                // it here, as a pre-adjustment to the *effective* current
                // centroid, leaves pinchTransformImage's own scale-around-
                // startingCentroid anchoring math completely untouched —
                // that's the "centroid/focal behavior" this keeps intact:
                // a pure zoom-in-place (currentCentroid == startingCentroid,
                // zero delta) is entirely unaffected by this damping.
                let rawCentroidDelta = CGSize(width: currentCentroid.x - pinchCentroidAtGestureStart.x, height: currentCentroid.y - pinchCentroidAtGestureStart.y)
                let dampedCentroidDelta = CropEditorMath.dampedTranslation(rawCentroidDelta, sensitivity: CropEditorView.panTranslationSensitivity)
                let dampedCurrentCentroid = CGPoint(x: pinchCentroidAtGestureStart.x + dampedCentroidDelta.width, y: pinchCentroidAtGestureStart.y + dampedCentroidDelta.height)
                let rawProposed = Self.rawPinchProposedRect(
                    from: pinchImageDisplayRectAtGestureStart,
                    scaleFactor: dampedScale,
                    startingCentroid: pinchCentroidAtGestureStart,
                    currentCentroid: dampedCurrentCentroid,
                    imageAspectSize: parent.imageAspectSize,
                    frameRect: parent.frameRect
                )
                let finalRect = CropEditorMath.pinchTransformImage(
                    pinchImageDisplayRectAtGestureStart,
                    scaleFactor: dampedScale,
                    startingCentroid: pinchCentroidAtGestureStart,
                    currentCentroid: dampedCurrentCentroid,
                    imageAspectSize: parent.imageAspectSize,
                    coveringFrame: parent.frameRect
                )
                parent.commitImageDisplayRect(finalRect, ImageRectMutation(
                    source: .pinch,
                    owner: "pinch",
                    recognizerState: "changed",
                    gestureStartRect: pinchImageDisplayRectAtGestureStart,
                    rawProposedRect: rawProposed,
                    translationDelta: dampedCentroidDelta,
                    pinchScale: dampedScale,
                    startingCentroid: pinchCentroidAtGestureStart,
                    currentCentroid: dampedCurrentCentroid,
                    touchCount: touchCount
                ))
            case .ended, .cancelled, .failed:
                if owner == .pinch {
                    owner = nil
                    pinchTouchContinuityBroken = false
                    parent.notifyGestureEnded()
                }
            default:
                break
            }
        }

        /// Diagnostic only — mirrors `CropEditorMath.pinchTransformImage`'s
        /// computation up to (but not including) its final
        /// `clampImageOrigin` call, so the logged "raw proposed rect
        /// before clamping" reflects what the real function actually
        /// computes internally. Never used for the committed rect itself
        /// — that always comes from the real, tested function.
        private static func rawPinchProposedRect(
            from imageRect: CGRect,
            scaleFactor: CGFloat,
            startingCentroid: CGPoint,
            currentCentroid: CGPoint,
            imageAspectSize: CGSize,
            frameRect: CGRect,
            maximumScaleMultiplier: CGFloat = 9
        ) -> CGRect {
            guard imageRect.width > 0, imageRect.height > 0,
                  imageAspectSize.width > 0, imageAspectSize.height > 0 else { return imageRect }

            let minimumSize = CropEditorMath.minimumCoveringSize(imageAspectSize: imageAspectSize, toCover: frameRect)
            let minimumScale = minimumSize.width / imageAspectSize.width
            let maximumScale = minimumScale * maximumScaleMultiplier
            let currentScale = imageRect.width / imageAspectSize.width
            let clampedScale = min(max(currentScale * scaleFactor, minimumScale), maximumScale)
            let newSize = CGSize(width: imageAspectSize.width * clampedScale, height: imageAspectSize.height * clampedScale)

            let fractionX = (startingCentroid.x - imageRect.minX) / imageRect.width
            let fractionY = (startingCentroid.y - imageRect.minY) / imageRect.height
            let scaledOrigin = CGPoint(x: startingCentroid.x - fractionX * newSize.width, y: startingCentroid.y - fractionY * newSize.height)

            let centroidDelta = CGSize(width: currentCentroid.x - startingCentroid.x, height: currentCentroid.y - startingCentroid.y)
            let translatedOrigin = CGPoint(x: scaledOrigin.x + centroidDelta.width, y: scaledOrigin.y + centroidDelta.height)

            return CGRect(origin: translatedOrigin, size: newSize)
        }
    }
}
