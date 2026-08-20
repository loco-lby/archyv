import Foundation

/// Link Cherry Visual Picker 01: "what should visually represent this
/// link in my archive?" A candidate is deliberately ephemeral — it never
/// reaches `StoredItem`/`MediaStore` unless the user actually selects
/// it; only the chosen candidate's bytes ever become authoritative
/// `imageData`. Candidate 0 is always Cherries' best single guess (the
/// exact image today's single-image flow would have used), so a user
/// who never swipes gets today's behavior byte-for-byte.
public struct ResolvedImageCandidate: Identifiable, Sendable {
    /// Stable dedupe/diffing identity — a normalized form of the
    /// candidate's origin, never the raw bytes (comparing bytes would be
    /// the "expensive perceptual comparison" this milestone explicitly
    /// avoids).
    public let id: String
    public let source: Source

    public enum Source: Sendable {
        /// Already-fetched bytes — used for the generic
        /// `LPMetadataProvider` candidate and any `SourceEnricher`
        /// result, both of which only ever hand back an `NSItemProvider`
        /// or a URL fetched at resolve time, not a re-fetchable URL of
        /// their own. Materializing this candidate is then just
        /// validation + a `MediaStore` write, no network.
        case bytes(Data, typeHint: String)
        /// A URL to fetch lazily, only when this candidate is actually
        /// materialized (shown for the first time, or selected) — used
        /// for ecommerce alternate-image candidates, which may never be
        /// looked at.
        case url(URL)
    }

    public init(id: String, source: Source) {
        self.id = id
        self.source = source
    }
}

/// The result of resolving a URL into candidate visuals, before any one
/// of them has been materialized into archived bytes.
public struct ResolvedURLCherry: Sendable {
    public let title: String?
    public let sourceURL: URL
    /// Ordered by confidence — index 0 is always the best single guess.
    public let candidates: [ResolvedImageCandidate]

    public init(title: String?, sourceURL: URL, candidates: [ResolvedImageCandidate]) {
        self.title = title
        self.sourceURL = sourceURL
        self.candidates = candidates
    }
}

/// Pure candidate-list assembly: dedup + cap, shared by every candidate
/// source so the rules live in exactly one place.
public enum CandidateAssembly {
    /// V1 cap — "prefer the first high-confidence candidates rather than
    /// dumping an entire 40-image product gallery into the Share
    /// Extension." Bounds both UI complexity (page-dot rows) and the
    /// worst-case number of alternate-candidate network fetches.
    public static let maximumCandidates = 10

    /// Appends `additional` candidates after `existing` (existing —
    /// almost always just the single best-guess candidate — always
    /// keeps priority position 0), skipping any whose `id` already
    /// appears, and stopping once `maximumCandidates` is reached.
    public static func merging(_ existing: [ResolvedImageCandidate], with additional: [ResolvedImageCandidate]) -> [ResolvedImageCandidate] {
        var seenIDs = Set(existing.map(\.id))
        var result = existing
        for candidate in additional {
            guard result.count < maximumCandidates else { break }
            guard seenIDs.insert(candidate.id).inserted else { continue }
            result.append(candidate)
        }
        return result
    }

    /// A practical, cheap dedupe key for an image URL — NOT perceptual
    /// comparison. Strips the query string (the same asset is routinely
    /// referenced with different cache-busting/version parameters across
    /// Open Graph vs. JSON-LD vs. an inline gallery array) and, since
    /// e-commerce CDNs commonly serve the identical source asset at
    /// several resolutions via a `_{width}x{height}` filename suffix
    /// (e.g. Shopify's `photo_1024x1024.jpg` vs. `photo.jpg`), strips
    /// that suffix too before comparing.
    public static func dedupeKey(for url: URL) -> String {
        var path = url.path
        if let range = path.range(of: #"_\d+x\d+(?=\.[a-zA-Z0-9]+$)"#, options: .regularExpression) {
            path.removeSubrange(range)
        }
        return "\(url.host ?? "")\(path)".lowercased()
    }
}
