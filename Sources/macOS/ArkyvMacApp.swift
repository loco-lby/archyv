import SwiftUI
import ArkyvKit

/// Phase 3 will turn this into a menu-bar app (MenuBarExtra) with a compact
/// popover, drag-out, and Cmd+C shared-clipboard sync. For now it's a
/// minimal compiling shell so the target builds alongside iOS.
@main
struct ArkyvMacApp: App {
    // NOTE: unlike the iOS targets, project.yml declares no macOS-side font
    // auto-registration (the `ATSApplicationFontsPath` Info.plist key) — this
    // stub relied entirely on the manual CoreText call that iOS just dropped
    // in favor of `UIAppFonts`. Until `ATSApplicationFontsPath` is added here,
    // custom fonts will consistently fall back to system fonts on macOS
    // (gracefully — `ArkyvFont.mono`/`.sans` already handle that) rather than
    // intermittently, as before. Low priority given this target is still a
    // Phase 3 stub, but flagging it rather than letting it regress silently.
    #if DEBUG
    init() { ArkyvFont.verifyFontsAvailable() }
    #else
    init() {}
    #endif

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
