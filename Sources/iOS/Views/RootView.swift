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
                floatingBottomOverlay
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

    /// Try10 refinement: the wordmark and dock cluster align to the
    /// masonry grid's own column centerlines, not arbitrary screen-relative
    /// positions or safe-area edges. This mirrors ArchiveView's masonry
    /// geometry exactly — 2 columns, MasonryGrid's own 8pt inter-column
    /// `spacing`, ArchiveView's 8pt outer `.padding(.horizontal, 8)` on the
    /// grid (see `ArchiveView.body`/`MasonryGrid.columnWidth`) — computed
    /// from this GeometryReader's actual width rather than a hardcoded
    /// per-device number, so it stays correct across screen sizes.
    /// `.position(x:y:)` centers each view's own bounding box at the given
    /// point, so the 3-button `floatingDock` is centered as one cluster on
    /// the right column's centerline, exactly like a single view would be.
    ///
    /// Both float on the same vertical center ("horizontal band") rather
    /// than a shared bottom edge — bottom-aligning the much shorter
    /// wordmark against the taller dock made it read as sitting low;
    /// center-aligning brings it up to match the dock's optical middle.
    private var floatingBottomOverlay: some View {
        GeometryReader { geo in
            let outerPadding: CGFloat = 8
            let gridSpacing: CGFloat = 8
            let columnWidth = (geo.size.width - 2 * outerPadding - gridSpacing) / 2
            let leftColumnCenterX = outerPadding + columnWidth / 2
            let rightColumnCenterX = geo.size.width - outerPadding - columnWidth / 2
            // Same 16pt clearance below the dock as before, now expressed
            // as a center Y within this GeometryReader's own height.
            let bandCenterY = geo.size.height - 16 - Self.dockDiameter / 2

            ZStack {
                floatingWordmark
                    .position(x: leftColumnCenterX, y: bandCenterY)
                floatingDock
                    .position(x: rightColumnCenterX, y: bandCenterY)
            }
        }
        .frame(height: Self.dockDiameter + 16)
    }

    /// Matches `floatingDockButton`'s own fixed circle size below.
    private static let dockDiameter: CGFloat = 58.24

    /// A quiet brand mark living in the room, not a control — no
    /// background, pill, material, or outline, and deliberately never
    /// hit-tested (`.allowsHitTesting(false)`) so it can never steal a tap
    /// from whatever Archive content it happens to float over. Reuses the
    /// same template-rendered vector asset as before (Resources/
    /// Assets.xcassets/CherriesWordmark.imageset). Adaptive `textPrimary`
    /// here — unlike the fixed brand-cream tried for the old top header
    /// this replaces — so it keeps reading in both appearances without a
    /// backdrop of its own. 27.04pt height carried forward from the
    /// prior header experiment as an optical starting point.
    private var floatingWordmark: some View {
        Image("CherriesWordmark")
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 27.04)
            .foregroundStyle(ArkyvColor.textPrimary)
            .accessibilityLabel("Cherries")
            .allowsHitTesting(false)
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
                dockIcon("CherriesIconHome", size: 21.504)
            }
            .accessibilityLabel("Archive")

            // Scissors/Add — the existing capture/add entry point
            // (CaptureCoordinator.startAdd()), unchanged behavior.
            floatingDockButton {
                capture.startAdd()
            } icon: {
                dockIcon("CherriesIconAdd", size: 21.504)
            }
            .accessibilityLabel("Capture")

            // More — the existing Settings destination.
            floatingDockButton {
                tab = .settings
            } icon: {
                dockIcon("CherriesIconMenu", size: 21.504)
            }
            .accessibilityLabel("More")
        }
    }

    /// A single floating tool: fixed 52×52 optical size (matching the
    /// minimum comfortable hit target), consistent spacing handled by the
    /// caller's `HStack`, never a differently-sized/shaped control among
    /// the three.
    private func floatingDockButton<Icon: View>(action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            icon()
                .frame(width: 58.24, height: 58.24)
                .background {
                    // `.ultraThinMaterial` alone kept its adaptive
                    // legibility-over-arbitrary-imagery quality, but read
                    // too light per review — the black overlay darkens it
                    // by a controlled, tunable amount (25%) on top of that
                    // same material, rather than replacing it with a flat
                    // color and losing the adaptive blur.
                    Circle().fill(.ultraThinMaterial)
                    Circle().fill(Color.black.opacity(0.25))
                }
        }
        .buttonStyle(.plain)
    }

    /// Template-rendered vector asset (see Resources/Assets.xcassets/
    /// CherriesIcon*.imageset) — replaces the earlier hand-transcribed
    /// `CherryMarkView`/`CherriesScissorsIcon`/`CherriesMenuIcon` Shapes
    /// now that real icon assets exist. Fixed brand cream (#ede9df)
    /// rather than adaptive `textPrimary` — deliberate, per explicit
    /// review, matching the header wordmark/search icon.
    private func dockIcon(_ name: String, size: CGFloat) -> some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundStyle(Color(hex: 0xEDE9DF))
    }
}
