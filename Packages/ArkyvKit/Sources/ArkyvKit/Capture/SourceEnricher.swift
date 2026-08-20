import Foundation

/// Priority Source Intelligence 01: the smallest maintainable shape for
/// optional, source-specific enhancement of the generic URL → Cherry
/// pipeline. "Generic resolver = universal safety net; priority source
/// intelligence = narrow, evidence-backed enhancements for a few
/// high-value sources where generic metadata materially fails user
/// intent." An enricher NEVER replaces the generic path — `matches`
/// decides deterministically (no network) whether one applies at all,
/// and any failure inside `enrich` (thrown error) means
/// `URLCherryResolver` falls straight through to its unchanged, existing
/// generic `LPMetadataProvider` resolution. No registry, no dependency
/// injection — just a plain array `URLCherryResolver` checks in order.
public protocol SourceEnricher: Sendable {
    /// Cheap, synchronous, no network — decides whether this enricher
    /// applies to `url` at all.
    func matches(_ url: URL) -> Bool

    /// Attempts enrichment. Throwing (for any reason: network, decode,
    /// malformed response) is the ONLY failure signal `URLCherryResolver`
    /// needs — it never inspects the error, just falls back to generic.
    func enrich(_ url: URL) async throws -> EnrichedLinkContent
}

/// What an enricher can improve over generic `LPLinkMetadata`: a better
/// title, and/or a better representative image (as a URL to fetch bytes
/// from — enrichers never touch `MediaStore`/persistence themselves).
public struct EnrichedLinkContent: Sendable {
    public let title: String?
    public let imageURL: URL

    public init(title: String?, imageURL: URL) {
        self.title = title
        self.imageURL = imageURL
    }
}
