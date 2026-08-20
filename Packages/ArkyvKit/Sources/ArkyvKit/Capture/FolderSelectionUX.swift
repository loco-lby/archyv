import Foundation

/// Context + Single-Folder UX 01: the one canonical "what does tapping a
/// folder row mean" rule, shared by the Share Extension's save drawer and
/// Item Detail's Folder editor so the two pickers can never disagree
/// about interaction semantics. A Cherry lives in zero or one folder —
/// tapping a different folder replaces the current selection outright
/// (never adds to it); tapping the already-selected folder again clears
/// back to Unfiled, since that's the only way back to it without a
/// separate control.
public enum FolderSelectionUX {
    /// `current` is the presently selected folder ID (`nil` = Unfiled);
    /// `tapped` is the row just tapped. Pure and stateless — callers own
    /// actually writing the result into their own `@State`.
    public static func toggling(current: UUID?, tapped: UUID) -> UUID? {
        current == tapped ? nil : tapped
    }
}
