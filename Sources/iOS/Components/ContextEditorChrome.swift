import SwiftUI
import ArkyvKit

/// Shared "sideroom" chrome for Item Detail's context editors (Notes,
/// Source, Tags, Folder): a large Cherries X (top-left, cancel) and ✓
/// (top-right, confirm) — the same Action Capture confirmation language
/// `CropEditorView`/`ScreenshotCaptureFlowView` already use, at their
/// default "large" size, just tinted to the adaptive `textPrimary`
/// semantic color instead of a fixed white (this screen isn't a
/// darkroom-forced-dark surface) — with an optional quiet centered title
/// between them. X always means "leave without accepting this session";
/// ✓ always means "finish this session," never "save the whole Cherry."
///
/// Each editing room is a `fullScreenCover`, so there is no swipe-to-
/// dismiss gesture to disambiguate against — X and ✓ are the only two
/// ways out, by construction.
struct ContextEditorChrome<Content: View>: View {
    var title: String?
    /// Core Loop Hardening 02 §4: the smallest shared visible-failure
    /// signal for every sideroom mutation — `nil` (the default) changes
    /// nothing for a caller that doesn't pass one. Before this, a failed
    /// save already correctly rolled back and kept the room open (see
    /// `ItemDetailView`'s own `onConfirm` handlers), but gave the user no
    /// signal beyond "nothing happened when I tapped ✓" — this reuses the
    /// exact same inline-text/`ArkyvColor.accent` language the Share
    /// Extension's own `saveError` state already uses, rather than a new
    /// toast/alert framework.
    var errorMessage: String? = nil
    var onCancel: () -> Void
    var onConfirm: () -> Void
    var isConfirmEnabled: Bool = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let title {
                    Text(title)
                        .font(ArkyvFont.publicSans(size: 13, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(ArkyvColor.textSecondary)
                }
                HStack {
                    CherriesCancelControl(action: onCancel, color: ArkyvColor.textPrimary)
                    Spacer()
                    CherriesConfirmControl(action: onConfirm, isEnabled: isConfirmEnabled, color: ArkyvColor.textPrimary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            if let errorMessage {
                Text(errorMessage)
                    .font(ArkyvFont.mono(.regular, size: 12))
                    .foregroundStyle(ArkyvColor.accent)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }

            content()
        }
        .background(ArkyvColor.canvas.ignoresSafeArea())
        .animation(.easeOut(duration: 0.2), value: errorMessage)
    }
}
