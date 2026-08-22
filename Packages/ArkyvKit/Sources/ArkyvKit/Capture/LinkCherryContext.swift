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
    ///
    /// Link Cherry Title Quality Repair 01: Editorial Eden Recon 01 found
    /// this rule was too aggressive — a title containing the registrable
    /// name ANYWHERE was treated as boilerplate, with no regard for how
    /// much real content sat alongside it. Two real editorial headlines
    /// (Aeon, Nautilus) were silently reduced to no title at all, purely
    /// because their publication's short single-word name happened to
    /// appear literally inside their own ordinary "Headline | Publication"
    /// suffix — the exact convention this whole check exists to see past.
    /// Multi-word publications (Works in Progress, The Point Magazine,
    /// Real Life, Magnum Photos) were never actually protected by
    /// correct reasoning; they only escaped because their registrable
    /// domain label concatenates the brand with no spaces
    /// ("worksinprogress") while the real title renders it with spaces
    /// ("Works in Progress") — a plain substring search can't bridge
    /// that gap. That was luck, not a working rule, and this fix doesn't
    /// rely on it: the answer must be "is this title genuinely
    /// content-free," never "does this title mention the source" — see
    /// `hasSubstantialContentBeforeSourceSuffix`.
    ///
    /// Vice Editorial Title Anomaly 01: that repair only recognized the
    /// registrable name as a TRAILING "Headline | Publication" suffix.
    /// Vice's real JSON-LD headline, "VICE Album Reviews, August 21:
    /// Brandon Flowers, Sam Smith, GB and More," puts the name LEADING
    /// instead — real editorial house style (matching "BuzzFeed
    /// Explains", "WIRED Presents"), not decorative boilerplate — and
    /// was still being wrongly suppressed for want of a separator to
    /// find. See `hasSubstantialContentAfterLeadingSourceName`, the
    /// mirror image of the trailing check.
    public static func displayTitle(title: String?, sourceURL: String?) -> String? {
        guard let domain = displayDomain(sourceURL: sourceURL) else { return nil }
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumTitleLength else { return nil }
        guard trimmed.caseInsensitiveCompare(domain) != .orderedSame else { return nil }
        guard let name = registrableName(fromHost: domain),
              name.count >= minimumMeaningfulNameLength,
              trimmed.range(of: name, options: .caseInsensitive) != nil
        else {
            return trimmed
        }
        // The registrable name appears somewhere in the title — on its
        // own that no longer means "boilerplate" (see doc comment
        // above). Only treat it as harmless publication-suffix tagging,
        // and keep the title, when it sits after a conventional
        // title/publication separator with substantial real content
        // before it. Otherwise this is exactly the shape of Instagram's
        // real "<name> Documented on Instagram" template — the site's
        // name fused directly into a content-free sentence, no
        // separator anywhere — and the original, more cautious
        // suppression still applies.
        if hasSubstantialContentBeforeSourceSuffix(trimmed, sourceName: name) {
            return trimmed
        }
        if hasSubstantialContentAfterLeadingSourceName(trimmed, sourceName: name) {
            return trimmed
        }
        return nil
    }

    /// Real "Headline | Publication" / "Headline - Publication" suffixes
    /// captured this session all use one of these four characters (Aeon
    /// `|`, Nautilus `-`, Real Life `—`, Emergence `–`) — a small,
    /// evidence-backed set, not every possible punctuation mark. `:` is
    /// deliberately excluded: it routinely appears inside a real
    /// headline's own clause (Works in Progress' "Beauty in My Backyard:
    /// ...", ArchDaily's "Building Optimism: Lessons from..."), so
    /// treating it as a suffix boundary would risk cutting a genuine
    /// headline in half.
    private static let titleSuffixSeparators: Set<Character> = ["|", "-", "–", "—"]
    /// The shortest real "headline before the separator" observed this
    /// session (Nautilus: "The New Flight of the Ibis") is 27 characters
    /// — this sits comfortably below every real case while still ruling
    /// out a near-empty prefix (e.g. a bare app/site name immediately
    /// followed by its own suffix, which is exactly the boilerplate
    /// shape this filter exists to catch).
    private static let minimumSuffixPrefixLength = 8

    /// `true` when `sourceName` appears only inside a trailing
    /// "separator + publication" tail, with a substantial headline
    /// before it — the real "Headline | Publication" shape (Aeon,
    /// Nautilus) — rather than fused directly into a content-free
    /// sentence with no separator at all (Instagram's real per-post
    /// template). Uses the LAST separator in the title, matching the
    /// conventional "headline, then a trailing publication tag" reading
    /// order.
    private static func hasSubstantialContentBeforeSourceSuffix(_ trimmed: String, sourceName: String) -> Bool {
        guard let separatorIndex = trimmed.lastIndex(where: { titleSuffixSeparators.contains($0) }) else {
            return false
        }
        let prefix = trimmed[trimmed.startIndex..<separatorIndex].trimmingCharacters(in: .whitespaces)
        let suffix = trimmed[trimmed.index(after: separatorIndex)...]
        guard prefix.count >= minimumSuffixPrefixLength else { return false }
        return suffix.range(of: sourceName, options: .caseInsensitive) != nil
    }

    /// Vice Editorial Title Anomaly 01: the mirror image of the
    /// trailing-suffix case above — the registrable name leads the
    /// title as a whole word (a real word-boundary check, so "Vice"
    /// never matches inside "Vicereine"), followed by substantial real
    /// content. Real evidence: Vice's own JSON-LD `headline`, "VICE
    /// Album Reviews, August 21: Brandon Flowers, Sam Smith, GB and
    /// More" — the publication's name integrated into the headline
    /// itself as house style (a real, recurring editorial convention —
    /// "BuzzFeed Explains", "WIRED Presents" are the same shape), not
    /// decorative suffix boilerplate and not Instagram's "<name>
    /// Documented on Instagram" template (which has no substantial
    /// content at all, leading or trailing).
    private static func hasSubstantialContentAfterLeadingSourceName(_ trimmed: String, sourceName: String) -> Bool {
        guard let range = trimmed.range(of: sourceName, options: [.caseInsensitive, .anchored]) else { return false }
        let rest = trimmed[range.upperBound...]
        // The title is just the bare name (nothing follows), or the
        // "match" is really the prefix of a longer word ("Vicereine")
        // — neither is a genuine leading-name-then-content shape.
        guard let nextChar = rest.first, !nextChar.isLetter, !nextChar.isNumber else { return false }
        let remaining = rest.trimmingCharacters(in: .whitespaces)
        return remaining.count >= minimumSuffixPrefixLength
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
