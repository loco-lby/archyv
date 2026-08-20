import Foundation

/// Priority Source Intelligence 01, Part A: fixes two real, evidence-
/// backed YouTube quality problems generic `LPLinkMetadata` cannot —
/// its `title` returns the CHANNEL name ("Max Kent"), not the video
/// title, and its `imageProvider` returns YouTube's own social-card
/// thumbnail with a play-button triangle baked directly into the pixel
/// bytes (confirmed by fetching and visually inspecting the raw image —
/// not a Cherries-rendered overlay, so there was never a UI layer to
/// remove).
///
/// Uses YouTube's public, documented oEmbed endpoint
/// (`https://www.youtube.com/oembed`) — the open oEmbed standard,
/// no API key, no authentication, no private/undocumented endpoint,
/// no scraping. One request returns both the real video title
/// (`"How To Capture Photos That Look Like Paintings"`, confirmed
/// against the real test video — genuinely different from the channel
/// name LPMetadataProvider returns) and a thumbnail URL
/// (`i.ytimg.com/vi/<id>/hqdefault.jpg`) confirmed, by the same direct
/// visual inspection, to have no play-button overlay baked in.
public struct YouTubeOEmbedEnricher: SourceEnricher, Sendable {
    public init() {}

    public func matches(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be"
    }

    public func enrich(_ url: URL) async throws -> EnrichedLinkContent {
        guard var components = URLComponents(string: "https://www.youtube.com/oembed") else {
            throw EnrichmentError.invalidEndpoint
        }
        components.queryItems = [
            URLQueryItem(name: "url", value: url.absoluteString),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let endpoint = components.url else { throw EnrichmentError.invalidEndpoint }

        let (data, response) = try await URLSession.shared.data(from: endpoint)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EnrichmentError.badResponse
        }
        let decoded = try JSONDecoder().decode(OEmbedResponse.self, from: data)
        guard let thumbnailURLString = decoded.thumbnailURL, let thumbnailURL = URL(string: thumbnailURLString) else {
            throw EnrichmentError.noThumbnail
        }
        return EnrichedLinkContent(title: decoded.title, imageURL: thumbnailURL)
    }

    private struct OEmbedResponse: Decodable {
        let title: String?
        let thumbnailURL: String?

        enum CodingKeys: String, CodingKey {
            case title
            case thumbnailURL = "thumbnail_url"
        }
    }

    enum EnrichmentError: Error {
        case invalidEndpoint
        case badResponse
        case noThumbnail
    }
}
