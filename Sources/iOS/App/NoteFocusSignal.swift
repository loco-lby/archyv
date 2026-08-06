import SwiftUI
import Observation

/// Explicit shared signal — not inferred keyboard-height tracking — so
/// `ItemDetailView`'s note composer can tell `RootView` "hide your chrome,
/// I have focus" without either view needing to know anything about the
/// other's internals, keyboard geometry, or view hierarchy depth.
///
/// Why a signal instead of RootView inferring this from keyboard
/// notifications/geometry: the actual bug this fixes is that RootView's
/// bottom nav sits in the same `ZStack` as the NavigationStack that
/// (several levels deep) hosts the focused text field, so it inherits the
/// `.keyboard` safe-area inset and rises right along with it — a plain
/// boolean set by the one view that actually knows when it's editing is
/// far simpler and more reliable than RootView trying to reconstruct that
/// fact from ambient keyboard frame data.
///
/// Injected once at the app root (see `ArkyvApp`) and read via
/// `@Environment(NoteFocusSignal.self)`.
@MainActor
@Observable
final class NoteFocusSignal {
    var isActive: Bool = false
}
