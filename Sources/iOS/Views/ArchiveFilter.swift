import Foundation

/// The single active lens over the one Archive surface — explicit
/// application state, owned by `RootView` (mirroring how `archivePath` is
/// already owned there so Archive-tab reselect can reset it from outside).
/// Never inferred from `NavigationPath`, and never derived from the legacy
/// `StoredItem.folder` relationship — that relationship is a single item's
/// transitional compatibility field (see `Repository.fileCapture`'s doc
/// comment in ArkyvKit), not browsing context.
///
/// Because this lives in `RootView`, above the `NavigationStack` that hosts
/// Item Detail, pushing/popping to Item Detail never touches it — so
/// "Back" from Item Detail always lands on whatever filter was active
/// before the push, with no extra plumbing required.
enum ArchiveFilter: Hashable {
    case all
    case unfiled
    case favorites
    case folder(UUID)
}
