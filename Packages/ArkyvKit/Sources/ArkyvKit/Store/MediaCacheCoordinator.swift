import Foundation

/// Coalesces concurrent `MediaStore` cache-miss reconstructions for the
/// same filename into a single in-flight `Task`, so simultaneous callers
/// (an Archive cell and Item Detail opening the same cold item, a
/// prefetch racing a render) await the same work instead of duplicating
/// it. Promoted to production in Media Architecture Cutover 01 — validated
/// as a DEBUG-only prototype in Media Cache Foundation 01, where the
/// duplication this exists to prevent was demonstrated, not assumed
/// (`testConcurrentMissesForTheSameFilenameDuplicateReconstructionWork`).
///
/// No persistent state, no schema, no daemon — `inFlight` holds only
/// currently-running reconstructions and is pruned immediately after each
/// one completes, success or failure alike.
public actor MediaCacheCoordinator {
    public static let shared = MediaCacheCoordinator()

    private var inFlight: [String: Task<Data?, Never>] = [:]

    public func data(for filename: String, store: MediaStore, reconstructingFrom source: @escaping @Sendable () -> Data?) async -> Data? {
        if let existingTask = inFlight[filename] {
            return await existingTask.value
        }
        let task = Task<Data?, Never> {
            store.reconstruct(filename: filename, from: source)
        }
        inFlight[filename] = task
        let result = await task.value
        inFlight[filename] = nil
        return result
    }
}
