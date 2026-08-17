# arkyv (ScreenshotApp)

Catch screenshots the moment they happen and file them into folders. Native
Apple app (iOS + macOS, SwiftUI), local-first with SwiftData, synchronized
through the user's private iCloud/CloudKit database. "Pinterest, but for
your own screenshots."

## Status

| Phase | Scope | State |
|------|-------|-------|
| **1** | iOS local: screenshot detection, capture sheet, folders, masonry grid, reference detail, local-first storage | ✅ Built |
| 2 | CloudKit sync (private database) + offline-first | ✅ Built |
| 3 | macOS menu-bar app + shared clipboard sync | 🔲 Stub target compiles |
| 4 | Vision OCR + full-text search | 🔲 (search works locally already) |
| 5 | Notes | ✅ (notes are shipped as part of Phase 1) |

## Layout

```
project.yml                     XcodeGen project (iOS app + Share ext + macOS app)
Packages/ArkyvKit/              Shared Swift package — models, design tokens, store
  Sources/ArkyvKit/
    Design/     ArkyvColor, ArkyvFont, ArkyvMetrics   (Figma tokens, defined once)
    Model/      ItemKind, FolderIcon
    Store/      StoredModels (SwiftData), ArkyvStore, MediaStore, AppGroup
    Capture/    CaptureDraft
Sources/iOS/                    iPhone app
  App/          ArkyvApp, entitlements, Info.plist
  Capture/      ScreenshotDetector (PHPhotoLibrary), CaptureCoordinator
  Views/        Archive (root, née Home), FolderGrid (legacy, unused), ItemDetail,
                CaptureSheet, NewFolder, Settings…
  Components/    MasonryGrid, FlowLayout, LocalImageView, chips
Sources/Share/                 Share Extension (backgrounded capture)
Sources/macOS/                 Menu-bar app (Phase 3 stub for now)
Resources/                     Fonts (see Design system below), Assets.xcassets
```

## Design system

Tokens are defined once in `ArkyvKit/Design`. Never hard-code a hex or font name in
a view — use the tokens.

- **Colors:** adaptive Light/Dark semantic tokens (`ArkyvColor.canvas` /
  `.textPrimary` / `.textSecondary` / etc., via `Color(light:dark:)`), not fixed
  hex values — dark canvas is `#070707`. A few fixed-appearance surfaces
  (`CropEditorView`, `ScreenshotCaptureFlowView`'s capture flow) are a deliberate
  "darkroom" exception and stay non-adaptive by design.
- **Type:** Lora (`ArkyvFont.mono`/`.sans`, both resolve to the same Lora variable
  font — family split is historical, not functional) is the *current* One Archive
  / Cherries v0.1 typeface, reached after auditioning Instrument Sans,
  Commissioner, Epilogue, Space Grotesk, and IBM Plex Sans in the same slot. This
  is a considered checkpoint, not a locked-in permanent brand decision — expect it
  to keep evolving with real-world use. The other auditioned font files stay in
  `Resources/Fonts/` unregistered/unreferenced until a final typeface is chosen
  and the rest are cleaned up.
- **Radii:** buttons `2px` (sharp), cards `12px`, pills `4px`, sheet `28–32px`;
  Archive masonry tiles are a deliberate exception at `0pt` (see One Archive v0.1
  below).
- Lucide icons in the design map to **SF Symbols**; the Cherries wordmark and
  Home/Plus/Menu dock icons are bundled as template-rendered vector assets
  (`CherriesWordmark`, `CherriesIconHome`/`CherriesIconAdd`/`CherriesIconMenu`).

## One Archive v0.1

The root Archive surface (`ArchiveView`, `ArchiveFilterRail`, floating chrome in
`RootView`) reached a physically-approved checkpoint. The product/design
reasoning behind it, for future work to build on rather than re-litigate:

- **Content-first:** the user's collection should dominate the interface. Core
  principle is *collect richly, display sparingly* — archived items render
  primarily as their visual artifact, with essentially no permanent item-level
  metadata/chrome. The visual field should feel assembled/collected, not like a
  conventional grid of UI cards — hence `0pt` masonry tile corners.
- **No masthead:** the filter rail + search are the only top-level chrome,
  providing orientation without a dominant branded header. The Cherries wordmark
  floats quietly over the collection (bottom-left, center-aligned on the left
  masonry column) as ambient identity, not a masthead — it never reclaims the
  vertical space the old branded header used to occupy.
- **Familiar root navigation:** Home / Plus / Menu (bottom-right, center-aligned
  on the right masonry column) use immediately understandable iconography on
  purpose — clarity beats novelty in primary navigation. Cherries' brand can stay
  distinctive without forcing users to learn custom navigation symbols. These are
  floating tools sitting over the Archive, not a conventional tab bar, and root
  Archive controls (the dock, Home's scroll-to-top behavior) deliberately don't
  propagate into focused/task screens (Item Detail, Crop Editor, capture flows)
  unless a screen is explicitly designed for them.
- **Filter rail:** typography and contrast alone carry the active/inactive
  distinction (currently Lora Medium 16pt, inactive at 75% of `textPrimary`'s own
  opacity) plus a small 4pt dot beneath the active filter as a restrained,
  secondary confirmation of selection — never an underline, pill, background, or
  other heavier active-state treatment.
- **Scrolling:** the native vertical scrollbar is intentionally hidden with
  nothing replacing it. A custom right-side scroll-progress-dot indicator was
  attempted and abandoned after it caused a real layout regression (see git
  history around the "ARCHIVE KNOWN-GOOD RESTORE BUILD" recovery) — don't
  resurrect that experiment casually; if scroll-position feedback comes back, it
  should be transient (visible only during active scrolling) and proven
  layout-neutral before it touches `ArchiveView` again.
- **What's next:** Archive micro-changes should now primarily be driven by
  extended real-world use rather than speculative visual tweaking. Manual
  drag/reordering of Archive items is an intentional product idea worth
  revisiting later, but is not currently implemented.

## Build

Requires Xcode 16+ and [XcodeGen](https://github.com/yonsson/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate          # regenerates ScreenshotApp.xcodeproj from project.yml
open ScreenshotApp.xcodeproj
```

Then select the **Arkyv** scheme and run on an iPhone / simulator.

> **Note on the App Group entitlement:** the app, Share Extension, and macOS app
> share `group.com.expatinsurance.arkyv` (SwiftData store + media live there).
> Xcode's automatic signing (team `AZPJ6UN5SY`) will provision it on first run.

### Shared package validation (no simulator needed)

```bash
cd Packages/ArkyvKit && swift build      # compiles the shared logic
```

### ⚠️ iOS simulator on this Mac

This machine's Xcode (26.6) has iOS **SDK 26.5** installed but only the iOS
**26.2** simulator runtime, and the iOS 26.5 *device* platform component is
missing — so `xcodebuild` currently finds no usable iOS destination. Install a
matching runtime once:

```bash
xcodebuild -downloadPlatform iOS        # or: Xcode ▸ Settings ▸ Components
```

After that:

```bash
xcodebuild -project ScreenshotApp.xcodeproj -scheme Arkyv \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

The **ArkyvMac** scheme builds today (`platform=macOS`) and is the quickest way
to smoke-test the shared stack.

## Sync

Data is stored locally with SwiftData and synchronized through the user's
private iCloud/CloudKit database — no external backend.
