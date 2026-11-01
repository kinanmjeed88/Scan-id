# Scan-id × Maktabati Pro crop integration — engineering plan (Phase 2)

Status: written before any code change in Phase 2. Companion to
`MAKTABATI_PRO_CROP_ENGINEERING_REPORT_2026-11-01.md` (Phase 1 evidence) and to
the final report `SCAN_ID_MAKTABATI_CROP_INTEGRATION_REPORT.md` (written last).

Base: `546c7fb` on `arena/9c08ad5c-scan-id`. The session is pinned to this
branch, so no dedicated branch is created. No force push, no merge, no PR
until CI is green on the last SHA.

## 1. Facts this plan relies on (proven in Phase 1 unless marked)

- The Maktabati Pro APK taps in order and appends while fewer than four points
  exist (`Lne0.e`). Its tap guard rejects points within 28 × `Lhb3.b()` of a
  handle or out of bounds; drag radius 32 × `Lhb3.b()` (proven, bytecode).
- Scan-id's `crop_screen.dart` has no four-tap mode. It has four drag handles
  (`crop-corner-$i`, 40 px) that are children of an `InteractiveViewer`
  (proven). Their on-screen size therefore scales with zoom (inferred from the
  widget tree; not measured).
- Scan-id's `document_detector.dart` already implements a structure-tensor
  gradient, Hough-line quads, convex hull, enclosing quad, Otsu and morphology
  (proven). It has no Canny stage and no `approxPolyDP` stage.
- `_orderQuad` in the detector is a private copy of corner ordering with an
  arbitrary weight (`dx + 1.15 * len / maxLen`) (proven).
- `_arrangeLegacyImportedImages` drops `forceReview` and `forceReviewReason`
  when it rebuilds `BoundaryProposal` (proven, D9).
- `_suggest` captures the draft before an `await` and writes the result with the
  captured adjustments, without checking whether the state changed (proven).
- The AI contracts are frozen: `minAutoAcceptConfidence: 1.01` on both models,
  `modelDisagreement`, `uncalibratedClassicalScore`, the DocAligner adapter, the
  DocQuadNet SHA-256 and `tool/check_detector_retirement.py` (proven).

## 2. Decisions

| ID | Decision | Reason |
|----|----------|--------|
| P1 | One corner-ordering function in `lib/domain/geometry.dart`, used by the detector and the manual tap path. The arbitrary `1.15` weight is removed. | The user forbids duplicated logic. A single rule makes the tap order and the detector order identical. |
| P2 | A pure `ManualQuadSelection` in `lib/domain/` holds tap-ordered points (max 4), with validation. It is completed only through `normalizedQuadIssue`. | Keeps the state machine testable without Flutter. |
| P3 | Tap mode is an explicit button (`تحديد الزوايا بالنقر`). The default remains four handles, so the existing widget tests that open the screen and drag `crop-corner-*` keep their behaviour. | No change to existing flows; no surface UI. |
| P4 | Tap mode commits a single history entry when four valid points complete. Taps are not individual undo entries. Undo or leave clears the partial selection. | Undo/Redo and Revision stay consistent. |
| P5 | Handles keep their keys and centre-on-corner geometry. Each handle's visual and hit box is wrapped in an inverse-scale `Transform` driven by the zoom of `_view`, so it stays 40 px on screen. | Acceptance: fixed-size handles under zoom. |
| P6 | Overlapping handles are not re-routed to the nearest corner in this phase. The later handle wins. | Re-routing needs a new gesture layer. Recorded as a gap, not hidden. |
| P7 | `_suggest` captures the state identity before the `await`. If the state changed, the result is discarded with a notice. The adjustments come from the current state. | Stale-result guard. |
| P8 | `_arrangeLegacyImportedImages` forwards `forceReview` and `forceReviewReason` (D9). A test runs through `arrangeImportedImages`. | D9 fix. |
| P9 | No detection threshold or candidate rule changes. The APK's Canny/approxPolyDP pipeline is **not** added as a second detector. | Duplicate logic is forbidden. Tuning without a corpus is not provable. Documented as an explicit non-adoption. |
| P10 | The EXIF path and the output path (`prepare_image.dart`, `crop_draft.toRecipe`, `image_limits.dart`) are not changed. | Closed facts. D4/D7 are not part of this phase. |

## 3. Protected items (must not change)

- `tool/check_detector_retirement.py`, the DocQuadNet SHA-256 and
  `assets/models/docquadnet256_trained_opset17.ort`.
- The DocAligner adapter and `docaligner_model.dart` thresholds.
- `minAutoAcceptConfidence: 1.01`, `modelDisagreement`, `uncalibratedClassicalScore`.
- The cascade in `boundary_proposal_cascade.dart`.
- `Project.schemaVersion = 5` and `scan-id-local-annotations-v2`.
- `suggestedPolygon` vs `polygon` separation.
- App version, signing and identity. No new dependencies.
- Personal images. Only synthetic fixtures are used.

## 4. Changes by file

1. `lib/domain/geometry.dart`: add `canonicalQuadCorners(List<Point2>)` and
   `nearestCornerIndex(...)`. Ordering: angle-sort about the centroid, enforce a
   positive shoelace area, then choose the start edge by the highest
   `dx/len`, ties broken by longer edge, then lowest index.
2. `lib/imaging/document_detector.dart`: `_orderQuad` calls the domain function.
   Output convention is unchanged (TL, TR, BR, BL).
3. `lib/domain/manual_quad_selection.dart` (new): `ManualQuadSelection`.
4. `lib/presentation/crop_screen.dart`:
   - tap mode (button, tap surface, partial markers, Cancel);
   - inverse-scale handles;
   - stale-result guard in `_suggest`.
5. `lib/application/project_service.dart`: forward `forceReview` and
   `forceReviewReason` in `_arrangeLegacyImportedImages`.
6. Tests:
   - `test/domain/geometry_test.dart`: ordering cases (shuffled, rotated, 45°
     degenerate, bow-tie rejection).
   - `test/domain/manual_quad_selection_test.dart` (new): T01 to T04 domain parts.
   - `test/application/manual_intake_integration_test.dart`: D9 test through
     `arrangeImportedImages`.
   - `test/widget_test.dart` or a new widget test: tap mode completes four taps
     into four handles and enables preview. Fixed-handle size test if the widget
     tree can be measured.

## 5. Test-plan coverage (17 cases from the Phase 1 report)

- Implemented in this phase: T01 (ordering and cyclic-shift), T02 (tap count and
  rejection in the domain), T03 (duplicate and out-of-bounds rejection), T05
  (completion requires a valid quad), T09 (forceReview on the legacy path, D9),
  T13 (stale-result guard, via code review plus a test where feasible).
- Partially implemented: T04 (fixed handle size, if measurable), T06 (undo/redo
  of one entry), T14 (detector ordering unchanged on existing fixtures).
- Not implemented here and reported as gaps: quality-target measurement on a
  real corpus (no corpus available in CI; not claimed); T16 and T17 timing and
  memory benchmarks on device.

## 6. Validation

- Dart format, analyzer, `flutter test` and the source guard run only in CI. No
  Dart SDK is available locally, so every commit is validated by a CI run.
- Each commit is pushed and its run read. The `diagnostics/*.log` annotations are
  used, because the blob log endpoint returns EOF.
- A test is reported as passed only when its CI job is green.
- The earlier failure on `546c7fb` (two jobs, steps that fetch a model and
  launch the diagnostic build) is handled by a rerun of the failed jobs. The
  cause is reported as unproven if the rerun does not explain it.
