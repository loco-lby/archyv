import SwiftUI
import SwiftData
import ArkyvKit

@main
struct ArkyvApp: App {
    /// Shared local-first database (App Group container).
    let modelContainer: ModelContainer
    @State private var capture: CaptureCoordinator

    init() {
        // Fonts register automatically via UIAppFonts — this just confirms
        // it worked, in Debug builds only.
        #if DEBUG
        ArkyvFont.verifyFontsAvailable()
        #endif
        let container = ArkyvStore.makeModelContainer()
        self.modelContainer = container
        _capture = State(initialValue: CaptureCoordinator(container: container))

        // Seed the folders from the design on first run.
        let repo = Repository(context: container.mainContext)
        try? repo.seedIfEmpty()

        // ONE-TIME MIGRATION — safe to delete once all devices have run it.
        IconMigration.runIfNeeded(repository: repo)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(capture)
                .tint(ArkyvColor.textPrimary)
                .preferredColorScheme(.dark)
        }
        .modelContainer(modelContainer)
    }
}
