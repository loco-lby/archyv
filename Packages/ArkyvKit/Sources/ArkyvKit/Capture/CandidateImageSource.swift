import Foundation

/// Link Cherry Visual Picker 01: a second, small, deliberately distinct
/// protocol from `SourceEnricher` — an enricher replaces the SINGLE best
/// candidate; a candidate source supplies ADDITIONAL alternate candidate
/// URLs appended after whatever the primary resolution (enricher or
/// generic) already produced. Never used alone; always additive.
public protocol CandidateImageSource: Sendable {
    /// Cheap, synchronous, no network.
    func matches(_ url: URL) -> Bool

    /// Returns zero or more candidate image URLs, ordered by confidence.
    /// Throwing (network failure, unparsable page) means "no additional
    /// candidates" — never a reason to fail the whole resolution.
    func candidateImageURLs(for url: URL) async throws -> [URL]
}
