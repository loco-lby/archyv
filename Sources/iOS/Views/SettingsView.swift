import SwiftUI
import ArkyvKit

/// Minimal settings surface. Sign in with Apple + sync status land in Phase 2.
struct SettingsView: View {
    @Environment(CaptureCoordinator.self) private var capture

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ArkyvWordmarkView(height: 30)

                section("ACCOUNT") {
                    row(icon: "person.crop.circle", title: "Sign in with Apple", detail: "Phase 2")
                    row(icon: "arrow.triangle.2.circlepath", title: "Sync", detail: "Local only")
                }

                section("CAPTURE") {
                    row(icon: "camera.viewfinder", title: "Screenshot detection", detail: "On")
                    row(icon: "square.and.arrow.up", title: "Share Extension", detail: "Enabled")
                }

                section("ABOUT") {
                    row(icon: "info.circle", title: "Version", detail: "0.1 · Phase 1")
                }

                #if DEBUG
                section("DEVELOPER") {
                    Button {
                        capture.simulateScreenshotFromLibrary()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "camera.viewfinder").font(.system(size: 18)).frame(width: 24)
                            Text("Simulate a screenshot").font(.arkyvLabel)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12))
                        }
                        .foregroundStyle(ArkyvColor.textPrimary)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .arkyvOutlinedSurface()
                    }
                    Text("Simulator can't create real screenshot assets — this runs your newest photo through the detection → drawer flow.")
                        .font(.arkyvCaption)
                        .foregroundStyle(ArkyvColor.subdued)
                }
                #endif
            }
            .padding(20)
        }
        .background(ArkyvColor.canvas)
        .safeAreaInset(edge: .top) {
            HStack {
                Text("Settings").font(.arkyvHeading).foregroundStyle(ArkyvColor.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(ArkyvColor.canvas)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.arkyvSection).foregroundStyle(ArkyvColor.textSecondary)
            content()
        }
    }

    private func row(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 18)).frame(width: 24)
                .foregroundStyle(ArkyvColor.textPrimary)
            Text(title).font(.arkyvLabel).foregroundStyle(ArkyvColor.textPrimary)
            Spacer()
            Text(detail).font(.arkyvCaption).foregroundStyle(ArkyvColor.subdued)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .arkyvOutlinedSurface()
    }
}
