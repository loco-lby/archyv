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
  Views/        Home, FolderGrid, ItemDetail, CaptureSheet, NewFolder, Settings…
  Components/    MasonryGrid, FlowLayout, LocalImageView, chips
Sources/Share/                 Share Extension (backgrounded capture)
Sources/macOS/                 Menu-bar app (Phase 3 stub for now)
Resources/                     Fonts (Intel One Mono, Instrument Sans), Assets.xcassets
```

## Design system

Tokens were pulled directly from the "arkyv test" Figma file and defined once in
`ArkyvKit/Design`. Never hard-code a hex or font name in a view — use the tokens.

- **Colors:** bg `#111`, card `#1a1a1a`, border `#2a2a2a`, surface/selected `#222`,
  text `#e0e0e0` / secondary `#999` / dim `#6e6e6a`.
- **Type:** `Intel One Mono` (display/labels), `Instrument Sans` (small UI text).
- **Radii:** buttons `2px` (sharp), cards `12px`, pills `4px`, sheet `28–32px`.
- Lucide icons in the design map to **SF Symbols**; the `arkyv` wordmark + mark
  are bundled as vector assets (`ArkyvWordmark`, `ArkyvMark`).

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
