import XCTest
@testable import ArkyvKit

/// Link Cherry Ingestion + Source Semantics 01. Pins the narrow rule
/// that decides whether a plain-text share is treated as a URL share —
/// exactly one bare http/https URL, nothing else.
final class PlainTextURLRecognizerTests: XCTestCase {
    func testBareHTTPSURLRecognized() {
        let url = PlainTextURLRecognizer.recognizedURL(from: "https://example.com/page")
        XCTAssertEqual(url?.absoluteString, "https://example.com/page")
    }

    func testBareHTTPURLRecognized() {
        let url = PlainTextURLRecognizer.recognizedURL(from: "http://example.com/page")
        XCTAssertEqual(url?.absoluteString, "http://example.com/page")
    }

    func testYouTubeURLWithTimestampRecognizedVerbatim() {
        let raw = "https://www.youtube.com/watch?v=XcObGXRfKyU&t=106s"
        let url = PlainTextURLRecognizer.recognizedURL(from: raw)
        XCTAssertEqual(url?.absoluteString, raw)
    }

    func testSurroundingWhitespaceIsTrimmedAndStillRecognized() {
        let url = PlainTextURLRecognizer.recognizedURL(from: "  https://example.com/page  \n")
        XCTAssertEqual(url?.absoluteString, "https://example.com/page")
    }

    func testProseWithEmbeddedURLIsNotRecognized() {
        XCTAssertNil(PlainTextURLRecognizer.recognizedURL(from: "Check this out https://example.com"))
    }

    func testOrdinaryProseIsNotRecognized() {
        XCTAssertNil(PlainTextURLRecognizer.recognizedURL(from: "hello world"))
    }

    func testEmptyStringIsNotRecognized() {
        XCTAssertNil(PlainTextURLRecognizer.recognizedURL(from: ""))
        XCTAssertNil(PlainTextURLRecognizer.recognizedURL(from: "   "))
    }

    func testNonHTTPSchemeIsNotRecognized() {
        XCTAssertNil(PlainTextURLRecognizer.recognizedURL(from: "mailto:someone@example.com"))
        XCTAssertNil(PlainTextURLRecognizer.recognizedURL(from: "ftp://example.com/file"))
    }

    func testURLWithoutHostIsNotRecognized() {
        XCTAssertNil(PlainTextURLRecognizer.recognizedURL(from: "https:///no-host"))
    }
}
