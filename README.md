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
    Store/      StoredModels (SwiftData), ArkyvStore, MediaStore, AppGroup,
                ImageDecodeCache/ImageDecoding, IntegrityCheck
    Capture/    CaptureDraft
  Sources/ArkyvBench/            `swift run` synthetic-archive benchmark harness
                                  (Scale Foundation 01 — see its own doc comment)
Sources/iOS/                    iPhone app
  App/          ArkyvApp, entitlements, Info.plist, ImageCacheStressTest (DEBUG)
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
  and the rest are cleaned up. Public Sans (`ArkyvFont.publicSans`) was added
  additively as a second, quieter face for Item Detail's utility/metadata layer
  (Source/Tags/Folder/Notes chips) — it is scoped to that context UI, not a
  replacement for Lora elsewhere in the app.
- **Radii:** buttons `2px` (sharp), cards `12px`, pills `4px`, sheet `28–32px`;
  Archive masonry tiles are a deliberate exception at `0pt` (see One Archive v0.1
  below).
- **Motion:** one principle governs all Cherries motion — **fast hands, calm
  room**. Input responds immediately, but a visual state change should *settle*,
  not *pop*: no bounce/overshoot, no flash, nothing celebratory for ordinary
  actions, nothing that rushes the user past a choice they may still be
  considering. Motion exists to reassure ("your input was understood"), preserve
  continuity, and let a state settle into place — never to demand attention. For
  small, local state changes, ~180–240ms of native ease-in-out is a useful
  starting point (`ArkyvMotion.settle` in `ArkyvMetrics.swift`), tuned by feel
  rather than treated as a rigid token — add the next `ArkyvMotion` case only
  when a genuinely different kind of transition needs one. Shorthand: *"You're in
  a library, not a sports bar."* First approved real-world example: Item Detail's
  Folder room selection animation.
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
- **Known follow-up — bottom-of-Archive content can end underneath the
  floating dock:** normal iOS rubber-band bounce occurs at the true end of
  the `ScrollView` content before the final item(s) can clear the dock
  visually, despite `ArchiveView`'s masonry grid already carrying a
  deliberate 96pt bottom padding specifically for this (see its own
  comment). A read-only inspection (Performance Foundation 01 session)
  found the dock's own footprint (`RootView.floatingBottomOverlay`) needs
  ~74.24pt of clearance (58.24pt circle + 16pt gap) from its container's
  own bottom edge — on paper, 96pt should cover that with room to spare,
  which doesn't match what's observed on-device. Leading hypothesis, not
  yet confirmed: `RootView`'s outer `ZStack` has an `.ignoresSafeArea()`
  sibling, which can pull the whole `ZStack`'s layout bounds (and thus the
  dock's `.bottom`-aligned position) to the literal screen edge, while
  `ArchiveView`'s `ScrollView` — which never opts out of safe-area — likely
  still insets its own content independently, so the two clearance numbers
  may not share a reference frame. Needs live verification (Xcode view
  debugger or on-device geometry logging) before touching anything.
  Expected fix shape once confirmed: keep the dock as a floating overlay,
  only increase `ArchiveView`'s bottom padding by the right amount — no
  `GeometryReader`/preference-key scroll measurement, no masonry/scrolling
  architecture change.

## Item Detail v0.1

Item Detail (`ItemDetailView`, its four "sideroom" editors in
`ItemDetailEditors.swift`, and the shared `ContextEditorChrome`) reached a
physically-approved checkpoint. The product/design reasoning behind it:

- **Image/artifact first, a view not a form:** Item Detail is primarily a
  summary of a Cherry's context, not an editing surface — the artifact stays
  visually dominant and nothing on the main room is inline-editable anymore.
- **Source / Tags / Folder are the three primary retrieval/context
  siblings** — one compact, centered control cluster beneath the image, quiet
  text + chevron, no boxes/backgrounds. Notes is optional annotation and
  intentionally secondary: a small "+ Add note" / single-line-preview entry
  point beneath the trio, never a fourth equal sibling, never a large inline
  form on this screen.
- **Editing happens in focused "siderooms," not inline:** tapping Source,
  Tags, Folder, or Notes opens a dedicated `fullScreenCover` room built on the
  shared X / title / ✓ `ContextEditorChrome`. Each room owns a local draft — X
  genuinely cancels (nothing persists), the large ✓ is the only persistence
  boundary, and confirming always returns to the same Item Detail item. This
  is the "tap a piece of context → dedicated room → finish/cancel → return"
  model — deliberately not the earlier keyboard-adjacent inline-editing
  experiment (custom keyboard toolbar/Done accessory, relocated-field focus
  state), which was fully removed rather than kept as a fallback.
- **Empty context asks quietly; existing context may earn more visibility**
  — e.g. Notes' quiet empty "+ Add note" vs. its slightly stronger populated
  single-line-preview treatment.
- **Folder room** matches One Archive's own visual language (bold/dimmed
  contrast, no bounding cards, no per-folder decorative glyph system) and
  reuses Archive's own active-state dot as the local-selection indicator.
  Folder reassignment stays a local draft until the room's ✓; "+ New Folder"
  is a secondary, bottom-of-list creation action and currently still
  persists the folder immediately on creation (only the *assignment* is
  staged) — a known, deliberate simplification, not yet worth the
  complexity of deferring creation itself.
- **Crop/full-context rendering stays protected** — `CropRegion` math and
  `CropEditorView`'s gesture engine were deliberately untouched through this
  entire pass and shouldn't be rewritten casually alongside product UI work.
- **What's next:** Source/Tags/Folder/Notes rooms can keep growing
  individually without that complexity leaking back into the main Item
  Detail surface. Known follow-up, not part of this checkpoint: Share
  currently shares text rather than the saved image. (`NoteFocusSignal`,
  the mechanism that used to hide `RootView`'s dock while the old inline
  Notes field had focus, was removed entirely in the Performance
  Foundation 01 pass below — confirmed dead once nothing in the sideroom
  model ever set it.)

## Image loading (Performance Foundation 01)

`LocalImageView` (the one shared image view behind One Archive's masonry,
Item Detail, and the capture sheet) decodes through `ImageDecodeCache` /
`ImageDecoding` (`Packages/ArkyvKit/Sources/ArkyvKit/Store/
ImageDecodeCache.swift`) rather than a bare `UIImage(data:)`:

- **Cache:** an `NSCache`-backed, filename-plus-pixel-budget-keyed cache of
  already-decoded `UIImage`s — thread-safe, auto-evicting under memory
  pressure, sized (`totalCostLimit`/`countLimit`) against real masonry-
  thumbnail byte costs, physically re-verified after an initial too-small
  budget was caught evicting within a single ordinary scroll session. Never
  needs invalidating: `MediaStore` filenames are write-once, and crop is a
  display-time transform that never touches cached pixels.
- **Downsampling:** `LocalImageView.decodeTarget` defaults to `.full` (every
  call site's original behavior, unchanged) — callers that know they're a
  small fixed-size cell (One Archive's masonry grid) opt into
  `.thumbnail(shortEdgeTarget:)`, which decodes directly to a small pixel
  budget via native ImageIO thumbnailing instead of materializing a full-
  resolution bitmap first. `originalPixelSize` (free, already-stored
  `StoredItem.aspectWidth`/`.aspectHeight`) lets the thumbnail target
  whichever edge the layout is actually constrained by, since ImageIO's own
  `maxPixelSize` only constrains the *longer* edge.
- **Why this is safe for `CropRegion`:** `CropRegion.renderTransform` only
  ever consumes a decoded image's own `.size` relative to its normalized
  crop rect — never an absolute pixel count — so it's resolution-independent
  by construction (see its own doc comment and
  `CropRegionTests.testRenderTransformIsScaleInvariantAcrossDecodedResolutions`
  / `testVisibleSourceFractionIsIdenticalAcrossDecodedResolutions`). A
  downsampled decode renders the *exact* same visible crop as a full one,
  as long as its aspect ratio matches the original's — which
  `ImageDecoding.decode` guarantees by construction, never distorting.
  Crop Editor and Item Detail's full-context/zoom rendering always request
  `.full` and are never downsampled.
- **New call site expectations:** don't reintroduce a bare
  `UIImage(data:)` decode for anything rendered through `LocalImageView`
  (or sharing its filename space) — route through `ImageDecoding`/
  `ImageDecodeCache` instead, and only request `.thumbnail` for genuinely
  small, fixed-size renders.

## Data Integrity Contract (Foundation 01)

From a full capture→persistence→CloudKit lifecycle audit. Practical rules
for anyone touching `Repository`/capture flows, not a full architecture
doc.

- **Media is written before the `StoredItem` that references it, always.**
  Every capture surface (`ScreenshotDetector`, the Share Extension,
  `CaptureSheetView`'s photo picker) writes to `MediaStore` first and only
  then builds a `CaptureDraft`/calls `Repository.fileCapture`. No code path
  creates a `StoredItem.localFilename` reference before the file exists.
- **Original media is never rewritten or deleted out from under a live
  item.** Confirmed by inspection: `MediaStore.shared.delete(filename:)`
  has exactly one call site in the whole app (`CaptureSheetView`'s "remove
  staged photo" button, on content that was never filed). Cropping,
  editing metadata, moving between folders — none of them touch the
  original bytes.
- **Every `Repository` write ends in `save()` (the private helper), never
  a bare `context.save()`.** `save()` rolls the context back on failure,
  so a caller that catches an error and retries (every capture surface
  does) can't accidentally resurrect a failed attempt's still-pending
  objects alongside the retry's. If you add a new mutating method, route
  its write through `save()`, not `context.save()` directly.
- **`fileCapture` has no idempotency key.** Calling it twice for the same
  `CaptureDraft` creates two distinct `StoredItem`s — there's nothing on
  `StoredItem` tying it back to `draft.id`. Known, not fixed (would need a
  schema change); callers must not blindly retry `fileCapture` itself
  after a save whose outcome is genuinely unknown (as opposed to a
  caught, definite failure, which rollback already makes safe to retry).
- **`setMemberships` is the single authoritative write boundary for
  folder/membership consistency** — it's the one place that reconciles
  both the membership rows *and* legacy `item.folder` (to
  `folders.first`/`nil`) in the same `save()`. `move(_:to:)` is just
  `setMemberships(item, to: [folder])`. Don't hand-roll a second place
  that mutates `item.folder`; route through `setMemberships` (or `move`)
  so the two representations can't drift apart again.
- **Soft-delete cascades to memberships, not to the other side.**
  `softDelete(folder:)` deactivates its own membership rows; `softDelete
  (item:)` now does the same for its own rows (fixed this pass — it used
  to leave them active). Neither ever touches `StoredItem` fields/media on
  the *other* side of a membership — deleting a folder never deletes its
  items, and vice versa isn't a concept that exists.
- **Media staged for an abandoned capture (explicit cancel, or a dropped
  add-mode sheet) is not currently cleaned up**, except when
  `CaptureCoordinator.file(_:into:)` itself catches a `fileCapture`
  failure (fixed this pass — it now deletes the file it just staged
  before dismissing). Cancel paths in `ScreenshotCaptureFlowView`/the
  Share Extension leave their staged file on disk. This is a known,
  accepted gap (disk hygiene, not data loss) — see `IntegrityCheck` below
  for how to *observe* it; nothing auto-deletes on a mere "looks orphaned"
  signal.
- **`IntegrityCheck.run(context:)`** (`Store/IntegrityCheck.swift`,
  `#if DEBUG` only, not wired into any launch path) is a read-only scan
  for missing media, orphaned media files, folder/membership disagreement,
  and duplicate active memberships. It only ever reports counts/IDs —
  never mutates or deletes. Call it manually (Xcode console / future
  debug menu) when investigating a data-integrity question; don't wire it
  into app launch without first checking its I/O cost against a
  realistically large archive.

## Scale / Performance Contract (Foundation 01)

Synthetic-archive findings at 100 / 1,000 / 5,000 / 10,000 / 20,000 items —
methodology and full numbers below; durable takeaways only here.

- **Benchmark harness:** `Packages/ArkyvKit/Sources/ArkyvBench` — a plain
  `swift run` executable (deliberately not another XCTest target; see its
  own doc comment for why), always against an isolated in-memory
  `ModelContainer`, never the real store. Run it with
  `cd Packages/ArkyvKit && swift run -c release ArkyvBench` (use the Xcode
  toolchain directly, not `/usr/bin/swift` — see the Build section below).
  `IntegrityCheck` only runs in a `-c debug` invocation, matching its own
  `#if DEBUG` gating.
- **Known-safe range:** every measured operation stays well under 50ms up
  to 5,000 items. Comfortable range for today's architecture without any
  further work.
- **Known bottleneck — full-archive re-fetch on any mutation:**
  `ArchiveView`'s `@Query` has no predicate (soft-delete/kind filtering
  happens in-memory — a deliberate, already-documented workaround for a
  SwiftData/Swift type-checker hang when a predicate is combined with a
  `sort:` argument in the same query). SwiftData re-runs that unfiltered
  fetch whenever *any* `StoredItem` changes anywhere, not just the item
  actually touched. At 10,000 items this fetch+filter costs ~350-400ms;
  at 20,000, ~800ms — meaning something as small as toggling one favorite
  could cost most of a second of Archive re-fetch at that scale. The
  Unfiled filter (a per-item membership scan) and `Repository.search`
  scale the same way and land in the same range. Not fixed this pass:
  the correct fix is either revisiting the predicate/type-checker
  limitation or an incremental-loading architecture, both explicitly
  outside a "safe narrow optimization." Flagging this as the primary
  finding for a future dedicated pass, not attempting it opportunistically
  here.
- **Not a bottleneck, deliberately left alone:** `resolveItem`'s linear
  ID lookup (ArchiveView's own item-tap → Item Detail resolution) is
  O(N) but only 5-7ms even at 20,000 items — imperceptible, once per tap.
  Optimizing it (e.g. a dictionary index) would be solving a problem that
  doesn't exist at any tested scale.
- **Migrations stay O(1) once flagged done**, as designed:
  `MembershipMigration`/`IconMigration`'s warm (already-run) path is a
  single `UserDefaults` read regardless of archive size (<0.1ms at every
  tested size); only the one-time cold path scales with item count.
- **`ImageDecodeCache` at scale:** a scripted on-device stress run
  (synthetic in-memory JPEGs, no real user data — `ImageCacheStressTest`,
  `#if DEBUG`, inert unless launched with `--arkyv-bench-image-cache`)
  decoded/cached 3,000 distinct masonry-thumbnail-sized images in strict
  sequence (real device, physical run). Resident memory stayed flat —
  ~87MB — for the *entire* run, never trending toward the 320MB
  `totalCostLimit`, confirming Performance Foundation 01's cost math
  holds at real scale rather than just for a short scroll. A revisit
  check on the *oldest* 400 of the 3,000 (i.e. ~3,000 items back) found
  0 hits — expected, not a regression: Performance Foundation 01 already
  established the cache's effective warm depth at roughly ~90 items
  (320MB ÷ ~3.5MB/thumbnail), physically verified with 29/29 hits on a
  realistic ~90-item scroll-back. Checking 3,000-deep here was testing
  *whether memory stays bounded far past that depth* (it does), not
  re-testing warm-depth itself. **Verdict: 320MB reads as comfortably
  sufficient** for realistic scrolling (which rarely revisits content
  more than a screen or two of history back) and safely bounded even
  under a sustained, atypical decode load; no change made to the
  shipping budget. Two real lessons from building this, not cache
  findings: running a long synchronous loop inside `ArkyvApp.init()`
  trips iOS's launch watchdog well under any real memory pressure, and
  `Thread.sleep` inside a `Task` can stall Swift concurrency's
  cooperative thread pool — both fixed in the harness itself (moved to
  a post-launch `.task`, switched to `Task.sleep`), noted here since
  they're easy mistakes to repeat elsewhere.
- **Search readiness:** `Repository.search` and `ArchiveView`'s own
  inline search-as-you-type filter independently duplicate the same
  in-memory substring scan over title/note/OCR-text/sourceURL/tags — a
  future Search feature should converge these into one path rather than
  keep both. Folder names and dates aren't currently searchable at all.
  `ocrText` exists as a schema field but nothing populates it yet (Vision
  OCR is unbuilt — see Status). None of this is schema-blocked for a
  10k-item archive in the way full-archive re-fetch is; the real
  constraint is fixing the re-fetch bottleneck above, since Search would
  inherit it directly.
- **Per-cell hot-path rule for future work:** never add a full-archive
  scan (membership check, tag lookup, search match, anything O(N)) inside
  a masonry cell's own view body or `LocalImageView`'s decode path — those
  run once per visible cell, not once per user action, and would compound
  the cost above rather than just paying it once per mutation.

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

> **Note:** plain `swift build`/`swift test` (resolving to `/usr/bin/swift`,
> the CommandLineTools toolchain) fails on this machine with `external macro
> implementation type 'SwiftDataMacros...' could not be found` — a
> toolchain mismatch, not a real compile error. Fix: invoke Xcode's own
> toolchain explicitly —
> `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
> /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift
> test`. Even with the right toolchain, `RepositoryTests` (SwiftData-backed)
> currently crashes (signal 5) immediately on its first test when run this
> way — `CropRegionTests`/`CropEditorMathTests` (pure Foundation/
> CoreGraphics, no SwiftData) are unaffected and a reliable way to validate
> non-persistence logic from the CLI. `RepositoryTests` needs an actual iOS
> test target/scheme to run properly; none is currently wired into
> `project.yml`.

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
