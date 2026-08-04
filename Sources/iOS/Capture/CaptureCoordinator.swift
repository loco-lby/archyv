import SwiftUI
import SwiftData
import Observation
import ArkyvKit
#if canImport(Photos)
import Photos
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Drives the capture drawer. Two entry points, one destination:
///   • `.screenshot` — auto-fires when a screenshot is taken (in-app) or comes
///     from the Share Extension / Action Button. A media draft already exists;
///     the drawer just files it.
///   • `.add` — the in-app "+" button. Nothing is captured yet, so the drawer
///     lets the user pick existing photos from their library and/or write a
///     note, then choose a folder.
@MainActor
@Observable
final class CaptureCoordinator {
    /// Which drawer (if any) is presented.
    enum Drawer: Identifiable {
        case screenshot(CaptureDraft)
        case add

        var id: String {
            switch self {
            case .screenshot(let draft): return "shot-\(draft.id.uuidString)"
            case .add: return "add"
            }
        }

        var isAdd: Bool { if case .add = self { return true }; return false }
    }

    var drawer: Drawer?
    /// Transient confirmation toast ("Saved to Deadwest").
    var savedToast: SavedToast?
    /// Folder suggested at the top of the drawer.
    var suggestion: StoredFolder?

    private let container: ModelContainer
    private let detector: ScreenshotDetector

    init(container: ModelContainer) {
        self.container = container
        self.detector = ScreenshotDetector()
        detector.onScreenshot = { [weak self] draft in
            Task { @MainActor in self?.present(draft) }
        }
    }

    private var repo: Repository { Repository(context: container.mainContext) }

    func startDetecting() { detector.start() }
    func stopDetecting() { detector.stop() }
    /// Catch screenshots taken while the app was backgrounded.
    func checkForScreenshots() { detector.checkForNewScreenshots() }

    /// Present the screenshot drawer for an already-captured draft. The
    /// `.screenshot` case always routes to `ScreenshotCaptureFlowView` (see
    /// `CaptureSheetView`'s dispatcher) — never the old grid-based sheet, and
    /// never the manual "+" / Photos-picker path.
    func present(_ draft: CaptureDraft) {
        suggestion = try? repo.suggestedFolder(for: draft)
        drawer = .screenshot(draft)
        #if DEBUG
        print("[CaptureCoordinator] presenting .screenshot drawer for draft \(draft.id) (suggestion: \(suggestion?.name ?? "none")) -> ScreenshotCaptureFlowView")
        #endif
    }

    /// Present the in-app "Add to arkyv" drawer (photo picker + note).
    func startAdd() {
        suggestion = try? repo.suggestedFolder(for: CaptureDraft(kind: .note))
        drawer = .add
    }

    /// One-tap save from the drawer.
    func file(_ draft: CaptureDraft, into folder: StoredFolder) {
        do {
            try repo.fileCapture(draft, into: folder)
            savedToast = SavedToast(folderName: folder.name, icon: folder.icon)
        } catch {
            savedToast = SavedToast(folderName: "Error saving", icon: .symbol("exclamationmark.triangle"))
        }
        drawer = nil
    }

    func createFolderAndFile(_ draft: CaptureDraft, name: String, icon: FolderIcon) {
        guard let folder = try? repo.createFolder(name: name, icon: icon) else { return }
        file(draft, into: folder)
    }

    /// Recompute the suggested folder as the user stages content in add-mode.
    func refreshSuggestion(for draft: CaptureDraft) {
        suggestion = try? repo.suggestedFolder(for: draft)
    }

    func dismiss() {
        #if DEBUG
        print("[CaptureCoordinator] dismiss() called — drawer was \(drawer.map { "\($0.id)" } ?? "nil")")
        #endif
        drawer = nil
        #if DEBUG
        print("[CaptureCoordinator] drawer is now nil")
        #endif
    }

    #if DEBUG
    /// DEBUG helper: the Simulator can't create real screenshot assets, so this
    /// runs the newest library photo through the exact screenshot draft path to
    /// demo the detection → drawer → file loop. Not compiled in release builds.
    func simulateScreenshotFromLibrary() {
        #if canImport(Photos)
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            guard let self, status == .authorized || status == .limited else { return }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = 1
            guard let asset = PHAsset.fetchAssets(with: .image, options: options).firstObject else { return }
            let req = PHImageRequestOptions()
            req.isNetworkAccessAllowed = true
            req.deliveryMode = .highQualityFormat
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: req) { data, _, _, _ in
                guard let data, let image = UIImage(data: data),
                      let saved = try? MediaStore.shared.save(image: image) else { return }
                let draft = CaptureDraft(
                    kind: .screenshot,
                    localFilename: saved.filename,
                    pixelSize: CGSize(width: CGFloat(asset.pixelWidth), height: CGFloat(asset.pixelHeight)),
                    sourceDevice: .iOS
                )
                Task { @MainActor in self.present(draft) }
            }
        }
        #endif
    }
    #endif
}

struct SavedToast: Identifiable, Equatable {
    let id = UUID()
    let folderName: String
    let icon: FolderIcon
}
