import Foundation

/// ONE-TIME MIGRATION. Safe to delete once every real device has run it
/// (check by bumping `hasRunKey` never needing a v2, or just by time —
/// there's no reason to keep this around past a couple of releases).
///
/// Folders created before the `FolderGlyph` icon system shipped are stored
/// with legacy `sf:<symbol name>` icon tokens (see `FolderIcon.swift`).
/// `FolderIconView` still renders those fine, so nothing is broken — but
/// existing users never see the new geometric icon language. This rewrites
/// every such folder's icon in place, once, so existing installs pick up the
/// new look automatically, without a reinstall and without touching any
/// other folder data (name, sortOrder, items, etc. are untouched).
///
/// To remove: delete this file, and the two `IconMigration.runIfNeeded(...)`
/// call sites (`ArkyvApp.swift`, `ShareViewController.swift`).
public enum IconMigration {
    /// Legacy SF Symbol name → `FolderGlyph`. The first five are the exact
    /// mapping the original seed data used (Deadwest/Cool Shit/Recipes/Japan
    /// 2026/Inspiration); the rest is the old create-folder icon palette,
    /// mapped by feel, so any folder ever created before this release
    /// resolves to something on-brand rather than falling back silently.
    private static let symbolToGlyph: [String: FolderGlyph] = [
        "star": .star,
        "face.smiling": .cross,
        "fork.knife": .triangle,
        "airplane": .circle,
        "paintpalette": .diamond,
        "heart": .diamond,
        "bolt": .triangle,
        "camera": .circle,
        "book": .circle,
        "music.note": .star,
        "cart": .diamond,
        "tshirt": .circle,
        "house": .circle,
        "map": .triangle,
        "lightbulb": .star,
        "flame": .triangle,
        "leaf": .circle,
        "gamecontroller": .cross,
    ]

    /// App Group flag so this only does real work once, across every process
    /// (main app + Share Extension) that might call it at launch.
    private static let hasRunKey = "com.arkyv.migration.folderIconsToGlyphs.v1"

    /// Runs the migration if it hasn't already succeeded. Cheap to call from
    /// every process's launch path — a single `UserDefaults` read in the
    /// common case where it's already done.
    public static func runIfNeeded(repository: Repository) {
        let defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
        guard !defaults.bool(forKey: hasRunKey) else { return }

        do {
            let folders = try repository.folders(includingDeleted: true)
            var migratedAny = false
            for folder in folders where folder.icon.kind == .symbol {
                let glyph = symbolToGlyph[folder.icon.value] ?? .star
                folder.icon = .glyph(glyph)
                folder.updatedAt = .now
                folder.dirty = true
                migratedAny = true
            }
            if migratedAny {
                try repository.context.save()
            }
            // Mark done even if nothing needed migrating — no legacy
            // folders existed, which is itself a valid terminal state.
            defaults.set(true, forKey: hasRunKey)
        } catch {
            // Leave the flag unset so we retry next launch instead of
            // silently stranding folders on legacy SF Symbol icons.
        }
    }
}
