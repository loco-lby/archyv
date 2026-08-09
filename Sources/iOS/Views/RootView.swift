import SwiftUI
import ArkyvKit

/// App shell: Archive / Settings sections with the minimal bottom nav, the
/// capture drawer, and the saved-confirmation toast.
struct RootView: View {
    @Environment(CaptureCoordinator.self) private var capture
    @Environment(NoteFocusSignal.self) private var noteFocus
    @Environment(\.scenePhase) private var scenePhase
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

    enum Tab { case archive, settings }

    var body: some View {
        @Bindable var capture = capture
        ZStack(alignment: .bottom) {
            ArkyvColor.background.ignoresSafeArea()

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
                bottomNav
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: noteFocus.isActive)
        .background(ArkyvColor.background)
        .sheet(item: $capture.drawer) { drawer in
            // v0.02: the screenshot flow should read as "no unnecessary app
            // chrome" — no grabber, no rounded sheet corners pretending
            // there's something underneath. Add-mode keeps the softer sheet
            // treatment since it's a genuine in-app action, not a borrowed
            // moment.
            CaptureSheetView(drawer: drawer)
                .presentationDetents([.large])
                .presentationDragIndicator(drawer.isAdd ? .visible : .hidden)
                .presentationBackground(ArkyvColor.background)
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

    private var bottomNav: some View {
        VStack(spacing: 0) {
            Rectangle().fill(ArkyvColor.border).frame(height: 1)
            HStack {
                // Cherry / Home — returns to the root Archive surface.
                // Tapping while already there resets BOTH the nav path
                // (old behavior) AND the active filter back to All — the
                // dock's Home button means "take me to the one Archive,"
                // not just "pop to root." Obsoletes the old grid-icon
                // "Archive" tab identity per the v0.2 visual direction.
                Button {
                    if tab == .archive {
                        log("Cherry reselected — resetting archivePath and activeFilter to All (path count was \(archivePath.count))")
                        archivePath = NavigationPath()
                        activeFilter = .all
                    } else {
                        tab = .archive
                    }
                } label: {
                    VStack(spacing: 6) {
                        CherryMarkView(size: 22, color: tab == .archive ? ArkyvColor.textPrimary : ArkyvColor.iconDefault)
                        Text("Home")
                            .font(ArkyvFont.sans(size: 11, weight: .medium))
                    }
                    .foregroundStyle(tab == .archive ? ArkyvColor.textPrimary : ArkyvColor.iconDefault)
                }
                .frame(width: 56)
                Spacer()
                // Scissors — triggers the same existing capture/add flow as
                // before (CaptureCoordinator.startAdd()); only the visual
                // control changed, not the behavior. The future native
                // Photos-picker Scissors flow is a later milestone.
                Button {
                    capture.startAdd()
                } label: {
                    Image(systemName: "scissors")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(ArkyvColor.textPrimary)
                        .frame(width: 52, height: 52)
                        .background(ArkyvColor.surface, in: RoundedRectangle(cornerRadius: ArkyvRadius.button))
                }
                .offset(y: -6)
                Spacer()
                // More — same Settings destination as before, relabeled.
                navItem(.settings, systemImage: "line.3.horizontal", label: "More")
            }
            .padding(.horizontal, 40)
            .frame(height: 44)
            // Design System: nav bar background = `surface` (#1A1A1A). That's
            // still `ArkyvColor.card`'s value until the token migration lands
            // (next step) — using it here as a temporary correct-value stand-in.
            .background(ArkyvColor.card)
        }
    }

    /// - Parameters:
    ///   - systemImage: default (inactive) glyph.
    ///   - activeSystemImage: filled variant shown when this tab is selected.
    ///     Defaults to `systemImage` for icons with no distinct filled form
    ///     (e.g. `line.3.horizontal`, which reads as "filled" already).
    ///   - onReselect: fires instead of `tab = target` when this tab is
    ///     tapped while it's already the active one (e.g. pop to root).
    ///     Tabs with nothing to reset can omit it and reselecting is a no-op,
    ///     same as today.
    private func navItem(_ target: Tab, systemImage: String, activeSystemImage: String? = nil, label: String, onReselect: (() -> Void)? = nil) -> some View {
        let isActive = tab == target
        return Button {
            if isActive, let onReselect {
                onReselect()
            } else {
                tab = target
            }
        } label: {
            VStack(spacing: 6) {
                // Navigation bar icons: 24×24pt, ~2px stroke.
                Image(systemName: isActive ? (activeSystemImage ?? systemImage) : systemImage)
                    .font(.system(size: 24, weight: .medium))
                Text(label)
                    .font(ArkyvFont.sans(size: 11, weight: .medium))
            }
            .foregroundStyle(isActive ? ArkyvColor.textPrimary : ArkyvColor.iconDefault)
        }
        .frame(width: 56)
    }
}
