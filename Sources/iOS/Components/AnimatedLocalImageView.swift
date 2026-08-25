import SwiftUI
import ArkyvKit

/// Animation Rendering 01: faithful animated playback for a single,
/// genuinely multi-frame source. A deliberate sibling to `LocalImageView`,
/// not a modification of it — every existing call site (One Archive,
/// Editorial covers, Folder grids) keeps rendering through the unchanged
/// `LocalImageView`/`Image(uiImage:)` path, so this file's existence can't
/// regress a single static image anywhere. Wired into exactly one place
/// for this milestone: `ItemDetailView`.
///
/// "It should simply behave like the object it is" — no play/pause
/// control, no badge, no chrome. A static source shows a static frame,
/// a real animated source plays, on its own source-authored timing.
struct AnimatedLocalImageView: View {
    let filename: String?
    var fallbackImageData: () -> Data? = { nil }
    var contentMode: ContentMode = .fit
    /// Same non-destructive crop as `LocalImageView` — the identical
    /// `CropRegion.renderTransform` math, applied per-frame so the crop
    /// window never drifts across the animation. See `croppedImage(_:)`.
    var cropRegion: CropRegion = .fullImage

    /// Reduce Motion: shows the first frame only, never starts the frame
    /// clock. Matches the system's own stated intent for this setting
    /// (suppress non-essential motion) rather than polling
    /// `UIAccessibility.isReduceMotionEnabled` — this stays correct
    /// automatically if the user toggles it while Item Detail is open.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var staticImage: UIImage?
    @State private var animatedSource: AnimatedImageDecoding.AnimatedSource?
    @State private var loadedFilename: String?
    @State private var didFail = false
    /// Reset per load so a freshly opened item always starts its loop at
    /// frame 0, rather than inheriting elapsed time from whatever was
    /// previously on screen.
    @State private var startDate = Date()

    var body: some View {
        Group {
            if let animatedSource, !reduceMotion {
                TimelineView(.animation) { context in
                    let frame = AnimatedImageDecoding.currentFrame(in: animatedSource, elapsed: context.date.timeIntervalSince(startDate))
                    rendered(frame.image)
                }
            } else if let staticImage {
                // Covers three cases identically: a genuinely static
                // source, an animated source while Reduce Motion is on
                // (first decoded frame, per the source's own real pixels
                // — never a separately-generated "poster frame"), and the
                // instant-first-frame preview while a large animated
                // source is still being fully decoded.
                rendered(staticImage)
            } else {
                placeholder
            }
        }
        .task(id: filename) { await load() }
    }

    @ViewBuilder
    private func rendered(_ image: UIImage) -> some View {
        if cropRegion.isFullImage {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else {
            croppedImage(image)
        }
    }

    /// Identical math/structure to `LocalImageView.croppedImage(_:)` — see
    /// its doc comment. Duplicated rather than shared because the two
    /// views' `image` sources differ in type/lifecycle; the transform
    /// itself (`CropRegion.renderTransform`) is the single shared source
    /// of truth both call into.
    private func croppedImage(_ image: UIImage) -> some View {
        GeometryReader { geometry in
            let transform = cropRegion.renderTransform(imageSize: image.size, containerSize: geometry.size)
            let scaledSize = CGSize(width: image.size.width * transform.scale, height: image.size.height * transform.scale)
            let imageCenter = CGPoint(x: transform.offset.width + scaledSize.width / 2, y: transform.offset.height + scaledSize.height / 2)
            Image(uiImage: image)
                .resizable()
                .frame(width: scaledSize.width, height: scaledSize.height)
                .position(x: imageCenter.x, y: imageCenter.y)
        }
        .clipped()
    }

    private var placeholder: some View {
        ZStack {
            ArkyvColor.surface
            if didFail || filename == nil {
                Image(systemName: "photo")
                    .font(.system(size: 28))
                    .foregroundStyle(ArkyvColor.subdued)
            } else {
                ProgressView().tint(ArkyvColor.subdued)
            }
        }
    }

    private func load() async {
        guard let filename else { return }
        guard filename != loadedFilename else { return }
        didFail = false
        animatedSource = nil
        staticImage = nil

        // Same MediaStore-first, imageData-fallback shape as
        // `LocalImageView.load()` — see its own doc comment for why the
        // fallback must read `item.imageData` back on the main actor
        // before crossing into a detached task.
        var data = await Task.detached(priority: .userInitiated) {
            MediaStore.shared.data(for: filename)
        }.value
        if data == nil {
            let restored = fallbackImageData()
            guard let restored else {
                if filename == self.filename { didFail = true }
                return
            }
            data = await MediaStore.shared.data(for: filename, reconstructingFrom: { restored })
        }
        guard let data else {
            if filename == self.filename { didFail = true }
            return
        }

        // Cheap, byte-truth check BEFORE any real decoding — a `.gif`
        // filename with exactly one frame is not animated (this
        // milestone's own §14 finding).
        let count = await Task.detached(priority: .userInitiated) {
            AnimatedImageDecoding.frameCount(ofData: data)
        }.value

        guard count > 1 else {
            let ui = await Task.detached(priority: .userInitiated) {
                ImageDecoding.decode(data, maxPixelSize: nil)
            }.value
            guard filename == self.filename else { return }
            if let ui {
                staticImage = ui
                loadedFilename = filename
            } else {
                didFail = true
            }
            return
        }

        let decoded = await Task.detached(priority: .userInitiated) {
            AnimatedImageDecoding.decodeAnimated(data, maxPixelSize: AnimatedImageDecoding.itemDetailFrameTarget)
        }.value
        guard filename == self.filename else { return }

        if let decoded, let first = decoded.frames.first {
            // First frame renders instantly via `staticImage` while
            // `animatedSource` (already fully decoded at this point —
            // see §7/§15) takes over on the very next body evaluation;
            // no separate "waiting to animate" state needed.
            staticImage = first.image
            animatedSource = decoded
            startDate = Date()
            loadedFilename = filename
        } else {
            // Genuinely multi-frame but over the memory budget, or a
            // frame failed to decode: never crash, never show nothing —
            // fall back to the same single-frame static path a purely
            // static image would take.
            let ui = await Task.detached(priority: .userInitiated) {
                ImageDecoding.decode(data, maxPixelSize: nil)
            }.value
            if let ui {
                staticImage = ui
                loadedFilename = filename
            } else {
                didFail = true
            }
        }
    }
}
