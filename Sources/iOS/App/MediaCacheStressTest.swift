import Foundation
import UIKit
import Darwin
import SwiftData
import ArkyvKit

#if DEBUG
/// Media Cache Foundation 01: a scripted, on-device measurement of the
/// specific NEW cost Option 2 (Media Storage Architecture 01) would
/// introduce — reading `StoredItem.imageData` (a SwiftData
/// `.externalStorage` attribute) and materializing it into a real disk
/// cache file (`MediaCachePrototype`, from `ArkyvKit`) — compared against
/// a warm cache hit, at real-device I/O speeds rather than the isolated
/// macOS-CLI numbers `ArkyvBench` already produced.
///
/// Entirely inert unless launched with `--arkyv-bench-media-cache`.
/// Touches only an isolated, in-memory `ModelContainer` (never the real
/// on-disk/CloudKit store) and a scratch temp directory (never the real
/// `Media/` directory) — no real user data anywhere in this file.
enum MediaCacheStressTest {
    /// Realistic per-item sizes, matching Storage Foundation 01's own
    /// blended estimate — deliberately capped below the ~4-6MB high end
    /// ArkyvBench already covered on macOS; this tool's job is measuring
    /// real-device I/O/decode latency at representative sizes, not
    /// re-proving the size-scaling relationship a second time.
    private static let sizeSamplesKB = [150, 400, 800, 1_200]

    static func run() async {
        print("[MediaCacheStressTest] starting — isolated in-memory container + scratch cache dir, no real data touched")

        let container = ArkyvStore.makeModelContainer(inMemory: true)
        let itemCount = 46
        let ids = await populate(container: container, itemCount: itemCount)

        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("media-cache-stress-\(UUID().uuidString)")
        let cache = MediaCachePrototype(root: cacheRoot, capacityBytes: 500_000_000)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        // Mirrors LocalImageView's own masonry thumbnail target.
        let maxPixelSize = await LocalImageView.masonryThumbnailShortEdge

        // A. One Archive — first screen (~10 items), entirely cold.
        await measureBatch(
            label: "A1. One Archive: first ~10 items, COLD cache, thumbnail decode",
            ids: Array(ids.prefix(10)), container: container, cache: cache, maxPixelSize: maxPixelSize
        )
        try? await Task.sleep(for: .milliseconds(100))
        // Revisit the SAME 10 — now warm.
        await measureBatch(
            label: "A2. One Archive: SAME ~10 items, WARM cache, thumbnail decode",
            ids: Array(ids.prefix(10)), container: container, cache: cache, maxPixelSize: maxPixelSize
        )
        try? await Task.sleep(for: .milliseconds(100))
        // A wider scroll — 30 more items, entirely cold (fresh IDs never touched above).
        await measureBatch(
            label: "A3. One Archive: scroll 30 NEW items, COLD cache, thumbnail decode",
            ids: Array(ids[10..<40]), container: container, cache: cache, maxPixelSize: maxPixelSize
        )
        try? await Task.sleep(for: .milliseconds(100))

        // B. Item Detail — single full-resolution open, cold vs warm.
        // ids[40..<46] were never touched by A1-A3 above (which only ever
        // read ids[0..<40]) — genuinely cold, not just "not in this
        // particular batch."
        let freshDetailID = ids[40]
        await measureSingle(label: "B1. Item Detail: cold item, FULL-RESOLUTION decode (no downsampling)", id: freshDetailID, container: container, cache: cache, maxPixelSize: nil)
        await measureSingle(label: "B2. Item Detail: SAME item, WARM cache, FULL-RESOLUTION decode", id: freshDetailID, container: container, cache: cache, maxPixelSize: nil)

        // C. Crop Editor — byte-identity check between imageData and the
        // materialized cache file (fidelity, not just performance). A
        // separate, still-never-touched item.
        await verifyByteIdentity(id: ids[41], container: container, cache: cache)

        // D/E — Option 2 Validation Gate 01, Sections 2 and 3.
        await runReinstallSimulation()
        await runOfflineLocalAuthorityCheck()

        print("[MediaCacheStressTest] done. Exiting.")
        exit(0)
    }

    // MARK: - D. Reinstall / fresh-local-store simulation (Validation Gate 01 §2)

    /// A brand-new, separate isolated container + a cache root that has
    /// NEVER had anything written to it — the exact shape a reinstalled
    /// app or a new device has: SwiftData/CloudKit delivered the item's
    /// row and its `imageData`, but nothing has ever touched `MediaStore`
    /// on this "device." Confirms the full pipeline (fetch → cache miss →
    /// reconstruct → decode) succeeds from that state, and that the
    /// reconstructed file is byte-identical to `imageData` — i.e. no
    /// permanent MediaStore original from a "previous installation" is
    /// required for a correct render.
    private static func runReinstallSimulation() async {
        print("[MediaCacheStressTest] D. Reinstall simulation: fresh container + fresh cache root, zero prior MediaStore-equivalent state...")
        let container = ArkyvStore.makeModelContainer(inMemory: true)
        let ids = await populate(container: container, itemCount: 3)
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("media-cache-reinstall-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        // Confirm the "device" genuinely starts with nothing.
        let startedEmpty = !FileManager.default.fileExists(atPath: cacheRoot.path)
        let cache = MediaCachePrototype(root: cacheRoot, capacityBytes: 500_000_000)

        var allOK = true
        for id in ids {
            let outcome: (decoded: Bool, byteIdentical: Bool) = await Task.detached(priority: .userInitiated) {
                let context = ModelContext(container)
                let descriptor = FetchDescriptor<StoredItem>(predicate: #Predicate { $0.id == id })
                guard let item = try? context.fetch(descriptor).first, let imageData = item.imageData,
                      let filename = item.localFilename else { return (false, false) }
                guard let materialized = cache.data(for: filename, reconstructingFrom: imageData) else { return (false, false) }
                let decoded = ImageDecoding.decode(materialized, maxPixelSize: nil) != nil
                return (decoded, materialized == imageData)
            }.value
            allOK = allOK && outcome.decoded && outcome.byteIdentical
        }
        print("[MediaCacheStressTest] D. started with empty cache root: \(startedEmpty), all \(ids.count) items reconstructed+decoded+byte-identical: \(allOK ? "CONFIRMED" : "FAILED")")
    }

    // MARK: - E. Offline local-authority check (Validation Gate 01 §3)

    /// `ArkyvStore.makeModelContainer(inMemory: true)` sets
    /// `cloudKitDatabase: .none` explicitly (see ArkyvStore.swift) — this
    /// container has literally zero network/CloudKit code path available
    /// to it, which is the strongest "offline" guarantee achievable in an
    /// automated test (stronger than toggling airplane mode, which
    /// wouldn't stop an already-in-flight sync on a real device anyway).
    /// Proves `imageData` alone — with no cache file ever having existed
    /// — is sufficient to reconstruct the original, with no CloudKit
    /// upload/sync of any kind involved at any point.
    private static func runOfflineLocalAuthorityCheck() async {
        print("[MediaCacheStressTest] E. Offline local-authority check: zero-CloudKit container, delete-then-reconstruct...")
        let container = ArkyvStore.makeModelContainer(inMemory: true)
        let ids = await populate(container: container, itemCount: 1)
        let id = ids[0]
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("media-cache-offline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let cache = MediaCachePrototype(root: cacheRoot, capacityBytes: 500_000_000)

        let result: (firstReadOK: Bool, secondReadAfterDeleteOK: Bool, byteIdentical: Bool) = await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<StoredItem>(predicate: #Predicate { $0.id == id })
            guard let item = try? context.fetch(descriptor).first, let imageData = item.imageData, let filename = item.localFilename else {
                return (false, false, false)
            }
            // Step 1: imageData is readable and yields a working cache file.
            guard let first = cache.data(for: filename, reconstructingFrom: imageData) else { return (false, false, false) }
            // Step 2: delete ONLY the derived cache representation — never
            // touches imageData/the model at all.
            try? FileManager.default.removeItem(at: cache.url(for: filename))
            // Step 3: the original is still available, reconstructed
            // again from imageData alone — the whole point of "imageData
            // is genuinely sufficient as local durable authority, even
            // before/without any CloudKit involvement."
            guard let second = cache.data(for: filename, reconstructingFrom: imageData) else { return (true, false, false) }
            return (true, true, first == second && second == imageData)
        }.value
        print("[MediaCacheStressTest] E. imageData readable: \(result.firstReadOK), survives cache-file deletion + reconstructs: \(result.secondReadAfterDeleteOK), byte-identical throughout: \(result.byteIdentical)")
    }

    // MARK: - Setup

    /// Generating + JPEG-encoding 120 synthetic images is real, non-trivial
    /// CPU work — an earlier version of this function ran entirely on the
    /// main actor (required for `container.mainContext`) and tripped
    /// iOS's hang watchdog (SIGKILL), the exact same class of bug
    /// `ImageCacheStressTest` hit and fixed in Scale Foundation 01, just
    /// via a different code path (main-actor-isolated work *after*
    /// launch, not launch-time `init()` work). Fixed the same way that
    /// one was: keep the expensive part (image generation/encoding) off
    /// the main actor, and only hop to `@MainActor` for the cheap
    /// SwiftData insert+save loop.
    private static func populate(container: ModelContainer, itemCount: Int) async -> [UUID] {
        let payloads: [(index: Int, data: Data)] = await Task.detached(priority: .utility) {
            (0..<itemCount).map { i in
                let sizeBytes = sizeSamplesKB[i % sizeSamplesKB.count] * 1024
                return (i, syntheticJPEG(approximateByteCount: sizeBytes, seed: i))
            }
        }.value

        return await MainActor.run {
            var ids: [UUID] = []
            let context = container.mainContext
            for (i, data) in payloads {
                let item = StoredItem(kind: .screenshot, localFilename: "media-cache-stress-\(i).jpg", imageData: data,
                                       aspectWidth: 1170, aspectHeight: 2532)
                context.insert(item)
                ids.append(item.id)
            }
            try? context.save()
            return ids
        }
    }

    private static func syntheticJPEG(approximateByteCount: Int, seed: Int) -> Data {
        // A real, decodable JPEG (unlike ArkyvBench's raw-byte payloads —
        // this tool also exercises ImageDecoding, so the bytes must be
        // genuine image data). Size is approximate — compressed JPEG size
        // isn't exactly controllable, which is fine for this comparison.
        let side = CGFloat(max(200, Int((Double(approximateByteCount) * 0.6).squareRoot())))
        let size = CGSize(width: side, height: side * 2532 / 1170)
        let renderer = UIGraphicsImageRenderer(size: size)
        let hue = CGFloat(seed % 360) / 360
        let image = renderer.image { ctx in
            UIColor(hue: hue, saturation: 0.6, brightness: 0.8, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.85) ?? Data()
    }

    // MARK: - Measurement

    /// Mirrors the real cache-miss shape: fetch the item on a FRESH
    /// context (simulating nothing already resident in memory), ask the
    /// cache for its file (which reconstructs from `imageData` on a
    /// miss), then decode. Off the main actor, matching how
    /// `LocalImageView.load()` already does its own decode work.
    private static func measureBatch(label: String, ids: [UUID], container: ModelContainer, cache: MediaCachePrototype, maxPixelSize: CGFloat?) async {
        let start = Date()
        var decodedCount = 0
        for id in ids {
            if await loadAndDecode(id: id, container: container, cache: cache, maxPixelSize: maxPixelSize) != nil {
                decodedCount += 1
            }
        }
        let elapsedMS = Date().timeIntervalSince(start) * 1000
        let perItem = ids.isEmpty ? 0 : elapsedMS / Double(ids.count)
        print("[MediaCacheStressTest] \(label): \(decodedCount)/\(ids.count) decoded, \(String(format: "%.1f", elapsedMS))ms total (\(String(format: "%.2f", perItem))ms/item)")
    }

    private static func measureSingle(label: String, id: UUID, container: ModelContainer, cache: MediaCachePrototype, maxPixelSize: CGFloat?) async {
        let start = Date()
        let decoded = await loadAndDecode(id: id, container: container, cache: cache, maxPixelSize: maxPixelSize)
        let elapsedMS = Date().timeIntervalSince(start) * 1000
        print("[MediaCacheStressTest] \(label): \(decoded != nil ? "OK" : "FAILED") in \(String(format: "%.2f", elapsedMS))ms")
    }

    private static func loadAndDecode(id: UUID, container: ModelContainer, cache: MediaCachePrototype, maxPixelSize: CGFloat?) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<StoredItem>(predicate: #Predicate { $0.id == id })
            guard let item = try? context.fetch(descriptor).first, let imageData = item.imageData else { return nil }
            let filename = item.localFilename ?? "\(id).jpg"
            guard let bytes = cache.data(for: filename, reconstructingFrom: imageData) else { return nil }
            return ImageDecoding.decode(bytes, maxPixelSize: maxPixelSize)
        }.value
    }

    /// Section 7/Crop Editor fidelity: the materialized cache file must be
    /// byte-for-byte identical to the durable `imageData` source it came
    /// from — the same guarantee `MediaStore.data(for:restoringFrom:)`
    /// already provides today (Recovery/Portability Foundation 01),
    /// re-confirmed here for the prototype cache specifically.
    private static func verifyByteIdentity(id: UUID, container: ModelContainer, cache: MediaCachePrototype) async {
        let result: Bool = await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<StoredItem>(predicate: #Predicate { $0.id == id })
            guard let item = try? context.fetch(descriptor).first, let imageData = item.imageData,
                  let filename = item.localFilename else { return false }
            guard let materialized = cache.data(for: filename, reconstructingFrom: imageData) else { return false }
            return materialized == imageData
        }.value
        print("[MediaCacheStressTest] C. Crop Editor fidelity check: materialized cache file byte-identical to imageData — \(result ? "CONFIRMED" : "FAILED")")
    }
}
#endif
