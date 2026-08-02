import SwiftUI
import ArkyvKit

/// App shell: Archive / Settings sections with the minimal bottom nav, the
/// capture drawer, and the saved-confirmation toast.
struct RootView: View {
    @Environment(CaptureCoordinator.self) private var capture
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: Tab = .archive
    /// Content-fitted height for the capture drawer (updated by the sheet).
    @State private var drawerHeight: CGFloat = 480

    enum Tab { case archive, settings }

    var body: some View {
        @Bindable var capture = capture
        ZStack(alignment: .bottom) {
            ArkyvColor.background.ignoresSafeArea()

            Group {
                switch tab {
                case .archive:
                    NavigationStack { HomeView() }
                case .settings:
                    NavigationStack { SettingsView() }
                }
            }
            .padding(.bottom, 64)

            bottomNav
        }
        .background(ArkyvColor.background)
        .sheet(item: $capture.drawer) { drawer in
            CaptureSheetView(drawer: drawer, measuredHeight: $drawerHeight)
                .presentationDetents([.height(drawerHeight)])
                .presentationDragIndicator(.visible)
                .presentationBackground(ArkyvColor.background)
                .presentationCornerRadius(ArkyvRadius.sheet)
        }
        .overlay(alignment: .bottom) {
            if let toast = capture.savedToast {
                SavedToastView(toast: toast)
                    .padding(.bottom, 80)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast.id) {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation(.easeOut) { capture.savedToast = nil }
                    }
            }
        }
        .animation(.spring(duration: 0.3), value: capture.savedToast)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                capture.startDetecting()
                capture.checkForScreenshots()
            }
        }
    }

    private var bottomNav: some View {
        VStack(spacing: 0) {
            Rectangle().fill(ArkyvColor.border).frame(height: 1)
            HStack {
                navItem(.archive, systemImage: "circle.badge.xmark", label: "Archive")
                Spacer()
                // Center mark — add existing photos / notes to a folder in-app.
                Button {
                    capture.startAdd()
                } label: {
                    ArkyvMarkView(height: 26, color: ArkyvColor.textPrimary)
                        .frame(width: 52, height: 52)
                        .background(ArkyvColor.surface, in: RoundedRectangle(cornerRadius: ArkyvRadius.button))
                }
                .offset(y: -6)
                Spacer()
                navItem(.settings, systemImage: "gearshape", label: "Settings")
            }
            .padding(.horizontal, 40)
            .padding(.top, 12)
            .frame(height: 64)
            .background(ArkyvColor.background)
        }
    }

    private func navItem(_ target: Tab, systemImage: String, label: String) -> some View {
        Button {
            tab = target
        } label: {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 20))
                Text(label)
                    .font(ArkyvFont.sans(size: 11, weight: .medium))
            }
            .foregroundStyle(tab == target ? ArkyvColor.textPrimary : ArkyvColor.textDim)
        }
        .frame(width: 56)
    }
}
