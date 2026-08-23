import XCTest
import CryptoKit
import ImageIO
import CoreGraphics
@testable import ArkyvKit

/// Media Preservation Foundation 01. Proves, with real (locally-generated,
/// deterministic) encoded fixtures — not synthetic claims — that
/// `MediaStore.save(data:)` preserves original bytes exactly, and that
/// `ImageDecoding.fileExtension(ofData:)` correctly identifies format from
/// the bytes themselves rather than a filename or declared content type.
/// Deliberately network-free: fixtures are either generated locally via
/// ImageIO (JPEG/PNG/GIF — CoreGraphics can encode these) or a small
/// real-world sample embedded as a literal constant (WebP — CoreGraphics
/// cannot encode WebP, only decode it, so a genuine sample is required).
///
/// What this file does NOT cover, and why: `ShareViewController`'s
/// `encodedFastPathDraft`/`extractProvenanceURL` and `CaptureSheetView`'s
/// `loadPickedPhoto`/`ScreenshotDetector`'s `loadDraft` are UIViewController/
/// SwiftUI code in separate compilation targets with no XCTest target
/// configured (the same pre-existing gap every other app-target-only view
/// in this codebase has) — verified instead via a standalone script against
/// real `NSItemProvider` instances (matching this project's established
/// precedent) and physical Device A QA, not by inventing a fake seam here.
final class MediaPreservationTests: XCTestCase {
    // MARK: - Fixtures
    //
    // Generated locally via ImageIO (`generate_fixtures.swift`/
    // `gen_jpeg.swift`, disposable scratch scripts, not part of this
    // package) and verified at generation time: PNG has real alpha, GIF
    // has 3 real frames, JPEG has none of either. The WebP sample is a
    // small real file (Google's own public WebP gallery) embedded as a
    // literal constant so this suite stays network-free at test time.

    private static let jpegFixture = Data(base64Encoded:
        "/9j/4AAQSkZJRgABAQAASABIAAD/4QBARXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAABKADAAQAAAABAAAABAAAAAD/wAARCAAEAAQDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9sAQwACAgICAgIDAgIDBQMDAwUGBQUFBQYIBgYGBgYICggICAgICAoKCgoKCgoKDAwMDAwMDg4ODg4PDw8PDw8PDw8P/9sAQwECAgIEBAQHBAQHEAsJCxAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ/90ABAAB/9oADAMBAAIRAxEAPwDx+iiiv9VD/Nc//9k="
    )!

    private static let transparentPNGFixture = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAAXNSR0IArs4c6QAAADhlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAABKADAAQAAAABAAAABAAAAADmpNw4AAAAFklEQVQIHWP8z8DQwIAEmJDYYCZhAQBkEQGHDYHBwAAAAABJRU5ErkJggg=="
    )!

    /// 3 real, distinct frames (red/green/blue), 0.2s delay each, infinite
    /// loop — verified `frameCount == 3` at generation time via ImageIO
    /// itself, not assumed from the encoder call succeeding.
    private static let animatedGIFFixture = Data(base64Encoded:
        "R0lGODdhBAAEAKIAAAAAAAAA//8AAAD/AP///wAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQFFAAFACwAAAAABAAEAAADBCi63JIAIfkEBRQABQAsAAAAAAQABAAAAwQ4utyTACH5BAUUAAUALAAAAAAEAAQAAAMEGLrckQA7"
    )!

    // MARK: - A. JPEG

    func testJPEGPersistsExactlyAndDecodesValidly() throws {
        let (mediaStore, root) = makeIsolatedMediaStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Self.jpegFixture
        let ext = ImageDecoding.fileExtension(ofData: data)
        XCTAssertEqual(ext, "jpg")

        let filename = try mediaStore.save(data: data, ext: ext)
        let persisted = mediaStore.data(for: filename)

        XCTAssertEqual(persisted, data, "JPEG bytes must round-trip exactly")
        assertByteIdentical(input: data, persisted: persisted)
        XCTAssertNotNil(ImageDecoding.decode(persisted!), "persisted JPEG must still decode")
    }

    // MARK: - B. Transparent PNG — the flagship non-destructive regression

    func testTransparentPNGPersistsExactlyAndKeepsAlpha() throws {
        let (mediaStore, root) = makeIsolatedMediaStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Self.transparentPNGFixture
        let ext = ImageDecoding.fileExtension(ofData: data)
        XCTAssertEqual(ext, "png")
        XCTAssertTrue(hasAlpha(data), "fixture sanity check — the input itself must have real alpha")

        let filename = try mediaStore.save(data: data, ext: ext)
        let persisted = mediaStore.data(for: filename)

        assertByteIdentical(input: data, persisted: persisted)
        XCTAssertTrue(hasAlpha(persisted!), "alpha must survive the save/readback round-trip — this is the transparency regression specimen")
    }

    // MARK: - C. Animated GIF — the flagship animation regression

    func testAnimatedGIFPersistsExactlyAndKeepsAllFrames() throws {
        let (mediaStore, root) = makeIsolatedMediaStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Self.animatedGIFFixture
        let ext = ImageDecoding.fileExtension(ofData: data)
        XCTAssertEqual(ext, "gif")
        let inputFrameCount = frameCount(data)
        XCTAssertGreaterThan(inputFrameCount, 1, "fixture sanity check — the input itself must be genuinely multi-frame")

        let filename = try mediaStore.save(data: data, ext: ext)
        let persisted = mediaStore.data(for: filename)

        assertByteIdentical(input: data, persisted: persisted)
        let persistedFrameCount = frameCount(persisted!)
        XCTAssertEqual(persistedFrameCount, inputFrameCount, "frame count before and after must match exactly")
        XCTAssertGreaterThan(persistedFrameCount, 1, "must still be genuinely animated after save/readback — this is the flagship preservation specimen")
    }

    /// The current renderer is explicitly allowed to show only frame 1 —
    /// deferred to Animation Rendering 01 — but it must not CRASH or fail
    /// to decode a multi-frame GIF as a static image either.
    func testAnimatedGIFStillDecodesAsAStaticImageForTodaysRenderer() {
        XCTAssertNotNil(ImageDecoding.decode(Self.animatedGIFFixture), "today's single-frame renderer must still successfully decode a preserved animated GIF, even though it only shows frame 1")
    }

    // MARK: - D. Static WebP

    func testStaticWebPPersistsExactlyAndDecodes() throws {
        let (mediaStore, root) = makeIsolatedMediaStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try XCTUnwrap(Self.staticWebPFixture, "WebP fixture failed to decode from its embedded base64 — fixture corruption, not a production bug")
        let ext = ImageDecoding.fileExtension(ofData: data)
        XCTAssertEqual(ext, "webp")

        let filename = try mediaStore.save(data: data, ext: ext)
        let persisted = mediaStore.data(for: filename)

        assertByteIdentical(input: data, persisted: persisted)
        XCTAssertNotNil(ImageDecoding.decode(persisted!), "persisted WebP must still decode")
    }

    // MARK: - G. Crop metadata never rewrites original bytes

    /// Repository.fileCapture with a non-default CropRegion must persist
    /// the crop as separate metadata (cropX/Y/Width/Height) — never by
    /// rewriting/rasterizing imageData. Proven directly against the
    /// animated GIF fixture specifically: if crop ever silently flattened
    /// the source, this would be the fixture to catch it on (a rasterized
    /// crop of a GIF could not still be multi-frame).
    @MainActor
    func testCropRegionDoesNotRewriteOriginalMediaBytes() throws {
        let container = ArkyvStore.makeModelContainer(inMemory: true)
        let repo = Repository(context: container.mainContext)
        let (mediaStore, root) = makeIsolatedMediaStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Self.animatedGIFFixture
        let filename = try mediaStore.save(data: data, ext: "gif")

        let region = CropRegion(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let item = try repo.fileCapture(CaptureDraft(kind: .image, localFilename: filename, cropRegion: region))

        XCTAssertEqual(item.cropRegion, region, "crop persists as metadata")
        XCTAssertEqual(item.localFilename, filename, "localFilename — and therefore the original file on disk — is untouched by cropping")
        let stillOnDisk = mediaStore.data(for: filename)
        assertByteIdentical(input: data, persisted: stillOnDisk)
        XCTAssertEqual(frameCount(stillOnDisk!), 3, "the original GIF on disk must still be genuinely multi-frame after a crop was applied — cropping must never rasterize/flatten the source")
    }

    // MARK: - I. Unknown/unsupported media fails safely, never lies

    func testUnknownBytesFallBackToSafeDefaultExtensionRatherThanLying() {
        let garbage = Data("not an image, not anything ImageIO recognizes".utf8)
        XCTAssertEqual(ImageDecoding.fileExtension(ofData: garbage), "jpg", "the documented, honest fallback — never a guessed/lying extension")
        XCTAssertNil(ImageDecoding.pixelSize(ofData: garbage), "genuinely undecodable data must report nil, not fabricate dimensions")
    }

    // MARK: - J. Existing Link Cherry path (materializeCandidate) unchanged,
    // now with a real multi-frame GIF as direct regression evidence — this
    // exact combination (a GIF resolved as a Link Cherry) was previously
    // only proven true by code inspection, not a dedicated test.

    func testLinkCherryMaterializeCandidatePreservesAnimatedGIFExactly() async throws {
        let (mediaStore, root) = makeIsolatedMediaStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Self.animatedGIFFixture
        let candidate = ResolvedImageCandidate(id: "primary", source: .bytes(data, typeHint: "gif"))

        let draft = await URLCherryResolver.materializeCandidate(
            candidate, title: "An animated thing", sourceURL: URL(string: "https://example.com/thing.gif")!,
            sourceDevice: .iOS, mediaStore: mediaStore
        )

        let filename = try XCTUnwrap(draft?.localFilename)
        let persisted = mediaStore.data(for: filename)
        assertByteIdentical(input: data, persisted: persisted)
        XCTAssertEqual(frameCount(persisted!), 3)
    }

    // MARK: - Helpers

    private func makeIsolatedMediaStore() -> (MediaStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaPreservationTests-\(UUID().uuidString)")
        return (MediaStore(isolatedRoot: root), root)
    }

    private func assertByteIdentical(input: Data, persisted: Data?, file: StaticString = #filePath, line: UInt = #line) {
        guard let persisted else {
            XCTFail("persisted data is nil", file: file, line: line)
            return
        }
        let inputHash = SHA256.hash(data: input)
        let persistedHash = SHA256.hash(data: persisted)
        XCTAssertEqual(
            Data(inputHash), Data(persistedHash),
            "SHA-256 mismatch — persisted bytes must be byte-identical to what Cherries received (not claiming identity with any upstream original iOS may have already transformed)",
            file: file, line: line
        )
    }

    private func frameCount(_ data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }

    private func hasAlpha(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        return (props[kCGImagePropertyHasAlpha] as? Bool) ?? false
    }

    /// A small real static WebP (Google's public WebP gallery sample) —
    /// CoreGraphics/ImageIO can DECODE WebP but not ENCODE it, so this one
    /// fixture (unlike JPEG/PNG/GIF above) could not be generated locally
    /// and is a genuine third-party sample instead.
    private static let staticWebPFixture: Data? = Data(base64Encoded: staticWebPBase64)
}

/// Google's public WebP gallery sample (gstatic.com/webp/gallery/4.sm.webp)
/// — a small, genuine, third-party-encoded static WebP file, embedded so
/// `MediaPreservationTests` stays network-free at test time.
private let staticWebPBase64 = "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"
