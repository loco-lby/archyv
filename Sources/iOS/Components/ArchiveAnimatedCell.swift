import SwiftUI
import ArkyvKit

/// One Archive Motion 01: `LocalImageView`'s existing masonry thumbnail
/// rendering — byte-for-byte the same call, same modifiers a caller
/// applies around it — is ALWAYS the base layer here, and is already a
/// correct static representation of an animated source (a multi-frame
/// GIF/WebP's frame 0 decodes fine through the ordinary static path, per
/// Animation Rendering 01's own regression coverage). This view only ever
/// adds an OPTIONAL animated overlay on top, granted centrally by
/// `ArchiveAnimationCoordinator` — never in place of the poster, so there
/// is no blank tile, layout jump, or reload flash at any point in the
/// eligibility lifecycle.
///
/// A static Cherry (the overwhelming majority) pays for none of this
/// beyond one cached-after-first-check async read: `checkEligibility()`
/// is gated on `item.kind.isMedia`, its answer is cached forever per
/// filename (`AnimationEligibilityCache`), and a confirmed-static item
/// never reports its frame to the coordinator, never registers as a
/// candidate, and never touches `AnimatedImageDecoding.decodeAnimated`.
struct ArchiveAnimatedCell: View {
    let item: StoredItem
    let coordinator: ArchiveAnimationCoordinator
    /// QA Follow-Up 02 §1/§3/§4: the archive viewport's own size, passed
    /// down from `ArchiveView`'s outer `GeometryReader` — needed so this
    /// cell can compute and report its own visibility DIRECTLY, rather
    /// than through `CellFramePreferenceKey`/`.onPreferenceChange`. Real
    /// device evidence (a live diagnostic capture during an Item Detail →
    /// Back repro) proved the preference-based path silently drops a
    /// reappearing cell's report: after `.onDisappear` clears its
    /// coordinator candidate, reappearing at the EXACT SAME on-screen
    /// geometry (scroll position never moved) produces a preference value
    /// SwiftUI considers unchanged from the last one it delivered, so
    /// `onPreferenceChange`'s closure is never called again — the
    /// coordinator is left believing this cell doesn't exist, with
    /// nothing left to ever tell it otherwise. `.onAppear`/`.onChange`
    /// have no such value-equality suppression: they fire on every
    /// genuine appearance/change event, independent of whether the
    /// resulting geometry happens to match a prior report.
    let viewportSize: CGSize

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isAnimated: Bool?
    @State private var animatedSource: AnimatedImageDecoding.AnimatedSource?
    @State private var startDate = Date()

    /// Masonry-tile-appropriate decode budget — these are ~180pt-wide
    /// grid cells, not full-screen Item Detail views, so reuse the exact
    /// pixel target `LocalImageView`'s own masonry thumbnail already
    /// decodes at, not Item Detail's much larger 1024pt cap.
    private static let thumbnailFrameTarget = LocalImageView.masonryThumbnailShortEdge

    private var isGranted: Bool { coordinator.grantedIDs.contains(item.id) }

    /// See the `.task` call site below and
    /// `ArchiveAnimationCoordinator.resumeIfNeeded()`'s own doc comment.
    private struct PlaybackTaskKey: Equatable {
        let isGranted: Bool
        let resumeGeneration: Int
    }

    var body: some View {
        ZStack {
            LocalImageView(
                filename: item.localFilename,
                fallbackImageData: { item.imageData },
                cropRegion: item.cropRegion,
                decodeTarget: .thumbnail(shortEdgeTarget: LocalImageView.masonryThumbnailShortEdge),
                originalPixelSize: CGSize(width: item.aspectWidth, height: item.aspectHeight)
            )
            if let animatedSource, !reduceMotion {
                TimelineView(.animation) { context in
                    let frame = AnimatedImageDecoding.currentFrame(in: animatedSource, elapsed: context.date.timeIntervalSince(startDate))
                    croppedOrPlain(frame.image)
                }
                .allowsHitTesting(false)
            }
        }
        .background {
            // Only genuinely-animated cells report their visibility — this
            // is what keeps the coordinator's candidate set (and therefore
            // its per-update ranking work) bounded to the small minority
            // of Cherries that could ever animate, not the whole archive.
            if isAnimated == true {
                GeometryReader { geo in
                    let frame = geo.frame(in: .named("archiveScroll"))
                    Color.clear
                        .onAppear { reportVisibility(frame: frame) }
                        .onChange(of: frame) { _, newFrame in reportVisibility(frame: newFrame) }
                }
            }
        }
        .task(id: item.localFilename) { await checkEligibility() }
        // Physical QA Follow-Up §D: `resumeGeneration` is folded into
        // this task's identity specifically so a foreground-resume that
        // doesn't change WHICH cells are granted still forces a genuine
        // re-run — see `ArchiveAnimationCoordinator.resumeIfNeeded()`'s
        // own doc comment.
        .task(id: PlaybackTaskKey(isGranted: reduceMotion ? false : isGranted, resumeGeneration: coordinator.resumeGeneration)) {
            if reduceMotion {
                return
            } else if isGranted {
                // A resume forces a fresh decode + fresh `startDate` even
                // if `animatedSource` never actually went nil — guarantees
                // correct visual resumption regardless of exactly why
                // playback had stalled, without touching anything for a
                // cell that isn't currently granted.
                animatedSource = nil
                await decodeIfNeeded()
            } else {
                animatedSource = nil // revoked — release decoded frames promptly, §8
            }
        }
        .onDisappear {
            coordinator.remove(id: item.id)
            animatedSource = nil
        }
    }

    /// Interprets this cell's own frame (already in the `"archiveScroll"`
    /// coordinate space, so it already reflects scroll offset) against
    /// the fixed viewport rect, and reports directly to the coordinator —
    /// see `viewportSize`'s own doc comment for why this bypasses the
    /// PreferenceKey pipeline entirely rather than relying on its
    /// change-detection.
    private func reportVisibility(frame: CGRect) {
        let viewport = CGRect(origin: .zero, size: viewportSize)
        let intersection = frame.intersection(viewport)
        let cellArea = frame.width * frame.height
        let visibleFraction = cellArea > 0 ? (intersection.width * intersection.height) / cellArea : 0
        let viewportCenter = CGPoint(x: viewport.midX, y: viewport.midY)
        let cellCenter = CGPoint(x: frame.midX, y: frame.midY)
        let distance = hypot(cellCenter.x - viewportCenter.x, cellCenter.y - viewportCenter.y)
        coordinator.updateVisibility(id: item.id, visibleFraction: visibleFraction, distanceFromCenter: distance)
    }

    /// Identical crop math to `LocalImageView`/`AnimatedLocalImageView`'s
    /// own `croppedImage(_:)` — the same shared `CropRegion.renderTransform`
    /// source of truth, applied to whichever frame is currently showing so
    /// the crop window holds steady across the animation rather than only
    /// applying to frame 0.
    @ViewBuilder
    private func croppedOrPlain(_ image: UIImage) -> some View {
        if item.cropRegion.isFullImage {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            GeometryReader { geometry in
                let transform = item.cropRegion.renderTransform(imageSize: image.size, containerSize: geometry.size)
                let scaledSize = CGSize(width: image.size.width * transform.scale, height: image.size.height * transform.scale)
                let center = CGPoint(x: transform.offset.width + scaledSize.width / 2, y: transform.offset.height + scaledSize.height / 2)
                Image(uiImage: image)
                    .resizable()
                    .frame(width: scaledSize.width, height: scaledSize.height)
                    .position(x: center.x, y: center.y)
            }
            .clipped()
        }
    }

    /// Physical QA Follow-Up §C: a cold cache miss here used to be left
    /// `nil`/unanswered forever, on the theory that the poster
    /// `LocalImageView` above would materialize the cache file as a side
    /// effect of its own rendering. That theory was wrong for exactly the
    /// case masonry cells always use: `LocalImageView`'s `.thumbnail`
    /// decode target deliberately decodes straight from `imageData`
    /// WITHOUT writing a `MediaStore` cache file (see its own doc
    /// comment — "no MediaStore cache file write required merely to
    /// render a small tile"), unlike Item Detail's `.full`-equivalent
    /// path, which always does. An item that reaches Archive via a cold
    /// cache miss — any provenance, not just a particular source family
    /// — would therefore animate correctly in Item Detail while
    /// permanently reading as static in Archive, with no later recovery.
    /// Now falls back to `item.imageData` directly, matching
    /// `AnimatedLocalImageView`'s own contract exactly, rather than
    /// duplicating `LocalImageView`'s cache-skipping thumbnail behavior.
    private func checkEligibility() async {
        guard item.kind.isMedia, !item.isEditorial, let filename = item.localFilename else { return }
        if let cached = AnimationEligibilityCache.shared.isAnimated(forFilename: filename) {
            isAnimated = cached
            return
        }
        guard let data = await resolvedData(filename: filename) else { return }
        guard !Task.isCancelled else { return }
        let animated = AnimatedImageDecoding.frameCount(ofData: data) > 1
        AnimationEligibilityCache.shared.store(animated, forFilename: filename)
        if filename == item.localFilename { isAnimated = animated }
    }

    private func decodeIfNeeded() async {
        guard animatedSource == nil, let filename = item.localFilename else { return }
        guard let data = await resolvedData(filename: filename) else { return }
        let target = Self.thumbnailFrameTarget
        let decoded = await Task.detached(priority: .userInitiated) {
            AnimatedImageDecoding.decodeAnimated(data, maxPixelSize: target)
        }.value
        guard !Task.isCancelled, filename == item.localFilename else { return }
        if let decoded {
            animatedSource = decoded
            startDate = Date()
        }
    }

    /// The shared cold-cache-miss fallback both methods above need — the
    /// same shape as `LocalImageView`'s own `.full`-target fallback:
    /// `item.imageData` is a SwiftData property, so it's read here on the
    /// main actor (where this `async` method already runs, per SwiftUI's
    /// `.task` contract) before crossing into `MediaStore`'s
    /// off-main-actor reconstruction, never touched from inside a
    /// detached `Task`.
    private func resolvedData(filename: String) async -> Data? {
        if let cached = MediaStore.shared.data(for: filename) { return cached }
        guard let restored = item.imageData else { return nil }
        return await MediaStore.shared.data(for: filename, reconstructingFrom: { restored })
    }
}
