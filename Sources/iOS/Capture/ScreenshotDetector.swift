import Foundation
import ArkyvKit
#if canImport(Photos)
import Photos
import UIKit

/// Offers to file a screenshot the next time you open arkyv — whether it's a
/// real OS screenshot taken in another app, or one relayed through the
/// Action Button's Shortcuts bridge (Take Screenshot → Save to Photo Album →
/// Open Arkyv). There's intentionally no live in-app observer; detecting
/// while already inside arkyv has no benefit, you'd use "+".
///
/// IMPORTANT: screenshots created by the Shortcuts "Take Screenshot" → "Save
/// to Photo Album" pipeline are NOT reliably tagged `.photoScreenshot` the
/// way a hardware-button screenshot is — Shortcuts writes the asset as a
/// generic photo import. So acceptance can't *require* that subtype; it's
/// one of two independent paths, not a hard filter (see `findCandidate`).
///
/// A durable high-water mark (App Group `UserDefaults`) records the last
/// *successfully filed* screenshot's creation date, so we never re-file one
/// or surface the pre-install backlog — but critically, it only advances
/// after the asset has actually loaded into a `CaptureDraft`, so a failed
/// intermediate step (image load, MediaStore write) leaves the asset
/// retryable rather than silently skipping it forever.
final class ScreenshotDetector {
    /// Called on the main actor with a ready-to-file draft (image already
    /// written to MediaStore).
    var onScreenshot: ((CaptureDraft) -> Void)?

    private var authorized = false
    private var didRequest = false
    private var hasRunOnce = false
    /// Reentrancy guard — RootView can trigger `startDetecting()` and
    /// `checkForScreenshots()` back to back on the same activation; this
    /// keeps two overlapping Photos fetch/retry sequences from ever running
    /// at once.
    private var isChecking = false

    private let defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
    private let highWaterKey = "lastHandledScreenshotDate"

    /// How recent a candidate's creationDate must be, relative to *now* at
    /// evaluation time, to count as "probably from this launch" for the
    /// shortcut-bridge path. Starting narrow (~5s) per physical-device
    /// testing; tune this one constant if it proves too tight or too loose.
    private let launchWindow: TimeInterval = 5
    /// Bounded, non-blocking retry for Photos indexing lag. Checks
    /// immediately, then retries on this interval until `maxRetryWindow`
    /// elapses — never polls indefinitely.
    private let retryInterval: TimeInterval = 0.4
    private let maxRetryWindow: TimeInterval = 2.0

    private var lastHandled: Date? {
        get {
            let t = defaults.double(forKey: highWaterKey)
            return t > 0 ? Date(timeIntervalSinceReferenceDate: t) : nil
        }
        set { defaults.set(newValue?.timeIntervalSinceReferenceDate ?? 0, forKey: highWaterKey) }
    }

    /// Request Photos access once, then run a catch-up check.
    func start() {
        log("start() — didRequest=\(didRequest)")
        guard !didRequest else { checkForNewScreenshots(); return }
        didRequest = true
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            guard let self else { return }
            DispatchQueue.main.async {
                self.authorized = (status == .authorized || status == .limited)
                self.logAuthorization(status)
                self.checkForNewScreenshots()
            }
        }
    }

    func stop() {}

    /// Called on launch (cold or warm) and every foreground reactivation.
    func checkForNewScreenshots() {
        let kind = hasRunOnce ? "foreground reactivation" : "cold launch / first activation"
        hasRunOnce = true
        log("checkForNewScreenshots() — \(kind), authorized=\(authorized)")

        guard !isChecking else {
            log("reentrancy guard — a check is already in progress, skipping")
            return
        }
        guard authorized else {
            log("not authorized — skipping. (This is a permissions gap, not \"no new screenshot\" — see authorization log above.)")
            return
        }
        isChecking = true
        attempt(retryIndex: 0, deadline: Date().addingTimeInterval(maxRetryWindow))
    }

    // MARK: - Bounded retry

    private func attempt(retryIndex: Int, deadline: Date) {
        log("retry attempt #\(retryIndex)")
        guard let candidate = findCandidate() else {
            guard Date() < deadline else {
                log("no qualifying candidate within the retry window — giving up for this activation")
                isChecking = false
                return
            }
            log("no qualifying candidate yet — retrying in \(retryInterval)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) { [weak self] in
                self?.attempt(retryIndex: retryIndex + 1, deadline: deadline)
            }
            return
        }

        loadDraft(from: candidate) { [weak self] success in
            guard let self else { return }
            if success {
                // Stop retrying immediately — a valid CaptureDraft is staged.
                self.isChecking = false
                return
            }
            // Intermediate failure (image load / MediaStore write). The mark
            // was NOT advanced, so this asset stays a valid candidate — keep
            // retrying inside the same bounded window rather than losing it.
            guard Date() < deadline else {
                self.log("candidate failed to load and the retry window is over — giving up for this activation (asset remains retryable next activation, mark untouched)")
                self.isChecking = false
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.retryInterval) { [weak self] in
                self?.attempt(retryIndex: retryIndex + 1, deadline: deadline)
            }
        }
    }

    // MARK: - Candidate lookup

    /// Fetches the newest handful of image assets — unfiltered at the
    /// PHFetchOptions level — and evaluates each in code against two
    /// independent acceptance paths. Returns the first (newest) that
    /// qualifies.
    private func findCandidate() -> PHAsset? {
        let priorMark = lastHandled
        log("high-water mark before this check: \(priorMark.map { "\($0)" } ?? "none (first run)")")

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 5
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var candidates: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in candidates.append(asset) }

        guard !candidates.isEmpty else {
            log("no image assets in the library")
            return nil
        }

        if priorMark == nil, let newestCreated = candidates.first?.creationDate {
            // First run ever: baseline without filing, so the untimed
            // native-screenshot path never surfaces the pre-install backlog.
            // The shortcut-bridge path below is unaffected by this baseline
            // (it always checks against `priorMark`, captured above) — a
            // backlog photo can never satisfy the recency window anyway.
            lastHandled = newestCreated
            log("first run — baselined high-water mark to \(newestCreated) without filing it")
        }

        for asset in candidates {
            guard let created = asset.creationDate else {
                log("candidate \(asset.localIdentifier) has no creationDate — skipping")
                continue
            }
            let isScreenshotSubtype = asset.mediaSubtypes.contains(.photoScreenshot)
            let isRecent = abs(Date().timeIntervalSince(created)) < launchWindow
            let matchesScreen = matchesScreenDimensions(asset)
            let newerThanMark = priorMark.map { created > $0 } ?? true

            let passesNativeScreenshotPath = isScreenshotSubtype && newerThanMark
            let passesShortcutBridgePath = isRecent && matchesScreen && newerThanMark
            let accepted = passesNativeScreenshotPath || passesShortcutBridgePath
            let reason = passesNativeScreenshotPath ? "native screenshot" : (passesShortcutBridgePath ? "shortcut-bridge heuristic" : "rejected")

            log(describe(asset, isScreenshotSubtype: isScreenshotSubtype, isRecent: isRecent, matchesScreen: matchesScreen, newerThanMark: newerThanMark, verdict: reason))

            if accepted { return asset }
        }
        log("no candidate passed acceptance")
        return nil
    }

    /// Pixel dimensions matching the device's own screen, in either
    /// orientation — the strongest available signal that an untagged asset
    /// is a just-taken screenshot rather than an arbitrary recent photo.
    private func matchesScreenDimensions(_ asset: PHAsset) -> Bool {
        let scale = UIScreen.main.scale
        let w = Int((UIScreen.main.bounds.width * scale).rounded())
        let h = Int((UIScreen.main.bounds.height * scale).rounded())
        let asset2 = (asset.pixelWidth, asset.pixelHeight)
        return asset2 == (w, h) || asset2 == (h, w)
    }

    // MARK: - Draft loading

    /// Loads the asset's image data, stages it in MediaStore, and hands back
    /// a `CaptureDraft` via `onScreenshot`. Only advances the high-water mark
    /// on success — a failure at any step leaves the asset retryable.
    private func loadDraft(from asset: PHAsset, completion: @escaping (Bool) -> Void) {
        log("loading image data for \(asset.localIdentifier)")
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false

        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { [weak self] data, _, _, _ in
            guard let self else { DispatchQueue.main.async { completion(false) }; return }
            DispatchQueue.main.async {
                guard let data else {
                    self.log("image data load FAILED for \(asset.localIdentifier)")
                    completion(false)
                    return
                }
                guard let image = UIImage(data: data) else {
                    self.log("UIImage decode FAILED for \(asset.localIdentifier) (\(data.count) bytes)")
                    completion(false)
                    return
                }
                self.log("image data loaded OK (\(data.count) bytes)")
                guard let saved = try? MediaStore.shared.save(image: image) else {
                    self.log("MediaStore.save FAILED for \(asset.localIdentifier)")
                    completion(false)
                    return
                }
                self.log("MediaStore staged as \(saved.filename)")

                let draft = CaptureDraft(
                    kind: .screenshot,
                    localFilename: saved.filename,
                    pixelSize: CGSize(width: CGFloat(asset.pixelWidth), height: CGFloat(asset.pixelHeight)),
                    sourceDevice: .iOS
                )
                self.log("CaptureDraft created: \(draft.id)")

                if let created = asset.creationDate {
                    self.lastHandled = created
                    self.log("high-water mark advanced to \(created)")
                }

                self.onScreenshot?(draft)
                completion(true)
            }
        }
    }

    // MARK: - DEBUG logging

    private func logAuthorization(_ status: PHAuthorizationStatus) {
        let description: String
        switch status {
        case .authorized: description = "authorized (full library access)"
        case .limited: description = "limited — only user-selected photos are visible; the shortcut-created screenshot may not be included unless it's in the selected set"
        case .denied: description = "denied"
        case .restricted: description = "restricted"
        case .notDetermined: description = "notDetermined"
        @unknown default: description = "unknown(\(status.rawValue))"
        }
        log("Photos authorization: \(description)")
        if status == .denied || status == .restricted {
            log("Photos access is \(description) — the relay CANNOT work until this changes. This is a permissions gap, not \"checked and found no new screenshot.\"")
        }
    }

    private func describe(
        _ asset: PHAsset,
        isScreenshotSubtype: Bool,
        isRecent: Bool,
        matchesScreen: Bool,
        newerThanMark: Bool,
        verdict: String
    ) -> String {
        let filename = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "?"
        let created = asset.creationDate.map { "\($0)" } ?? "nil"
        return "candidate id:\(asset.localIdentifier) created:\(created) mediaType:\(asset.mediaType.rawValue) subtypes:\(asset.mediaSubtypes.rawValue) size:\(asset.pixelWidth)x\(asset.pixelHeight) file:\(filename) — screenshotSubtype:\(isScreenshotSubtype) recent(<\(Int(launchWindow))s):\(isRecent) matchesScreen:\(matchesScreen) newerThanMark:\(newerThanMark) -> \(verdict.uppercased())"
    }

    private func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[ScreenshotDetector] \(message())")
        #endif
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
