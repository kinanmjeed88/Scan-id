# PR #60 — manual multi-document selection: delivery report

Branch `arena/d2061602-scan-id` · base `8c92003` · verified commit **`cf43c9d`**
Run **`44726420448`** — all four jobs success.

This report **supersedes** the option-5 section of
`docs/reports/PR60_VERIFICATION_2026-11-19.md`. That section judged the
*automatic* multi-document segmenter. The shipped feature is a **manual**
workspace, so those precision numbers are not a criterion for it and are not
used here as one.

## What was built

A photograph can hold several documents. Automatic segmentation stays disabled
because it was measured and found unqualified (`docs/BOUNDARY_AUDIT_REPORT.md`:
instance precision 0.4667, recall 0.5714). The capability is therefore offered
honestly: **the person outlines each document by hand**, and nothing guesses.

| Requirement | Where |
|---|---|
| Full original photo, zoom + pan, true coordinate correspondence | `lib/presentation/image_viewport.dart`, `MultiDocumentCropScreen` canvas |
| Tap four corners per document, edit points, cancel a selection | `ManualSelectionSet.addCorner/moveCorner/undoCorner`, cancel button |
| Independent kind + side per document, defaults when unstated | `ManualDocumentSelection.kind/side/kindForExtraction` |
| List to move between documents, classify, delete | numbered list, `multi-selection-row-*` / `multi-selection-delete-*` |
| Each cropped independently, perspective-corrected, into the existing path | sequential `ProjectService.extractManualDerivedDocument` |
| Accuracy under zoom/pan, ordering/bounds/self-intersection validation | `ImageViewport.screenDistance`, shared `canonicalQuadCorners` / `unorderedQuadIssue` / `normalizedQuadIssue` |
| Reuse existing components, no mandatory auto-detection | no `.suggest(` or segmenter call in the new code |
| Other four options unchanged | diff touches only the five files below + tests |

### Files changed

- `lib/domain/manual_document_selection.dart` (new) — one selection and the set
  of them: per-document corners in **normalized image coordinates**, per-document
  kind + side, add/edit/undo/cancel corner, delete, a ten-document cap, and a
  separating-axis overlap rule so two documents cannot cover the same pixels.
  All quadrilateral validation is delegated to the existing geometry contract.
- `lib/presentation/image_viewport.dart` (new) — the single place image and
  screen coordinates meet. Zoom keeps the point under the finger fixed, pan
  cannot lose the photograph, and a screen tap becomes a normalized image point.
- `lib/presentation/multi_document_crop_screen.dart` (new) — the workspace.
- `lib/presentation/project_screen.dart` — one new menu entry beside the existing
  extract action; it opens the workspace on the **root** photograph.
- `lib/presentation/intake_options_sheet.dart` — the option-5 subtitle now states
  that the person outlines each document and that automatic detection stays off.

### Two decisions worth stating

1. **An unstated category becomes a free document.** The existing extraction path
   refuses `DocumentKind.unknown` outright — a document with no category has no
   size and no place on the sheet. The screen offered «تعرّف تلقائي» and then
   failed at Add (a real bug the widget test caught). It now resolves to
   `DocumentKind.other`, which keeps a provisional footprint **off** the A4 sheet
   and goes to review, where the existing classification flow settles it. The
   screen says this in words *before* the person commits. No classification is
   invented here.
2. **Applying is all-or-nothing.** Adding only the valid selections would
   silently drop a document the person drew, which is the failure mode this
   feature exists to prevent. The message names each incomplete document.

## Tests

**Actual results, from run `44726420448`:** `Flutter tests` step **success**;
`Dart format gate` **success**; `Flutter analyze --fatal-infos` **success**;
`Build Android debug APK` **success**; `Build Windows release` **success**;
`Launch the diagnostic build on Android 16` **success**.

52 test cases added:

| File | Cases | Covers |
|---|---|---|
| `test/domain/manual_document_selection_test.dart` | 24 | multiple selections, tap-order independence, invalid geometry with its own message, per-document kind/side, edit one corner without touching another, undo, cancel, cap at ten, delete, overlap (touching vs. overlapping vs. rotated) |
| `test/presentation/image_viewport_test.dart` | 16 | letterboxing, exact inverse conversion, clamping, zoom about a focus point, a corner staying on the same document pixel at 3×, pan bounds, zoom-bounded, resize |
| `test/application/manual_multi_selection_test.dart` | 6 | two selections → two documents through the real service, per-document categories, source photo untouched, perspective rectification of a skewed card, unstated-category default, zoom+pan coordinate contract |
| `test/presentation/multi_document_crop_screen_test.dart` | 7 | whole photo opens empty, two documents drawn and listed with their own kinds, Add crops each independently, delete leaves the other, incomplete blocks Add, zoom does not break tapping, cancel keeps the row |

### Bugs these tests found (and that are now fixed)

Every one of these was a real defect, not a test adjustment:

- **Overlap test inverted.** Separating on any edge normal means *no* overlap;
  the code returned the opposite, so two cards covering the same pixels were
  accepted while a side-by-side pair was refused.
- **`add()` never ran the overlap check** — only `replace()` did.
- **`assert` instead of `require`** for an unusable viewport box: it vanishes in
  release builds and would have let a bogus transform through.
- **Gesture ambiguity.** Competing recognisers let a tap be resolved as a tiny
  pan, so no corner was ever placed. Replaced with explicit pointer tracking: one
  pointer taps/pans/drags, two pointers pinch about their midpoint.
- **Taps mis-mapped under a stretched image.** The photo was drawn filling the
  box while the transform assumed a letterboxed fit, so every corner landed
  slightly wrong. The image is now drawn exactly where the transform says.
- **`ScaleEndDetails.localFocalPoint` does not exist** (compile error on the
  Windows job) and a nullable receiver could not be promoted by `require`.

Three test expectations were themselves wrong and were corrected with the
reasoning recorded in-place: the normalized-ring aspect (0.667, not 0.5), that
`Point2` has no value equality, and that the test's own trapezoid is **taller**
(210 px) than wide (202 px), so "wider than tall" was asserting the wrong shape.

## Platform builds

- **Android**: debug smoke APK and the release APK both build (job `android`).
- **Windows**: the release build compiles and links. This job is what first caught
  the two Dart compile errors above, before `analyze` reported them.
- **Android 16 (API 36) emulator**: the diagnostic build launches and the stage
  list is recorded (`probe.installed`, `native.preflight.*`,
  `flutter_plugins.registration.*`).

### One infrastructure failure, stated plainly

The first attempt on `cf43c9d` failed the `Android 16 startup evidence` job with
*"The reports are missing: app.first_home_frame"*. `git diff 01ef7d8..HEAD` shows
`tool/run_android16_startup.sh` and `.github/workflows/verify.yml` **unchanged**,
and the same job was green on `01ef7d8`. `gh run rerun --failed` turned it green
with no code change. It is emulator flakiness, not a regression — but it is
recorded rather than hidden.

## Not done, by instruction

No merge, no release, no tag. PR #60 is still open.

## What is still not proven

- No local Flutter/Dart SDK in this environment: every result above comes from
  CI, never from a local run.
- No real photographs and no real-device ARM64 run: the tests use synthetic
  scenes and the emulator is x86_64.
- Run logs are not downloadable from this network; the evidence channel is the
  job/step conclusions and check-run annotations. Where a figure (such as a test
  count from the runner's own output) could not be observed, it is **not**
  quoted here.
