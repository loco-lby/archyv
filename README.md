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
