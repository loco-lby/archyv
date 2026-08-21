import Foundation

/// Link Cherry Visual Picker 01, Part C: the smallest ecommerce
/// image-candidate enrichment justified by real evidence (Darc Sport's
/// real product page, inspected during Priority Source Intelligence 01).
/// Standards first: `schema.org` `Product`/`ProductGroup` `.image` via
/// JSON-LD (Ecommerce ProductGroup Support 01 added `ProductGroup`
/// recognition — see `isProductType`'s own doc comment), the documented,
/// cross-platform mechanism. Only falls back to a narrow,
/// empirically-verified Shopify page-data convention (a `"images":[...]`
/// array Shopify's default themes embed inline for their own theme JS)
/// when JSON-LD alone doesn't establish at least two trustworthy images
/// — never instead of it, never for non-Shopify pages, and never load-
/// bearing: if both are absent or malformed, this source simply
/// contributes zero additional candidates and generic resolution is
/// completely unaffected.
///
/// Deliberately NOT a DOM scraper: both mechanisms parse structured,
/// machine-readable data the page itself already publishes for
/// programmatic consumption (JSON-LD is literally standards-based;
/// the Shopify array is a stable, widely-relied-upon theme convention),
/// never arbitrary `<img>` tags — so logos, favicons, review avatars,
/// and recommendation-widget images are structurally excluded, not
/// filtered after the fact.
public struct ProductPageCandidateSource: CandidateImageSource, Sendable {
    public init() {}

    /// Applies broadly to any http/https URL — there's no reliable way
    /// to know a page carries `Product` structured data without
    /// fetching it, so "no Product schema found" is handled as zero
    /// candidates inside `candidateImageURLs`, never a matching failure
    /// here.
    ///
    /// Pinterest Link Cherry V1 01: Pinterest Candidate Quality 01's
    /// forensic audit proved, against 4 real Pins (1 tagged `Product`, 3
    /// `SocialMediaPosting`), that Pinterest's own `Product.image` JSON-LD
    /// array is never a genuine multi-photo gallery — every entry across
    /// every Pin tested was Pinterest's own CDN size/crop-bucket
    /// convention for ONE underlying photo (resolution variants, a
    /// square thumbnail crop, a wide social-card crop), not a Pin
    /// author's intentional alternate images. Pinterest's own data model
    /// has no multi-image-per-Pin concept at all — unlike a real
    /// ecommerce product page (Darc Sport) or an Instagram carousel,
    /// there is nothing here for a candidate picker to legitimately
    /// offer. Excluded by host, not by page content, since "carries
    /// `Product` JSON-LD" is exactly the signal that was producing the
    /// false positive — a content-shape check couldn't distinguish
    /// Pinterest's case from a real one.
    public func matches(_ url: URL) -> Bool {
        guard url.scheme == "http" || url.scheme == "https" else { return false }
        guard let host = url.host?.lowercased() else { return true }
        return !Self.isPinterestHost(host)
    }

    private static func isPinterestHost(_ host: String) -> Bool {
        host == "pinterest.com" || host.hasSuffix(".pinterest.com")
            || host == "pin.it" || host.hasSuffix(".pin.it")
    }

    public func candidateImageURLs(for url: URL) async throws -> [URL] {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [] }

        return Self.candidateImages(html: html, pageURL: url)
    }

    /// The full pure pipeline `candidateImageURLs(for:)` runs after
    /// fetching the page — exposed separately (no network) so tests can
    /// exercise it directly against real captured HTML fixtures, the
    /// same split every other network-touching source/enricher in this
    /// codebase already uses.
    static func candidateImages(html: String, pageURL: URL) -> [URL] {
        excludingPageOwnPrimaryImage(rawCandidateImages(html: html, pageURL: pageURL), html: html, pageURL: pageURL)
    }

    private static func rawCandidateImages(html: String, pageURL: URL) -> [URL] {
        let jsonLDImages = productImagesFromJSONLD(html: html, pageURL: pageURL)
        // The `>= 2` threshold reads the RAW count — "did JSON-LD alone
        // establish at least two trustworthy images" — not the deduped
        // count, so a page whose JSON-LD supplies several resolution
        // variants of one photo (Allbirds' real shape: a `width=`
        // query-parameter family) still correctly skips the Shopify
        // fallback; only the returned list itself is deduped.
        if jsonLDImages.count >= 2 {
            return Self.dedupingByNormalizedIdentity(jsonLDImages)
        }
        let shopifyImages = shopifyGalleryImages(html: html, pageURL: pageURL)
        guard !shopifyImages.isEmpty else { return jsonLDImages }
        return Self.dedupingByNormalizedIdentity(jsonLDImages + shopifyImages)
    }

    /// Ecommerce Cross-Source Candidate Dedupe 01: real Allbirds JSON-LD
    /// exposed a gap this milestone's forensic tracing found — multiple
    /// entries *within the same* `ProductGroup.image` array (four
    /// `width=100/300/600/900` resolution variants of one photo) were
    /// never deduped against EACH OTHER, only ever against a separate
    /// Shopify-fallback array. Applied uniformly wherever a candidate
    /// list is returned, using the exact same `dedupeKey` normalization
    /// (ignores query string and CDN filename-suffix resolution
    /// variants) already relied on elsewhere in this type.
    private static func dedupingByNormalizedIdentity(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            if seen.insert(CandidateAssembly.dedupeKey(for: url)).inserted {
                result.append(url)
            }
        }
        return result
    }

    /// Ecommerce Cross-Source Candidate Dedupe 01: candidate 0 (the
    /// generic `"primary"` candidate `URLCherryResolver` always produces
    /// first) is Apple's `LPMetadataProvider` result, handed back as raw
    /// bytes via an `NSItemProvider` — `LPLinkMetadata` has no accessor
    /// for the image's own URL, so a direct URL (or even a cheap-to-fetch
    /// byte hash for every additional candidate) comparison against
    /// candidate 0 isn't available here.
    ///
    /// Forensic tracing (real Gymshark + Allbirds product pages) proved
    /// `LPMetadataProvider`'s choice is, in every real case tested,
    /// exactly the page's own `og:image` — that's the whole point of
    /// Open Graph tags, and this source already fetches the page HTML
    /// to read JSON-LD, so reading `og:image` too costs nothing extra.
    /// Filtering any additional candidate that normalizes (via the same
    /// `CandidateAssembly.dedupeKey` already used for intra-source
    /// dedup) to that URL is therefore a practical, deterministic proxy
    /// for "the same image candidate 0 already is" — not a byte
    /// comparison, but not a guess either.
    ///
    /// This is why BOTH real duplicates collapse correctly even though
    /// they fail differently: Gymshark's is byte-identical (only
    /// `http`/`https` differs — `dedupeKey` never even looks at scheme);
    /// Allbirds' is NOT byte-identical (same path, only a `width=` query
    /// parameter differs, so the two files are genuinely different
    /// resolutions/bytes — a byte-hash comparison would have missed it,
    /// but `dedupeKey` already ignores the query string). A real
    /// multi-photo gallery (Darc Sport, Vibecrafts) routinely lists its
    /// own cover photo as gallery entry 1 — this filter removes exactly
    /// that one redundant entry and leaves every genuinely different
    /// photo untouched; it dedupes by normalized image identity only,
    /// never by product/SKU/dimension similarity.
    private static func excludingPageOwnPrimaryImage(_ images: [URL], html: String, pageURL: URL) -> [URL] {
        guard let primaryImageURL = pageOGImageURL(html: html, pageURL: pageURL) else { return images }
        let primaryKey = CandidateAssembly.dedupeKey(for: primaryImageURL)
        return images.filter { CandidateAssembly.dedupeKey(for: $0) != primaryKey }
    }

    /// `og:image`'s real attribute order varies by store (confirmed
    /// `property`-before-`content` on some real ecommerce pages, the
    /// reverse on others — the same divergence already documented
    /// between `InstagramSourceEnricher` and `PinterestSourceEnricher`);
    /// tries both.
    static func pageOGImageURL(html: String, pageURL: URL) -> URL? {
        let patterns = [
            #"<meta[^>]*property=["']og:image["'][^>]*content=["']([^"']*)["']"#,
            #"<meta[^>]*content=["']([^"']*)["'][^>]*property=["']og:image["']"#,
        ]
        let nsHTML = html as NSString
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            if let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: nsHTML.length)), match.numberOfRanges > 1 {
                let raw = nsHTML.substring(with: match.range(at: 1))
                return URL(string: raw, relativeTo: pageURL)?.absoluteURL
            }
        }
        return nil
    }

    // MARK: - schema.org JSON-LD Product.image

    static func productImagesFromJSONLD(html: String, pageURL: URL) -> [URL] {
        var images: [URL] = []
        for block in jsonLDBlocks(in: html) {
            guard let data = block.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            for object in flattenToObjects(json) {
                guard isProductType(object["@type"]) else { continue }
                images.append(contentsOf: imageURLs(from: object["image"], relativeTo: pageURL))
            }
        }
        return images
    }

    /// Ecommerce ProductGroup Support 01: Ecommerce Link Cherry Recon 02
    /// found `ProductGroup` — schema.org's dedicated type for "a product
    /// with variants" — on 5 of 6 real, successfully-fetched ecommerce
    /// pages (Studio2am, Gymshark, Vibecrafts, Nike, Allbirds); only the
    /// original Darc Sport proof case used the older bare `Product`.
    /// `ProductGroup` was invisible to this check before, so every one of
    /// those pages silently contributed zero candidates — not a crash,
    /// not wrong output, just missed coverage. `ProductGroup.image` is
    /// read through the exact same `imageURLs(from:)` below `Product`
    /// already used — schema.org defines both types' `image` property
    /// identically (string/array/`ImageObject`), confirmed against the
    /// real captured fixtures, so no second parser was needed. This is
    /// deliberately ONLY a type-recognition change — no `hasVariant`,
    /// `variesBy`, or `offers.@id` handling yet; see this milestone's own
    /// scope boundary.
    private static func isProductType(_ value: Any?) -> Bool {
        if let type = value as? String { return type == "Product" || type == "ProductGroup" }
        if let types = value as? [String] { return types.contains("Product") || types.contains("ProductGroup") }
        return false
    }

    /// `image` may be a bare string, an array of strings, an
    /// `ImageObject` dictionary (`{"url"/"contentUrl": "..."}`), or an
    /// array mixing either shape — schema.org permits all of these.
    private static func imageURLs(from value: Any?, relativeTo pageURL: URL) -> [URL] {
        func resolve(_ string: String) -> URL? { URL(string: string, relativeTo: pageURL)?.absoluteURL }
        switch value {
        case let string as String:
            return [resolve(string)].compactMap { $0 }
        case let array as [Any]:
            return array.flatMap { imageURLs(from: $0, relativeTo: pageURL) }
        case let object as [String: Any]:
            if let urlString = (object["url"] as? String) ?? (object["contentUrl"] as? String) {
                return [resolve(urlString)].compactMap { $0 }
            }
            return []
        default:
            return []
        }
    }

    /// A JSON-LD value can itself be an array of top-level objects (a
    /// `@graph`-style page) or a single object — this flattens both
    /// shapes to a uniform list of `[String: Any]` objects to scan for
    /// `@type == "Product"`.
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

    // MARK: - Narrow Shopify gallery fallback

    /// Shopify's default themes commonly embed the full product-image
    /// gallery as an inline `"images":[...]` JSON array (protocol-
    /// relative URLs, e.g. `"//shop.example.com/cdn/.../photo.jpg"`) for
    /// their own theme JavaScript to consume — empirically confirmed
    /// present on the real Darc Sport product page during Priority
    /// Source Intelligence 01's reconnaissance. Not a formal standard;
    /// used only as the documented fallback this type's own doc comment
    /// describes, and any parse failure here just yields zero images,
    /// never an error.
    static func shopifyGalleryImages(html: String, pageURL: URL) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: #""images"\s*:\s*(\[[^\]]*\])"#) else { return [] }
        let nsHTML = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: nsHTML.length)),
              match.numberOfRanges > 1 else { return [] }
        let arrayLiteral = nsHTML.substring(with: match.range(at: 1))
        guard let data = arrayLiteral.data(using: .utf8),
              let strings = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return strings.compactMap { raw -> URL? in
            let normalized = raw.hasPrefix("//") ? "https:\(raw)" : raw
            return URL(string: normalized, relativeTo: pageURL)?.absoluteURL
        }
    }
}
