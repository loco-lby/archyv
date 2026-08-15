import SwiftUI
import SwiftData
import ArkyvKit

/// App shell: Archive / Settings sections with the floating root dock, the
/// capture drawer, and the saved-confirmation toast.
struct RootView: View {
    @Environment(CaptureCoordinator.self) private var capture
    @Environment(NoteFocusSignal.self) private var noteFocus
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @State private var tab: Tab = .archive
    /// Owned here, not by ArchiveView, so tapping the already-selected
    /// Archive tab can reset it from outside without recreating ArchiveView
    /// itself.
    @State private var archivePath = NavigationPath()
    /// Owned here, alongside `archivePath`, for the same reason: explicit
    /// application state that survives ArchiveView being torn down/rebuilt,
    /// and that Archive-tab reselect can reset from outside. Never inferred
    /// from `archivePath` or from `StoredItem.folder` — see `ArchiveFilter`.
    @State private var activeFilter: ArchiveFilter = .all
    /// D4: SeedGate's in-foreground polling loop — see `startSeedGateLoop`.
    /// Cancelled the moment the app leaves `.active`; `nil` whenever no
    /// loop is currently running (either never started, or already
    /// stopped after resolving).
    @State private var seedGateTask: Task<Void, Never>?

    enum Tab { case archive, settings }

    var body: some View {
        @Bindable var capture = capture
        ZStack(alignment: .bottom) {
            ArkyvColor.canvas.ignoresSafeArea()

            Group {
                switch tab {
                case .archive:
                    // No bottom padding here (unlike Settings below):
                    // Archive's masonry content should scroll edge-to-edge
                    // and pass behind/under the floating dock, not stop
                    // short of it — the dock is a floating overlay, not a
                    // layout-reserving bar.
                    NavigationStack(path: $archivePath) {
                        ArchiveView(archivePath: $archivePath, activeFilter: $activeFilter)
                    }
                case .settings:
                    // No push navigation here yet, so no path to manage —
                    // this pattern extends the same way if that changes.
                    NavigationStack { SettingsView() }
                        .padding(.bottom, 64)
                }
            }

            // A plain `if`, not `.hidden()`/`.opacity(0)` — those still
            // occupy layout space and (for `.hidden()`) still exist in the
            // tree, and this exact view is the thing that was rising above
            // the keyboard: it lives in this ZStack, a sibling of the
            // NavigationStack that (several levels deep) hosts the note
            // composer, so it inherits the `.keyboard` safe-area inset same
            // as anything else here would. Removing it from the tree
            // entirely — not just visually — is what actually keeps it out
            // of layout and hit-testing while a note has focus.
            //
            // Also hidden once Item Detail is pushed (`archivePath` is
            // non-empty) — the floating dock belongs to root Archive
            // screens only, not task/detail screens. Settings has no push
            // destinations yet, so it's always "root" for this check.
            if !noteFocus.isActive && (tab == .settings || archivePath.isEmpty) {
                floatingDock
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: noteFocus.isActive)
        .background(ArkyvColor.canvas)
        .sheet(item: $capture.drawer) { drawer in
            // v0.02: the screenshot flow should read as "no unnecessary app
            // chrome" — no grabber, no rounded sheet corners pretending
            // there's something underneath. Add-mode keeps the softer sheet
            // treatment since it's a genuine in-app action, not a borrowed
            // moment.
            CaptureSheetView(drawer: drawer)
                .presentationDetents([.large])
                .presentationDragIndicator(drawer.isAdd ? .visible : .hidden)
                .presentationBackground(ArkyvColor.canvas)
                .presentationCornerRadius(drawer.isAdd ? ArkyvRadius.screen : 0)
        }
        .overlay(alignment: .bottom) {
            if let toast = capture.savedToast {
                SavedToastView(toast: toast)
                    .padding(.bottom, 80)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity)
                            .animation(.easeOut(duration: 0.3)),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                            .animation(.easeIn(duration: 0.2))
                    ))
                    .task(id: toast.id) {
                        // Motion spec: visible 3000ms, enter 300ms ease-out, exit 200ms ease-in.
                        try? await Task.sleep(for: .seconds(3))
                        capture.savedToast = nil
                    }
            }
        }
        // Ambient trigger for the toast's state change — the actual enter/exit
        // curves live on the asymmetric transition above and take precedence.
        .animation(.easeOut(duration: 0.3), value: capture.savedToast)
        // `initial: true` is load-bearing: on a cold launch (e.g. the Action
        // Button spawning a fresh process) `scenePhase` starts at `.active`
        // directly — plain `.onChange` only fires on *transitions*, so
        // without `initial: true` detection would never run on first launch,
        // only on later foreground reactivations.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                capture.startDetecting()
                capture.checkForScreenshots()
                // D3B: one small backfill batch per foreground activation,
                // off the main actor — a fresh background ModelContext on
                // the same container, never mainContext itself, so this
                // never competes with UI reads/writes on the main thread.
                let container = modelContext.container
                Task.detached(priority: .background) {
                    let backgroundContext = ModelContext(container)
                    ImageBackfill.runNextBatch(context: backgroundContext)
                }
                startSeedGateLoop()
            } else {
                // D4: stop polling the moment we leave .active — never
                // runs while backgrounded, restarted fresh next activation.
                seedGateTask?.cancel()
                seedGateTask = nil
            }
        }
        .onChange(of: archivePath.count) { old, new in
            log("archivePath.count changed: \(old) -> \(new)")
        }
    }

    private func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[RootView] \(message())")
        #endif
    }

    /// D4: while the app stays continuously foregrounded, periodically
    /// re-evaluate SeedGate so a genuinely new user isn't stuck waiting
    /// for a background/reopen cycle to receive default folders once the
    /// window elapses. Non-blocking — runs entirely off the main actor,
    /// on a fresh background ModelContext each tick, same as the
    /// ImageBackfill call above. Stops itself the moment the store is no
    /// longer empty, for any reason (we just seeded, or real CloudKit
    /// data landed independently) — never polls forever. Also stopped
    /// externally the moment scenePhase leaves .active.
    private func startSeedGateLoop() {
        guard seedGateTask == nil else { return }
        let container = modelContext.container
        seedGateTask = Task.detached(priority: .background) {
            while !Task.isCancelled {
                let backgroundContext = ModelContext(container)
                SeedGate.evaluate(context: backgroundContext, timedSeedPermission: .allowed)
                let stillEmpty = (try? Repository(context: backgroundContext).folders(includingDeleted: true).isEmpty) ?? false
                guard stillEmpty else { return }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// One Archive Shell 00: three separate floating tools over the
    /// collection, not a conventional enclosing tab bar — no shared
    /// background strip, no divider hairline, no persistent "which tab is
    /// active" highlighting (Scissors is a momentary action, not a
    /// destination, so a uniform treatment across all three reads more
    /// like "tools" than "tabs"). Each sits in its own translucent
    /// `.ultraThinMaterial` circle so it stays legible floating over
    /// whatever imagery happens to be underneath it, regardless of system
    /// appearance — a fixed-color background couldn't guarantee that the
    /// same way a system material can.
    private var floatingDock: some View {
        HStack(spacing: 12) {
            // Archive/Home — returns to the root Archive surface. Tapping
            // while already there resets both the nav path and the active
            // filter back to All, matching the dock's "take me to the one
            // Archive" meaning rather than just "pop to root."
            floatingDockButton {
                if tab == .archive {
                    log("Home reselected — resetting archivePath and activeFilter to All (path count was \(archivePath.count))")
                    archivePath = NavigationPath()
                    activeFilter = .all
                } else {
                    tab = .archive
                }
            } icon: {
                CherryMarkView(size: 26.88, color: ArkyvColor.textPrimary)
            }
            .accessibilityLabel("Archive")

            // Scissors — the existing capture/add entry point
            // (CaptureCoordinator.startAdd()), unchanged behavior.
            floatingDockButton {
                capture.startAdd()
            } icon: {
                CherriesScissorsIcon(size: 26.88, color: ArkyvColor.textPrimary)
            }
            .accessibilityLabel("Capture")

            // More — the existing Settings destination.
            floatingDockButton {
                tab = .settings
            } icon: {
                CherriesMenuIcon(size: 26.88, color: ArkyvColor.textPrimary)
            }
            .accessibilityLabel("More")
        }
        // Comfortable home-indicator clearance beyond what the safe area
        // already reserves — these are meant to float clear of it, not
        // hug it.
        .padding(.bottom, 16)
    }

    /// A single floating tool: fixed 52×52 optical size (matching the
    /// minimum comfortable hit target), consistent spacing handled by the
    /// caller's `HStack`, never a differently-sized/shaped control among
    /// the three.
    private func floatingDockButton<Icon: View>(action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            icon()
                .frame(width: 58.24, height: 58.24)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }
}
