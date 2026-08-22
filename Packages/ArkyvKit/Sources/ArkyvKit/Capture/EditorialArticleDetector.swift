import Foundation

/// Editorial Cover V1: standards-first "is this page an article" signal —
/// evidence-backed, not a domain allowlist. Editorial Eden Recon 01 traced
/// 14 real editorial pages; Link Cherry Title Quality Repair 01 confirmed
/// JSON-LD `headline` is clean in every case it's present. This type reuses
/// that same evidence to answer two separate questions: (1) is this
/// content editorial at all, (2) if so, is there a cleaner headline than
/// whatever the generic `LPMetadataProvider` path would otherwise store.
///
/// A completely separate fetch/parse from `ProductPageCandidateSource` —
/// touching ecommerce candidate logic was explicitly out of scope for this
/// milestone, so nothing here is shared with it, matching the existing
/// precedent that Instagram/Pinterest's enrichers each already have their
/// own independent HTML-fetch/meta-parsing code with no shared utility.
/// The real cost of this is one extra page-HTML fetch for generic/long-
/// tail URL saves — the same order of cost `ProductPageCandidateSource`
/// already incurs unconditionally today for the same class of URL.
///
/// Detection order, both confirmed against real pages (Editorial Eden
/// Recon 01 fixtures) with zero false positives against 5 real ecommerce
/// pages (Darc Sport, Gymshark, Allbirds, Nike, Vibecrafts — none carry
/// `Article`/`NewsArticle`/`BlogPosting` JSON-LD or `og:type="article"`):
///   1. JSON-LD `@type` of `Article`, `NewsArticle`, or `BlogPosting` —
///      covers 11 of 14 real recon pages, headline "clean" in all 11.
///   2. `og:type="article"` fallback for the pages with no JSON-LD at all
///      but a real Open Graph article signal (confirmed real case: Real
///      Life's "Roving Eyes"). Doesn't supply a headline override — only
///      JSON-LD's own `headline` field is trusted for that.
/// Pages with neither signal (confirmed real cases: It's Nice That,
/// National Geographic's client-rendered photo gallery) are correctly
/// left unclassified — not a bug, a page that genuinely doesn't publish
/// article-shaped structured data.
/// Narrow seam so `URLCherryResolver` is testable without hitting the
/// real network — same shape as `LinkMetadataFetching` over
/// `LPMetadataProvider` and `CandidateImageSource` over
/// `ProductPageCandidateSource`: one real conformer
/// (`EditorialArticleDetector`), one fake for tests.
public protocol ArticleDetecting: Sendable {
    func detect(for url: URL) async -> EditorialSignal?
}

public struct EditorialArticleDetector: ArticleDetecting, Sendable {
    public init() {}

    private static let articleTypes: Set<String> = ["Article", "NewsArticle", "BlogPosting"]

    /// `nil` means "no editorial signal found" — the caller's existing
    /// generic-title/generic-image behavior is completely unaffected.
    public func detect(for url: URL) async -> EditorialSignal? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }

        if let headline = Self.jsonLDArticleHeadline(in: html) {
            return EditorialSignal(headline: headline)
        }
        if Self.hasArticleOpenGraphType(html) {
            return EditorialSignal(headline: nil)
        }
        return nil
    }

    // MARK: - JSON-LD Article/NewsArticle/BlogPosting

    static func jsonLDArticleHeadline(in html: String) -> String? {
        for block in jsonLDBlocks(in: html) {
            guard let data = block.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            for object in flattenToObjects(json) {
                guard isArticleType(object["@type"]) else { continue }
                if let headline = object["headline"] as? String {
                    let trimmed = headline.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    return decodeHTMLEntities(trimmed)
                }
            }
        }
        return nil
    }

    private static func isArticleType(_ value: Any?) -> Bool {
        if let type = value as? String { return articleTypes.contains(type) }
        if let types = value as? [String] { return types.contains { articleTypes.contains($0) } }
        return false
    }

    /// Same array/`@graph` flattening shape `ProductPageCandidateSource`
    /// uses for `Product`/`ProductGroup` — duplicated rather than shared,
    /// see this type's own doc comment for why.
    private static func flattenToObjects(_ json: Any) -> [[String: Any]] {
        if let object = json as? [String: Any] {
            if let graph = object["@graph"] as? [Any] {
                return graph.compactMap { $0 as? [String: Any] }
            }
            return [object]
        }
        if let array = json as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }
        return []
    }

    private static func jsonLDBlocks(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<script[^>]*type=["']application/ld\+json["'][^>]*>(.*?)</script>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return [] }
        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        return matches.compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return nsHTML.substring(with: match.range(at: 1))
        }
    }

    // MARK: - og:type fallback

    /// Real evidence (Editorial Eden Recon 01) that this fallback earns
    /// its place rather than just approximating JSON-LD: Real Life's
    /// "Roving Eyes" has NO JSON-LD at all, but a real
    /// `<meta property="og:type" content="article">` tag — without this
    /// fallback that page would never be classified as editorial despite
    /// being a genuine article. Attribute order varies by site (the same
    /// divergence already documented between Instagram and Pinterest),
    /// so both orders are tried.
    static func hasArticleOpenGraphType(_ html: String) -> Bool {
        let patterns = [
            #"<meta[^>]*property=["']og:type["'][^>]*content=["']article["']"#,
            #"<meta[^>]*content=["']article["'][^>]*property=["']og:type["']"#,
        ]
        for pattern in patterns {
            if html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Entity decoding

    /// Same shape as `InstagramSourceEnricher.decodeHTMLEntities`,
    /// duplicated not shared (see this type's own doc comment) — plus a
    /// wider named-entity table, evidence-backed by real headlines this
    /// detector actually hit during verification: Colossal's headline
    /// arrives as the numeric `"...This Year&#8217;s Ocean Art..."`, but
    /// Wallpaper's and Magnum's real JSON-LD headlines instead use the
    /// literal NAMED entities `&rsquo;` (both) — undecoded by Instagram's
    /// narrower table, which this milestone never had a real headline
    /// exercising that gap.
    static func decodeHTMLEntities(_ string: String) -> String {
        var result = string
        let named: [(String, String)] = [
            ("&quot;", "\""), ("&amp;", "&"), ("&apos;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "),
            ("&rsquo;", "\u{2019}"), ("&lsquo;", "\u{2018}"),
            ("&rdquo;", "\u{201D}"), ("&ldquo;", "\u{201C}"),
            ("&mdash;", "\u{2014}"), ("&ndash;", "\u{2013}"),
            ("&hellip;", "\u{2026}"),
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
}

/// `headline` is only ever populated from a real JSON-LD `Article`-family
/// `headline` field — never a guess, never derived from the `og:type`
/// fallback alone.
public struct EditorialSignal: Sendable {
    public let headline: String?
}
