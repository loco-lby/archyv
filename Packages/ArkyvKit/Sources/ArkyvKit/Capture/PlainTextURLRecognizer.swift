import Foundation

/// Link Cherry Ingestion + Source Semantics 01: the narrowest possible
/// rule for treating a plain-text share as a URL share. Some apps'
/// native Share Sheet (confirmed for YouTube) hand the Share Extension a
/// `public.plain-text` payload instead of a `public.url`-typed one even
/// though the content is nothing but a link — this makes that
/// indistinguishable, downstream, from a genuine URL-typed share, so it
/// can be routed through the exact same `URLCherryResolver` path.
///
/// Deliberately NOT a general link-extractor: a payload with any
/// surrounding text ("Check this out https://example.com") is left
/// alone and falls through to the existing plain-text/note behavior —
/// extracting a URL out of arbitrary prose is a different, much fuzzier
/// problem this milestone explicitly doesn't take on.
public enum PlainTextURLRecognizer {
    /// `text`, trimmed of leading/trailing whitespace, must be *exactly*
    /// one `http`/`https` URL with a host — nothing else. Internal
    /// whitespace anywhere in the trimmed string means this isn't a bare
    /// URL and the caller should treat it as ordinary text.
    public static func recognizedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
