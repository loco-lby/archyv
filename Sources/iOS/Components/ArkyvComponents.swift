import SwiftUI
import ArkyvKit

// FolderIconView / ArkyvMarkView / ArkyvWordmarkView live in ArkyvKit
// (Design/BrandViews.swift) so the Share Extension and macOS app share them.

/// Loads a capture image from the local MediaStore by filename, off the main
/// thread, with a graceful placeholder while missing/loading.
struct LocalImageView: View {
    let filename: String?
    /// D4: CloudKit-restore fallback source, called only when the normal
    /// MediaStore file is missing (a fresh-device restore, where
    /// `imageData` synced via CloudKit but the local file was never
    /// written on this device). A closure, not a plain `Data?` — reading
    /// `item.imageData` eagerly on every view evaluation would fault in
    /// the (often multi-hundred-KB-to-multi-MB) externalStorage blob on
    /// the main thread for every grid cell, every time, even though
    /// MediaStore already has the file in the overwhelming common case.
    /// Defaults to `{ nil }` so every existing call site (staged/draft
    /// captures, which have no backing `StoredItem` at all) needs no
    /// change.
    var fallbackImageData: () -> Data? = { nil }
    var contentMode: ContentMode = .fill
    /// Non-destructive crop — see `CropRegion`. Defaults to `.fullImage`,
    /// which takes a completely different, *unchanged* rendering path
    /// (the plain `.aspectRatio(contentMode:)` below) — not the new
    /// crop-fill path applied for any other value. This isn't an
    /// optimization: it's what guarantees every existing call site, and
    /// every item that's never had a real crop applied, renders exactly
    /// as it always has, byte-for-byte the same code path as before this
    /// property existed.
    var cropRegion: CropRegion = .fullImage

    @State private var image: UIImage?
    /// The filename `image` actually reflects — lets a stale in-flight load
    /// (from a filename that's since changed again) recognize itself as
    /// stale and discard its result instead of clobbering a newer one.
    @State private var loadedFilename: String?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                if cropRegion.isFullImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else {
                    croppedImage(image)
                }
            } else {
                placeholder
            }
        }
        // Cross-fade rather than a hard cut: when a folder's cover image
        // changes (e.g. a new capture just landed in it), the old image
        // stays on screen and gently dissolves into the new one instead of
        // the view visibly rebuilding — one less thing churning in the
        // folder card right as the user might be tapping it.
        .animation(.easeInOut(duration: 0.2), value: loadedFilename)
        .task(id: filename) { await load() }
    }

    /// Non-destructive crop rendering: the *full* image, scaled and
    /// offset via `CropRegion.renderTransform` so the crop exactly fills
    /// this view's container, then clipped. No pixels are touched —
    /// `image` here is always the untouched original. `GeometryReader`
    /// supplies the container size the transform is computed against;
    /// callers that want a specific crop aspect ratio should constrain
    /// this view's frame externally (e.g. via `.aspectRatio(item.aspectRatio,
    /// contentMode: .fit)`, the same pattern already used for the grid).
    private func croppedImage(_ image: UIImage) -> some View {
        GeometryReader { geometry in
            let transform = cropRegion.renderTransform(imageSize: image.size, containerSize: geometry.size)
            let scaledSize = CGSize(width: image.size.width * transform.scale, height: image.size.height * transform.scale)
            // `transform.offset` is the image's top-left origin placed directly
            // in container coordinates — NOT a `.offset()`-style shift from a
            // centered default. `.position()` is what actually honors that
            // contract; using `.offset()` here previously shifted the image
            // from the wrong baseline and rendered the wrong source region.
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

        // Phase 1: the normal, fast path — off the main thread, unchanged
        // from before D4. No StoredItem/SwiftData access here at all.
        let primary = await Task.detached(priority: .userInitiated) {
            MediaStore.shared.data(for: filename)
        }.value
        if handle(primary, for: filename) { return }

        // Phase 2: D4 fallback, only reached when MediaStore didn't have
        // the file. `fallbackImageData()` reads a SwiftData model
        // property (`item.imageData`), so it MUST run here — on the main
        // actor, where `.task` already runs — never inside the detached
        // Task above, which SwiftData model objects aren't safe to touch
        // from. Only the resulting plain `Data` (Sendable) crosses into
        // the next detached hop to write it to disk.
        guard let restored = fallbackImageData() else {
            if filename == self.filename { didFail = true }
            return
        }
        let materialized = await Task.detached(priority: .userInitiated) {
            MediaStore.shared.data(for: filename, restoringFrom: restored)
        }.value
        if !handle(materialized, for: filename), filename == self.filename {
            didFail = true
        }
    }

    /// Applies a load result if `filename` is still what this view wants.
    /// Returns `true` iff resolution is complete — either a usable image
    /// was applied, or the request is stale and should just be ignored.
    /// `false` means "no image yet, caller should try the next fallback
    /// (or give up)" — callers are responsible for setting `didFail` in
    /// that case, since a stale, still-`false` result must NOT set it.
    @discardableResult
    private func handle(_ data: Data?, for filename: String) -> Bool {
        guard filename == self.filename else { return true }
        guard let data, let ui = UIImage(data: data) else { return false }
        image = ui
        loadedFilename = filename
        return true
    }
}

/// The `#tag` pill from the reference-detail design.
struct TagPill: View {
    let text: String
    var body: some View {
        Text(text.hasPrefix("#") ? text : "#\(text)")
            .font(.arkyvCaption)
            .foregroundStyle(ArkyvColor.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .arkyvOutlinedSurface(fill: ArkyvColor.surface, stroke: ArkyvColor.divider, radius: ArkyvRadius.pill)
    }
}

/// The "Suggested: X" chip pinned above the folder grid in the capture sheet.
struct SuggestionChip: View {
    let folderName: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles")
                .font(.system(size: 9))
            Text("Suggested: \(folderName)")
                .font(.arkyvStatus)
        }
        .foregroundStyle(ArkyvColor.textPrimary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(ArkyvColor.surface, in: RoundedRectangle(cornerRadius: ArkyvRadius.pill))
    }
}
