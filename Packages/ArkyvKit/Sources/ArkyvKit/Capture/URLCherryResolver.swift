import Foundation
import LinkPresentation
import UniformTypeIdentifiers

/// URL → Cherry Production Foundation 01: resolves a shared URL into an
/// ordinary image-backed `CaptureDraft` using Apple-native LinkPresentation
/// metadata — "a user does not save a link, they save the thing it points
/// to." On ANY failure (no network, timeout, no image, undecodable bytes)
/// this returns `nil` and the caller falls back to the existing text-only
/// URL draft — resolution is an enhancement, never a new failure
/// dependency. Feeds the SAME `CaptureDraft` → `Repository.fileCapture`
/// path every other image capture already uses; this is not a parallel
/// persistence system.
public enum URLCherryResolver {
    /// Single bounded budget for the whole resolution attempt — small and
    /// defensible for a Share Extension's tight lifetime, not tuned
    /// per-step. Slightly larger than Production Foundation 01's original
    /// 6s: a matched source enricher can add up to two extra network
    /// round-trips (its own lookup, then a thumbnail fetch) before ever
    /// falling back to the generic path, and both must still fit inside
    /// one bounded attempt.
    public static let defaultTimeout: TimeInterval = 8

    /// Checked in order; the first enricher whose `matches(_:)` returns
    /// `true` gets one attempt before the generic path runs. Not a
    /// registry/plugin system — a plain, small, ordered list, matching
    /// "approximately a handful of launch-time enrichers, not an
    /// enterprise framework."
    public static let defaultEnrichers: [SourceEnricher] = [YouTubeOEmbedEnricher()]

    /// Checked only when no enricher matched — an enricher already IS
    /// the highest-confidence single image for its source (YouTube),
    /// so there is nothing for a candidate source to usefully add there.
    public static let defaultCandidateSources: [CandidateImageSource] = [ProductPageCandidateSource()]

    /// Attempts to resolve `url` into an image-backed draft using ONLY
    /// the single best-guess candidate — the exact behavior this type
    /// has always had, and still what every existing caller/test uses.
    /// A thin wrapper around `resolveCandidates`/`materializeCandidate`;
    /// see `resolveCandidates` for the Link Cherry Visual Picker 01
    /// multi-candidate API. `sourceURL` is always `url.absoluteString` —
    /// the *original* incoming URL, never a canonicalized one — so
    /// query-string context (Instagram's `img_index`, YouTube's `t=`)
    /// survives untouched.
    public static func resolve(
        _ url: URL,
        sourceDevice: SourcePlatform,
        fetcher: LinkMetadataFetching = LPMetadataProvider(),
        mediaStore: MediaStore = .shared,
        enrichers: [SourceEnricher] = defaultEnrichers,
        timeout: TimeInterval = defaultTimeout
    ) async -> CaptureDraft? {
        guard let resolved = await resolveCandidates(
            url, sourceDevice: sourceDevice, fetcher: fetcher, enrichers: enrichers, candidateSources: [], timeout: timeout
        ), let primary = resolved.candidates.first else {
            return nil
        }
        return await materializeCandidate(primary, title: resolved.title, sourceURL: url, sourceDevice: sourceDevice, mediaStore: mediaStore)
    }

    /// Link Cherry Visual Picker 01: resolves `url` into an ORDERED list
    /// of candidate visuals rather than committing to one — candidate 0
    /// is always the same single best guess `resolve` alone would have
    /// produced (an enricher's image if one matched and succeeded,
    /// otherwise generic `LPMetadataProvider`'s). Candidate 0's bytes
    /// are fetched eagerly, right here, so displaying it is exactly as
    /// fast as today's single-image flow; every other candidate is a
    /// lazy `.url` the caller only fetches via `materializeCandidate` if
    /// the user actually looks at or selects it. Additional candidates
    /// (from `candidateSources`) are only ever appended AFTER candidate
    /// 0 and only when no enricher already produced the primary image —
    /// "don't let a random alternate image outrank the existing proven
    /// representative image without evidence." Returns `nil` on total
    /// failure (no candidate at all), exactly like `resolve`.
    public static func resolveCandidates(
        _ url: URL,
        sourceDevice: SourcePlatform,
        fetcher: LinkMetadataFetching = LPMetadataProvider(),
        enrichers: [SourceEnricher] = defaultEnrichers,
        candidateSources: [CandidateImageSource] = defaultCandidateSources,
        timeout: TimeInterval = defaultTimeout
    ) async -> ResolvedURLCherry? {
        await withTaskGroup(of: ResolvedURLCherry?.self) { group in
            group.addTask {
                await attemptResolveCandidates(url, fetcher: fetcher, enrichers: enrichers, candidateSources: candidateSources)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                debugLog("timed out after \(timeout)s for \(url.absoluteString)")
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// Downloads (or, for an already-fetched `.bytes` candidate, simply
    /// validates) `candidate`'s image and saves it through the exact
    /// same `MediaStore` path any other image capture uses — this is the
    /// ONLY point at which a candidate's bytes ever touch persistence.
    /// Unselected candidates this is never called for are never fetched
    /// again and never persisted at all.
    public static func materializeCandidate(
        _ candidate: ResolvedImageCandidate,
        title: String?,
        sourceURL: URL,
        sourceDevice: SourcePlatform,
        mediaStore: MediaStore = .shared
    ) async -> CaptureDraft? {
        let data: Data
        let ext: String
        switch candidate.source {
        case .bytes(let existingData, let typeHint):
            data = existingData
            ext = typeHint
        case .url(let imageURL):
            do {
                let (fetchedData, response) = try await URLSession.shared.data(from: imageURL)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    debugLog("materialize: bad response for candidate \(candidate.id)")
                    return nil
                }
                data = fetchedData
            } catch {
                debugLog("materialize: fetch failed for candidate \(candidate.id): \(error)")
                return nil
            }
            ext = imageURL.pathExtension.isEmpty ? "jpg" : imageURL.pathExtension
        }
        guard !Task.isCancelled else { return nil }

        // Header-only inspection (ImageIO, no full decode) — validates
        // AND supplies `CaptureDraft.pixelSize` in one cheap call
        // regardless of source resolution.
        guard let pixelSize = ImageDecoding.pixelSize(ofData: data) else {
            debugLog("materialize: undecodable bytes for candidate \(candidate.id)")
            return nil
        }
        guard !Task.isCancelled else { return nil }

        guard let filename = try? mediaStore.save(data: data, ext: ext) else {
            debugLog("materialize: MediaStore save failed for candidate \(candidate.id)")
            return nil
        }

        debugLog("materialized candidate \(candidate.id) -> \(data.count) bytes, \(Int(pixelSize.width))x\(Int(pixelSize.height))")
        return CaptureDraft(
            kind: .image,
            localFilename: filename,
            pixelSize: pixelSize,
            title: title,
            sourceURL: sourceURL.absoluteString,
            sourceDevice: sourceDevice
        )
    }

    private static func attemptResolveCandidates(
        _ url: URL,
        fetcher: LinkMetadataFetching,
        enrichers: [SourceEnricher],
        candidateSources: [CandidateImageSource]
    ) async -> ResolvedURLCherry? {
        if let enricher = enrichers.first(where: { $0.matches(url) }) {
            if let primary = await fetchEnrichedImage(url, enricher: enricher) {
                let candidate = ResolvedImageCandidate(id: "primary", source: .bytes(primary.data, typeHint: primary.ext))
                return ResolvedURLCherry(title: primary.title, sourceURL: url, candidates: [candidate])
            }
            debugLog("enrichment unavailable/failed for \(url.absoluteString) — falling back to generic")
        }

        guard let primary = await fetchGenericImage(url, fetcher: fetcher) else { return nil }
        var candidates = [ResolvedImageCandidate(id: "primary", source: .bytes(primary.data, typeHint: primary.ext))]

        if let source = candidateSources.first(where: { $0.matches(url) }) {
            if let extraURLs = try? await source.candidateImageURLs(for: url), !Task.isCancelled {
                let extraCandidates = extraURLs.map { ResolvedImageCandidate(id: CandidateAssembly.dedupeKey(for: $0), source: .url($0)) }
                candidates = CandidateAssembly.merging(candidates, with: extraCandidates)
                debugLog("candidate source found \(extraCandidates.count) additional, \(candidates.count) total after merge for \(url.absoluteString)")
            }
        }
        return ResolvedURLCherry(title: primary.title, sourceURL: url, candidates: candidates)
    }

    /// A matched enricher gets exactly one attempt; ANY failure (thrown
    /// error, non-200 thumbnail fetch, undecodable bytes) returns `nil`
    /// so the caller falls through to the unchanged generic path —
    /// never a hard failure for the whole resolution just because one
    /// source's enrichment didn't work this time.
    private static func fetchEnrichedImage(_ url: URL, enricher: SourceEnricher) async -> (title: String?, data: Data, ext: String)? {
        let enriched: EnrichedLinkContent
        do {
            enriched = try await enricher.enrich(url)
        } catch {
            debugLog("enricher threw for \(url.absoluteString): \(error)")
            return nil
        }
        guard !Task.isCancelled else { return nil }

        let data: Data
        do {
            let (fetchedData, response) = try await URLSession.shared.data(from: enriched.imageURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                debugLog("enriched image fetch bad response for \(url.absoluteString)")
                return nil
            }
            data = fetchedData
        } catch {
            debugLog("enriched image fetch failed for \(url.absoluteString): \(error)")
            return nil
        }
        guard !Task.isCancelled, ImageDecoding.pixelSize(ofData: data) != nil else {
            debugLog("enriched image undecodable or cancelled for \(url.absoluteString)")
            return nil
        }
        let ext = enriched.imageURL.pathExtension.isEmpty ? "jpg" : enriched.imageURL.pathExtension
        return (enriched.title, data, ext)
    }

    private static func fetchGenericImage(_ url: URL, fetcher: LinkMetadataFetching) async -> (title: String?, data: Data, ext: String)? {
        let metadata: LPLinkMetadata
        do {
            metadata = try await fetcher.fetchMetadata(for: url)
        } catch {
            debugLog("metadata fetch failed for \(url.absoluteString): \(error)")
            return nil
        }
        guard !Task.isCancelled else {
            debugLog("cancelled after metadata fetch for \(url.absoluteString)")
            return nil
        }
        guard let imageProvider = metadata.imageProvider else {
            debugLog("no imageProvider for \(url.absoluteString)")
            return nil
        }
        guard let (data, typeIdentifier) = await loadImageData(from: imageProvider) else {
            debugLog("image provider load failed for \(url.absoluteString)")
            return nil
        }
        guard !Task.isCancelled, ImageDecoding.pixelSize(ofData: data) != nil else {
            debugLog("undecodable image bytes or cancelled for \(url.absoluteString)")
            return nil
        }
        let ext = UTType(typeIdentifier)?.preferredFilenameExtension ?? "jpg"
        return (metadata.title, data, ext)
    }

    /// Picks the first registered type that conforms to `.image` (matches
    /// what Discovery Spike 01's harness did against all six real URLs,
    /// including a non-JPEG/PNG case — Instagram's icon came back as
    /// `org.webmproject.webp`) and loads its raw bytes unmodified.
    private static func loadImageData(from provider: NSItemProvider) async -> (Data, String)? {
        guard let typeIdentifier = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data.map { ($0, typeIdentifier) })
            }
        }
    }

    private static func debugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[URLCherryResolver] \(message())")
        #endif
    }
}

/// Narrow seam over `LPMetadataProvider` so `URLCherryResolver` is
/// testable without hitting the real network — deliberately just the one
/// method the resolver actually calls, not a general LinkPresentation
/// abstraction.
public protocol LinkMetadataFetching: Sendable {
    func fetchMetadata(for url: URL) async throws -> LPLinkMetadata
}

extension LPMetadataProvider: LinkMetadataFetching {
    public func fetchMetadata(for url: URL) async throws -> LPLinkMetadata {
        // `LPMetadataProvider.cancel()` is the documented way to actually
        // stop an in-flight fetch (Task cancellation alone doesn't reach
        // into it) — wiring this means `URLCherryResolver`'s timeout race
        // genuinely tears down the losing network request instead of
        // leaving it running unobserved after resolve() has already
        // returned.
        try await withTaskCancellationHandler {
            try await startFetchingMetadata(for: url)
        } onCancel: {
            self.cancel()
        }
    }
}
