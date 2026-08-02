import Foundation

/// Shared identifiers for the app + Share Extension + macOS app.
public enum AppGroup {
    /// Keep in sync with the entitlements files and `project.yml`.
    public static let identifier = "group.com.expatinsurance.arkyv"

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
