import Foundation

/// Pinterest Link Cherry V1 01: a single-authoritative-image source,
/// deliberately a `SourceEnricher` and never a `CandidateImageSource` —
/// Pinterest Candidate Quality 01's forensic audit proved, against 4 real
/// Pins (1 tagged `Product`, 3 `SocialMediaPosting`), that Pinterest
/// never exposes more than one genuinely distinct photo per Pin. Every
/// apparent "candidate" `ProductPageCandidateSource` was previously
/// surfacing for a Product-tagged Pin was Pinterest's own CDN
/// size/crop-bucket convention for the *same* underlying image —
/// resolution variants of one 4:5 composition, plus Pinterest's own
/// square thumbnail crop and wide social-card crop, none of them a Pin
/// author's intentional alternate image. `ProductPageCandidateSource`
/// now excludes Pinterest hosts entirely (see its own doc comment) as
/// the required fix; this enricher exists only for the optional quality
/// bonus described below, and matching the same hosts here means
/// Pinterest's resolution never even reaches the (already-excluded)
/// candidate-source path in the first place — `URLCherryResolver`
/// always tries a matched enricher first.
///
/// **The one thing this enricher does:** Pinterest's CDN URLs encode
/// resolution as a swappable path segment
/// (`i.pinimg.com/{size}/{2}/{2}/{2}/{hash}.{ext}`), and Pinterest
/// Candidate Quality 01 proved, by downloading and comparing real bytes,
/// that `/originals/` is the exact same faithful 4:5 composition as the
/// `236x`/`474x`/`564x`/`736x` size buckets — just at full resolution,
/// with zero crop tradeoff. If the page's own `og:image` uses one of
/// those recognized buckets, this attempts the `/originals/` swap —
/// opportunistically, fully validated (HTTP success, decodable bytes,
/// positive dimensions), with silent fallback to the unmodified
/// `og:image` on ANY failure — same acceptance-rule shape as Instagram's
/// optional thumbnail enhancement, same `withTaskGroup` timeout-race
/// pattern, not new concurrency machinery. It deliberately does NOT
/// touch Pinterest's thumbnail (`60x60`, `136x136`) or social-card
/// (`600x315`-shaped) crop families — those are genuinely different
/// compositions, not resolution variants, and Section 3 of this
/// milestone explicitly excludes them.
///
/// **Title:** read directly from `og:title` with no transformation —
/// unlike Instagram's caption, which needed a boilerplate prefix
/// stripped out, Pinterest's own `og:title` (confirmed during Candidate
/// Quality 01's recon: `"GANG - Print by Ces XC | DROOL Art | ..."`) is
/// already the same direct, un-wrapped field `LPMetadataProvider`
/// itself would read as an Open Graph consumer — a verbatim pass-through
/// keeps this enricher's title behavior equivalent to the generic path
/// it replaces, not a new title algorithm layered on top of it.
public struct PinterestSourceEnricher: SourceEnricher, Sendable {
    public init() {}

    public func matches(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "pinterest.com" || host.hasSuffix(".pinterest.com")
            || host == "pin.it" || host.hasSuffix(".pin.it")
    }

    public func enrich(_ url: URL) async throws -> EnrichedLinkContent {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EnrichmentError.badResponse
        }
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw EnrichmentError.undecodableResponse
        }
        guard let imageURLString = Self.metaContent(property: "og:image", in: html),
              let imageURL = URL(string: imageURLString) else {
            throw EnrichmentError.noRepresentativeImage
        }
        let title = Self.metaContent(property: "og:title", in: html)
        let finalImageURL = await Self.optionalOriginalsUpgrade(for: imageURL) ?? imageURL
        return EnrichedLinkContent(title: title, imageURL: finalImageURL)
    }

    // MARK: - Optional /originals/ quality bonus (bonus, never a dependency)

    private static let originalsUpgradeTimeout: Duration = .milliseconds(2500)

    /// Races the validated upgrade attempt against a dedicated timeout —
    /// the exact same pattern `URLCherryResolver.resolveCandidates` and
    /// `InstagramSourceEnricher`'s optional thumbnail step already use.
    private static func optionalOriginalsUpgrade(for imageURL: URL) async -> URL? {
        guard let candidateURL = originalsUpgradeURL(for: imageURL) else { return nil }
        return await withTaskGroup(of: URL?.self) { group in
            group.addTask { await validateUpgrade(candidateURL) }
            group.addTask {
                try? await Task.sleep(for: originalsUpgradeTimeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// The pure, network-free half: does `imageURL` belong to a
    /// recognized *faithful-composition* size bucket, and if so, what's
    /// its `/originals/` sibling? Deliberately a narrow allowlist
    /// (`236x`/`474x`/`564x`/`736x` only) rather than "any size-shaped
    /// path segment" — Pinterest's thumbnail (`60x60`, `136x136`) and
    /// social-card (`600x315`) crops are NOT in this set, so they're
    /// never touched, matching Section 3 exactly.
    static func originalsUpgradeURL(for imageURL: URL) -> URL? {
        guard let host = imageURL.host?.lowercased(), host == "i.pinimg.com" else { return nil }
        let recognizedFaithfulSizeBuckets: Set<String> = ["236x", "474x", "564x", "736x"]
        let components = imageURL.pathComponents
        guard components.count > 1, recognizedFaithfulSizeBuckets.contains(components[1]) else { return nil }
        var rebuilt = components
        rebuilt[1] = "originals"
        var urlComponents = URLComponents(url: imageURL, resolvingAgainstBaseURL: false)
        urlComponents?.path = "/" + rebuilt.dropFirst().joined(separator: "/")
        return urlComponents?.url
    }

    /// Full validation of the candidate `/originals/` URL: HTTP success,
    /// decodable bytes, positive real dimensions. `nil` on any failure —
    /// the caller always has the already-valid, un-upgraded `og:image`
    /// URL to fall back to.
    private static func validateUpgrade(_ candidateURL: URL) async -> URL? {
        guard let (data, response) = try? await URLSession.shared.data(from: candidateURL),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        guard let pixelSize = ImageDecoding.pixelSize(ofData: data),
              pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        return candidateURL
    }

    // MARK: - Meta tag extraction
    //
    // Pinterest's real, confirmed attribute order is the REVERSE of
    // Instagram's — `<meta content="..." data-app="true" name="og:x"
    // property="og:x"/>`, `content` first — confirmed directly against
    // the real Pin page during Candidate Quality 01's recon.

    static func metaContent(property: String, in html: String) -> String? {
        let escapedProperty = NSRegularExpression.escapedPattern(for: property)
        let pattern = "<meta\\s+content=[\"']([^\"']*)[\"'][^>]*\\bproperty=[\"']\(escapedProperty)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    enum EnrichmentError: Error {
        case badResponse
        case undecodableResponse
        case noRepresentativeImage
    }
}
