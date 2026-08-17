import SwiftUI
import UIKit

/// Wraps `content` in a native `UIScrollView` purely for its built-in
/// pinch-to-zoom + pan mechanics. SwiftUI's own `MagnificationGesture` has
/// no anchor/location value at all — it only ever reports a magnification
/// factor — so a hand-rolled `.scaleEffect` + `.offset` implementation
/// (this container's predecessor) can only zoom around a single fixed
/// point, which in practice meant always the image's own center,
/// regardless of where the user actually pinched. `UIScrollView` zooming
/// is anchor-correct by construction — it's the exact mechanism Photos.app
/// itself uses — and free-pans a zoomed view within the bounds its own
/// `contentSize` already defines, including natural rubber-band overshoot
/// at the edges. None of that is reimplemented by hand here; it's inherent
/// to using the real thing.
struct ZoomableImageContainer<Content: View>: UIViewRepresentable {
    var minZoom: CGFloat = 1
    var maxZoom: CGFloat = 5
    /// True whenever `zoomScale` is above `minZoom` — callers use this to
    /// suspend an enclosing SwiftUI `ScrollView` (`.scrollDisabled`) so
    /// panning the zoomed image doesn't fight the page's own scroll, and
    /// so a plain drag on the *unzoomed* image still scrolls the page
    /// normally rather than being captured by this scroll view.
    @Binding var isZoomedIn: Bool
    /// Bumping this (any change; the value itself is never read) snaps
    /// zoom/pan back to the fitted, centered 1x state — the same "tick"
    /// convention already used elsewhere (see
    /// `RootView.scrollArchiveToTopTick`). Callers bump it when the hosted
    /// content changes size/identity (e.g. crop ↔ original), so a stale
    /// zoom never carries into a differently-sized image.
    var resetSignal: Int
    /// Preserves the existing tap-to-toggle-context interaction. A plain
    /// SwiftUI `.onTapGesture` layered on top of a `UIViewRepresentable`
    /// isn't reliably hit-tested through it, so the tap is recognized
    /// natively instead, via a `UITapGestureRecognizer` on the same scroll
    /// view — coexisting with the scroll view's own pinch/pan recognizers
    /// the ordinary UIKit way, no ordering tricks required.
    var onSingleTap: (() -> Void)?
    let content: Content

    init(
        minZoom: CGFloat = 1,
        maxZoom: CGFloat = 5,
        isZoomedIn: Binding<Bool>,
        resetSignal: Int,
        onSingleTap: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self._isZoomedIn = isZoomedIn
        self.resetSignal = resetSignal
        self.onSingleTap = onSingleTap
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(hostingController: UIHostingController(rootView: content), isZoomedIn: $isZoomedIn, onSingleTap: onSingleTap)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = minZoom
        scrollView.maximumZoomScale = maxZoom
        scrollView.bouncesZoom = true
        scrollView.bounces = true
        // Starts disabled — with nothing zoomed in yet there's nothing to
        // pan, and leaving it enabled would let this view's own pan
        // recognizer capture drags meant for the page's outer ScrollView.
        // `scrollViewDidZoom` flips it on/off with zoom state.
        scrollView.isScrollEnabled = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let hosted = context.coordinator.hostingController.view!
        hosted.backgroundColor = .clear
        hosted.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            hosted.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            hosted.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            // Content matches the visible frame exactly at zoomScale 1 —
            // the standard single-view-zoomable-scroll-view constraint
            // pattern; UIScrollView's own zoom transform grows it from there.
            hosted.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            hosted.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        scrollView.addGestureRecognizer(tap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.hostingController.rootView = content
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.applyResetIfNeeded(resetSignal, scrollView: scrollView)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let hostingController: UIHostingController<Content>
        @Binding var isZoomedIn: Bool
        var onSingleTap: (() -> Void)?
        private var lastResetSignal: Int?

        init(hostingController: UIHostingController<Content>, isZoomedIn: Binding<Bool>, onSingleTap: (() -> Void)?) {
            self.hostingController = hostingController
            self._isZoomedIn = isZoomedIn
            self.onSingleTap = onSingleTap
        }

        /// No-ops on the very first call (nothing to reset back from yet)
        /// so this container doesn't animate on initial appearance; every
        /// subsequent change to `signal` snaps zoom/pan back to fitted.
        func applyResetIfNeeded(_ signal: Int, scrollView: UIScrollView) {
            defer { lastResetSignal = signal }
            guard let last = lastResetSignal, last != signal else { return }
            scrollView.setZoomScale(1, animated: true)
            scrollView.setContentOffset(.zero, animated: true)
            scrollView.isScrollEnabled = false
            isZoomedIn = false
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            hostingController.view
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let zoomedIn = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            if zoomedIn != isZoomedIn { isZoomedIn = zoomedIn }
            scrollView.isScrollEnabled = zoomedIn
        }

        /// Pinching back down past ~1x settles fully back to the fitted,
        /// centered view rather than leaving it at some odd near-1 scale
        /// or off-center offset.
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            guard scale <= scrollView.minimumZoomScale + 0.01 else { return }
            UIView.animate(withDuration: 0.25) {
                scrollView.contentOffset = .zero
            }
            scrollView.isScrollEnabled = false
            isZoomedIn = false
        }

        @objc func handleTap() {
            onSingleTap?()
        }
    }
}
