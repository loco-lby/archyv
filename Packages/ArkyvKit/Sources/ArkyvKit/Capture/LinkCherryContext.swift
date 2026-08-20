import Foundation

/// Context + Single-Folder UX 01: "Link Cherries need a label, not a
/// card." Pure, source-agnostic rules for deciding what quiet provenance
/// text (if any) Item Detail should show for a Cherry that came from a
/// URL — never a per-source adapter (no Pinterest/Instagram/YouTube
/// special-casing), derived from six real stored titles captured during
/// URL → Cherry's physical QA passes.
public enum LinkCherryContext {
    /// Real page/product titles observed this far are well under this;
    /// Pinterest's real stored title was 118 characters of pipe-separated
    /// keyword stuffing — a generic, source-agnostic proxy for "this
    /// isn't really a title."
    private static let maximumTitleLength = 100
    /// Below this, checking whether the title merely contains the site's
    /// own name risks false positives on short/common words (e.g. a
    /// two-letter TLD-adjacent label) — real registrable names in the six
    /// captured sources are all comfortably longer than this.
    private static let minimumMeaningfulNameLength = 4

    /// The human-readable host to display for `sourceURL`, or `nil` if
    /// there's no usable URL at all (`nil`/empty/unparsable) — the single
    /// signal that decides whether a Cherry gets ANY link context in Item
    /// Detail. `www.` is stripped since it adds no information; the rest
    /// of the host is shown exactly as-is (no other normalization) —
    /// `studio2am.co`, `shop.darcsport.com`, `pin.it`.
    public static func displayDomain(sourceURL: String?) -> String? {
        guard let sourceURL,
              let url = URL(string: sourceURL),
              var host = url.host,
              !host.isEmpty else { return nil }
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host
    }

    /// The smallest reasonable "is this title worth confidently showing"
    /// rule: non-empty, not excessively long, not literally the domain,
    /// and not merely the site restating its own name back (Instagram's
    /// real stored title, "<name> Documented on Instagram," is a generic
    /// per-post template with zero post-specific information — a title
    /// containing the site's own registrable name is a decent, fully
    /// generic proxy for "this describes the platform, not the content").
    /// Returns `nil` — meaning Item Detail omits the title line entirely,
    /// never shows a fallback string — whenever any check fails, so a
    /// bad/unusable title is silently absent rather than confidently
    /// wrong. Requires a usable domain first, same as `displayDomain`.
    public static func displayTitle(title: String?, sourceURL: String?) -> String? {
        guard let domain = displayDomain(sourceURL: sourceURL) else { return nil }
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumTitleLength else { return nil }
        guard trimmed.caseInsensitiveCompare(domain) != .orderedSame else { return nil }
        if let name = registrableName(fromHost: domain),
           name.count >= minimumMeaningfulNameLength,
           trimmed.range(of: name, options: .caseInsensitive) != nil {
            return nil
        }
        return trimmed
    }

    /// A rough, non-PSL-aware "second-to-last label" heuristic —
    /// `studio2am.co` → `studio2am`, `shop.darcsport.com` → `darcsport`,
    /// `pin.it` → `pin`. Good enough for the one thing this file uses it
    /// for (a generic-template detector), not a general domain-parsing
    /// utility.
    private static func registrableName(fromHost host: String) -> String? {
        let labels = host.split(separator: ".")
        guard labels.count >= 2 else { return nil }
        return String(labels[labels.count - 2])
    }
}
