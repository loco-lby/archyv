import Foundation
import UIKit
import Darwin
import ArkyvKit

#if DEBUG
/// Scale Foundation 01: a scripted, on-device stress test of
/// `ImageDecodeCache`/`ImageDecoding` at a much larger scale than a human
/// can practically scroll through by hand — the same methodology used to
/// physically verify the cache in Performance Foundation 01 (decode a
/// long run of distinct images, then revisit an earlier stretch and count
/// hits vs. re-decodes), just scripted and much longer.
///
/// Entirely inert unless explicitly launched with the
/// `--arkyv-bench-image-cache` argument (see `ArkyvApp.init()`) — never
/// runs during ordinary development or use, DEBUG-only, and touches
/// nothing but `ImageDecodeCache.shared` with synthetic, in-memory-only
/// JPEG data. No real user photos, no SwiftData, no disk writes beyond
/// what `ImageDecodeCache` itself already does in memory.
enum ImageCacheStressTest {
    /// Deliberately NOT `@MainActor` — runs via `Task.detached` off the
    /// main thread, the same way `LocalImageView.load()`'s own decode
    /// work does. `ImageDecodeCache`/`ImageDecoding` have no main-thread
    /// requirement; `UIGraphicsImageRenderer`/`UIImage.jpegData` are safe
    /// to use off-main as long as a given renderer instance isn't shared
    /// concurrently, which this loop never does.
    ///
    /// `async`, using `Task.sleep` rather than `Thread.sleep`, for a real
    /// reason found while building this: `Thread.sleep` inside a `Task`
    /// blocks one of Swift concurrency's small, shared cooperative-pool
    /// threads rather than truly suspending — combined with `.utility`
    /// priority and other concurrent work (SwiftUI, `ScreenshotDetector`),
    /// an earlier version of this test using `Thread.sleep` stalled
    /// indefinitely partway through a run. `Task.sleep` suspends properly
    /// and doesn't have this problem.
    static func run() async {
        let itemCount = 3000
        let revisitCount = 400 // simulates scrolling back to the top after a long forward scroll
        // Mirrors LocalImageView's own maxPixelSize(for:originalPixelSize:)
        // math for a 1170x2532 portrait source at the real masonry
        // short-edge target.
        let maxPixelSize = LocalImageView.masonryThumbnailShortEdge * (2532.0 / 1170.0)

        // Filenames only kept for the revisit pass — cheap, unlike raw
        // image bytes. Each JPEG is generated, decoded, cached, and
        // discarded one at a time in the loop below (never held as an
        // array of N raw Data buffers at once — that's a self-inflicted
        // memory bomb in the *test*, unrelated to what LocalImageView
        // actually does: read one file, decode it, move on).
        let filenames = (0..<itemCount).map { "stress-\($0).jpg" }

        print("[ImageCacheStressTest] forward pass: generating + decoding + caching \(itemCount) distinct synthetic 1170x2532 JPEGs one at a time (simulated scroll-down)…")
        let forwardStart = Date()
        let progressStride = 250
        for (i, filename) in filenames.enumerated() {
            autoreleasepool {
                let data = syntheticScreenshotJPEG(index: i)
                let key = ImageDecodeCache.key(filename: filename, maxPixelSize: maxPixelSize)
                if let ui = ImageDecoding.decode(data, maxPixelSize: maxPixelSize) {
                    ImageDecodeCache.shared.store(ui, forKey: key)
                }
            }
            if (i + 1) % progressStride == 0 {
                print("[ImageCacheStressTest]   ...\(i + 1)/\(itemCount) decoded, resident memory ~\(String(format: "%.1f", residentMemoryMB())) MB")
                // A brief, deliberate pause every batch — real scrolling is
                // never a zero-delay tight loop, and this gives the OS a
                // chance to act on any memory-pressure signal between
                // batches, the same way it would between a human's actual
                // scroll gestures. Still far more aggressive than any real
                // scroll: 3000 items in ~12 short pauses.
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        let forwardMS = Date().timeIntervalSince(forwardStart) * 1000
        print("[ImageCacheStressTest] forward pass: \(itemCount) decodes in \(String(format: "%.1f", forwardMS))ms (\(String(format: "%.2f", forwardMS / Double(itemCount)))ms/decode avg)")

        print("[ImageCacheStressTest] revisit pass: checking cache for the OLDEST \(revisitCount) decodes (simulated scroll back to the top)…")
        var hits = 0
        var misses = 0
        let revisitStart = Date()
        for filename in filenames.prefix(revisitCount) {
            let key = ImageDecodeCache.key(filename: filename, maxPixelSize: maxPixelSize)
            if ImageDecodeCache.shared.image(forKey: key) != nil {
                hits += 1
            } else {
                misses += 1
            }
        }
        let revisitMS = Date().timeIntervalSince(revisitStart) * 1000
        print("[ImageCacheStressTest] revisit pass: \(hits) hits, \(misses) misses out of \(revisitCount) (\(String(format: "%.1f", revisitMS))ms)")
        print("[ImageCacheStressTest] interpretation: hits show how many of the OLDEST \(revisitCount) decodes were still resident after \(itemCount) total unique decodes — i.e. how deep a 320MB cache stays warm before eviction catches up with a long forward scroll.")
        print("[ImageCacheStressTest] final resident memory ~\(String(format: "%.1f", residentMemoryMB())) MB")
        print("[ImageCacheStressTest] done. Exiting.")
        exit(0)
    }

    /// A small, deterministic, solid-color-gradient JPEG at real screenshot
    /// dimensions — distinct bytes per index (so nothing coalesces at the
    /// file level), but cheap and fast to generate compared to loading
    /// real photos.
    private static func syntheticScreenshotJPEG(index: Int) -> Data {
        let size = CGSize(width: 1170, height: 2532)
        let renderer = UIGraphicsImageRenderer(size: size)
        let hue = CGFloat(index % 360) / 360
        let color = UIColor(hue: hue, saturation: 0.6, brightness: 0.8, alpha: 1)
        let image = renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }

    /// Best-effort resident-memory reading (same Darwin `task_info` call
    /// `ArkyvBench` uses on macOS) — diagnostic only, not exact.
    private static func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.resident_size) / 1024 / 1024
    }
}
#endif
