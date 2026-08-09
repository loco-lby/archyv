import SwiftUI
import SwiftData
import ArkyvKit
#if canImport(UIKit)
import UIKit
#endif

/// The v0.02 capture flow — canonical destination for the Action Button /
/// Share Extension / screenshot-detector paths. One continuous view, no
/// navigation, no nested sheets. Four beats:
///
///   1. `.prompt`   — full-bleed screenshot, "Tap what you want to archive."
///   2. `.isolated` — tap anywhere lifts the photo into a centered card,
///                    everything else recedes. "Save to where? / Select folder ↓"
///   3. picking     — "Select folder ↓" reveals a lightweight dropdown.
///   4. confirmed   — the folder tap IS the save. "Saved ✓" holds briefly,
///                    then the whole flow dismisses itself.
///
/// v1 note: there's no real subject/region detection yet — "tap what you
/// want to archive" isolates the *whole* screenshot, not a detected
/// sub-region. The choreography is real; the intelligence is a later pass.
/// See the Design System's `dropdown-panel` (V2 storyboard, node 175:114)
/// for the folder-picker spec this was built against.
struct ScreenshotCaptureFlowView: View {
    /// Always the full, untouched screenshot — there's no region/subject
    /// detection yet (see the file-level v1 note). This is the future
    /// integration point: a real "isolate what you tapped" feature would
    /// produce its own cropped image/`CaptureDraft` upstream and hand *that*
    /// in here, rather than this view doing any cropping itself.
    let draft: CaptureDraft

    @Environment(CaptureCoordinator.self) private var capture
    @Environment(\.modelContext) private var context

    // Unfiltered `@Query` + in-memory filter, not a `#Predicate` nil-check —
    // see ArchiveView.swift's `allFoldersRaw` doc comment: a `deletedAt ==
    // nil` predicate combined with a `sort:` argument in the same `@Query`
    // hits a SwiftData/Swift type-checker complexity limit.
    @Query(sort: [SortDescriptor(\StoredFolder.sortOrder)])
    private var allFoldersRaw: [StoredFolder]

    private var folders: [StoredFolder] {
        allFoldersRaw.filter { !$0.isSoftDeleted }
    }

    private enum Stage { case prompt, isolated }
    @State private var stage: Stage = .prompt
    @State private var showingPicker = false
    @State private var didSave = false
    @State private var saveError = false

    private var isolated: Bool { stage == .isolated }

    var body: some View {
        ZStack {
            ArkyvColor.background.ignoresSafeArea()

            screenshotLayer
                .opacity(didSave ? 0 : 1)

            promptHeader
                .allowsHitTesting(!didSave)
                .opacity(didSave ? 0 : 1)

            if showingPicker && !didSave {
                dropdownOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }

            if didSave {
                confirmationOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .onAppear { log("confirmationOverlay appeared") }
                    .onDisappear { log("confirmationOverlay disappeared") }
            }
        }
        .overlay(alignment: .topTrailing) {
            if !didSave {
                dismissButton
                    .padding(.trailing, 20)
                    .padding(.top, 8)
            }
        }
        .animation(.easeOut(duration: 0.28), value: stage)
        .animation(.easeOut(duration: 0.18), value: showingPicker)
        .animation(.easeOut(duration: 0.22), value: didSave)
        .animation(.easeOut(duration: 0.2), value: saveError)
        .onAppear { log("appeared for draft \(draft.id)") }
        .onDisappear { log("disappeared for draft \(draft.id)") }
        .onChange(of: didSave) { old, new in log("didSave: \(old) -> \(new)") }
        .onChange(of: showingPicker) { old, new in log("showingPicker: \(old) -> \(new)") }
        .onChange(of: saveError) { old, new in log("saveError: \(old) -> \(new)") }
    }

    private func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[ScreenshotCaptureFlowView] \(message())")
        #endif
    }

    // MARK: Screenshot — full-bleed hero that lifts into a centered card

    private var screenshotLayer: some View {
        Group {
            if let filename = draft.localFilename {
                // `.fill` in the full-bleed prompt stage (it's a backdrop,
                // cropping to fill the screen is correct there). `.fit` once
                // isolated: the card is choreography — a staging area the
                // whole screenshot lifts into, not a crop of what the user
                // tapped. `.fill` here would silently misrepresent what's
                // actually being saved by hiding part of the image behind
                // the card's bounds. Showing the full image letterboxed is
                // the honest placeholder until real region-selection exists
                // (see `draft`'s doc comment and `select(_:)` below).
                LocalImageView(filename: filename, contentMode: isolated ? .fit : .fill)
            } else {
                ArkyvColor.background
            }
        }
        .frame(
            width: isolated ? 344 : nil,
            height: isolated ? 344 : nil
        )
        .frame(
            maxWidth: isolated ? nil : .infinity,
            maxHeight: isolated ? nil : .infinity
        )
        .overlay(Color.black.opacity(isolated ? 0 : 0.18))
        .clipShape(RoundedRectangle(cornerRadius: isolated ? 4 : 0))
        .overlay(
            RoundedRectangle(cornerRadius: isolated ? 4 : 0)
                .strokeBorder(ArkyvColor.accent, lineWidth: isolated ? 2.5 : 0)
        )
        .shadow(color: .black.opacity(isolated ? 0.75 : 0), radius: isolated ? 28 : 0, y: isolated ? 14 : 0)
        .ignoresSafeArea(isolated ? [] : .all)
        .contentShape(Rectangle())
        .onTapGesture {
            guard stage == .prompt, !didSave else { return }
            stage = .isolated
        }
    }

    // MARK: Prompt / header text

    private var promptHeader: some View {
        VStack {
            if isolated {
                VStack(spacing: 6) {
                    Text("Save to where?")
                        .font(ArkyvFont.mono(.bold, size: 16))
                        .foregroundStyle(ArkyvColor.textPrimary)
                    Button {
                        showingPicker = true
                    } label: {
                        Text("Select folder ↓")
                            .font(ArkyvFont.mono(.regular, size: 13))
                            .foregroundStyle(ArkyvColor.textSecondary)
                    }
                    .disabled(showingPicker)
                }
                .padding(.top, 72)
            } else {
                promptPill
                    .padding(.top, 8)
            }
            Spacer()
        }
    }

    private var promptPill: some View {
        Text("Tap what you want to archive")
            .font(ArkyvFont.mono(.regular, size: 12))
            .foregroundStyle(ArkyvColor.textPrimary.opacity(0.85))
            .padding(.horizontal, 24)
            .padding(.vertical, 11)
            .background(Color.black, in: Capsule())
            .overlay(Capsule().strokeBorder(ArkyvColor.accent, lineWidth: 1.5))
    }

    // MARK: Folder dropdown — exactly the V2 storyboard's dropdown-panel

    private var dropdownOverlay: some View {
        VStack {
            Spacer().frame(height: 152)
            folderPanel
            if saveError {
                Text("Couldn't save — try again")
                    .font(ArkyvFont.mono(.regular, size: 12))
                    .foregroundStyle(ArkyvColor.accent)
                    .padding(.top, 10)
                    .transition(.opacity)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .allowsHitTesting(!didSave)
    }

    private var folderPanel: some View {
        VStack(spacing: 4) {
            ForEach(folders) { folder in
                folderRow(folder)
            }
        }
        .padding(8)
        .background(ArkyvColor.card, in: RoundedRectangle(cornerRadius: ArkyvRadius.sheet))
        .overlay(
            RoundedRectangle(cornerRadius: ArkyvRadius.sheet)
                .strokeBorder(ArkyvColor.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 12, y: 12)
    }

    private func folderRow(_ folder: StoredFolder) -> some View {
        // Emphasis may change. Position never does — `folders` is the stable
        // sortOrder query; suggestion only ever affects this row's styling.
        let isSuggested = folder.id == capture.suggestion?.id
        return Button {
            select(folder)
        } label: {
            HStack(spacing: 10) {
                FolderIconView(icon: folder.icon, size: 13, color: ArkyvColor.accent)
                Text(folder.name)
                    .font(ArkyvFont.mono(isSuggested ? .bold : .regular, size: 13))
                    .foregroundStyle(ArkyvColor.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSuggested {
                    Circle().fill(ArkyvColor.accent).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                isSuggested ? ArkyvColor.accent.opacity(0.06) : Color.clear,
                in: RoundedRectangle(cornerRadius: ArkyvRadius.row)
            )
            .overlay(alignment: .leading) {
                if isSuggested {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(ArkyvColor.accent)
                        .frame(width: 2)
                        .padding(.vertical, 2)
                }
            }
        }
        .disabled(didSave)
    }

    // MARK: Confirmation — the folder tap IS the save, no separate button

    private var confirmationOverlay: some View {
        VStack(spacing: 16) {
            Text("Saved ✓")
                .font(ArkyvFont.mono(.bold, size: 20))
                .foregroundStyle(ArkyvColor.textPrimary)
            Button {
                capture.dismiss()
            } label: {
                Text("View →")
                    .font(ArkyvFont.mono(.regular, size: 13))
                    .foregroundStyle(ArkyvColor.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(ArkyvColor.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(ArkyvColor.border, lineWidth: 1))
            }
        }
    }

    // MARK: Dismiss (not in the V2 mock, but a bare "cancel this capture"
    // escape hatch is load-bearing for actually testing dozens of captures)

    private var dismissButton: some View {
        Button {
            capture.dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ArkyvColor.iconDefault)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
    }

    // MARK: Save

    /// Folder tap IS the save — no separate Save button, no dismiss-delay
    /// morph. The write is synchronous (SwiftData `context.save()`), so
    /// gating the haptic and "Saved ✓" on its actual result costs no
    /// perceptible delay — it still reads as instant, but it's now instant
    /// *and honest*: the confirmation only appears once the row is really in
    /// the database. A failed write leaves the dropdown open and tappable so
    /// the user can just try again, instead of silently lying "Saved."
    ///
    /// `draft` is filed exactly as captured — whole-screenshot in, whole
    /// screenshot on disk. A future cropped-selection feature would swap in
    /// a cropped image/new `CaptureDraft` *before* this call, not change
    /// anything about how `fileCapture` itself is invoked here.
    private func select(_ folder: StoredFolder) {
        guard !didSave else { return }
        saveError = false
        do {
            try Repository(context: context).fileCapture(draft, into: folder)
            log("repository save completed — draft \(draft.id) filed into \"\(folder.name)\"")
        } catch {
            log("repository save FAILED for draft \(draft.id) into \"\(folder.name)\": \(error)")
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            #endif
            saveError = true
            return
        }
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
        didSave = true
        showingPicker = false
        Task {
            try? await Task.sleep(for: .milliseconds(1000))
            log("post-save delay elapsed — calling capture.dismiss()")
            capture.dismiss()
        }
    }
}
