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
    Store/      StoredModels (SwiftData), ArkyvStore, MediaStore, MediaCacheCoordinator,
                AppGroup, ImageDecodeCache/ImageDecoding, IntegrityCheck, CherryManifest (DEBUG)
    Capture/    CaptureDraft
  Sources/ArkyvBench/            `swift run` synthetic-archive benchmark harness
                                  (Scale Foundation 01 — see its own doc comment)
Sources/iOS/                    iPhone app
  App/          ArkyvApp, entitlements, Info.plist, ImageCacheStressTest (DEBUG),
                IngestionStressTest (DEBUG), MediaCacheStressTest (DEBUG),
                OptionTwoValidationLog (DEBUG)
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

## Recovery / Portability Contract (Foundation 01)

From a full audit of what it takes to reconstruct a Cherry after device
loss, reinstall, or partial sync. No schema/CloudKit architecture changed
this pass — this is what's true about the *existing* one.

- **The authoritative original is the media bytes, held twice, on
  purpose.** `StoredItem.localFilename` → a `MediaStore` file is the
  primary local read path every render uses. `StoredItem.imageData`
  (`@Attribute(.externalStorage)`) is a second, deliberately redundant
  on-device copy of the *same* bytes, whose only job is to be the
  CloudKit sync transport (`.externalStorage` is what SwiftData's
  CloudKit integration maps to a `CKAsset`) — a plain filename string
  couldn't sync the bytes themselves, only its own text. **Yes, original
  media is uploaded to iCloud/CloudKit today**, via this mechanism, for
  every new capture (`Repository.fileCapture` populates `imageData`
  directly from the just-written `MediaStore` file) — this was
  previously mis-documented in `StoredModels.swift` as "not wired in
  yet, a later milestone"; that comment was stale and has been
  corrected as part of this audit.
- **Self-healing recovery already exists for the reinstall/new-device
  case.** `MediaStore.data(for:restoringFrom:)` — consumed by
  `LocalImageView.load()` and `ItemDetailView.presentCropEditor()` —
  tries the local file first and, only if it's missing, materializes it
  from `item.imageData` and writes it to disk exactly as if it had been
  captured on this device. This is the actual mechanism behind "replace
  your phone, sign into the same Apple ID, reinstall Cherries, your
  archive comes back" — not a documented product promise anywhere yet,
  but a real, already-built, already-used code path.
- **Known gap: historical items backfill slowly.** `ImageBackfill` only
  populates `imageData` for pre-existing items 20 at a time, once per
  app foreground activation (deliberately conservative, never blocking
  launch). A large historical archive could take many app opens to
  become fully CloudKit-protected. Not a bug — a real, quantifiable
  window during which an old, not-yet-backfilled item has no recovery
  path if its *local* copy is also lost before that device's backfill
  catches up. `IntegrityCheck`'s `itemsWithRecoverableMedia` /
  `itemsWithNoKnownRecovery` (added this pass) is how to observe this on
  a given device.
- **Everything else is a plain synced property, no special case
  needed:** `cropRegion` (scalar `cropX/Y/Width/Height`), tags, notes,
  sourceURL, favorite, folder/membership relationships, timestamps,
  soft-delete tombstones — all ordinary `@Model` properties on the same
  CloudKit-enabled `ModelConfiguration` (`ArkyvStore.makeModelContainer`,
  `cloudKitDatabase: .private(...)`), synced the same way as everything
  else with zero custom sync code. `StoredFolder`/`StoredFolderMembership`
  sync identically to `StoredItem` — no special-casing anywhere.
- **No custom sync/conflict logic exists** — `dirty`/`remoteSyncedAt`
  (on all three models) are written on every mutation but never read
  anywhere in the codebase; they're vestigial bookkeeping from an
  earlier "D1/D2" milestone stage, not wired into any actual decision.
  All sync and conflict resolution is entirely SwiftData's own built-in
  CloudKit integration — nothing here overrides or races it. Two-device
  concurrent edits fall back to SwiftData/CloudKit's documented default
  merge behavior (field-level, not something this codebase customizes).
- **Filenames are opaque, globally-unique-enough UUIDs, but not
  content-identifying.** `MediaStore.save`'s filename UUID is
  independent of `StoredItem.id` (two separate random UUIDs) — safe
  from collisions, but a media file with no surviving `StoredItem` row
  pointing at it cannot be reconnected to "which capture" by inspecting
  the file alone. This is why `IntegrityCheck`'s orphan detection can
  only ever report *that* a file is unclaimed, never *whose* it was —
  true reconnection (Recovery/Portability Phase 5's category D vs. E)
  would need a durable content ID embedded some other way (e.g. image
  metadata) — a schema-adjacent decision, not implemented here per
  explicit instruction to stop and report rather than add it.
- **Standard device/iCloud backup is a second, independent safety
  net.** Neither `MediaStore`'s directory nor the SwiftData store file
  are excluded from backup (no `isExcludedFromBackup` anywhere in the
  codebase) — a full-device iCloud/Finder backup restore brings the
  whole App Group container back verbatim, independent of CloudKit
  record sync. Not a promise Cherries actively engineers for, but a
  real, currently-true protection layer worth knowing about.
- **`CherryManifest`** (`Store/CherryManifest.swift`, `#if DEBUG`, no UI,
  no import path) proves the current models already contain everything
  a future portable `Archive/media/ + cherries.json` export would need —
  verified with a round-trip JSON test (encode → decode → exactly
  equal, including soft-deleted tombstones). Folder-organized export,
  ZIP packaging, and any actual product export UX remain undesigned;
  this only answers "is the data representable," which it is.
- **No CRITICAL/HIGH durability gap found.** The one real risk
  identified (historical-item backfill window, above) is bounded,
  self-correcting, and already observable via `IntegrityCheck` — not an
  architectural gap requiring product/CloudKit redesign.

## Ingestion Contract (Share/Capture Reliability Foundation 01)

From a full audit of every capture surface's provider→decode→
MediaStore→`Repository.fileCapture`→SwiftData-save→completion lifecycle,
with the Share Extension (the tightest memory budget of any Cherries
process) as the main focus.

- **Original bytes ownership:** every capture surface writes to
  `MediaStore` (or now, for the Share Extension's JPEG fast path, copies
  directly into it) *before* `CaptureDraft`/`Repository.fileCapture` ever
  runs — `fileCapture` only ever reads an already-staged file, never
  creates one. Unchanged by this pass; already true and already audited
  in Data Integrity Foundation 01.
- **Found: the pre-existing path silently re-compresses every shared
  image, regardless of source format.** `MediaStore.save(image:)` always
  calls `UIImage.jpegData(compressionQuality: 0.9)` — a JPEG shared from
  Safari got decoded to a full bitmap and re-encoded back into a *new*
  JPEG, discarding the original bytes and likely some metadata, for no
  functional reason. Not previously documented anywhere. Fixed for the
  common case (see below); still true for HEIC/PNG/other non-JPEG
  sources, which still go through decode-then-re-encode — changing that
  would mean deciding whether Cherries stores originals in their native
  format at all, a real product/architecture question, not a narrow fix,
  so it's flagged here rather than attempted.
- **Fixed: `ShareViewController.jpegFastPathDraft`** — when the shared
  attachment is already a JPEG, its bytes are copied straight into
  `MediaStore` (`MediaStore.save(copyingFileAt:)`, new, zero in-memory
  buffering when the provider hands back a file URL) and only the pixel
  *dimensions* are read from the file header (`ImageDecoding.pixelSize`,
  new — no bitmap ever decoded). Falls back to the original decode/
  re-encode path unchanged for anything else. This is strictly better on
  every axis for the common case: exact original bytes preserved
  (including EXIF orientation — more faithfully than the old path,
  which normalizes it during re-encode), no full-resolution bitmap ever
  materializes, less CPU. A one-shot on-device comparison (12/24/48MP
  synthetic JPEGs) confirmed the new path's resident-memory delta stays
  ~0MB at every size the old path measurably moves the needle at — see
  the note on measurement precision below.
- **Fixed: the Share Extension's own preview thumbnail decoded at full
  resolution.** `MediaThumbnail` (`ShareViewController.swift`) predates
  `ImageDecodeCache`/`ImageDecoding` and lives in a separate target, so
  it never picked up Performance Foundation 01's downsampling — it was
  doing a bare `UIImage(data:)` full decode to render a ≤360pt preview.
  Now uses `ImageDecoding.decode(_:maxPixelSize:)` like everything else.
- **Fixed: `completeRequest` could theoretically fire twice.**
  `ShareViewController.finish()`/`cancel()` now share a `didComplete`
  guard. `NSExtensionContext.completeRequest` tolerating repeat calls
  isn't documented API contract Cherries should rely on; this makes it
  unconditionally true regardless. Narrow, always-correct, no behavior
  change for the (overwhelmingly common) single-call case.
- **Verified, not a gap: provider double-callback protection already
  exists, structurally.** Every `provider.loadItem(forTypeIdentifier:)`
  call here uses Swift's automatic completion-handler-to-`async`
  bridging (`try? await provider.loadItem(...)`), which traps
  ("SWIFT TASK CONTINUATION MISUSE") if the underlying completion
  handler is invoked more than once — a documented Swift Concurrency
  guarantee, not something this codebase implements itself.
- **Verified: the single-image contract holds.** `NSExtensionActivationRule`
  declares `ImageWithMaxCount: 1` — the system itself won't even offer
  Cherries in the share sheet for a multi-image selection, before any
  Cherries code runs. `extractDraft()` structurally only ever returns
  the *first* successfully-loaded image provider. No mismatch found
  between the declared contract and the implementation.
- **Found, not fixed (a discovered behavior worth knowing, not a bug):**
  when a single share payload includes *both* an image and a URL
  attachment (common when sharing an image from a web page), Cherries
  keeps only the image — the URL branch in `extractDraft()` only runs if
  no image provider succeeded, so `sourceURL` never gets populated in
  that case. Deterministic and consistent, just possibly surprising.
  Explicitly not changed — "new link-capture behavior" is out of scope
  this pass.
- **Failure/cancellation paths already correct, reused, not
  reinvented:** `ShareDrawerContent.confirmSave()`'s `catch` already
  leaves the drawer open with `saveError = true` and never calls
  `completeRequest` on failure (no accidental completion-as-success,
  retry stays possible) — unchanged, already correct before this pass.
  A cancelled/abandoned share still leaves its staged `MediaStore` file
  orphaned — the same known, accepted gap Data Integrity Foundation 01
  already documented for every capture surface, not something new to
  this one.
- **Action Button companion audit:** `ScreenshotDetector`'s `isChecking`
  reentrancy guard already prevents overlapping detection passes;
  `MediaStore`'s UUID-based filenames can't collide; `CaptureCoordinator
  .file`'s Data-Integrity-Foundation-01 cleanup-on-failure still holds
  unchanged. One narrow, discovered edge case, not fixed: if a *second*
  screenshot is detected (app backgrounded and reforegrounded) while an
  earlier one's drawer is still open, `CaptureCoordinator.present(_:)`
  silently replaces the currently-shown draft rather than queuing or
  ignoring the new one — deciding which of those three is correct
  product behavior is out of scope for a narrow technical pass.
  `fileCapture`'s known lack of an idempotency key (Data Integrity
  Foundation 01) applies here too, unchanged — no schema work done.
- **Measurement note:** the on-device peak-memory comparison
  (`IngestionStressTest`, `#if DEBUG`, `--arkyv-bench-ingestion`) uses
  the same coarse `mach_task_basic_info` resident-size sampling
  `ImageCacheStressTest` used in Scale Foundation 01. It reliably shows
  the new path at ~0MB and the old path measurably above that at every
  tested size, but the old path's absolute deltas (2-6.5MB even at
  ~48MP) are smaller than a naive "width×height×4 bytes" bitmap
  estimate would predict — likely either a more memory-efficient
  ImageIO-internal re-encode pipeline than that model assumes, or this
  sampling approach undercounting the true instantaneous peak. The
  *comparison* is trustworthy; the old path's absolute number shouldn't
  be read as a precise peak without real Instruments profiling. The
  fidelity win (exact original bytes, unmodified) doesn't depend on
  this measurement at all.

## Storage Contract (Disk Pressure Foundation 01)

From a full audit of local storage ownership, growth, and every
file-writing boundary's behavior under low-disk conditions. Core rule:
a storage problem may block a *new* save, but must never corrupt an
*existing* Cherry or claim success for one that didn't actually happen.

- **CRITICAL, found and fixed: a disk-full Share Extension capture could
  silently "succeed" as an empty note while the actual photo was lost.**
  `ShareViewController.extractDraft()`'s image→URL→text fallback chain
  didn't distinguish "no image was shared" from "an image was shared but
  every attempt to save it failed" — the latter fell straight through
  to a contentless `CaptureDraft(kind: .note)`, which the drawer then
  presented as a completely normal, ready-to-save draft (enabled ✓, no
  error, no preview because there was nothing to preview). A user
  tapping ✓ in that state filed a real, successful, entirely empty
  `StoredItem` while their photo silently never existed anywhere. Fixed:
  an image-processing failure now returns `nil` instead of falling
  through, and the drawer shows an explicit "Couldn't load — nothing to
  save" state (✓ stays disabled) rather than presenting a false-ready
  draft. Scoped to the image path specifically — it's the only one of
  the three fallback branches that writes substantial bytes to disk.
- **Found and fixed: `MediaStore.save(copyingFileAt:)` (new in Share/
  Capture Reliability Foundation 01) wasn't atomic.** Unlike
  `save(data:)`, which gets atomicity for free from `Data.write(options:
  .atomic)`, a bare `FileManager.copyItem(at:to:)` writes directly to
  the destination path — a disk-full error or process kill mid-copy
  could have left a truncated file sitting at the exact filename a
  `StoredItem` was about to reference as its original. Fixed: copies to
  a `.staging-<uuid>` sibling in the same directory first, then does a
  single atomic move into place (same volume, so it's a real rename,
  not a second copy) — cleaning up the staging file on either outcome.
- **Verified, not changed: every other media write path was already
  atomic.** `save(data:)` and the D4 self-healing restore write
  (`data(for:restoringFrom:)`) both already use `Data.write(options:
  .atomic)` — Foundation's documented contract (write to an auxiliary
  file, then rename) means a failure here can *never* leave a partial
  file at the final path. `save(image:)` delegates to `save(data:)`, so
  it inherits the same guarantee.
- **Verified: `Repository.fileCapture` is structurally unreachable
  before media exists.** Every capture surface writes to `MediaStore`
  first and only calls `fileCapture` with an already-staged filename
  (Recovery/Portability Foundation 01) — a media-write failure means
  `fileCapture` (and therefore any `StoredItem`) simply never gets
  created for that capture, on every surface except the one bug above,
  which is now fixed the same way.
- **Verified: existing data survives a failed SwiftData save.** Two
  independent layers protect it — SQLite's own ACID/journaled commit
  (a framework guarantee, not something Cherries implements) means a
  failed write leaves the database file in its previous consistent
  state, never partially written; `Repository.save()`'s rollback-on-
  failure (Data Integrity Foundation 01) means the in-memory context
  doesn't retain stale pending objects afterward either. No new code
  needed here — this is exactly the "don't manufacture handling
  Foundation/SQLite already provides" case.
- **Cloud restore under low disk stays safely retryable, not
  corrupting.** `data(for:restoringFrom:)`'s write is atomic (above), so
  a disk-full failure during the D4 self-healing restore can't leave a
  corrupt local file — the function still returns the fetched
  `imageData` bytes for *this* render (a reasonable "show it now even
  though local persistence didn't stick" choice, not a bug), and the
  next access simply retries the same restore, since `MediaStore` still
  reports the file as absent. The synced `imageData` itself is
  untouched by any of this — it only gets consumed, never mutated, by a
  failed restore attempt.
- **Local persistent footprint (Category A) is the only one that
  scales with archive size — and it's roughly *doubled* by design.**
  Every media item exists on disk twice: once in `MediaStore`
  (`localFilename`, the fast local read path) and once again as
  `StoredItem.imageData` (`.externalStorage`, the CloudKit sync
  transport — confirmed local, on-disk, not purely cloud-side; see
  Recovery/Portability Foundation 01). Rough, explicitly-approximate
  ranges (real screenshots compress well as JPEG @0.9 quality — often
  150KB-1MB; real camera photos compress far less — often 2-6MB;
  assume ~800KB/item blended average across a realistic screenshot-
  heavy archive):

  | Cherries | Category A (media, ×2) | Category B (metadata) | Category C (cache/temp) |
  |---|---|---|---|
  | 100 | ~160MB | ~0.2MB | ~0 (in-memory only) |
  | 1,000 | ~1.6GB | ~2MB | ~0 |
  | 5,000 | ~8GB | ~10MB | ~0 |
  | 10,000 | ~16GB | ~20MB | ~0 |

  Category B (title/tags/note/URL/timestamps — small strings/scalars
  outside the externalStorage blob) is negligible at every tested size.
  Category C: `ImageDecodeCache` is `NSCache`-backed, RAM-only, zero
  disk footprint (Performance Foundation 01); transient staging files
  from the atomic-write fix above are cleaned up within the same
  function call, never accumulate. A photo-heavy (vs. screenshot-heavy)
  archive could run several times higher than this table — these are
  genuinely rough planning ranges, not measured facts.
- **Orphan/leak assessment: no new leak source found, existing ones
  already tracked.** The only accumulation sources are the already-
  documented ones (Data Integrity Foundation 01, Share/Capture
  Reliability Foundation 01): media staged for a cancelled/abandoned
  capture. `IntegrityCheck.orphanedMediaFilenames` already detects
  these. **What proof a future conservative GC pass would need before
  ever deleting a file:** (1) no live *or* soft-deleted `StoredItem
  .localFilename` references it (already checked); (2) it's
  meaningfully older than any plausible in-flight capture/share session
  — a conservative age threshold (e.g. 24-48h), not just "orphaned right
  now," to never race a draft the user hasn't finished with yet. Not
  implemented — detection only, per this pass's explicit scope; "when
  uncertain, preserve user media."
- **`MediaStore.totalBytesOnDisk()`** (new, Phase 9): a plain
  `FileManager` enumeration summing `.totalFileAllocatedSizeKey` (real
  disk blocks used) across `MediaStore`'s directory, skipping hidden/
  staging files. O(file count) — cheap at realistic archive sizes, but
  not free; diagnostic/test use only, on-demand, never wired into
  launch. No user-visible surface — a future "Your archive uses 8.4GB"
  feature could read from this, but that UI is undesigned and out of
  scope here.
- **Not simulated directly, and why:** a genuinely truncated mid-write
  file (vs. the "never created at all" failures this pass's tests
  exercise) would need either an actual full disk or a custom
  `FileManager`-replacing seam — the former is explicitly forbidden
  ("never fill the real device disk"), the latter would mean refactoring
  `MediaStore` for test-double injection, explicitly discouraged
  ("do not refactor the storage architecture for test purity"). Given
  `Data.write(options: .atomic)` and the new copy-then-atomic-move
  pattern are both *Foundation's own* documented guarantees, not
  Cherries-authored logic, this pass verified the failure-injectable
  parts (missing source, no staging-file leakage) and relied on
  documented framework behavior for the rest, rather than building
  infrastructure to re-prove what the platform already guarantees.

## Lifecycle / Transaction Contract (Fault Injection Foundation 01)

From deliberately interrupting Cherries at ugly moments — cancellation,
backgrounding, termination, duplicate callbacks, injected save failures —
across every atomic user operation (capture, crop, the four Item Detail
siderooms, favorite, folder create/move/delete). Core rule: every
operation leaves either a valid persisted Cherry or a cleanly
cancelled/failed one — never an ambiguous half-Cherry.

- **HIGH, found and fixed: Item Detail's four siderooms (Notes/Source/
  Tags/Folder) dismissed as if saved even when the save failed.** Each
  room's `onConfirm` closure ran `try? repo.updateX(...)` and then
  unconditionally cleared `activeRoom`, closing the room regardless of
  whether the write actually succeeded — a genuine save failure (e.g. a
  poisoned context) rolled the field back to its prior value exactly as
  designed, but the UI had already dismissed as if the edit stuck,
  silently discarding what the user typed with no error shown. Fixed to
  mirror `CropEditorView`'s existing, already-correct pattern: the room
  only dismisses on a successful save; on failure it stays open with the
  user's draft intact, so a retry is always possible and nothing is
  silently lost. The Folder room's "Unfiled" path mutates `item.folder`
  directly before calling `setMemberships` — proven (see
  `LifecycleFaultInjectionTests`) that `setMemberships`'s rollback
  reverts that outer mutation too, since `ModelContext.rollback()` acts
  on every pending change on the shared context, not just the ones the
  failing method itself made. No manual revert needed.
- **Found and fixed (narrow, storage-hygiene only): three cancel paths
  left an orphaned `MediaStore` file that a well-defined "yes, this is
  abandoned" moment could reclaim immediately instead of waiting for
  `IntegrityCheck` to notice it later.** `ScreenshotCaptureFlowView`'s
  two cancel controls and the Share Extension's Cancel now delete the
  draft's staged file at the exact point cancellation is confirmed.
  `CaptureSheetView`'s add-mode dismiss button does the same for a
  staged-but-unconfirmed photo — but *only* when `confirmingFolderID ==
  nil`: `confirm(_:)` schedules its actual save after a 180ms delay that
  dismissing does **not** cancel, so cleaning up unconditionally could
  delete the exact file a still-in-flight save is about to read into a
  StoredItem, turning a valid Cherry into one with no recoverable media
  at all. The Share Extension's version needed the equivalent guard —
  `didSave`, set only after `fileCapture` returns successfully — since
  its Cancel control has no built-in disabled state during a save.
- **Verified, not changed: capture crash safety across the whole
  lifecycle.** Media-write-succeeds-then-death leaves an orphan file but
  never a fake `StoredItem` (fileCapture is the only place one gets
  created, and it always runs synchronously and atomically). StoredItem-
  save-succeeds-then-death is safe by construction: `Repository.save()`
  is a synchronous, ACID-committed SQLite write, durable the instant it
  returns — a Cherry that saved but whose confirmation UI never ran
  still exists exactly once on relaunch. `ScreenshotDetector`'s
  reentrancy guard (`isChecking`) and every confirm button's own
  `guard !didSave`/`!isSaving` are structurally sufficient — SwiftUI
  delivers taps serially on the main actor, so two overlapping
  synchronous confirms were never actually possible; the guards are
  correct belt-and-suspenders, not load-bearing against real
  concurrency. Share Extension `completeRequest` stays exactly-once via
  the existing `didComplete` guard (Share/Capture Reliability
  Foundation 01) — unchanged, reconfirmed.
- **Verified: entering background never promotes an unconfirmed draft to
  a persisted edit.** Nothing hooks `scenePhase` to any `Repository`
  write for a sideroom/crop/capture draft — those are plain `@State`,
  which SwiftUI keeps alive across backgrounding and only loses on an
  actual process death, matching the explicit product semantic
  ("losing an unconfirmed draft to termination is acceptable; do not add
  draft persistence to survive it"). `ImageBackfill`/`SeedGate`'s
  background-activation Tasks are separately safe by the same
  resumable-batch design already documented — an interrupted batch
  simply gets picked up again next foreground activation.
- **Known, accepted, unchanged: a second screenshot detected while a
  capture drawer is already open silently replaces it** — confirmed this
  also fires via the plain background→foreground reactivation path
  (`RootView`'s `scenePhase` hook re-runs `checkForScreenshots()` on
  every return to `.active`), not only live in-app detection. Same
  already-deferred product decision from Share/Capture Reliability
  Foundation 01 (`CaptureCoordinator.present(_:)` overwrites `drawer`
  rather than queuing) — not touched here.
- **Known, accepted, unchanged: `fileCapture` has no idempotency key.**
  Characterized precisely rather than re-litigated: since `fileCapture`
  itself never retries automatically (a Swift call either returns,
  meaning success, or throws, meaning failure — there is no ambiguous
  in-process middle state), the realistic trigger for a duplicate Cherry
  is a *human* repeating the physical share/capture action after not
  seeing a confirmation UI they were durably owed (see the StoredItem-
  save-succeeds-then-death case above) — not a code-level retry bug.
  Still schema-adjacent and out of scope; see `testRepeatedFileCapture
  ForTheSameDraftCreatesTwoDistinctItems`.
- **Known, accepted, unchanged: Folder creation is not fully
  transactional the way the rest of the Folder room is.** `+ New Folder`
  persists a real `StoredFolder` immediately on its own sheet's Create
  tap — only the *assignment* to the current item stays staged behind
  the room's own ✓. Pre-existing, already documented at the call site;
  restated here because Section 6 of this pass asked for an honest
  characterization rather than a claim of full transactionality.
- **Verified: crop interruption safety end-to-end.** Entering the editor
  never mutates the persisted crop (only reads it, to seed local
  `@State`); every pan/pinch/resize stays local until Done; Cancel or
  termination before Done leaves the prior crop untouched (no Repository
  call is even attempted); a failed re-crop save leaves the previous
  valid crop exactly intact (rollback — see
  `testUpdateCropRegionRollsBackOnInjectedSaveFailureLeavingPreviousCropIntact`)
  and the editor stays open rather than silently discarding the attempt;
  a confirmed crop survives a fresh `ModelContext` read (relaunch
  simulation). No crop math touched.
- **Rollback contract stress-tested across every representative mutation
  kind**, not just `fileCapture`/`setMemberships` (Data Integrity
  Foundation 01's original coverage): note, source, tags, favorite,
  move, crop region, and soft-delete each verified to (1) genuinely
  throw under a real injected failure, (2) leave the in-memory field
  exactly at its last-saved value afterward — never a half-applied
  mutation — and (3) succeed cleanly on an immediate retry on the same
  context. No new fault-injection production code was added — every
  test reuses Data Integrity Foundation 01's existing genuine-failure
  technique (a pending relationship to an object from a different
  container's context, which makes SwiftData's own `save()` genuinely
  reject the whole pending transaction), just aimed at more mutation
  types.
- **`IntegrityCheck` integrated into the fault-injection harness rather
  than duplicated**, per this pass's own instruction: one test performs
  a genuinely-failed, rolled-back mutation and then runs the existing
  DEBUG scan against the same context, confirming a rolled-back failure
  leaves nothing behind for it to flag.
- **Memory pressure:** `ImageDecodeCache` is `NSCache`-backed and evicts
  under system pressure by Foundation's own documented contract
  (Performance Foundation 01); nothing here ever discards a persisted
  original or mutates logical state in response to memory pressure — no
  new benchmarking needed, per this pass's own scope.

## Media Architecture Contract (Cutover 01)

Following the Media Storage Architecture / Media Cache Foundation / Option
2 Validation Gate milestone sequence (all empirically validated, including
a real two-device CloudKit sync test), Cherries' media architecture is:

- **Authoritative durable local + remote media:** `StoredItem.imageData`
  (`@Attribute(.externalStorage)`). Populated synchronously inside
  `Repository.fileCapture`; durable the instant that `save()` returns
  (SQLite's ACID commit), independent of CloudKit upload timing or network
  state. Its CloudKit-managed local representation (`_EXTERNAL_DATA`)
  remains backup-eligible — it's the actual durable copy.
- **Remote durable media:** the private CloudKit database, via the CKAsset
  SwiftData's CloudKit integration mirrors from `imageData` — entirely
  framework-managed, no custom sync code.
- **Derived local working cache:** `MediaStore`. Bounded (1GB default,
  `MediaStore.cacheCapacityBytes`), reconstructable byte-for-byte from
  `imageData` on any cache miss (`MediaStore.data(for:reconstructingFrom:)`,
  coalesced across concurrent requests by `MediaCacheCoordinator` — a real,
  demonstrated duplication this actor exists to prevent, not a
  hypothetical), and excluded from device backup
  (`MediaStore.excludeFromBackup()`, reaffirmed on every `init()` rather
  than assumed to survive directory recreation).
- **The authority transition:** every capture surface still writes to
  `MediaStore` *first* (before a `StoredItem` exists — nothing about
  capture ordering changed). The instant `Repository.fileCapture`'s
  `save()` succeeds, `imageData` is authoritative and `MediaStore`'s file
  becomes redundant cache. Pre-save cancel/orphan cleanup
  (`ScreenshotCaptureFlowView`, `ShareViewController`, `CaptureSheetView`)
  is unaffected — that window predates `imageData` entirely.
- **One Archive thumbnails decode directly from `imageData` on a cold
  cache miss** — no `MediaStore` file is written merely to render a small
  tile. Only full-resolution consumers (Item Detail, Crop Editor) warm the
  cache, since a real file benefits repeat full-resolution access.
- **A missing `MediaStore` file is the routine, expected cold-cache-miss
  state, not corruption** — `IntegrityCheck.isClean` now depends only on
  `itemsWithNoKnownRecovery` (imageData also absent — genuine MEDIA LOSS),
  not on `itemsWithMissingMedia` (which includes every ordinary CACHE
  MISS/recoverable state).
- **A failed cache write never blocks viewing a Cherry** — if `imageData`
  is readable but the cache write fails (e.g. low disk), the caller still
  gets the bytes; only the on-disk cache copy is missing.
- **No mass migration.** Existing users already have byte-identical
  `MediaStore` + `imageData` copies (confirmed since D3A) — cutover
  required no rewrite of existing data, only a declaration of which copy
  is authoritative going forward.

## Cache Eviction Contract (Eviction Activation 01)

`MediaStore.evictionEnabled = true` — production eviction is live, after
a dedicated deletion-contract audit found and fixed two real structural
gaps the safety ramp above existed specifically to catch before this flag
could safely flip.

- **Capped at 1GB** (`MediaStore.cacheCapacityBytes`) — a single fixed
  constant, not adaptive/proportional.
- **Opportunistic, not a daemon.** The only production trigger is once
  per foreground activation (`RootView`'s `scenePhase` hook, mirroring
  `ImageBackfill`/`SeedGate`'s existing pattern) — no perpetual background
  worker, no post-write trigger (removed — see below).
- **Modification-date recency approximates LRU**, bumped on every cache
  hit — intentionally approximate, not perfect theoretical LRU, per this
  milestone's own explicit scope.
- **Two structural (not timing-based) protections**, both proven via
  dedicated tests, not assumed:
  - `MediaStore.evictionGracePeriod` (5 minutes) — no file younger than
    this is ever eviction-eligible, regardless of cache pressure or sort
    order. Protects the pre-save/authority-transition window: a freshly
    staged capture has no `StoredItem`/`imageData` yet, and eviction has
    no way to know that from the filesystem alone.
  - `Repository.filenamesLackingImageData()`, threaded through as
    `evictIfNeeded(protecting:)` at the one call site with SwiftData
    access (`RootView`). Protects historical/pre-`ImageBackfill` items
    whose `MediaStore` file is still their only local copy. Fails
    CLOSED — if this query itself throws, that pass skips eviction
    entirely rather than risk evicting without full protection. This is
    also why the post-write eviction trigger `reconstruct(filename:from:)`
    used to have was removed entirely: `MediaStore` has no SwiftData
    access at that call site to compute this protection, so it no longer
    triggers eviction at all — only `RootView`'s foreground pass does.
- **Deletion failures are tolerated, never faked as success.** A file
  that can't be removed (e.g. `evictIfNeeded`'s own byte-accounting)
  is only ever subtracted from the running total on a CONFIRMED removal
  — the cap is a goal the next opportunistic pass will keep pursuing,
  never a guarantee worth risking data over.
- **Missing cache is normal, cache deletion never implies Cherry
  deletion.** `imageData` is authoritative; a `MediaStore` file's absence
  — whether never-written or evicted — is the same routine cold-cache-miss
  state either way, self-healing on next access.
- **Real-device performance:** scan+trim of a realistic ~1,500-file cache
  measured ~135ms, entirely off the main actor, imperceptible in the
  backgrounded foreground-activation trigger it runs from.

## Build

Requires Xcode 16+ and [XcodeGen](https://github.com/yonsson/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate          # regenerates ScreenshotApp.xcodeproj from project.yml
open ScreenshotApp.xcodeproj
```

Then select the **Arkyv** scheme and run on an iPhone / simulator.

> **Note on the App Group entitlement:** the app, Share Extension, and macOS app
> share `group.com.deadwest.cherries` (SwiftData store + media live there).
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

## Multi-Device Consistency Contract (Foundation 01)

Cherries relies entirely on SwiftData/CloudKit's native merge behavior —
there is no custom sync engine, CRDT, or version-vector layer, and this
milestone deliberately did not build one. What follows is the empirical
v1 conflict contract, confirmed via real two-device testing (Sammy's
iPhone 17 Pro Max + a second iPhone, same iCloud account), not assumed.

**Safety result: no CRITICAL or HIGH defects found.** Across baseline
convergence, concurrent favorite/note/sourceURL/tag edits, folder
move/delete/creation races, crop conflicts, delete-vs-edit races,
delete-vs-cache-reconstruction, simultaneous captures, and an
offline-then-reconnect batch edit, `imageData` (the durable media
authority) was never lost or corrupted, no logical Cherry ever vanished,
no item ever became unreachable, and a full-archive `IntegrityCheck` on
both devices after the entire stress campaign reported
`itemsWithNoKnownRecovery` (real media loss) and `duplicateActiveMemberships`
at **zero on both devices**.

**Per-field conflict semantics:**

- **Favorite / note / sourceURL** — plain scalar last-writer-wins at
  CloudKit record granularity. Converges reliably; no character-level or
  partial merge (a note fully replaces, never blends).
- **Tags** — confirmed **whole-array last-writer-wins, not a merged
  collection**. Two devices independently adding different tags to the
  same item does *not* preserve both additions — one array wins outright,
  and the other device's addition is silently, completely dropped with no
  indication to either user. Treat as a real product limitation, not a
  bug: this is exactly how a `[String]` property syncs under CloudKit's
  per-record model.
- **Folder placement** — the weakest point in the contract. Folder
  membership (`StoredFolderMembership`) rows are independent CKRecords,
  so two devices concurrently moving the same item into two *different*
  folders can each successfully insert their own row, and CloudKit has no
  reason to conflict two inserts of different records — both sync down as
  simultaneously active. Confirmed as a real, non-trivial pattern: **11
  items in the live archive** carry 2+ active folder memberships at once.
  This is not corruption (the schema already allows multi-folder
  membership) and the item stays fully reachable, but it's very likely
  unintended by the user rather than deliberate multi-select. The legacy
  `item.folder` scalar resolves independently via ordinary last-writer-wins
  and may not agree with either device's last local action.
- **Folder deletion** — deactivates the folder's memberships but does
  **not** clear `item.folder` on member items (pre-existing Repository
  behavior, not introduced by this milestone). A deleted folder can leave
  member items with a stale legacy pointer; the item remains fully
  retrievable via the canonical membership-based read path (effectively
  Unfiled). This is exactly the shape `IntegrityCheck.folderMembershipDisagreements`
  already exists to catch.
- **Folder creation** — clean. Two devices creating folders with the same
  display name produce distinct UUIDs and both sync correctly as separate
  folders; duplicate names are allowed by design in v1.
- **Crop** — whole-region last-writer-wins (`CropRegion`'s 4 doubles
  replace atomically). One complete, valid crop always won outright — no
  hybrid or invalid crop was ever observed. Convergence was noticeably
  slower than scalar fields (~2 minutes observed vs. ~15-30s).
- **Soft-delete** — last-writer-wins scalar. Under a genuine concurrent
  delete-vs-edit race, `isSoftDeleted` divergence between devices was
  observed to persist for several minutes before converging — but
  `imageData` stayed fully intact throughout the entire divergence window
  in every case, including while independently exercising cache
  eviction/reconstruction mid-divergence on the device that hadn't yet
  learned of the deletion. No hard-delete exists; this milestone
  confirmed a soft-deleted item never becomes destructive to authoritative
  media, even mid-race.
- **Simultaneous new captures** — clean. Two near-simultaneous captures
  on different devices produced distinct UUIDs and `localFilename`s, no
  collision, and correctly-paired `imageData` on both devices.
- **Offline batch edit → reconnect** — a device that made several edits
  while genuinely offline (Airplane Mode) converged cleanly once
  reconnected, with no corruption, no crash, and media intact.

**Convergence timing is not uniform and is sensitive to how quickly the
writing device goes quiet after a local edit.** CloudKit's background
export needs real wall-clock time after a commit to actually serialize
and transmit; a process that terminates or backgrounds very soon after a
write can outrace it. Confirmed directly: an otherwise-identical note
conflict stayed divergent for 60+ seconds with no post-write delay, and
converged immediately with a 5-second delay before process exit. This is
a genuine characteristic of the sync model, not merely a test-harness
artifact — Cherries itself has no code path that force-exits after a
write, but backgrounding shortly after an edit is an ordinary, frequent
mobile scenario that plausibly has the same effect.

**CloudKit error visibility: silent-only today.** Confirmed via full
source review — no `CKError`, `NSPersistentCloudKitContainerEvent`, or any
sync-status handling exists anywhere in the app. If an edit never syncs
(quota, account issue, or the timing risk above), there is currently no
in-app signal distinguishing "synced" from "pending" from "stuck." No UI
or implementation work was done this milestone (correctly out of scope)
— flagged for future product consideration, not a defect in itself.

**Two narrow, diagnostic-only fixes were made to `IntegrityCheck`** (no
schema, sync, or UI changes):
- Added `itemsWithMultipleActiveFolders` — surfaces items with 2+
  simultaneously-active folder memberships (see Folder placement above).
  Report-only; nothing here auto-resolves a multi-folder race, since doing
  so would mean picking a winner across devices — exactly the kind of
  custom conflict protocol this milestone is scoped to avoid building.
- Fixed a real non-determinism bug in `folderMembershipDisagreements`:
  its "expected legacy folder" pick for an item with multiple active
  memberships depended on `Dictionary`-grouping iteration order, which
  Swift randomizes per-process — so two devices scanning *identical*
  synced data could report different disagreement counts for reasons
  unrelated to their actual data. Confirmed directly (16 vs. 10-16 across
  runs before the fix) and confirmed fixed (16 = 16 on both devices,
  repeatable) by sorting deterministically before picking.

**Remaining risks (no CRITICAL/HIGH found):**
- MEDIUM — tags can silently lose a concurrent addition with zero
  indication to the user.
- ~~MEDIUM — concurrent folder moves can leave an item in 2+ folders at
  once from an unintended race~~ — **resolved, see Single-Folder Invariant
  Foundation 01 below.**
- MEDIUM — CloudKit sync status is entirely invisible to the user.
- LOW — convergence latency varies significantly by field/payload size
  and by how quickly the app goes quiet after a write.

None of these are custom-sync/CRDT-shaped problems — they're either
already-detectable via `IntegrityCheck`, or product/UX questions (tag
merge UX, multi-folder surfacing, sync status visibility) for a future,
separately-scoped milestone.

## Single-Folder Invariant Contract (Foundation 01)

**GREEN.** The product contract — a `StoredItem` has zero active folder
memberships (Unfiled) or exactly one, never more — is now enforced and
deterministic across devices, confirmed via real two-device testing. No
custom sync engine, CRDT, or version vector was built.

**Canonical representation:** `StoredFolderMembership` is the canonical
relationship; `StoredItem.folder` is a compatibility mirror that must
agree with it, never an independent source of truth. `Repository.setMemberships`
is the sole local write boundary and already reconciles `item.folder` to
the membership set on every local write.

**Root cause of duplicate memberships:** membership rows are independent
CKRecords. Two devices concurrently moving the same item to two different
folders each insert their own row; CloudKit has no reason to conflict two
inserts of different records, so both sync down active everywhere.
`setMemberships`'s exclusivity guarantee only covers rows a device
locally knows about at call time — it cannot retroactively deactivate a
row a different device inserts concurrently.

**Reconciliation rule (`FolderMembershipReconciler`):** when an item has
2+ active memberships, the most-recently-created one wins (tie-broken by
membership UUID — never observed in practice, no timestamp ties in the
real archive's conflict set). Every other active membership is
deactivated and `item.folder` is mirrored to the winner. Deterministic
regardless of fetch/`Set`/`Dictionary` iteration order (confirmed via a
25-iteration shuffled-input test) — the exact class of non-determinism
found and fixed in `IntegrityCheck` last milestone. Idempotent: a
no-op (no write, no `save()`) against already-clean state, confirmed on
both synthetic data and the real archive (a second `reconcileAll` pass
produced zero corrections).

**Trigger:** one bounded pass per foreground activation in `RootView`,
alongside the existing `ImageBackfill`/cache-eviction passes — same
pattern, no daemon, no CloudKit polling.

**Real archive repair:** 11 pre-existing real items (predating this
milestone's testing by 9 days — this exact race had already happened
during ordinary two-device use) were previewed read-only, reviewed, and
approved before any mutation. 10 of 11 required only deactivating a
stale hidden membership with **zero visible folder change** — Cherries
was already displaying the correct folder; only the invisible duplicate
underneath was cleaned up. One item's displayed folder changed
(Deadwest → Recipes), correctly reflecting its genuinely most-recent
placement. Confirmed via `IntegrityCheck`: `itemsWithMultipleActiveFolders`
went from 11 to 0, matching on both devices.

**Closeout (same-night follow-up): legacy mirror now agrees in every
case, not just the 2+-membership one.** The 6 `folderMembershipDisagreements`
above were a *different* bug class than the concurrent-move race:
`Repository.removeMembership()` never updated `item.folder` when an
item's last (or a remaining) membership changed, and
`Repository.softDelete(folder:)` deactivated a deleted folder's
memberships but never cleared or re-mirrored affected items'
`item.folder`. Both are now fixed at their own write sites:

- `removeMembership`: mirrors `item.folder` to whichever canonical
  membership remains (via the same `FolderMembershipReconciler.winner`
  rule), or `nil` if none does.
- `softDelete(folder:)`: for every member item, re-mirrors `item.folder`
  to its remaining canonical membership, or `nil` (Unfiled) if the
  deleted folder was its only one. The item itself is never touched
  beyond this — no cascading soft-delete, fully reachable either way.

`FolderMembershipReconciler.reconcileAll`/`.preview` were generalized to
cover this same 0-or-1-membership mirror-mismatch shape, not just the
2+-membership collapse — one mechanism, one rule, for "make `item.folder`
agree with canonical state" in every shape the invariant governs.

The 6 pre-existing real disagreements were classified before repair: 2
were this session's own `mdc-test`-tagged fixtures, 4 were real archive
items — 2 stale-after-`removeMembership`-equivalent-history, 2
stale-after-folder-deletion. All 6 repairs mirrored `item.folder` to
exactly what canonical membership state already showed (a real active
membership, or Unfiled) — none invented a folder outside canonical
state. Since One Archive's own filtering already reads live membership
(not `item.folder`), these items were already displaying correctly
there; the fix corrects Item Detail's Folder-room initial selection,
the one surface that still reads the legacy mirror directly.

Final state, confirmed on both devices: `itemsWithMultipleActiveFolders
= 0`, `folderMembershipDisagreements = 0`, `duplicateActiveMemberships =
0`, `itemsWithNoKnownRecovery = 0`. The single-folder invariant,
including full legacy-mirror agreement, now holds across the entire
real archive.

## Release Environment Contract (Foundation 01)

**CLEAN — code/configuration.** Verified that the architecture validated
in development remains correct under actual Release configuration; no
code changes were required.

- **App/extension entitlement parity confirmed** in the compiled Release
  binary, not just source intent: app and Share Extension embed identical
  `com.apple.developer.icloud-container-identifiers` and
  `com.apple.security.application-groups`.
- **Release build succeeds** (`xcodebuild build`/`archive -configuration
  Release`, full scheme, app + embedded extension).
- **Existing App Group/archive survives a Release-configured install** —
  confirmed via `databaseUUID` staying identical across install (same
  container, not a fresh/wiped one), app launches and runs with no crash.
- **DEBUG diagnostics correctly gated** — exhaustive audit of every `#if
  DEBUG` site across the app, extension, and package; zero instances of
  DEBUG-only code accidentally active in Release.
- **Production logging/privacy hygiene clean** — every `print`/logging
  call site in the codebase is DEBUG-gated; no unconditional production
  logging of notes, URLs, tags, folder names, filenames, or CloudKit
  identifiers.
- **Media/cache architecture identical in Release** — `MediaStore`/
  `ImageDecodeCache` contain no DEBUG conditionals; only compiler
  optimization level differs between configurations, not behavior.

**Release-blocker status:**
- **CONFIRMED BLOCKER:** CloudKit production schema has not yet been
  confirmed deployed. Development CloudKit auto-creates schema as the
  app runs (already exercised all session); production does not —  it
  requires an explicit deploy via CloudKit Dashboard before any
  production-environment build's CloudKit sync will work. Not deployed
  by this milestone, pending manual deployment and confirmation.
- **UNRESOLVED UNTIL REAL ORGANIZER DISTRIBUTION:** distribution signing.
  This environment has no local Apple Distribution certificate, but that
  alone doesn't confirm a blocker — Xcode Organizer's real TestFlight
  distribution workflow supports cloud-managed signing under Automatically
  Manage Signing, which may satisfy distribution without one. Requires
  verification through that actual workflow, not assumed from local
  keychain state alone.

Next: a real TestFlight/production-environment validation milestone,
once the CloudKit production schema deployment above is confirmed.

## Pre-Launch Migration Ferry (Foundation 01)

DEBUG/internal-only migration tooling — not a shipped feature, no UI —
proving the technical-identity cutover plan's chosen path (export → clean
new identity → reimport) is safe before it's ever attempted for real.

- **`CherryManifest`** (extended from its earlier Recovery/Portability
  Foundation 01 export-only form) now carries `imageData` directly and
  provides `importArchive`, which reconstructs folders → items → the
  canonical single-folder membership through the same field-level rules
  `Repository`/`FolderMembershipReconciler` use — not by copying the
  SQLite database. **Fail-closed**: refuses to import into any non-empty
  destination (no merge/idempotency engine — a deliberate scope decision
  for a one-time internal tool). A single atomic `save()` means a failed
  import leaves the destination exactly as empty as it started.
- **`MigrationFerry`** is the on-device harness: exports the real archive
  (read-only), writes the artifact to the app's own Documents directory
  (never the App Group — trivially distinguishable from real archive
  storage), reads it back from disk, imports into a fresh isolated
  in-memory container (never the real App Group or any CloudKit
  container), and runs a full round-trip comparison plus `IntegrityCheck`.
- **Proven against the real archive**: 84 items (83 active, 1
  soft-deleted), 12 folders, 75 memberships, ~73.6MB of authoritative
  `imageData` — exported in 0.27s to a 101,098,627-byte JSON artifact
  (SHA256 `1e1bef03…0ce441ed`, independently re-verified off-device),
  imported in 0.04s. Round-trip comparison: **zero mismatches** across
  imageData byte-identity, crop regions, and all metadata/membership
  fields, for every item. `itemsWithMultipleActiveFolders`,
  `folderMembershipDisagreements`, `duplicateActiveMemberships`, and
  `itemsWithNoKnownRecovery` all zero in the reconstructed isolated
  archive. Real archive confirmed unchanged afterward (item/folder counts
  identical before and after).
- **GREEN** — the current real archive can be exported and reconstructed
  byte-for-byte into a fresh isolated store. Safe to proceed to the
  technical-identity cutover this ferry exists to prepare for.

## Technical Identity Cutover (Foundation 01)

**GREEN — permanent namespace live, new environment verified empty, old
environment fully intact.** A clean cut (no dual-container bridge) from
the prototype Expat Insurance / Arkyv namespace to the permanent
Deadwest / Cherries identity:

| | Legacy (still installed, untouched) | Permanent |
|---|---|---|
| App | `com.expatinsurance.arkyv` | `com.deadwest.cherries` |
| Share Extension | `com.expatinsurance.arkyv.Share` | `com.deadwest.cherries.share` |
| macOS | `com.expatinsurance.arkyv.mac` | `com.deadwest.cherries.mac` |
| App Group | `group.com.expatinsurance.arkyv` | `group.com.deadwest.cherries` |
| CloudKit | `iCloud.com.expatinsurance.arkyv` | `iCloud.com.deadwest.cherries` |

No record migration was attempted from the legacy CloudKit container —
the pre-launch migration artifact (`Cherries_PreLaunch_Migration_2026-08-19.json`,
verified byte-identical, stored outside the project at `~/Documents/Cherries
Migration Backup/`) is the sole transfer mechanism, applied in a later,
separate milestone. No Production CloudKit schema deployed.

**Verified on physical device:** both identities coexist (old app/archive
completely unaffected — `itemCount=84` unchanged); new app launches to a
genuinely empty archive (0 items, 5 default-seeded folders, `isClean=true`);
compiled entitlements confirmed correct via `codesign`, not just source
files, on both the main app and Share Extension; the new App Group
container confirmed physically distinct with `arkyv.store`/`Media/`
correctly nested under it; one disposable, clearly-tagged test item
confirmed local `imageData` persists normally in the new environment.
Zero remaining production/runtime references to the legacy namespace —
only one intentional, documented comment explaining the cutover.

**Known limitation:** the `ArkyvMac` app target has no XcodeGen-generated
scheme, so it can't be built via a bare `xcodebuild -target` invocation
outside Xcode's own GUI (pre-existing gap, unrelated to this cutover —
its identity/build *configuration* was verified via `-showBuildSettings`
instead, and the shared `ArkyvKit` package it depends on builds cleanly
for macOS via its own scheme).

Next: import the verified migration archive into the new environment.

## Real Archive Import (Foundation 01)

**GREEN.** Sammy's 84-item legacy archive is now live in the permanent
`com.deadwest.cherries` environment, imported from the verified
migration artifact — the old `com.expatinsurance.arkyv` environment
remains fully intact as the rollback path.

**Fail-closed check generalized from "empty" to "no collision."**
`CherryManifest.importArchive` originally refused any non-empty
destination (`Pre-Launch Migration Ferry 01`'s stricter rule, correct
for an always-empty isolated test store). A real cutover legitimately
leaves unrelated content in the new environment first (a disposable
CUTOVER-TEST item, a real Share Extension test Cherry, 5 default-seeded
folders) — none of that should block or be touched by the legacy
import. `ImportError.identityCollision` replaces `destinationNotEmpty`:
refuses only if an archive item/folder id already exists in the
destination, never reads or modifies unrelated existing rows otherwise.

**Result:** import succeeded — 84 items, 12 folders, 75 memberships,
73,638,128 bytes of `imageData`, matching the artifact exactly. **Zero
fidelity mismatches** across imageData byte-identity, crop regions, and
all metadata/membership fields for every item. Post-import
`IntegrityCheck` against the real container: `itemsWithMultipleActiveFolders
= 0`, `folderMembershipDisagreements = 0`, `duplicateActiveMemberships =
0`, `itemsWithNoKnownRecovery = 0`, `isClean = true`. A second import
attempt against the now-populated store correctly refused via identity
collision on all 84 item ids and 12 folder ids — confirmed duplicate-safety
directly on real data, not just synthetic tests. The old environment's
84-item archive was re-verified unchanged (exact baseline) before and
after.

Unrelated pre-existing content survived exactly as expected: 86 total
items (84 imported + 2 pre-existing — one disposable `mdc-test`-tagged
CUTOVER-TEST item, safe to delete at your discretion, and one real
Share Extension test Cherry), 17 total folders (12 imported + 5
default-seeded).

Next: two-device restore/sync validation, once Device A's migrated
archive is reviewed.

## Post-Migration Folder Reconciliation (Foundation 01)

**GREEN.** Sammy's physical-device sanity pass caught 5 duplicate folder
names (Deadwest, Cool Shit, Recipes, Japan 2026, Inspiration) — each
pair one populated, one empty.

**Root cause:** `SeedGate`'s 5 hardcoded default folder names (see
`SeedGate.swift`) are, not coincidentally, Sammy's own real folder
names — chosen as personally meaningful example defaults. When the new
`com.deadwest.cherries` identity first launched (genuinely empty App
Group + CloudKit container), SeedGate correctly did its designed job
after 90 seconds of observing an empty, iCloud-present store — exactly
the heuristic it uses to tell "brand-new user" apart from "existing
user whose CloudKit import hasn't landed yet." The later, deliberate
`Real Archive Import 01` then reconstructed the same-named originals
with their own preserved stable identities, producing the 5 collisions.
Not a bug in SeedGate — a one-time interaction between correct default
seeding and a manual JSON-based restore, a combination normal use
(fresh install + ordinary CloudKit sync, or a genuinely new user) never
produces.

**Proof before deletion** — four independent signals agreed exactly for
all 5 pairs: migration-manifest presence (kept ids present, deleted ids
absent), `dirty` flag (seeded `false`, imported `true` — `SeedGate`
explicitly clears it, `importArchive` never touches it), active
membership count (seeded 0, imported >0), and `createdAt` (all 5 deleted
rows share the identical SeedGate bulk-seed timestamp). Deleted via
`Repository.softDelete(folder:)`, the established path — no hand-edited
store, no items moved, no populated folder touched.

**Verified after:** `itemCount` unchanged (86), imported legacy payload
unaffected (imageData/crops/tags/notes/sourceURL/favorites/timestamps/
soft-delete state all untouched), `IntegrityCheck` clean on all four
targets, exactly one live folder per name. Old environment reconfirmed
unchanged (84/12/101).

**Seeding behavior:** no production code change needed. `SeedGate`
seeding brand-new users their 5 example folders remains correct,
intended behavior. The collision only arises from `CherryManifest.importArchive`
— a DEBUG-only, manually-triggered, one-time migration tool, not a
normal product flow — being run against an environment SeedGate had
already (correctly) populated. This was a one-time event specific to
this cutover.

## Pre-Sync Test Residue Cleanup (Foundation 01)

**GREEN.** Removed engineering test debris that had been faithfully
(correctly) migrated from the legacy archive, before Device B ever
reconstructs the new environment via CloudKit.

**Critical finding — a caught false positive.** The visible "Test"
folder's 5 members looked, by name and folder alone, like an obvious
engineering-residue candidate. Direct inspection proved otherwise:
zero test tags, and real, varying `imageData` sizes (367KB–4.4MB) with
real camera/screenshot dimensions (3024×4032, 1290×2796, 4284×5712) —
nothing like this repo's stress-test harnesses, which all generate a
fixed, tiny 35,520-byte synthetic image. Confirmed genuine Sammy
content and left untouched. This is exactly why the cleanup required
read-only, evidence-based proof (tags, byte sizes, dimensions, harness
name-literal matches) before any deletion, never inference from a name
alone.

**Removed, all independently proven synthetic:** 4 empty folders (`MDC
Folder A`, `MDC Folder B`, `MDC Collision` ×2 — zero relationships,
exact string match to this repo's own hardcoded harness folder-name
literals) and 5 items (all `mdc-test`-tagged, all exactly 35,520 bytes,
all Unfiled — including the disposable `CUTOVER-TEST` item created
during the identity cutover). Two already-soft-deleted `MDC Folder X`
rows needed no action. Sammy's real Share Extension test Cherry was
explicitly preserved per instruction.

**Result:** `IntegrityCheck` clean on all four targets after cleanup;
6 live folders remain (the 5 real migrated folders plus Sammy's genuine
`Test` folder); old environment reconfirmed unchanged (84/12/101).

## Two-Device Restore / Sync Validation (Foundation 01)

**GREEN.** Proved that a second physical device (iPhone 14 Max)
reconstructs the permanent `com.deadwest.cherries` archive through
ordinary CloudKit sync alone — no App Group copy, no MediaStore copy,
no migration JSON import, no manual file transfer. The only input to
Device B was a clean app install pointed at `iCloud.com.deadwest.cherries`.

**Restore fidelity.** Device B converged to the exact Device A baseline:
identical item/folder/membership counts, identical folder identities and
names, `IntegrityCheck` clean on both devices
(`isClean=true`, `folderDisagreements=0`, `duplicateMemberships=0`,
`multiFolderItems=0`, `noKnownRecovery=0`). A new `media-fingerprint`
harness action (SHA-256 over all live items' `(id, imageData)` pairs,
sorted by id) proved byte-exact media identity across both devices,
before and after the live sync test.

**Transient finding, not a defect.** Immediately after the fresh Device B
install, `IntegrityCheck` briefly showed `folderDisagreements=8` even
though item/folder/membership counts and total media bytes had already
fully converged — all 8 disagreements were items with `legacyFolder=nil`
but exactly one valid active membership. `reconcile-folders` found
nothing to fix (`reconciled=0`), and a fresh check moments later showed
`folderDisagreements=0`. This is cold CloudKit relationship-sync
ordering (the `item.folder` to-one reference settling slightly behind
other data during bulk initial import), not corruption, and it
self-resolved within about a minute of ordinary continued sync.

**Live bidirectional sync test.** Created `TWO-DEVICE-TEST-A` on Device A
and confirmed it reached Device B; edited it on Device B (appended
`#two-device-b`) and confirmed the edit reached Device A. Both
directions verified by exact field match (`noteBody`, `updatedAt`,
`imageDataBytes`).

**Key operational finding.** The A→B leg of the live sync test initially
appeared stuck — over 10 minutes and 20+ terminate/relaunch poll cycles
(~15–20s each) with no sign of the new item on Device B, in sharp
contrast to the full 86-item/74MB initial restore, which converged in
about a minute. The cause was the polling method itself: rapid
terminate/relaunch cycling never gave CloudKit's incremental-sync
machinery a continuous, undisturbed runtime window to complete an
import. Leaving the app foregrounded and untouched for a single
uninterrupted ~2-minute window let the same change complete normally.
The initial bulk restore was unaffected by this because it had a long
continuous window on its very first post-install launch. Any future
single-item sync testing on this harness should prefer one long
foreground dwell over many short relaunch cycles.

**Legacy environment:** confirmed untouched throughout — `arkyv`
(`com.expatinsurance.arkyv`) remains installed and running on Device A,
the migration backup file's SHA-256 is unchanged
(`1e1bef03...ce441e`), and no Production CloudKit schema was deployed.

## Permanent Environment Closeout (Foundation 01)

**GREEN.** Migration/sync chapter is now CLOSED. The permanent
`com.deadwest.cherries` environment is left in a clean everyday-use
state, with the legacy `arkyv` environment retained intentionally as a
rollback copy — not retired.

**TWO-DEVICE-TEST-A removed.** Identity confirmed before deletion
(`id=52B25162-4C90-400B-95E8-15DC7D5F1EAC`, `tags=["tagA","mdc-test"]`,
`noteBody` carrying both the A-side and B-side edits) via a hardcoded,
safety-checked harness action — never inferred from timestamp or name
proximity alone. Soft-deleted on Device A; convergence to Device B
confirmed (`isSoftDeleted=true`, matching `deletedAt`) after one
undisturbed foreground dwell, applying the "long dwell over rapid
relaunch cycling" lesson from the prior milestone. Active item count
returned to the pre-test baseline of 80.

**Manual Share Extension test Cherry identified, not deleted.**
`id=4EB86B4C-3478-4168-8089-38A91FED21D7`, created 2026-08-19 21:55:29
UTC, Unfiled, `sourceDevice=iOS`, `kind=screenshot`, 255,803 bytes, no
tags/title/note. Stood out unambiguously from the legacy archive by
`sourceDevice`: every migrated item shows `sourceDevice=unknown`
(preserved from the legacy JSON, which predates this field's iOS-vs-
unknown distinction); only this one item is `iOS`. Left in place per
instruction — not tagged synthetic, so not eligible for automatic
removal; Sammy can delete it manually if he wants to.

**Final two-device baseline:** both devices converged to identical
`IntegrityCheck` results — `isClean=true`, 87 total items (80 active / 7
soft-deleted), 17 folders, 75 memberships, `folderDisagreements=0`,
`duplicateActiveMemberships=0`, `itemsWithMultipleActiveFolders=0`,
`itemsWithNoKnownRecovery=0`.

**Rollback retention confirmed:** `com.expatinsurance.arkyv` installed
and present on both devices; the migration backup JSON's SHA-256 is
unchanged; no legacy Apple Developer resources were touched; no
Production CloudKit schema deployed; no App Store Connect work
performed.

**Action Button follow-up (read-only audit):** the codebase registers
no custom URL scheme and no App Intents, so the Action
Button/Shortcuts integration is necessarily a system-level "Open App"
selection, not a programmatic deep link this repo controls. Manual
steps for Sammy, depending on how it's currently configured:
- *If the Action Button is set directly to "Open App":* Settings →
  Action Button → swipe to "Open App" → "Choose an App" → select
  **Cherries** (now visually distinct from `arkyv`).
- *If the Action Button runs a Shortcut containing an "Open App"
  step:* Shortcuts app → open that shortcut → tap the app field on its
  "Open App" action → reselect **Cherries**.

**Migration chapter status: CLOSED.** Technical identity migration,
real archive migration, post-migration reconciliation, and two-device
restore/sync validation are all closed. The permanent Cherries
environment is now the development/daily-use authority; `arkyv` remains
installed on both devices as a deliberate rollback copy.

## URL → Cherry (Production Foundation 01)

**GREEN.** "A user does not save a link, they save the thing it points
to." `URLCherryResolver` (`Packages/ArkyvKit/Sources/ArkyvKit/Capture/URLCherryResolver.swift`)
turns a shared URL into an ordinary image-backed `CaptureDraft` using
Apple-native `LPMetadataProvider` — no platform-specific adapters, no
schema changes. It feeds the exact same `Repository.fileCapture` path
every other image capture already uses; this is not a parallel
persistence system.

**Integration point:** the one existing URL branch in
`ShareViewController.extractDraft()` — previously always returned a
contentless `CaptureDraft(kind: .text, title: url.host, sourceURL:
url.absoluteString)`. Now it first attempts `URLCherryResolver.resolve`;
on ANY failure (no network, timeout, no image, undecodable bytes) it
falls straight through to that exact same text-only draft. Resolution
is an enhancement, never a new failure dependency.

**Original URL, not canonical URL.** `sourceURL` is always set from the
raw incoming `URL`, never `metadata.url`/`metadata.originalURL` —
Discovery Spike 01 found Apple's own "resolved" URL silently drops
query context like Instagram's `?img_index=1` and YouTube's `&t=106s`.
Covered by a dedicated test (`testResolvePreservesOriginalURLVerbatimIncludingQueryParams`).

**Bounded, single timeout.** One 6s budget (`URLCherryResolver.defaultTimeout`)
races the entire resolution attempt (metadata fetch + image download)
against a timer via `withTaskGroup`; whichever finishes first wins, and
the loser is cancelled. `LPMetadataProvider.cancel()` is wired through
`withTaskCancellationHandler` so a timed-out fetch is actually torn
down, not just abandoned. `Task.isCancelled` is checked before the
`MediaStore.save` call specifically to close the (otherwise real) risk
of a lost race still persisting an orphaned file after `resolve()` has
already returned nil to a caller that moved on — this doesn't reach
into `NSItemProvider.loadDataRepresentation`'s completion-handler-based
API, which can't observe Swift Task cancellation, but that residual
gap is the same class of accepted, already-documented risk as other
cancelled-share orphaned-file cases in this codebase, not a new one.

**Image validation without a full decode:** the existing
`ImageDecoding.pixelSize(ofData:)` (header-only, `CGImageSource`-based)
both validates the bytes actually decode as an image AND supplies
`CaptureDraft.pixelSize` in one cheap call, regardless of source
resolution — no giant bitmap is ever materialized just to check
validity.

**Testing:** `URLCherryResolverTests.swift` exercises success, original-URL
preservation, title carry-through, and every failure path (fetch error,
no imageProvider, non-image type, undecodable bytes, timeout) entirely
against a fake `LinkMetadataFetching` and an isolated `MediaStore` — no
network dependency. Verified via a clean iOS `xcodebuild` build
(including the Share Extension) and careful code review; this
environment's pre-existing `swift test`/`swift build --build-tests`
gaps (documented earlier in this README) meant the suite could not
also be executed via the CLI this pass.

**Known V1 limitation, accepted:** Instagram's `img_index` survives in
`sourceURL` but generic LinkPresentation only exposes a post-level
preview image, not the specific carousel frame — deferred, as decided
in Discovery Spike 01; no Instagram-specific resolver was built.

## URL → Cherry Physical QA Follow-Up (Foundation 01)

**GREEN.** Two findings from Sammy's first physical QA pass, resolved/characterized.

**Share Extension layout, root cause and fix.** A very wide representative
image (Works in Progress's hero) displaced the drawer's X/checkmark/folder
controls out of the visible screen bounds. The first attempted fix
(combining `MediaThumbnail`'s two chained `.frame(maxWidth:)`/
`.frame(maxHeight:)` calls into one) did **not** resolve it — a
physical-device retest showed the same bleed. Flexible sizing
(`.infinity`/`max`) is a negotiation between parent and child, and
something in the VStack/ZStack chain was still letting an oversized
child win that negotiation for the whole drawer. The real fix: wrap
`ShareDrawerContent.body` in a `GeometryReader` and give every child
(`MediaThumbnail`, the content `VStack`, the folder dropdown) the
geometry's own concrete width/height — eliminating flexible sizing
from the chain entirely, so there is nothing left for an unusual
aspect ratio to exploit. Confirmed fixed live against the real Works
in Progress share; confirmed no regression on an ordinary screenshot
share.

**Instagram carousel — empirically characterized, not built.** DEBUG-only
instrumentation (logged to console and, since `devicectl` can't stream
console output from an OS-launched extension process, also to a small
local App Group file read back via a harness action) captured the real
Share Extension input for a live Instagram carousel share:
`providers=1`, `types=["public.url"]` only — **no image provider at
all**. Instagram hands Cherries a bare URL with the selected slide as
a query parameter (`?img_index=2`). Decisive proof the crop isn't
slide-aware: two saved Cherries from the *same* Instagram post at
different `img_index` values (2 and 4) resolved to **byte-identical**
image data (57,328 bytes both). Since `URLCherryResolver` only
downloads and stores bytes verbatim — no cropping logic exists in this
codebase's URL path — the "zoomed" crop originates from Instagram's
own server-side, post-level Open Graph image, not from Cherries. This
matches Discovery Spike 01's predicted scenario B/C and confirms
generic V1 genuinely cannot know which carousel slide was intended —
still deliberately not built this milestone.

**Legacy Arkyv branding, located:** `Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`
defines icon slots with **no actual image files assigned** — the
Share Sheet row icon Sammy sees is whatever iOS is caching from an
earlier install, not anything in the current asset catalog.
`ArkyvMark`/`ArkyvWordmark` imagesets still exist but aren't
referenced anywhere in the Share Extension's own code, only the main
app's — left untouched, read-only finding for a future rebrand pass.

## Context + Single-Folder UX (Foundation 01)

**GREEN.** Two product-clarity fixes from Sammy's real use of URL → Cherry.

**Link Cherry context — "a label, not a card."** `LinkCherryContext`
(pure, `ArkyvKit`) decides whether Item Detail shows a quiet title +
domain line beneath a URL-derived Cherry's image. The rule was derived
entirely from six real stored titles, not per-source adapters: a title
is shown only if non-empty, ≤100 characters (Pinterest's real stored
title was 118 characters of pipe-separated keyword stuffing), not
identical to the domain, and doesn't merely contain the site's own
registrable name (Instagram's real stored title, `"<name> Documented
on Instagram,"` is a generic per-post template with zero post-specific
information). The domain line can still appear even when the title is
omitted. Wired into `ItemDetailView` between the image and the
Source/Tags/Folder cluster; renders nothing at all for items without
`sourceURL`, so ordinary screenshots/photos are pixel-identical to
before — confirmed on Device A. One Archive is untouched.

**Single-folder picker — visual language, not a state bug.** Both
folder pickers (Share Extension drawer, Item Detail's Folder editor)
were already backed by a single optional selection — a Cherry could
never actually be in two folders. The confusion traced to inconsistent
*visual* language: the Share Extension stacked three simultaneous
selection cues (checkmark + tinted background + leading accent bar)
while Item Detail used a different cue entirely (a 4×4 dot, no check).
Both now use exactly one indicator, a trailing checkmark. The
tap-interpretation rule itself — tapping a different folder replaces
the selection, tapping the current selection clears to Unfiled — is
now a single shared pure function, `FolderSelectionUX.toggling(current:
tapped:)`, called from both pickers, so they're provably identical
rather than independently-written. The Share Extension's dropdown also
gained an explicit "Unfiled" row — previously there was no way back to
Unfiled once a folder was chosen. No `Repository`/schema changes: both
pickers already routed every write through the same single-folder
membership machinery; `IntegrityCheck` remained clean
(`duplicateActiveMemberships=0`, `itemsWithMultipleActiveFolders=0`,
`folderMembershipDisagreements=0`) throughout.

## Link Cherry Ingestion + Source Semantics (Foundation 01)

**GREEN.** Three narrow follow-ups from real Link Cherry use.

**YouTube/plain-text ingestion, fixed generically.** YouTube's native
Share Sheet hands the extension the link as `public.plain-text`, not a
`public.url`-typed attachment — confirmed via the DEBUG `ShareDiag`
instrumentation, which showed a real captured YouTube share with
`types=["public.plain-text"]` only. `PlainTextURLRecognizer` (pure,
`ArkyvKit`) recognizes a plain-text payload as a URL share only when
the trimmed text is *exactly* one `http`/`https` URL with a host —
"Check this out https://…" still falls through to ordinary note
behavior unchanged. Wired into `ShareViewController`'s existing
plain-text branch; a recognized URL now reaches the exact same
`URLCherryResolver` path a URL-typed share always used. Confirmed live
on Device A: a real YouTube share now produces an image-backed Cherry
with a resolved thumbnail, and `sourceURL` preserves the original URL
verbatim (confirmed with a real `is=` tracking query parameter surviving
intact; `&t=` timestamp preservation confirmed at the unit-test level —
the same, unmodified preservation mechanism, not separately re-tested
live this round).

**Domain tap now opens the page directly.** Item Detail's Link Cherry
context previously routed the domain line into the same Source-room
`activeRoom = .source` action as the "Source" chip. It now calls
`openURL` directly (the same mechanism `SourceEditorView`'s own "Open
Source" button already uses) — confirmed live: tapping `studio2am.co`
opens Safari immediately, and the separate Source chip still opens the
Source room exactly as before.

**Source-room metadata audit (read-only, no fields added).** Re-ran
Discovery Spike 01's harness with `Mirror` reflection against
`LPLinkMetadata` for all six real reference URLs. Findings that
correct the starting hypothesis:
- **`description`/`site name` are not exposed by Apple's public API at
  all** for any of the six sources — `title` is the only text field
  `LPLinkMetadata` genuinely offers. (`responds(to:)` reports `true`
  for private selectors named `description`/`summary`, but that's
  almost certainly `NSObject`'s own generic debug-description method,
  not page content — not something to build on.)
- **`title` is not unconditionally trustworthy** — 2 of 6 real sources
  (Pinterest's 118-character keyword-stuffed title, Instagram's
  generic "Documented on Instagram" template) are unusable, already
  correctly filtered by `LinkCherryContext`. YouTube's title ("Max
  Kent," the channel name) *passes* the existing generic filter and
  displays despite not describing the specific video — accepted,
  disclosed limitation, no YouTube-specific correction built.
- **Resolved/canonical URL differs meaningfully from the original in
  exactly 1 of 6 cases** (Darc Sport drops a `/collections/forever/`
  listing-context path segment) — a genuine but occasional nicety, not
  something to rely on.
- **Source-specific query context is genuinely useful in 2 of 6
  cases** — Instagram's `img_index` and YouTube's `t=`, both preserved
  only in the *original* URL, never the resolved one.
- **`videoProvider`/`remoteVideoURL` were both `nil`** for the YouTube
  URL even though it's a video — no embedded video metadata is
  reliably available via this API in this context.
- Favicon/icon, MIME types, provider identifiers, and image dimensions
  are confirmed low-value/technical, as hypothesized.

**Recommended Source-room hierarchy (not built yet):**
- **Always useful:** domain/host, original URL, saved date
  (`StoredItem.createdAt` — confirmed semantically correct for "Saved
  on [date]," including for migrated items, whose `createdAt` is their
  original legacy capture date, not the migration event; no new field
  needed).
- **Useful when present:** title (only once past the existing quality
  filter — not unconditional), canonical URL (only when it visibly
  differs), source-specific query context.
- **Low-value/noise:** favicon/icon, MIME types, provider identifiers,
  image dimensions, other technical metadata.
- **Not available via reliable public API:** description, site name,
  video/embedded-playback metadata — dropped from the hierarchy
  entirely rather than marked merely "unreliable."

**URL state/variant reconnaissance (for the upcoming multi-image
milestone):** the one real Darc Sport `sourceURL` captured so far
carries no variant/colorway query parameter — inconclusive on whether
a variant-specific share would encode one, since this URL was a
canonical product page, not necessarily one with an explicit variant
selected. Needs a fresh test share with a variant actively chosen
before that milestone can rely on this.

## Priority Source Intelligence (Foundation 01)

**GREEN.** "Generic resolver = universal safety net; priority source
intelligence = narrow, evidence-backed enhancements for a few
high-value sources where generic metadata materially fails user
intent." One enricher shipped (YouTube); the rest investigated and
explicitly deferred with evidence.

**YouTube play-icon: not Cherries chrome.** Fetched and visually
inspected the raw bytes LPMetadataProvider was resolving — the
play-button triangle is baked directly into YouTube's own served
social-card thumbnail pixels. Grepped the whole codebase for any play
icon SF Symbol (`play.fill`/`play.circle`/etc.) — zero matches
anywhere. There was no Cherries UI layer to remove.

**Fixed via YouTube's public oEmbed endpoint instead.** `https://www.youtube.com/oembed`
— the open, documented oEmbed standard, no API key, no auth, no
scraping — returns both the real video title (confirmed:
`"How To Capture Photos That Look Like Paintings"`, genuinely
different from `LPLinkMetadata.title`'s `"Max Kent"`, the channel
name) and a `thumbnail_url` confirmed, by the same direct visual
inspection, to have no play-button overlay baked in. `SourceEnricher`
(`matches(_:)` + `enrich(_:) async throws`) is the new minimal
architecture — a plain ordered array `URLCherryResolver` checks, no
registry, no persisted source-type schema. Any enrichment failure
(thrown error, bad thumbnail fetch, undecodable bytes) falls straight
through to the exact unchanged generic `LPMetadataProvider` path within
the same bounded attempt (timeout raised 6s → 8s to give a failed
enrichment room to still fall back). Confirmed live on Device A: clean
thumbnail, no play icon, real video title shown.

**Source-enricher reconnaissance for the other five families —
evidence-based, mostly DEFER:**
- **Pinterest:** generic already returns the correct Pin image;
  title is already correctly hidden by the existing filter. No public
  Pinterest metadata endpoint would improve on this without fragility.
  **GENERIC IS ENOUGH.**
- **Instagram:** confirmed the legacy no-auth oEmbed endpoint
  (`api.instagram.com/oembed`) now just redirects (302); the Graph API
  oEmbed variant returns only a client-JS-rendered embed skeleton with
  no real image/title data in the raw response — would require
  executing embedded JavaScript (browser automation) to get anything
  useful, explicitly excluded. **DEFER**, no viable public mechanism.
- **Ecommerce/product pages:** real finding — Darc Sport's page embeds
  a genuine multi-image `"images":[...]` array (4+ real product photos)
  in inline page JSON, and separately a JSON-LD `Product.offers` array
  whose URLs carry explicit `?variant=<id>` query parameters,
  confirming Shopify-style sites DO encode variant state in the URL.
  This is real evidence the data a future candidate-image picker needs
  *can* exist — but extracting it requires a dedicated raw-page-fetch +
  embedded-JSON-parsing mechanism per commerce platform (Shopify's own
  convention, not a universal standard), meaningfully more fragile and
  platform-specific than YouTube's single documented endpoint. **MAYBE
  BEFORE LAUNCH**, not built this pass.
- **Articles/editorial:** Works in Progress resolved perfectly
  generically end to end. **GENERIC IS ENOUGH.**
- **Reddit:** `www.reddit.com/oembed` returns a real post title but no
  direct image URL (only a JS-rendered embed widget, same limitation
  as Instagram) — and generic `LPLinkMetadata` already returns a
  reasonable title (`"From the r/X community on Reddit: …"`) plus an
  image directly, unlike Instagram's generic-template problem. Lower
  marginal value than YouTube. **DEFER.**

**Launch priority matrix:**

| Source | Generic quality | Specialist value | Fragility | Complexity | Wow impact | Recommendation |
|---|---|---|---|---|---|---|
| YouTube | Poor (channel name, play-icon thumbnail) | High | Low (public oEmbed) | Low | High | **Shipped this milestone** |
| Ecommerce/Shopify | Good (single image) | High (multi-image, variant) | High (platform-specific JSON parsing) | Medium-High | High | MAYBE BEFORE LAUNCH |
| Pinterest | Excellent (image), poor (title, already filtered) | Low | — | — | Low | GENERIC IS ENOUGH |
| Articles | Excellent | Low | — | — | Low | GENERIC IS ENOUGH |
| Instagram | Fair (post-level crop only) | High in theory, but unreachable | No viable public mechanism | — | — | DEFER (no path without private API/scraping) |
| Reddit | Good (title + image already) | Low-Medium | Medium (oEmbed, no image) | Low | Low | DEFER |

**Candidate-image-picker feasibility (reconnaissance only, not
built):** the underlying data genuinely exists for at least
Shopify-based product pages (a real multi-image array + variant-aware
URLs), so the picker is *feasible in principle* — but requires a new,
platform-specific page-parsing mechanism this milestone deliberately
didn't build.

**Source-room metadata implications:** `StoredItem.title`/`sourceURL`
(A: already exists) cover video/article/product title and original
URL for every source investigated. Domain/host (B: derivable from
`sourceURL`, no storage). Channel/author/subreddit/publication (C:
would require new persisted storage — not added). Description,
site name, full embedded JSON-LD/oEmbed payloads (D: should remain
ephemeral, not stored — matches "an archival object label, not a JSON
inspector").
