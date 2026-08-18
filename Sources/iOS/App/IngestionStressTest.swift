import Foundation
import UIKit
import Darwin
import ArkyvKit

#if DEBUG
/// Share/Capture Reliability Foundation 01: a scripted, on-device,
/// one-shot comparison of the Share Extension's old decode-then-
/// re-encode ingestion path against the new header-read-plus-file-copy
/// fast path (see `ShareViewController.jpegFastPathDraft`), at large
/// synthetic image sizes. Entirely inert unless explicitly launched with
/// `--arkyv-bench-ingestion` (see `ArkyvApp.body`'s `.task`) — no real
/// user data, no SwiftData, no MediaStore writes retained (cleaned up
/// after each size).
enum IngestionStressTest {
    /// (label, width, height) — 12MP/24MP/48MP-class sizes, the range
    /// Phase 2 asked for. Deliberately just a handful of sizes run once
    /// each, not a long loop — the point is a clean before/after
    /// comparison, not a scroll-endurance test like
    /// `ImageCacheStressTest`.
    private static let sizes: [(String, Int, Int)] = [
        ("~12MP", 4032, 3024),
        ("~24MP", 6000, 4000),
        ("~48MP", 8000, 6000),
    ]

    static func run() async {
        print("[IngestionStressTest] starting — comparing decode+re-encode vs. header-read+file-copy")
        for (label, width, height) in sizes {
            await measure(label: label, width: width, height: height)
        }
        print("[IngestionStressTest] done.")
    }

    private static func measure(label: String, width: Int, height: Int) async {
        autoreleasepool {
            print("[IngestionStressTest] \(label) (\(width)x\(height)) — generating synthetic JPEG…")
        }
        guard let data = syntheticJPEG(width: width, height: height) else {
            print("[IngestionStressTest] \(label) — failed to generate source data, skipping")
            return
        }
        print("[IngestionStressTest] \(label) — source is \(data.count / 1024)KB encoded")

        // OLD PATH: full decode to a bitmap, then re-encode — what
        // `imageDraft(from:)`'s fallback (and every source before this
        // pass) does for every shared image regardless of size. Measured
        // *inside* the autoreleasepool, before it drains — measuring
        // after (an earlier version of this test did) captures the
        // settled residual, not the actual peak the decode reached.
        let beforeOld = residentMemoryMB()
        var peakOld = beforeOld
        autoreleasepool {
            if let image = UIImage(data: data) {
                peakOld = max(peakOld, residentMemoryMB())
                let reencoded = image.jpegData(compressionQuality: 0.9)
                peakOld = max(peakOld, residentMemoryMB())
                _ = reencoded
            }
        }
        let afterOldDrain = residentMemoryMB()

        // NEW PATH: header-only dimensions read, source bytes untouched
        // — no bitmap ever materializes. This is what
        // `jpegFastPathDraft` now does for already-JPEG sources.
        let beforeNew = residentMemoryMB()
        var peakNew = beforeNew
        autoreleasepool {
            _ = ImageDecoding.pixelSize(ofData: data)
            peakNew = max(peakNew, residentMemoryMB())
        }
        let afterNewDrain = residentMemoryMB()

        print("[IngestionStressTest] \(label) — OLD (decode+re-encode) peak Δ~\(String(format: "%.1f", peakOld - beforeOld))MB " +
            "(settled Δ~\(String(format: "%.1f", afterOldDrain - beforeOld))MB after drain), " +
            "NEW (header-only) peak Δ~\(String(format: "%.1f", peakNew - beforeNew))MB " +
            "(settled Δ~\(String(format: "%.1f", afterNewDrain - beforeNew))MB after drain)")
    }

    private static func syntheticJPEG(width: Int, height: Int) -> Data? {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.9)
    }

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
