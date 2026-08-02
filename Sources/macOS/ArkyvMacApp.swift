import SwiftUI
import ArkyvKit

/// Phase 3 will turn this into a menu-bar app (MenuBarExtra) with a compact
/// popover, drag-out, and Cmd+C shared-clipboard via Supabase Realtime. For
/// now it's a minimal compiling shell so the target builds alongside iOS.
@main
struct ArkyvMacApp: App {
    init() { ArkyvFont.registerFonts() }

    var body: some Scene {
        MenuBarExtra("arkyv", systemImage: "square.grid.2x2") {
            VStack(alignment: .leading, spacing: 8) {
                Text("arkyv")
                    .font(.arkyvHeading)
                    .foregroundStyle(ArkyvColor.textPrimary)
                Text("Menu-bar clipboard arrives in Phase 3.")
                    .font(.arkyvCaption)
                    .foregroundStyle(ArkyvColor.textSecondary)
                Divider()
                Button("Quit arkyv") { NSApplication.shared.terminate(nil) }
            }
            .padding(16)
            .frame(width: 280)
            .background(ArkyvColor.background)
        }
        .menuBarExtraStyle(.window)
    }
}
