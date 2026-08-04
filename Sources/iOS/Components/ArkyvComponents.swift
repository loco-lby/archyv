import SwiftUI
import ArkyvKit

// FolderIconView / ArkyvMarkView / ArkyvWordmarkView live in ArkyvKit
// (Design/BrandViews.swift) so the Share Extension and macOS app share them.

/// Loads a capture image from the local MediaStore by filename, off the main
/// thread, with a graceful placeholder while missing/loading.
struct LocalImageView: View {
    let filename: String?
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    /// The filename `image` actually reflects — lets a stale in-flight load
    /// (from a filename that's since changed again) recognize itself as
    /// stale and discard its result instead of clobbering a newer one.
    @State private var loadedFilename: String?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
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

    private var placeholder: some View {
        ZStack {
            ArkyvColor.card
            if didFail || filename == nil {
                Image(systemName: "photo")
                    .font(.system(size: 28))
                    .foregroundStyle(ArkyvColor.textDim)
            } else {
                ProgressView().tint(ArkyvColor.textDim)
            }
        }
    }

    private func load() async {
        guard let filename else { return }
        guard filename != loadedFilename else { return }
        didFail = false
        let data = await Task.detached(priority: .userInitiated) {
            MediaStore.shared.data(for: filename)
        }.value
        // The `filename` this view wants may have changed again while this
        // load was in flight — discard a stale result rather than showing
        // (or briefly flashing) an image that's no longer the right one.
        guard filename == self.filename else { return }
        if let data, let ui = UIImage(data: data) {
            image = ui
            loadedFilename = filename
        } else {
            didFail = true
        }
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
            .arkyvOutlinedSurface(fill: ArkyvColor.surface, stroke: ArkyvColor.border, radius: ArkyvRadius.pill)
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
