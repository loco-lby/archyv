import SwiftUI
import SwiftData
import ArkyvKit

@main
struct ArkyvApp: App {
    /// Shared local-first database (App Group container).
    let modelContainer: ModelContainer
    @State private var capture: CaptureCoordinator
    @State private var noteFocusSignal = NoteFocusSignal()

    init() {
        // Fonts register automatically via UIAppFonts — this just confirms
        // it worked, in Debug builds only.
        #if DEBUG
        ArkyvFont.verifyFontsAvailable()
        #endif
        let container = ArkyvStore.makeModelContainer()
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
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(capture)
                .environment(noteFocusSignal)
                .tint(ArkyvColor.textPrimary)
                .preferredColorScheme(.dark)
        }
        .modelContainer(modelContainer)
    }
}
