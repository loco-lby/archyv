import SwiftUI
import ArkyvKit

/// Settings Cleanup 01: every row now reflects real, checkable state — no
/// hardcoded "On"/"Enabled" claims, no internal "Phase N" language. A row
/// that can't be honestly verified from inside the app (e.g. whether the
/// user has enabled the Share Extension in iOS's Share Sheet — no API
/// exposes that) is removed rather than shown with a guessed value. There
/// is no Cherries account system in V1, so there's no "ACCOUNT" section —
/// only "SYNC", which houses the one thing Cherries can actually verify:
/// real iCloud availability (Core Loop Hardening 02).
struct SettingsView: View {
    @Environment(CaptureCoordinator.self) private var capture
    /// Core Loop Hardening 02 §8-9: `nil` while the one-shot check is in
    /// flight — the row shows "Checking…" rather than a stale default, so
    /// it never has a moment where it's showing something untrue.
    @State private var iCloudStatus: ICloudAvailability?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ArkyvWordmarkView(height: 30)

                section("SYNC") {
                    row(icon: "arrow.triangle.2.circlepath", title: "iCloud", detail: iCloudStatus?.description ?? "Checking…")
                }

                section("ABOUT") {
                    navigationRow(icon: "questionmark.circle", title: "Help & FAQ") { HelpView() }
                    navigationRow(icon: "hand.raised", title: "Privacy") { PrivacyView() }
                    row(icon: "info.circle", title: "Version", detail: versionDetail)
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
        .task {
            iCloudStatus = await ICloudAvailability.current()
        }
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

    private func navigationRow<Destination: View>(icon: String, title: String, @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 18)).frame(width: 24)
                    .foregroundStyle(ArkyvColor.textPrimary)
                Text(title).font(.arkyvLabel).foregroundStyle(ArkyvColor.textPrimary)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(ArkyvColor.subdued)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .arkyvOutlinedSurface()
        }
        .buttonStyle(.plain)
    }

    /// Real `CFBundleShortVersionString`/`CFBundleVersion` from the actual
    /// built app — replaces the hardcoded "0.1 · Phase 1", which both
    /// leaked internal phase language and could silently drift from the
    /// real build.
    private var versionDetail: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}
