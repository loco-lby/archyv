import Foundation

/// Link Cherry Visual Picker 01, Part C: the smallest ecommerce
/// image-candidate enrichment justified by real evidence (Darc Sport's
/// real product page, inspected during Priority Source Intelligence 01).
/// Standards first: `schema.org` `Product.image` via JSON-LD, the
/// documented, cross-platform mechanism. Only falls back to a narrow,
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
    public func matches(_ url: URL) -> Bool {
        url.scheme == "http" || url.scheme == "https"
    }

    public func candidateImageURLs(for url: URL) async throws -> [URL] {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [] }

        let jsonLDImages = Self.productImagesFromJSONLD(html: html, pageURL: url)
        if jsonLDImages.count >= 2 {
            return jsonLDImages
        }
        let shopifyImages = Self.shopifyGalleryImages(html: html, pageURL: url)
        guard !shopifyImages.isEmpty else { return jsonLDImages }

        var seen = Set<String>()
        var merged: [URL] = []
        for candidateURL in jsonLDImages + shopifyImages {
            let key = CandidateAssembly.dedupeKey(for: candidateURL)
            if seen.insert(key).inserted {
                merged.append(candidateURL)
            }
        }
        return merged
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

    private static func isProductType(_ value: Any?) -> Bool {
        if let type = value as? String { return type == "Product" }
        if let types = value as? [String] { return types.contains("Product") }
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
