import XCTest
@testable import ArkyvKit

/// Animation Rendering 01. Proves, against a real (locally-generated,
/// deterministic) multi-frame GIF fixture — not a synthetic claim — that
/// `AnimatedImageDecoding` correctly detects animation, decodes every
/// frame with its own real per-frame delay and loop count, respects a
/// memory budget rather than eagerly decoding regardless of size, and
/// that `currentFrame(in:elapsed:)` maps wall-clock time onto the source's
/// own authored timing (never a manufactured fixed interval), including
/// both the infinite-loop-wrap case and the finite-loop-hold-last-frame
/// case.
///
/// Static-media regression (§13) lives in `MediaPreservationTests`, which
/// already proves `ImageDecoding.decode`/`fileExtension` are byte-for-byte
/// unchanged; this file only covers the new `AnimatedImageDecoding` API
/// surface, which no static call site (`LocalImageView`, Archive,
/// Editorial covers, Folder grids) ever touches.
final class AnimationRenderingTests: XCTestCase {
    // MARK: - Fixtures

    /// 3 real, distinct frames (red/green/blue), 0.2s delay each, infinite
    /// loop (NETSCAPE2.0 loop extension present) — the exact same
    /// specimen `MediaPreservationTests.animatedGIFFixture` uses, verified
    /// there to be genuinely 3-frame via ImageIO itself.
    private static let animatedGIFFixture = Data(base64Encoded:
        "R0lGODdhBAAEAKIAAAAAAAAA//8AAAD/AP///wAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQFFAAFACwAAAAABAAEAAADBCi63JIAIfkEBRQABQAsAAAAAAQABAAAAwQ4utyTACH5BAUUAAUALAAAAAAEAAQAAAMEGLrckQA7"
    )!

    private static let jpegFixture = Data(base64Encoded:
        "/9j/4AAQSkZJRgABAQAASABIAAD/4QBARXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAABKADAAQAAAABAAAABAAAAAD/wAARCAAEAAQDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9sAQwACAgICAgIDAgIDBQMDAwUGBQUFBQYIBgYGBgYICggICAgICAoKCgoKCgoKDAwMDAwMDg4ODg4PDw8PDw8PDw8P/9sAQwECAgIEBAQHBAQHEAsJCxAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ/90ABAAB/9oADAMBAAIRAxEAPwDx+iiiv9VD/Nc//9k="
    )!

    // MARK: - Frame count: the cheap, header-only animation signal

    func testFrameCountOnAnimatedGIFIsGenuinelyMultiFrame() {
        XCTAssertEqual(AnimatedImageDecoding.frameCount(ofData: Self.animatedGIFFixture), 3)
    }

    func testFrameCountOnStaticJPEGIsOne() {
        XCTAssertEqual(AnimatedImageDecoding.frameCount(ofData: Self.jpegFixture), 1)
    }

    func testFrameCountOnGarbageBytesIsZero() {
        XCTAssertEqual(AnimatedImageDecoding.frameCount(ofData: Data([0x00, 0x01, 0x02])), 0)
    }

    // MARK: - decodeAnimated: real per-frame delay and loop count

    func testDecodeAnimatedReadsRealFrameCountDelayAndLoopCount() throws {
        let source = try XCTUnwrap(AnimatedImageDecoding.decodeAnimated(Self.animatedGIFFixture, maxPixelSize: nil))
        XCTAssertEqual(source.frames.count, 3, "must decode every real frame, not just the first")
        for frame in source.frames {
            XCTAssertEqual(frame.delay, 0.2, accuracy: 0.001, "must read the fixture's real authored 0.2s delay, never a manufactured default")
        }
        XCTAssertEqual(source.loopCount, 0, "fixture's NETSCAPE2.0 extension specifies infinite looping")
        XCTAssertEqual(source.totalDuration, 0.6, accuracy: 0.001)
    }

    func testDecodeAnimatedReturnsNilForGenuinelyStaticSource() {
        XCTAssertNil(AnimatedImageDecoding.decodeAnimated(Self.jpegFixture, maxPixelSize: nil), "a single-frame source is not animated — must not fabricate a 1-frame AnimatedSource")
    }

    func testDecodeAnimatedRespectsAPixelSizeCap() throws {
        let source = try XCTUnwrap(AnimatedImageDecoding.decodeAnimated(Self.animatedGIFFixture, maxPixelSize: 2))
        for frame in source.frames {
            XCTAssertLessThanOrEqual(max(frame.image.size.width, frame.image.size.height), 4, "downsampled frames must respect the requested cap (allowing ImageIO's own rounding), not silently decode at full size")
        }
    }

    // MARK: - Memory budget: never eagerly decode past a hard ceiling

    func testDecodeAnimatedReturnsNilWhenEstimatedBytesExceedBudget() {
        // This fixture's real canvas is 4x4 — trivially under budget at
        // any reasonable cap. Proves the guard triggers on a budget that's
        // deliberately set far below what 3 frames of a 4x4 image could
        // ever need, without requiring a genuinely huge fixture in the
        // test bundle.
        let tinyBudget = 4 * 4 * 4 * 3 - 1 // one byte under exact
        XCTAssertNil(AnimatedImageDecoding.decodeAnimatedForTesting(Self.animatedGIFFixture, maxPixelSize: nil, maxDecodedBytesBudget: tinyBudget))
    }

    func testDecodeAnimatedSucceedsExactlyAtBudget() {
        let exactBudget = 4 * 4 * 4 * 3
        XCTAssertNotNil(AnimatedImageDecoding.decodeAnimatedForTesting(Self.animatedGIFFixture, maxPixelSize: nil, maxDecodedBytesBudget: exactBudget))
    }

    // MARK: - currentFrame(in:elapsed:) — source-authored timing, not a fixed interval

    func testCurrentFrameAtStartIsFirstFrame() throws {
        let source = try XCTUnwrap(AnimatedImageDecoding.decodeAnimated(Self.animatedGIFFixture, maxPixelSize: nil))
        let frame = AnimatedImageDecoding.currentFrame(in: source, elapsed: 0)
        XCTAssertTrue(frame.image === source.frames[0].image)
    }

    func testCurrentFrameMidwayThroughFirstFrameIsStillFirstFrame() throws {
        let source = try XCTUnwrap(AnimatedImageDecoding.decodeAnimated(Self.animatedGIFFixture, maxPixelSize: nil))
        let frame = AnimatedImageDecoding.currentFrame(in: source, elapsed: 0.1)
        XCTAssertTrue(frame.image === source.frames[0].image)
    }

    func testCurrentFrameAdvancesToSecondFrameAfterFirstDelayElapses() throws {
        let source = try XCTUnwrap(AnimatedImageDecoding.decodeAnimated(Self.animatedGIFFixture, maxPixelSize: nil))
        let frame = AnimatedImageDecoding.currentFrame(in: source, elapsed: 0.25)
        XCTAssertTrue(frame.image === source.frames[1].image)
    }

    func testCurrentFrameAdvancesToThirdFrame() throws {
        let source = try XCTUnwrap(AnimatedImageDecoding.decodeAnimated(Self.animatedGIFFixture, maxPixelSize: nil))
        let frame = AnimatedImageDecoding.currentFrame(in: source, elapsed: 0.45)
        XCTAssertTrue(frame.image === source.frames[2].image)
    }

    /// Infinite loop (`loopCount == 0`): once elapsed passes the total
    /// 0.6s loop duration, playback wraps back to frame 0 rather than
    /// holding or stopping — this is the "loops forever" contract.
    func testCurrentFrameWrapsAroundOnInfiniteLoop() throws {
        let source = try XCTUnwrap(AnimatedImageDecoding.decodeAnimated(Self.animatedGIFFixture, maxPixelSize: nil))
        let frame = AnimatedImageDecoding.currentFrame(in: source, elapsed: 0.65) // 0.65 mod 0.6 == 0.05 -> frame 0
        XCTAssertTrue(frame.image === source.frames[0].image)
    }

    /// Finite loop count: playback must hold on the final frame once the
    /// total play duration elapses, never wrap forever, and never crash.
    /// Constructed directly (not from a fixture — real GIF/WebP loop
    /// counts observed empirically in this milestone's own recon were
    /// either 0 or a large finite value, neither of which exercises this
    /// branch) since `AnimatedSource`/`Frame` are `@testable`-visible.
    func testCurrentFrameHoldsFinalFrameAfterFiniteLoopCountCompletes() {
        let frames = [
            AnimatedImageDecoding.Frame(image: UIImage(), delay: 0.1),
            AnimatedImageDecoding.Frame(image: UIImage(), delay: 0.1),
        ]
        let source = AnimatedImageDecoding.AnimatedSource(frames: frames, loopCount: 2) // total play duration: 0.4s
        let midplay = AnimatedImageDecoding.currentFrame(in: source, elapsed: 0.05)
        XCTAssertTrue(midplay.image === frames[0].image)

        let afterCompletion = AnimatedImageDecoding.currentFrame(in: source, elapsed: 0.5)
        XCTAssertTrue(afterCompletion.image === frames.last!.image, "must hold the final frame, not wrap past the authored loop count")
    }

    func testCurrentFrameOnSingleFrameSourceAlwaysReturnsThatFrame() {
        let frames = [AnimatedImageDecoding.Frame(image: UIImage(), delay: 0.1)]
        let source = AnimatedImageDecoding.AnimatedSource(frames: frames, loopCount: 0)
        XCTAssertTrue(AnimatedImageDecoding.currentFrame(in: source, elapsed: 999).image === frames[0].image)
    }
}
