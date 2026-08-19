import Foundation

/// Shared identifiers for the app + Share Extension + macOS app.
public enum AppGroup {
    /// Keep in sync with the entitlements files and `project.yml`.
    ///
    /// Technical Identity Cutover 01: permanent Deadwest/Cherries App
    /// Group — a clean cut, not a dual-container bridge. Shipping targets
    /// no longer reference the legacy `group.com.expatinsurance.arkyv`
    /// container at all; the pre-launch migration artifact
    /// (`Cherries_PreLaunch_Migration_2026-08-19.json`, stored outside
    /// the project) is the sole transfer mechanism for existing archive
    /// content, imported in a later, separate milestone.
    public static let identifier = "group.com.deadwest.cherries"

    /// Root of the shared container, or a per-process fallback (Simulator
    /// without the entitlement) so the app still runs during early bring-up.
    public static var containerURL: URL {
        if let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) {
            return url
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArkyvFallback", isDirectory: true)
    }
}
