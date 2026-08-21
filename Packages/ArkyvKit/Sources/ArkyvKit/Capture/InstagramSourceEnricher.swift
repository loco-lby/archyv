import Foundation

/// Instagram Link Cherry V1 01: title/image enrichment ONLY — Instagram
/// is deliberately a `SourceEnricher`, never a `CandidateImageSource`.
///
/// Instagram Link Cherry Recon 01 established, against the real public
/// HTTP response for a real carousel URL, that there is exactly ONE
/// server-selected representative image per post (its own `efg` hint
/// decodes to `FEED`/`CAROUSEL_ITEM`/`CLIPS.best_image_urlgen` depending
/// on post type) — no public carousel media array exists anywhere in the
/// unauthenticated response, and `img_index` is never honored
/// server-side at all: requesting the same post with `img_index` omitted,
/// `0`, `1`, `2`, and `3` returned a byte-identical `og:image` every
/// time, and the page's own `<link rel="canonical">` drops the query
/// string entirely. There is nothing here to build a candidate list
/// FROM — wiring Instagram into the ecommerce candidate-image swiper
/// would present a false choice, not a real one, so this deliberately
/// does not.
///
/// **Product invariant — enrichment is additive, never a downgrade:** a
/// `SourceEnricher`'s image unconditionally replaces the generic
/// candidate (see `URLCherryResolver.attemptResolveCandidates`), so this
/// type must never hand back a worse visual than generic resolution
/// would have produced on its own. For Instagram specifically this is
/// not just unlikely but structurally impossible to violate: the real
/// carousel post's HTML (Instagram Link Cherry Recon 01/Instagram V1 01)
/// contains exactly ONE `<meta property="og:image">` tag — confirmed by
/// direct count, not assumed — and `twitter:image` resolves to the
/// identical URL. `LPMetadataProvider` (the generic path) is itself an
/// Open Graph reader; it has no second, better image anywhere in the
/// same public document to prefer instead. Enriched and generic
/// therefore always resolve to the exact same bytes for Instagram —
/// this enricher cannot downgrade the visual because there is only ever
/// one visual to choose from either way. What it fixes is TITLE
/// quality, never image quality. Instagram's
/// `og:title`/`og:description` embed a real caption behind a boilerplate
/// prefix — `"<Account Name> on Instagram: "<caption>""` /
/// `"<handle> on <date>: "<caption>"."` — that literally contains the
/// word "Instagram," and `LinkCherryContext.displayTitle`'s existing
/// generic filter (Context + Single-Folder UX 01) already suppresses ANY
/// title containing the source's own registrable name as a boilerplate-
/// template detector. Left alone, that means a genuinely useful caption
/// gets thrown away at display time purely because of Instagram's own
/// prefix wording, not because the caption itself is generic. This
/// enricher strips that prefix at capture time so a real caption
/// survives the existing generic filter instead of becoming collateral
/// damage from it. When no real caption exists at all (confirmed during
/// recon: a Reel's `og:description` degrades to a plain engagement-stats
/// sentence, "70 likes, 6 comments - handle on date," with nothing
/// quoted to extract), title is simply `nil` — never a fabricated or
/// boilerplate-only stand-in.
///
/// **Method:** a single, ordinary public HTTP GET of the post/reel URL —
/// the same class of technique `ProductPageCandidateSource` already uses
/// for JSON-LD (reading `<meta>` tags a page already publishes for
/// programmatic/social-preview consumption, never DOM-driving, never a
/// private/undocumented endpoint). Recon confirmed this returns real
/// Open Graph data with no login wall and no dependency on User-Agent
/// spoofing — the same public response `LPMetadataProvider` itself
/// effectively reads.
public struct InstagramSourceEnricher: SourceEnricher, Sendable {
    public init() {}

    public func matches(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let isInstagramHost = host == "instagram.com" || host.hasSuffix(".instagram.com")
        guard isInstagramHost else { return false }
        let path = url.path
        return path.hasPrefix("/p/") || path.hasPrefix("/reel/") || path.hasPrefix("/reels/")
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
        // Never manipulate Instagram's own crop/derivative — used exactly
        // as supplied. `og:description` carries the real caption most
        // reliably (confirmed during recon); `og:title` is tried as a
        // fallback since it follows the same "<prefix>: "<caption>""
        // shape when present.
        let title = Self.extractCaption(fromDescription: Self.metaContent(property: "og:description", in: html))
            ?? Self.extractCaption(fromDescription: Self.metaContent(property: "og:title", in: html))
        // Instagram Optional Thumbnail Enhancement 01: `imageURL` above is
        // already a fully valid, independently-saveable result — this can
        // only ever replace it with something better, never block or fail
        // resolution. See `optionalUpgradedThumbnailURL`'s own doc comment.
        let finalImageURL = await Self.optionalUpgradedThumbnailURL(for: url) ?? imageURL
        return EnrichedLinkContent(title: title, imageURL: finalImageURL)
    }

    // MARK: - Optional thumbnail enhancement (bonus, never a dependency)

    /// Instagram Visual Asset Forensics 01 proved `og:image` is frequently
    /// a hard square crop (photos/carousels) or has a play-button icon
    /// baked directly into its pixels (Reels). Instagram Optional
    /// Thumbnail Feasibility 01 then proved, against 7 real posts (2
    /// photos, 3 Reels, 2 carousels), that `www.instagram.com/api/v1/
    /// oembed/`'s own `thumbnail_url` is a different, better-or-equal
    /// derivative in every single case — no login/cookies/auth required,
    /// an ordinary unauthenticated GET, median ~0.27s, worst observed
    /// ~0.71s. It remains an undocumented, first-party endpoint, not
    /// something to depend on — so this is wired in as strictly optional:
    /// `enrich(_:)` above already has a fully valid, independently-
    /// saveable `imageURL` before this ever runs. This function can only
    /// ever IMPROVE that result or leave it untouched — it never throws,
    /// never retries, and is bounded by its own dedicated timeout
    /// (`optionalThumbnailTimeout`) completely independent of
    /// `URLCherryResolver`'s own overall resolution budget. Racing it
    /// against a timeout task is the exact same `withTaskGroup` pattern
    /// `URLCherryResolver.resolveCandidates` already uses for its own
    /// timeout, not new concurrency machinery.
    private static let optionalThumbnailTimeout: Duration = .milliseconds(2500)

    private static func optionalUpgradedThumbnailURL(for postURL: URL) async -> URL? {
        await withTaskGroup(of: URL?.self) { group in
            group.addTask { await fetchValidatedThumbnail(for: postURL) }
            group.addTask {
                try? await Task.sleep(for: optionalThumbnailTimeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// The acceptance rule, deliberately boring (Instagram Optional
    /// Thumbnail Enhancement 01, Section 3): response succeeds, a
    /// `thumbnail_url` is present with positive reported dimensions, the
    /// thumbnail itself downloads successfully, and its bytes actually
    /// decode with positive real dimensions. No pixel-area/aspect-ratio/
    /// perceptual comparison against the `og:image` candidate — Feasibility
    /// 01's own real sample showed a dimension-comparison rule would have
    /// wrongly rejected a legitimately better carousel thumbnail. `nil` on
    /// ANY failure at ANY stage — never partially applies a result.
    private static func fetchValidatedThumbnail(for postURL: URL) async -> URL? {
        guard var components = URLComponents(string: "https://www.instagram.com/api/v1/oembed/") else { return nil }
        components.queryItems = [URLQueryItem(name: "url", value: postURL.absoluteString)]
        guard let endpoint = components.url else { return nil }

        guard let (data, response) = try? await URLSession.shared.data(from: endpoint),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let thumbnailURL = Self.validatedThumbnailURL(fromOEmbedJSON: data) else { return nil }

        guard let (imageData, imageResponse) = try? await URLSession.shared.data(from: thumbnailURL),
              let imageHTTP = imageResponse as? HTTPURLResponse, imageHTTP.statusCode == 200 else { return nil }
        guard let pixelSize = ImageDecoding.pixelSize(ofData: imageData),
              pixelSize.width > 0, pixelSize.height > 0 else { return nil }

        return thumbnailURL
    }

    /// The pure, network-free half of the acceptance rule — decodes the
    /// oEmbed JSON and checks for a present `thumbnail_url` with positive
    /// *reported* dimensions. Split out from `fetchValidatedThumbnail` so
    /// malformed-JSON and missing-thumbnail_url cases (unlike the real
    /// HTTP/timeout/decode-failure cases, which need the real network and
    /// are verified live on Device A, same as `enrich(_:)` itself) can be
    /// exercised directly, deterministically, with no network at all.
    static func validatedThumbnailURL(fromOEmbedJSON data: Data) -> URL? {
        guard let decoded = try? JSONDecoder().decode(OEmbedResponse.self, from: data),
              let thumbnailURLString = decoded.thumbnailURL,
              let thumbnailURL = URL(string: thumbnailURLString),
              let reportedWidth = decoded.thumbnailWidth, reportedWidth > 0,
              let reportedHeight = decoded.thumbnailHeight, reportedHeight > 0 else { return nil }
        return thumbnailURL
    }

    private struct OEmbedResponse: Decodable {
        let thumbnailURL: String?
        let thumbnailWidth: Int?
        let thumbnailHeight: Int?

        enum CodingKeys: String, CodingKey {
            case thumbnailURL = "thumbnail_url"
            case thumbnailWidth = "thumbnail_width"
            case thumbnailHeight = "thumbnail_height"
        }
    }

    // MARK: - Caption extraction

    /// Instagram's public `og:description`/`og:title` are consistently
    /// shaped `"<prefix>: "<caption>"."` when a real caption exists —
    /// confirmed against a real carousel post during Recon 01 — but
    /// degrade to a plain sentence with no quoted section at all for a
    /// Reel with nothing worth surfacing ("70 likes, 6 comments -
    /// <handle> on <date>"). Looking for a colon immediately followed by
    /// a double-quoted section is a simple, robust way to tell those two
    /// shapes apart without trying to parse the date/handle prefix
    /// itself, which isn't load-bearing for anything Cherries needs.
    static func extractCaption(fromDescription description: String?) -> String? {
        guard let description else { return nil }
        guard let regex = try? NSRegularExpression(pattern: #":\s*"(.+)"\.?\s*$"#, options: [.dotMatchesLineSeparators]) else { return nil }
        let ns = description as NSString
        guard let match = regex.firstMatch(in: description, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        let caption = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        return caption.isEmpty ? nil : caption
    }

    // MARK: - Meta tag extraction

    /// Matches Instagram's real, confirmed attribute order
    /// (`<meta property="og:x" content="...">`) — narrow by design, not a
    /// general-purpose HTML meta-tag parser.
    static func metaContent(property: String, in html: String) -> String? {
        let escapedProperty = NSRegularExpression.escapedPattern(for: property)
        let pattern = "<meta\\s+property=[\"']\(escapedProperty)[\"']\\s+content=[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return decodeHTMLEntities(ns.substring(with: match.range(at: 1)))
    }

    /// A meta tag's `content` attribute arrives HTML-entity-encoded
    /// (`&quot;`, `&#x2014;`, `&amp;`) — a small, explicit table plus
    /// numeric character references (`&#39;`/`&#x2014;`), deliberately
    /// NOT `NSAttributedString`'s HTML document reader: that API's HTML
    /// parser has a well-known main-thread/run-loop requirement that
    /// doesn't fit an `async` enrichment path safely, and this only ever
    /// needs to decode a short extracted snippet, not general HTML.
    static func decodeHTMLEntities(_ string: String) -> String {
        var result = string
        let named: [(String, String)] = [
            ("&quot;", "\""), ("&amp;", "&"), ("&apos;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "),
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        guard let regex = try? NSRegularExpression(pattern: #"&#(x[0-9A-Fa-f]+|[0-9]+);"#) else { return result }
        let ns = result as NSString
        var output = ""
        var lastEnd = 0
        for match in regex.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            let code = ns.substring(with: match.range(at: 1))
            let scalarValue: UInt32?
            if code.hasPrefix("x") || code.hasPrefix("X") {
                scalarValue = UInt32(code.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(code)
            }
            if let scalarValue, let scalar = Unicode.Scalar(scalarValue) {
                output.unicodeScalars.append(scalar)
            }
            lastEnd = match.range.location + match.range.length
        }
        output += ns.substring(from: lastEnd)
        return output
    }

    enum EnrichmentError: Error {
        case badResponse
        case undecodableResponse
        case noRepresentativeImage
    }
}
