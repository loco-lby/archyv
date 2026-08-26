import SwiftUI
import SwiftData
import ArkyvKit

@main
struct ArkyvApp: App {
    /// Shared local-first database (App Group container). `nil` only in
    /// the genuinely-unrecoverable case — see `init()`'s own doc comment.
    let modelContainer: ModelContainer?
    @State private var capture: CaptureCoordinator?

    init() {
        do {
            let container = try ArkyvStore.makeModelContainer()
            self.modelContainer = container
            _capture = State(initialValue: CaptureCoordinator(container: container))

            let repo = Repository(context: container.mainContext)

            // Default-folder seeding is NOT decided here — a single check at
            // launch can't safely tell "brand new user" apart from "existing
            // CloudKit user whose import just hasn't landed yet." See
            // SeedGate.swift; RootView's scenePhase hook owns this now,
            // checked repeatedly rather than once.

            // ONE-TIME MIGRATION — safe to delete once all devices have run it.
            IconMigration.runIfNeeded(repository: repo)

            // ONE-TIME BACKFILL — additive only, safe to delete once all
            // devices have run it. See MembershipMigration.swift.
            MembershipMigration.runIfNeeded(repository: repo)
        } catch {
            // Core Loop Hardening 02 §2: reaching here means BOTH the
            // on-disk+CloudKit container AND the in-memory fallback
            // failed to open — see `ArkyvStore.makeModelContainer`'s own
            // doc comment for exactly what that implies (genuinely rare;
            // in practice SwiftData itself cannot construct any container
            // on this device/OS). Previously this was the app's only
            // naked `try!` crash. `body` below now renders a small,
            // honest "couldn't start" screen instead of force-unwrapping.
            #if DEBUG
            print("[ArkyvApp] FATAL: could not create any ModelContainer: \(error)")
            #endif
            self.modelContainer = nil
            _capture = State(initialValue: nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let modelContainer, let capture {
                mainScene(modelContainer: modelContainer, capture: capture)
            } else {
                InitializationFailureView()
            }
        }
    }

    @ViewBuilder
    private func mainScene(modelContainer: ModelContainer, capture: CaptureCoordinator) -> some View {
        RootView()
            .environment(capture)
            .tint(ArkyvColor.textPrimary)
            .task {
                    // Scale Foundation 01: entirely inert unless explicitly
                    // launched with this argument (`devicectl device
                    // process launch ... com.deadwest.cherries
                    // --arkyv-bench-image-cache`) — never triggered by
                    // ordinary development or use. Deliberately NOT run
                    // from `init()`: a long synchronous stress loop before
                    // the app ever renders its first frame trips iOS's
                    // launch watchdog (confirmed — an earlier version of
                    // this hook did exactly that and got killed by signal
                    // 9 well under any real memory pressure). Runs after
                    // the real UI is already up, off the main thread, so
                    // it can't block launch or normal use either way.
                    #if DEBUG
                    if CommandLine.arguments.contains("--arkyv-bench-image-cache") {
                        Task.detached(priority: .userInitiated) {
                            await ImageCacheStressTest.run()
                        }
                    }
                    // Share/Capture Reliability Foundation 01 — same
                    // post-launch, off-main-thread pattern and the same
                    // reasoning as the hook above.
                    if CommandLine.arguments.contains("--arkyv-bench-ingestion") {
                        Task.detached(priority: .userInitiated) {
                            await IngestionStressTest.run()
                        }
                    }
                    // Media Cache Foundation 01 — same pattern again.
                    if CommandLine.arguments.contains("--arkyv-bench-media-cache") {
                        Task.detached(priority: .userInitiated) {
                            await MediaCacheStressTest.run()
                        }
                    }
                    // Option 2 Validation Gate 01 (two-device test) — an
                    // on-demand, read-only snapshot of the real,
                    // already-running container's most recent items.
                    // Unlike the hooks above, this deliberately reads the
                    // REAL modelContainer (not an isolated one) — the
                    // whole point is inspecting real synced data — but it
                    // only ever fetches and logs, never mutates.
                    if CommandLine.arguments.contains("--arkyv-validate-recent-media") {
                        OptionTwoValidationLog.reportMostRecentItems(container: modelContainer)
                    }
                    // Multi-Device Consistency Foundation 01 — deliberately
                    // operates on the REAL modelContainer (not isolated):
                    // this milestone's whole point is observing real
                    // cross-device CloudKit merge behavior. Every mutation
                    // routes through the same Repository methods any real
                    // UI action would call, against clearly-tagged test
                    // Cherries only — see MultiDeviceConsistencyHarness's
                    // own doc comment.
                    if let flagIndex = CommandLine.arguments.firstIndex(of: "--arkyv-mdc"),
                       flagIndex + 1 < CommandLine.arguments.count {
                        let action = CommandLine.arguments[flagIndex + 1]
                        let container = modelContainer
                        Task.detached(priority: .userInitiated) {
                            await MultiDeviceConsistencyHarness.run(action: action, container: container)
                        }
                    }
                    // Pre-Launch Migration Ferry 01 — export half reads the
                    // real modelContainer (read-only, matching every other
                    // real-data harness above); import half only ever
                    // writes into a fresh isolated in-memory container it
                    // creates itself. See MigrationFerry's own doc comment.
                    if let flagIndex = CommandLine.arguments.firstIndex(of: "--arkyv-migration"),
                       flagIndex + 1 < CommandLine.arguments.count {
                        let action = CommandLine.arguments[flagIndex + 1]
                        let container = modelContainer
                        Task.detached(priority: .userInitiated) {
                            await MigrationFerry.run(action: action, realContainer: container)
                        }
                    }
                    #endif
                }
            .modelContainer(modelContainer)
    }
}

/// Core Loop Hardening 02 §2: the small, honest screen shown only in the
/// genuinely-unrecoverable case — see `ArkyvApp.init()`'s own doc
/// comment. No technical detail, no retry button (there is nothing a
/// retry could fix that a relaunch wouldn't already attempt), calm tone.
private struct InitializationFailureView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Text("Cherries couldn't start")
                    .font(ArkyvFont.mono(.medium, size: 18))
                    .foregroundStyle(.white)
                Text("Please try reopening the app.")
                    .font(ArkyvFont.mono(.regular, size: 14))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(32)
            .multilineTextAlignment(.center)
        }
    }
}
