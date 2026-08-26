import Foundation
import SwiftData
import ArkyvKit
#if canImport(Darwin)
import Darwin
#endif

/// Scale Foundation 01: a `swift run`-able synthetic-archive benchmark
/// harness. Not an XCTest target — see `Package.swift`'s comment on why.
///
/// Always uses `ArkyvStore.makeModelContainer(inMemory: true)` — an
/// isolated, throwaway in-memory store, never the real on-disk/CloudKit
/// container. Nothing here ever touches a real user's data, and no real
/// device/CloudKit container is involved: this process runs entirely on
/// the Mac, in memory, and exits.
///
/// Run: `cd Packages/ArkyvKit && swift run -c release ArkyvBench` (or
/// `-c debug` for a closer-to-Xcode-Debug-build comparison — both are
/// reported in the Scale Foundation 01 findings).

// MARK: - Timing

@MainActor
@discardableResult
func time<T>(_ label: String, _ block: () throws -> T) rethrows -> T {
    let start = DispatchTime.now()
    let result = try block()
    let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    let padded = label.count < 52 ? label + String(repeating: " ", count: 52 - label.count) : label
    print("  \(padded) \(String(format: "%9.3f ms", elapsedMS))")
    return result
}

// MARK: - Resident memory (best-effort; macOS/Darwin only)

func residentMemoryMB() -> Double {
    #if canImport(Darwin)
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return -1 }
    return Double(info.resident_size) / 1024 / 1024
    #else
    return -1
    #endif
}

// MARK: - Synthetic archive generation (deterministic, no randomness)

/// Realistic pixel-dimension mix: mostly portrait phone screenshots (the
/// dominant real-world case), some landscape, a near-square, and one
/// long/scrolling-capture outlier — the exact shape `LocalImageView`'s
/// masonry-thumbnail short-edge math (Performance Foundation 01) has to
/// handle correctly.
private let aspectSamples: [(Double, Double)] = [
    (1170, 2532), (1179, 2556), (1284, 2778),
    (2000, 1500), (1600, 900),
    (1200, 1200),
    (1080, 3200),
]
private let tagSamples = ["food", "travel", "design", "funny", "reference", "wishlist", "recipe", "quote"]
private let folderNames = ["Deadwest", "Cool Shit", "Recipes", "Japan 2026", "Inspiration", "Work Refs", "Wishlist", "Memes"]

@MainActor
func makeSyntheticArchive(itemCount: Int, context: ModelContext) -> (folders: [StoredFolder], bigFolderName: String) {
    var folders: [StoredFolder] = []
    for (index, name) in folderNames.enumerated() {
        let folder = StoredFolder(name: name, icon: .glyph(.star), sortOrder: index)
        context.insert(folder)
        folders.append(folder)
    }
    // One already-soft-deleted folder — exercises IntegrityCheck's
    // soft-deleted-folder handling without needing a live item to
    // point at it.
    let deadFolder = StoredFolder(name: "Old Folder", icon: .glyph(.circle), sortOrder: folders.count)
    deadFolder.deletedAt = .now
    context.insert(deadFolder)

    for i in 0..<itemCount {
        let aspect = aspectSamples[i % aspectSamples.count]
        let hasCrop = i % 4 == 0
        let isFavorite = i % 11 == 0
        let hasNote = i % 6 == 0
        let hasSourceURL = i % 5 == 0
        let tagCount = i % 4
        let tags = (0..<tagCount).map { tagSamples[(i + $0) % tagSamples.count] }
        let isSoftDeleted = i % 47 == 0

        let item = StoredItem(
            kind: .screenshot,
            localFilename: "synthetic-\(i).jpg", // never actually written — queries only, no image I/O
            noteBody: hasNote ? "Synthetic note body for item \(i)." : nil,
            sourceURL: hasSourceURL ? "https://example.com/item/\(i)" : nil,
            tags: tags,
            isFavorite: isFavorite,
            aspectWidth: aspect.0,
            aspectHeight: aspect.1,
            sourceDevice: .iOS,
            createdAt: Date(timeIntervalSinceNow: -Double(itemCount - i) * 60)
        )
        if hasCrop {
            item.cropRegion = CropRegion(x: 0.1, y: 0.1, width: 0.6, height: 0.6)
        }
        if isSoftDeleted {
            item.deletedAt = .now
        }
        context.insert(item)

        // Uneven membership distribution — ~55% Unfiled, the rest spread
        // unevenly (one dominant folder, several small ones), mirroring
        // real usage rather than a uniform spread.
        let bucket = i % 20
        if bucket < 9 {
            let folderIndex: Int
            switch bucket {
            case 0, 1, 2, 3: folderIndex = 0 // "Deadwest" — the dominant folder
            case 4, 5: folderIndex = 1
            case 6: folderIndex = 2
            case 7: folderIndex = 3
            default: folderIndex = i % folders.count
            }
            let folder = folders[folderIndex]
            item.folder = folder
            context.insert(StoredFolderMembership(item: item, folder: folder))
        }
    }

    return (folders, folderNames[0])
}

// MARK: - Cold/warm migration-flag control
//
// `MembershipMigration`/`IconMigration` don't (deliberately — see their
// own doc comments) expose an injectable `UserDefaults`, so this
// benchmark-only helper resets their known flag keys directly to force a
// clean cold-path measurement each time. Coupled to those private string
// literals by necessity; if they're ever renamed, this silently measures
// nothing useful rather than crashing — acceptable for a throwaway
// measurement tool, not shipped app behavior.
@MainActor
func resetMigrationFlags() {
    let defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
    defaults.removeObject(forKey: "com.arkyv.migration.folderMembershipBackfill.v1")
    defaults.removeObject(forKey: "com.arkyv.migration.folderIconsToGlyphs.v1")
}

// MARK: - Suite

@MainActor
func runSuite(itemCount: Int) {
    print("=== \(itemCount) items ===")

    let container = try! ArkyvStore.makeModelContainer(inMemory: true)
    let memBefore = residentMemoryMB()

    time("populate + save (\(itemCount) items, \(folderNames.count + 1) folders)") {
        _ = makeSyntheticArchive(itemCount: itemCount, context: container.mainContext)
        try? container.mainContext.save()
    }
    let memAfterPopulate = residentMemoryMB()

    // A FRESH context against the SAME container — mirrors a real cold
    // launch reading an already-populated store back, not just re-reading
    // objects already resident in memory from the insert above.
    let freshContext = ModelContext(container)
    let freshRepo = Repository(context: freshContext)

    let allItems = time("fetch all StoredItem (unfiltered @Query equivalent)") {
        (try? freshContext.fetch(FetchDescriptor<StoredItem>(sortBy: [SortDescriptor(\StoredItem.createdAt, order: .reverse)]))) ?? []
    }

    let allImageItems = time("in-memory filter: !isSoftDeleted && kind.isMedia (ArchiveView.allImageItems)") {
        allItems.filter { !$0.isSoftDeleted && $0.kind.isMedia }
    }

    time("filter tab: Unfiled (ArchiveView.isUnfiled, per item)") {
        allImageItems.filter { ($0.memberships ?? []).filter { !$0.isSoftDeleted && $0.folder?.isSoftDeleted == false }.isEmpty }
    }

    time("filter tab: Favorites") {
        allImageItems.filter(\.isFavorite)
    }

    let allFolders = time("fetch all StoredFolder (Repository.folders)") {
        (try? freshRepo.folders(includingDeleted: true)) ?? []
    }
    if let bigFolder = allFolders.first(where: { $0.name == "Deadwest" }) {
        time("filter tab: one typical folder (\"Deadwest\", ArchiveView.isMember)") {
            allImageItems.filter { item in
                (item.memberships ?? []).contains { !$0.isSoftDeleted && $0.folder?.id == bigFolder.id && $0.folder?.isSoftDeleted == false }
            }
        }
    }

    if allImageItems.indices.contains(allImageItems.count / 2) {
        let midItemID = allImageItems[allImageItems.count / 2].id
        time("resolveItem(id) — linear scan (ArchiveView's actual method, per item-tap)") {
            allImageItems.first(where: { $0.id == midItemID })
        }
    }

    time("Repository.search(\"synthetic\") — full in-memory field scan") {
        (try? freshRepo.search("synthetic")) ?? []
    }

    #if DEBUG
    time("IntegrityCheck.run") {
        IntegrityCheck.run(context: freshContext)
    }
    #else
    print("  (IntegrityCheck.run skipped — #if DEBUG only, not present in a release build)")
    #endif

    resetMigrationFlags()
    time("MembershipMigration.runIfNeeded — COLD (flag unset, full scan)") {
        MembershipMigration.runIfNeeded(repository: freshRepo)
    }
    time("MembershipMigration.runIfNeeded — WARM (flag set, single read)") {
        MembershipMigration.runIfNeeded(repository: freshRepo)
    }
    resetMigrationFlags()
    time("IconMigration.runIfNeeded — COLD (flag unset, full scan)") {
        IconMigration.runIfNeeded(repository: freshRepo)
    }
    time("IconMigration.runIfNeeded — WARM (flag set, single read)") {
        IconMigration.runIfNeeded(repository: freshRepo)
    }

    let memAfterQueries = residentMemoryMB()
    if memBefore >= 0 {
        print(String(format: "  memory: baseline %.1f MB, +%.1f MB after populate, +%.1f MB after queries",
                     memBefore, memAfterPopulate - memBefore, memAfterQueries - memAfterPopulate))
    }
    print("")
}

// MARK: - Media Storage Architecture 01: externalStorage materialization cost
//
// Isolated, in-memory-only container (same as runSuite above — never a real
// device/CloudKit store). Answers one narrow, concrete question raised by
// the Media Storage Architecture 01 spike: how expensive is reading
// StoredItem.imageData (a SwiftData `.externalStorage` attribute) compared
// to reading the equivalent bytes from a plain file on disk (what
// MediaStore.data(for:) already does today)? This is the exact cost
// Option 2 (imageData as sole local authority, MediaStore as a purgeable
// cache) would pay on every cache miss.
//
// Realistic per-item sizes, matching Storage Foundation 01's own blended
// estimate (~800KB average across a screenshot-heavy archive, with real
// camera photos running several MB) — deterministic, no randomness.
private let mediaSizeSamplesKB: [Int] = [150, 400, 800, 1_200, 2_500, 4_800]

@MainActor
func makeSyntheticMediaArchive(itemCount: Int, context: ModelContext) -> [UUID] {
    var ids: [UUID] = []
    for i in 0..<itemCount {
        let sizeBytes = mediaSizeSamplesKB[i % mediaSizeSamplesKB.count] * 1024
        // Deterministic, non-uniform payload (not all-zero) — closer to
        // real compressed-image entropy than a single repeated byte,
        // without needing an actual decodable JPEG for a byte-materialization
        // cost measurement (decode cost is already covered separately by
        // Performance/Scale Foundation 01's ImageDecodeCache benchmarks).
        var bytes = Data(count: sizeBytes)
        bytes.withUnsafeMutableBytes { buffer in
            for offset in stride(from: 0, to: buffer.count, by: 4099) {
                buffer[offset] = UInt8((offset ^ i) & 0xFF)
            }
        }
        let item = StoredItem(kind: .screenshot, localFilename: "media-arch-\(i).jpg", imageData: bytes)
        context.insert(item)
        ids.append(item.id)
    }
    return ids
}

@MainActor
func runMediaStorageArchitectureBenchmark(itemCount: Int) {
    print("=== Media Storage Architecture 01 — \(itemCount) items ===")

    let container = try! ArkyvStore.makeModelContainer(inMemory: true)
    let ids = time("populate + save (\(itemCount) items with real imageData payloads)") {
        let ids = makeSyntheticMediaArchive(itemCount: itemCount, context: container.mainContext)
        try? container.mainContext.save()
        return ids
    }

    // Mirror the equivalent bytes out to real temp files — the plain-file
    // baseline MediaStore.data(for:) reads from today.
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("arkyvbench-media-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let freshContext = ModelContext(container)
    let freshItems = (try? freshContext.fetch(FetchDescriptor<StoredItem>())) ?? []
    for item in freshItems {
        if let data = item.imageData {
            try? data.write(to: tempDir.appendingPathComponent("\(item.id).jpg"))
        }
    }

    // COLD externalStorage read — a fresh context per item, mirroring a
    // real cold-cache scenario where nothing about this item is already
    // resident in memory.
    let memBeforeExternal = residentMemoryMB()
    time("read imageData for all \(itemCount) items (cold, fresh contexts, externalStorage materialization)") {
        for id in ids {
            let perItemContext = ModelContext(container)
            let descriptor = FetchDescriptor<StoredItem>(predicate: #Predicate { $0.id == id })
            if let item = try? perItemContext.fetch(descriptor).first {
                _ = item.imageData?.count // force materialization
            }
        }
    }
    let memAfterExternal = residentMemoryMB()

    // Plain-file baseline — what MediaStore.data(for:) already does today.
    let memBeforeFile = residentMemoryMB()
    time("read the same \(itemCount) items' bytes from plain files (MediaStore.data(for:) baseline)") {
        for id in ids {
            _ = try? Data(contentsOf: tempDir.appendingPathComponent("\(id).jpg"))
        }
    }
    let memAfterFile = residentMemoryMB()

    // Option 2's actual cache-miss round trip: materialize from
    // externalStorage, then write it to a working file (exactly what
    // MediaStore.data(for:reconstructingFrom:) already does for D4 recovery
    // today) — the real, total cost a cache miss would pay under Option 2,
    // not just the read half.
    let cacheMissDir = FileManager.default.temporaryDirectory.appendingPathComponent("arkyvbench-cachemiss-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: cacheMissDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: cacheMissDir) }
    time("full cache-miss round trip (\(itemCount)x): read imageData + atomic-write working file (MediaStore.data(for:reconstructingFrom:) shape)") {
        for id in ids {
            let perItemContext = ModelContext(container)
            let descriptor = FetchDescriptor<StoredItem>(predicate: #Predicate { $0.id == id })
            guard let item = try? perItemContext.fetch(descriptor).first, let data = item.imageData else { continue }
            try? data.write(to: cacheMissDir.appendingPathComponent("\(id).jpg"), options: .atomic)
        }
    }

    if memBeforeExternal >= 0 {
        print(String(format: "  memory: externalStorage pass +%.1f MB, plain-file pass +%.1f MB",
                     memAfterExternal - memBeforeExternal, memAfterFile - memBeforeFile))
    }
    print("")
}

// MARK: - Entry point

let configuration = ProcessInfo.processInfo.environment["ARKYV_BENCH_CONFIG"] ?? "debug"
print("ArkyvBench — Scale Foundation 01 (build config: \(configuration))")
print("")

let sizes = [100, 1_000, 5_000, 10_000, 20_000]
for size in sizes {
    await runSuite(itemCount: size)
}

print("--- Media Storage Architecture 01 ---")
print("")
for size in [100, 500, 2_000] {
    await runMediaStorageArchitectureBenchmark(itemCount: size)
}

print("Done.")
