import Foundation
import ArkyvKit
#if canImport(Photos)
import Photos
import UIKit

/// Offers to file a screenshot you took in **another app** the next time you
/// open arkyv. There is intentionally no live in-app observer: detecting a
/// screenshot while you're already inside arkyv has no benefit — you'd use the
/// "+" button. The Share Extension is the primary, instant capture path; this
/// is just a convenience catch-up for screenshots taken elsewhere.
///
/// A durable high-water mark (App Group `UserDefaults`) records the last handled
/// screenshot so we never re-file one or file the pre-install backlog.
final class ScreenshotDetector {
    /// Called on the main actor with a ready-to-file draft (image already
    /// written to MediaStore).
    var onScreenshot: ((CaptureDraft) -> Void)?

    private var authorized = false
    private var didRequest = false

    private let defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
    private let highWaterKey = "lastHandledScreenshotDate"

    private var lastHandled: Date? {
        get {
            let t = defaults.double(forKey: highWaterKey)
            return t > 0 ? Date(timeIntervalSinceReferenceDate: t) : nil
        }
        set { defaults.set(newValue?.timeIntervalSinceReferenceDate ?? 0, forKey: highWaterKey) }
    }

    /// Request Photos access once, then run a catch-up check.
    func start() {
        guard !didRequest else { checkForNewScreenshots(); return }
        didRequest = true
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            guard let self else { return }
            self.authorized = (status == .authorized || status == .limited)
            self.checkForNewScreenshots()
        }
    }

    func stop() {}

    /// Called when the app becomes active: if a newer screenshot exists than the
    /// last one we handled, surface it for filing.
    func checkForNewScreenshots() {
        guard authorized else { return }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "(mediaSubtypes & %d) != 0",
            PHAssetMediaSubtype.photoScreenshot.rawValue
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        guard let newest = PHAsset.fetchAssets(with: .image, options: options).firstObject,
              let created = newest.creationDate else { return }

        guard let mark = lastHandled else {
            // First run: baseline to newest existing screenshot; don't file the
            // pre-install backlog.
            lastHandled = created
            return
        }
        guard created > mark else { return }
        lastHandled = created
        loadDraft(from: newest)
    }

    private func loadDraft(from asset: PHAsset) {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false

        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { [weak self] data, _, _, _ in
            guard let self, let data, let image = UIImage(data: data),
                  let saved = try? MediaStore.shared.save(image: image) else { return }
            let draft = CaptureDraft(
                kind: .screenshot,
                localFilename: saved.filename,
                pixelSize: CGSize(width: CGFloat(asset.pixelWidth), height: CGFloat(asset.pixelHeight)),
                sourceDevice: .iOS
            )
            DispatchQueue.main.async { self.onScreenshot?(draft) }
        }
    }
}
#else
/// Non-iOS stub so the type exists cross-platform.
final class ScreenshotDetector {
    var onScreenshot: ((CaptureDraft) -> Void)?
    func start() {}
    func stop() {}
    func checkForNewScreenshots() {}
}
#endif
