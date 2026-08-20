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

    /// Attempts to resolve `url` into an image-backed draft. `sourceURL` on
    /// the returned draft is always `url.absoluteString` — the *original*
    /// incoming URL, never `metadata.url`/`metadata.originalURL` — so
    /// query-string context a generic "canonical URL" would silently drop
    /// (Instagram's `img_index`, YouTube's `t=`) survives untouched. This
    /// also holds for enriched drafts — `EnrichedLinkContent` only ever
    /// supplies a title/image, never a replacement URL.
    public static func resolve(
        _ url: URL,
        sourceDevice: SourcePlatform,
        fetcher: LinkMetadataFetching = LPMetadataProvider(),
        mediaStore: MediaStore = .shared,
        enrichers: [SourceEnricher] = defaultEnrichers,
        timeout: TimeInterval = defaultTimeout
    ) async -> CaptureDraft? {
        await withTaskGroup(of: CaptureDraft?.self) { group in
            group.addTask {
                await attemptResolve(url, sourceDevice: sourceDevice, fetcher: fetcher, mediaStore: mediaStore, enrichers: enrichers)
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

    private static func attemptResolve(
        _ url: URL,
        sourceDevice: SourcePlatform,
        fetcher: LinkMetadataFetching,
        mediaStore: MediaStore,
        enrichers: [SourceEnricher]
    ) async -> CaptureDraft? {
        if let enricher = enrichers.first(where: { $0.matches(url) }) {
            if let enrichedDraft = await attemptEnrichedResolve(url, sourceDevice: sourceDevice, mediaStore: mediaStore, enricher: enricher) {
                return enrichedDraft
            }
            debugLog("enrichment unavailable/failed for \(url.absoluteString) — falling back to generic")
        }
        return await attemptGenericResolve(url, sourceDevice: sourceDevice, fetcher: fetcher, mediaStore: mediaStore)
    }

    /// A matched enricher gets exactly one attempt; ANY failure (thrown
    /// error, non-200 thumbnail fetch, undecodable bytes, a save
    /// failure) returns `nil` here so the caller falls through to the
    /// unchanged generic path below — never a hard failure for the whole
    /// resolution just because one source's enrichment didn't work this
    /// time.
    private static func attemptEnrichedResolve(
        _ url: URL,
        sourceDevice: SourcePlatform,
        mediaStore: MediaStore,
        enricher: SourceEnricher
    ) async -> CaptureDraft? {
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
        guard !Task.isCancelled else { return nil }

        guard let pixelSize = ImageDecoding.pixelSize(ofData: data) else {
            debugLog("enriched image undecodable for \(url.absoluteString)")
            return nil
        }
        guard !Task.isCancelled else { return nil }

        let ext = enriched.imageURL.pathExtension.isEmpty ? "jpg" : enriched.imageURL.pathExtension
        guard let filename = try? mediaStore.save(data: data, ext: ext) else {
            debugLog("MediaStore save failed for enriched \(url.absoluteString)")
            return nil
        }

        debugLog("enriched-resolved \(url.absoluteString) -> \(data.count) bytes, title=\(enriched.title ?? "nil")")
        return CaptureDraft(
            kind: .image,
            localFilename: filename,
            pixelSize: pixelSize,
            title: enriched.title,
            sourceURL: url.absoluteString,
            sourceDevice: sourceDevice
        )
    }

    private static func attemptGenericResolve(
        _ url: URL,
        sourceDevice: SourcePlatform,
        fetcher: LinkMetadataFetching,
        mediaStore: MediaStore
    ) async -> CaptureDraft? {
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
        guard !Task.isCancelled else {
            debugLog("cancelled after image load for \(url.absoluteString)")
            return nil
        }

        // Header-only inspection (ImageIO, no full decode) — this is both
        // the "does this actually decode as an image" validation AND the
        // pixel-size read `CaptureDraft.pixelSize` needs, in one cheap
        // call regardless of how large the source image is.
        guard let pixelSize = ImageDecoding.pixelSize(ofData: data) else {
            debugLog("undecodable image bytes for \(url.absoluteString), \(data.count) bytes")
            return nil
        }

        guard !Task.isCancelled else {
            debugLog("cancelled before save for \(url.absoluteString)")
            return nil
        }
        let ext = UTType(typeIdentifier)?.preferredFilenameExtension ?? "jpg"
        guard let filename = try? mediaStore.save(data: data, ext: ext) else {
            debugLog("MediaStore save failed for \(url.absoluteString)")
            return nil
        }

        debugLog("resolved \(url.absoluteString) -> \(data.count) bytes, \(Int(pixelSize.width))x\(Int(pixelSize.height))")
        return CaptureDraft(
            kind: .image,
            localFilename: filename,
            pixelSize: pixelSize,
            title: metadata.title,
            sourceURL: url.absoluteString,
            sourceDevice: sourceDevice
        )
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
