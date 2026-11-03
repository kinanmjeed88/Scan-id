# PR #39 — Final Pre-Merge Independent Audit

Scope: read-only audit of the crop lifecycle, Boundary Gate, T04 (0.5 px), D7 (16 MP / silent downscale), and the full PR #39 diff.
Mode: audit only. No production file, test expectation, commit, push, or merge was changed. This report is the only new file.

---

## 0. Verdict

**NOT READY.**

Three medium-severity issues were confirmed by code reading and are not covered by any test:

| ID | Severity | Summary | Status |
|----|----------|---------|--------|
| C1 | Medium | Undo after a failed auto-detect fallback restores the full frame with the fallback flag cleared, so Preview and Accept become enabled on the full image with no notice. | Confirmed by code reading. Not executed. |
| C2 | Medium | A successful Suggest after the fallback leaves Preview and Accept disabled, while the notice tells the user to preview first. | Confirmed by code reading. Not executed. |
| C3 | Medium (decision) | An import with no detection opens the full frame with Preview and Accept enabled and no notice. This contradicts the fallback invariant. Fixing it changes behaviour, so it needs user approval. | Confirmed by code reading. Not executed. |

Per the audit rule, READY FOR REVIEW is not written while an unresolved medium issue remains. Section 9 lists what would change the verdict.

CI on `7647fdd` is green (push run `41467081513`, PR run `41467089128`). CI does not cover C1–C3. A green CI result is not evidence for these issues either way. No defect here was executed.

---

## 1. Reference state (verified at audit start)

| Item | Value | Evidence |
|------|-------|----------|
| Branch | `arena/9c08ad5c-scan-id` | `git rev-parse --abbrev-ref HEAD` |
| Remote branch / PR head | `7647fdd5f1c6526d1381c8337333256872e2739b` | `git fetch` (refs only) and `gh pr view 39` |
| PR #39 | OPEN, not draft, `mergedAt` null, base `searchidf` | `gh pr view 39 --json state,headRefOid,mergedAt,isDraft,baseRefName` |
| Local `HEAD` | `cc4ab7a…` (stale index and ref; not used for audit) | `git rev-parse HEAD` |
| Working tree | Identical to `7647fdd` | `diff -rq --exclude=.git` against `git archive 7647fdd` = no differences |
| CI on `7647fdd` | push run `41467081513` success; PR run `41467089128` success; `flutter test` `+897: All tests passed`; Android instrumentation `androidTests=4 failures=0` | Recorded in the integration report §15 |
| Local Dart / Flutter | Unavailable. No local test result is claimed here. | — |

Stop condition check: the state matched the request, so the audit continued.

---

## 2. Method and evidence level

- Source: `git archive 7647fdd` (450 files), plus read-only `git diff cc4ab7a 7647fdd` for the change set.
- Every finding below is labelled **Read** (code reading), **Test-read** (test source read, not run), or **CI** (run in GitHub Actions on `7647fdd`).
- No Dart test was executed locally. The proposed tests in §10 are **not** run and must be executed in CI before anyone relies on them.

---

## 3. Crop lifecycle

Line numbers are for `lib/presentation/crop_screen.dart` at `7647fdd`.

| Step | Code | Result | Evidence |
|------|------|--------|----------|
| Open | `_load` 376–478 | Opens source, resolves suggestion (`_resolveSuggestedCorners` 534), sets history and state. Every async completion checks `_isCurrentOperation` (generation and `mounted`). | Read |
| Load suggested corners | `_resolveSuggestedCorners` 534–593, `_usableSuggestedCorners` | Explicit or saved candidate is used only if `assessQuad` accepts it (bounds, finite, winding, convexity, area). Otherwise full frame plus notice. | Read |
| No candidate at all | `_load` 420–475 | Full frame, `_manualRequired` stays `false`, `resolution.notice` null. Preview and Accept enabled. | Read — see C3 |
| Switch to manual | `_enterManualFallback` 933–944 | Only when the draft is still the full frame. Sets `_manualRequired = true`, empty tap selection. | Read |
| Edit (corner drag) | `_moveCorner` ~1450–1480 | Refuses crossing (keeps last valid position). Clears `_manualRequired` on first valid move. `_clearPreview` called. | Read |
| Edit (tap ×4) | `_addManualTap` ~1400–1446 | On the fourth tap, clears `_manualRequired` and commits through `_change`. | Read |
| Edit (size, kind, adjustments) | `_onCustomSizeEdited` 682, `_selectDocumentKind` 765, `_autoAdjust` 812 | All go through `_commitState` or `_clearPreview`. | Read |
| Invalidate preview on edit | `_commitState` 650–664, `_clearPreview` 514 (bumps `_draftRevision`) | Preview is cleared on every state change. | Read |
| Undo / redo | `_undo` 722–735 | Restores history state and calls `_clearPreview`. **Does not touch `_manualRequired` or `_tapSelection` beyond clearing it.** | Read — see C1 |
| Suggest | `_suggest` 845–921 | Discards the result if `_state` changed (`identical` check). Clears notice on success. **Does not clear `_manualRequired` on success.** | Read — see C2 |
| Preview | `_render` 946–993; button 1888 | `if (_manualRequired) return;`, `_recipe()` validates the draft before preview. | Read |
| Accept | `_accept` 995–1066; button 1894 | Requires `!_manualRequired && _hasCurrentPreview`. Uses the preview's own recipe. Non-cancelable. Uses `widget.asset` captured at start. | Read |
| Cancel | `_cancelCancelableOperation` (`_leave` 1068) | Increments generation, cancels token, sets `_busy = false`. Late results are dropped. | Read |
| Leave | `_leave` 1068–1094 | Refuses while a non-cancelable operation runs. Pops immediately if not dirty. Otherwise shows the discard dialog. | Read |
| Return | New route each time (`layout_screen.dart:157,188`, `project_screen.dart:478`, `review_screen.dart:229`). State is rebuilt from the saved project. | Read |
| Replace target | `didUpdateWidget` 343–362 | Resets state and reloads, bumping generation. **No production caller swaps the asset under an open route** (all four call sites push a new route). | Read |
| Dispose | `dispose` 365–373 | Bumps generation, cancels, disposes controllers and view. | Read |

Tests covering this lifecycle (Test-read, and CI-proven as passing on `7647fdd`):

- `test/application/crop_lifecycle_test.dart` (197 lines): isolate cancellation, `awaitCancellable`, pre-cancelled open, default aspect.
- `test/application/manual_intake_integration_test.dart`: T-stale "late result after cancel is dropped" (~1206) and "reversed completion keeps newest" (~1256), using Completers. Fallback tests (~735–790).
- `test/widget_test.dart` ~850–905: failed detection, four taps lift the block.

Gaps (see §8): undo after fallback (C1), fallback then successful suggestion (C2), import with no detection (C3), leave and return (no test), replace during an in-flight accept (no test). `_DelayedEditor.blockPreview` in `crop_lifecycle_test.dart:26` is declared and read at line 47 but nothing sets it in that file.

---

## 4. Boundary Gate

Enforcement point: `verifyBoundary` in `lib/domain/boundary_decision.dart` (276–~400). Callers: `project_service.dart:718`, `recognition_pipeline.dart:490`, `boundary_proposal_cascade.dart:105`, `docaligner_model.dart:141`, `docquad_model.dart:129`.

| Requirement | Enforcement | Test (Test-read) | Result |
|-------------|-------------|------------------|--------|
| Rejects invalid bounds | `normalizedQuadIssue` → `outOfBounds` → `assessQuad` not acceptable → `needsReview` (geometryRejected) | `shared_geometry_contract_test.dart:27` (outside), `quad_set_validity_test.dart` (bounds category) | OK |
| Rejects crossed quads | `notConvex` (cross ≤ 1e-6 on any corner) and proper-crossing check | `boundary_decision_test.dart:136` "self-crossed quad needs review and cannot crop"; `quad_set_validity_test.dart:41–79` bow-tie in every starting corner | OK |
| Rejects duplicate points | Any repeated point yields a zero cross product → `notConvex` | **No test names duplicates.** `quad_set_validity_test.dart` covers collinear and inside-triangle cases only. | OK in behaviour; **gap L2** |
| Rejects invalid area | `twiceArea <= 1e-4` → `collapsedArea`; `singularPerspective` | `shared_geometry_contract_test.dart:27` (collapsed ring) | OK |
| Wrong point count | `wrongPointCount` → `rejected` (not review) | `boundary_decision_test.dart:82` malformed proposal | OK |
| Honours `forceReview` | `verifyBoundary` adds `forceReviewReason ?? multiSceneNotCorroborated` to reasons on every needs-review branch, so `forceReview` always yields `needsReview` | Service level: `manual_intake_integration_test.dart:244` "legacy import keeps a proposer forceReview demand (D9)"; pipeline level: `recognition_pipeline_test.dart:320–323`; cascade level: `boundary_proposal_cascade_test.dart:114`. **No `verifyBoundary` unit test with a valid quad and `forceReview: true`** (L7). | OK in code; unit-level gap |
| `forceReviewReason` preserved | `project_service.dart:731` forwards `forceReviewReason: rawProposal?.forceReviewReason`. The D9 test asserts `modelDisagreement`. | `manual_intake_integration_test.dart:263–264` | OK |
| No auto-accept when review required | Accepted only if `reasons` is empty. `detector` always adds `uncalibratedClassicalScore`. `learnedModel` below `minAutoAcceptConfidence` (1.01 in both models) adds `lowModelConfidence`. | `boundary_decision_test.dart:95` ("classical detector score is not treated as calibrated confidence"); learned-model tests at ~277–340 | OK |
| No invalid suggestion reaches Preview or Recipe | `_usableSuggestedCorners` (screen) before any suggestion is shown; `requireValidManualBoundary` (`crop_screen.dart:737–746`) before every recipe; `withSuggestedCrop` only if `assessment.acceptable` (`project_service.dart:757–765`) | `manual_intake_integration_test.dart` (~755–790) | OK |

Observations (not defects):

- **Valid measured quads auto-crop on the segmenter path and on the non-proposal `ImageEditor` path.** These producers add no uncalibrated reason, so a valid quad with `forceReview == false` is accepted. The existing tests state this as intended (`boundary_gate_test.dart` 49–80, "valid measured geometry is accepted without type evidence"; 263–296). The rule the request asks about is "no auto-accept when review is required", and that holds. Whether automatic cropping of valid measured geometry is the product intent is a spec question. It is listed as a residual risk (§9).
- **The non-proposal branch is unreachable in production.** The only `ImageEditor` implementation in `lib` is `LocalImageEditor`, which also implements `BoundaryProposalImageEditor` (`local_image_editor.dart:42–43`). The legacy `ImageEditor.suggest` call at `project_service.dart:707` and the `wholeFrameDetector` producer at `project_service.dart:720–722` are reached only through test doubles.

---

## 5. T04 — 0.5 px assessment

Question: does the handle sit on the corner within 0.5 px, and is the tolerance derived or simply chosen?

### 5.1 Coordinate chain (logical pixels, Flutter layout)

1. Canvas: normalised corner `c ∈ [0,1]` maps to `c × size` in the canvas. The canvas origin inside the stack is `(20, 20)` (`crop_screen.dart:1498` for the tap surface; hit layer uses `inset: 20`, `crop_corner_hit_layer.dart:146`).
2. Corner handle: `Positioned(left: corners[i].x * width, top: corners[i].y * height)` (`crop_screen.dart:1531–1535`). The visual is a 40×40 `Container` (`_cornerVisual` 1573–1585).
3. Handle centre in stack coordinates = `corner × size + 20`, which equals canvas position plus the 20 px origin offset. This matches the canvas corner.
4. `_ScreenFixedSize` (`crop_screen.dart:1943–1960`) applies `Transform.scale(1 / max(1, zoom))`. Scaling about the child's centre leaves the centre unchanged. `minScale: 1` (`crop_screen.dart:1333`), so `max(1, zoom)` equals zoom and the visual stays 40 logical px at any allowed zoom.
5. Hit layer uses the same mapping (`crop_corner_hit_layer.dart:146`). Hit radius 24 px is a selection radius, not an error allowance (`crop_screen.dart` P6 comment at ~1520).

Result: the layout arithmetic is exact in float64. The derivation gives zero systematic offset. The only error sources are float rounding and device rasterisation.

### 5.2 Device-pixel and DPR

- Flutter does not round widget offsets to device pixels during layout or paint of these transforms. Positions remain double-precision logical values.
- The engine rasterises at device pixels. Anti-aliased edges can place a visible centre at most about **0.5 device pixels** from the mathematical centre.
- In logical units that is `0.5 / DPR`. At DPR 1 it is 0.5 logical px. At DPR 2.625 it is about 0.19 logical px. At DPR < 1 it would exceed 0.5 logical px.
- GPU float32 error at the largest realistic coordinate (for example, canvas 1000 logical px × zoom 5 × DPR 3.5 ≈ 17 500 device px) is about 0.002 device px. It is negligible.

### 5.3 What the tests prove

- `crop_corner_hit_layer_test.dart:16–19` sets `_pxTol = 0.5` with the comment that a correct handle lands within float error at `devicePixelRatio 1`.
- Line 23 sets `tester.view.devicePixelRatio = 1`. The assertions (lines 130–151, 166–186, 241, 278) compare logical geometry: handle size 40 ± 0.5, handle centre to corner within `_pxTol`, and corner follows pointer within `_pxTol`.
- `manual_intake_integration_test.dart` sets DPR 1 in five places (408, 542, 661, 724, 789).

### 5.4 Assessment

- **Holds, as proven in CI at DPR 1, for logical geometry.** The tolerance 0.5 logical px is at least the device-pixel snapping bound at every DPR ≥ 1 (0.5/DPR ≤ 0.5). It is therefore not widened to fit an error. A 20 px offset bug would fail it.
- **Not proven on real devices.** The tests do not render at DPR ≠ 1 and do not check raster pixels. The 0.5 bound assumes DPR ≥ 1. Android devices below DPR 1 are not expected, but this is not tested.
- **No tolerance change is proposed.** A change would need a derivation, and this one supports keeping 0.5.

---

## 6. D7 — 16 MP limit and silent downscale

Policy as found (unchanged in this audit):

- `toRecipe` (`lib/domain/crop_draft.dart:66–104`) estimates output from the quad's own edge lengths. It refuses only if the **source** is out of budget (line 68). It scales the output silently: `scale = min(1, sqrt(maxImportPixels / (width·height)))` (line 96). The output is floored, so it stays within budget.
- `CropGeometry` (`geometry.dart` ~397–399) refuses an output above budget. This is a guard, not a policy.
- The full-density path (`requireFullResolutionCropFits`, `full_resolution_manual_crop.dart:92–106`) refuses when the **bounding box** of the requested region exceeds budget. Its message says silent downscale is not used. The check is `withinImageBudget`, shared with every other 16 MP check.

Call sites of `toRecipe` (grep, `lib`):

| Site | Purpose | Silent scale reachable? |
|------|---------|-------------------------|
| `crop_draft.dart:66` | definition | yes |
| `boundary_decision.dart:436` (`recipeFromAcceptedBoundary`) | automatic crop | yes |
| `manual_boundary.dart:216` (`requireValidManualBoundary`) | manual recipe (screen) | yes |
| `local_image_editor.dart:265, 281` | full-res region re-estimate | yes |
| `project_service.dart:909, 1304` | full frame, reset | yes |
| `editor_controller.dart:1003, 1043, 1073` | editor | yes |
| `local_project_recovery.dart:33` | recovery | yes |

Boundary and budget tests (Test-read, CI-proven as passing on `7647fdd`):

- `full_resolution_budget_test.dart:39–75`: exact boundary, hostile dimensions, full-density accepts exactly budget and refuses above it.
- `:59–73` "full-res refuses a 4800 px region of a 6000 px original" (diamond bounding box ≈ 23.04 MP). This test calls only `requireFullResolutionCropFits`. It does **not** call `toRecipe` on that region, which is correct because a 36 MP source is outside budget for `toRecipe` as well.
- `:97–121` sampled recipe never exceeds budget for in-budget sources.
- `:123–131` `toRecipe` keeps a crop at exactly the budget unscaled.
- `:133–150` `toRecipe` silently scales an over-budget estimate. Example: quad `[(0,1),(0.8,0),(1,0),(1,1)]` on 8000×2000. Estimate ≈ 4352.5 × 4800.3 (≈ 20.9 MP), scale ≈ 0.8751, output 3808 × 4200 = 15 993 600 px. I re-derived these numbers by hand; they are not a test output.
- `:152` hostile 64-bit source refused before any product.

Assessment:

- The two mechanisms act on different quantities. `toRecipe` scales the estimate of the **quad's output**. The full-density path refuses the **bounding box**. A diamond whose bounding box exceeds 16 MP is refused on the full-res path. The same quad, judged only through `toRecipe` at preview scale, is not refused.
- The silent scale is reachable on the full-res path in the accepted case. After `requireFullResolutionCropFits` passes (box ≤ 16 MP), `toRecipe` runs on the extracted region and can scale an estimate above 16 MP. The refusal message says silent downscale is not used, which is true for the refusal branch only.
- No unification and no change to 16 MP is proposed. Changing either would be a material D7 user-visible change and needs explicit approval.

---

## 7. Architecture review (full diff `cc4ab7a` → `7647fdd`)

Change set: 20 files, +3899 / −148. Production `lib` changes (insertions / deletions): `project_service.dart` (+5 / 0), `geometry.dart` (+159 / 0), `manual_quad_selection.dart` (+80 / 0), `crop_corner_hit_layer.dart` (+205 / 0), `crop_screen.dart` (+341 / −80), `document_detector.dart` (+3 / −38; `_orderQuad` delegates to `canonicalQuadCorners`), `full_resolution_manual_crop.dart` (+10 / −6).

### 7.1 Protected contracts (checked against the diff)

| Contract | Check | Result |
|----------|-------|--------|
| DocQuadNet, DocAligner, cascade, DocAligner adapter, DocQuadNet SHA-256 | No file in the diff path list | Unchanged |
| `minAutoAcceptConfidence: 1.01` | `docaligner_model.dart:139`, `docquad_model.dart:127` | Unchanged |
| `modelDisagreement`, `uncalibratedClassicalScore` | Only added references; no value changes | Unchanged |
| `Project.schemaVersion = 5` | `project.dart:846` | Unchanged |
| `scan-id-local-annotations-v2` | `reference_annotation/store.dart:16` | Unchanged |
| `suggestedPolygon` / `polygon` separation | `_savedSuggestionFor` reads `suggestedPolygon` only | Unchanged |
| EXIF, `prepare_image.dart` | Not in the diff | Unchanged |
| `tool/check_detector_retirement.py` | Not in the diff | Unchanged |
| App version, signing, identity | `pubspec.yaml` `0.1.2+3` on both SHAs; no signing files in the diff | Unchanged |
| P1 weight 1.15 | `geometry.dart:200` (`canonicalQuadCorners`) is the only weight | Unchanged |

### 7.2 Removed lines reviewed for weakened validation

- `crop_screen.dart`: removed lines are the old corner `GestureDetector` block (replaced by the single hit layer and visual-only handles) and the two button gates. The button gates are stricter after the change (`_manualRequired` added to Preview and Accept). No validation is removed.
- Old corner drag used `withCorner` and allowed crossing mid-drag. The new `_moveCorner` refuses crossing and holds the last valid position. This is stricter.
- `full_resolution_manual_crop.dart` `snappedSpanPixels`: now requires `start >= 0` and `end <= 1`. This is a tightening. The only caller computes `bounds` from corners validated by `CropGeometry`, so it does not reject valid input.

### 7.3 `document_detector._orderQuad` replaced by `canonicalQuadCorners`

Behaviour compared line by line (`document_detector.dart` old `_orderQuad` vs `geometry.dart:160–207`):

- Same centroid, same `atan2` sort, same winding fix (`area2 < 0` reverses), same edge lengths, same `maxLen` floor (`1e-6`), same `len <= 0` and `dx <= 0` skips, same score `dx + 1.15 * (len / maxLen)`, same default start 0. Equivalent in ordering.
- `_dist` (`document_detector.dart:1118`) and `edgeLength` (`geometry.dart:186–187`) are the same formula. `math.pow(x, 2)` versus `x * x` can differ in the last bit only, so only exact ties could change. Not observed.

Behavioural difference (latent, **L1**): `canonicalQuadCorners` builds `Point2`, and `Point2` throws `ValidationException` on non-finite coordinates. The old `_P` carried NaN into `_validQuad`, which rejected it quietly. If a NaN ever reached `_orderQuad`, the detector would now throw. Callers at `document_detector.dart:556`, `740`, `796` do not catch. Reachability: `_intersect` returns null for near-zero determinant (`d.abs() < 1e-12`), so non-finite output needs non-finite input. Not traced to a real input. Proposed guard in §10.

### 7.4 Race and concurrency

- Every async completion in `_load`, `_suggest`, `_render`, `_accept`, `_revertSavedCrop`, `_autoAdjust` checks `operation == _operationGeneration` and `mounted`. Concurrent operations are prevented by the `_busy` gating of every trigger button and of drag and tap callbacks (`crop_screen.dart` 1630, 1888, 1894, hit-layer `onDragUpdate` returns if `_busy`).
- Non-cancelable `_accept` survives a generation bump (see L4). Not reachable in production (§3, replace).

### 7.5 Image memory safety

- The new code holds no native image handles and adds no `ui.Image`, `ImageStream`, `addListener`, `Timer` or `StreamSubscription` (grep of the diff: none).
- `CornerHitLayer` disposes its `ImmediateMultiDragGestureRecognizer` (`crop_corner_hit_layer.dart:171–173`).
- Preview bytes are `Uint8List` values replaced on each render. No new retention beyond the previous single preview.
- Memory use of the full-resolution path is unchanged by this PR (the 16 MP budget and the JPEG-region path are the same code).

### 7.6 Coordinate and geometry correctness

- Corner mapping: `inset + c × size` in the hit layer and `c × size` plus the 20 px origin in the visual layer. Both agree (§5.1).
- Winding: `assessQuad` requires clockwise screen winding in pixel space; detector and manual selection both produce it (`canonicalQuadCorners`). Verified by `quad_set_validity_test.dart:137–164`.
- `toRecipe` uses `(sourceWidth − 1)` in pixel distances, consistent with the normalised-to-pixel convention used by `assessQuad`.

### 7.7 Other architecture notes

- No API signature changed. No feature removed. No model, library or detector retired.
- The `forceReview` forwarding is additive (`project_service.dart:730–731`).

---

## 8. Tests and gaps

Tests executed in CI on `7647fdd` (proven by CI, not locally): full `flutter test` suite `+897`, all passed. Android instrumentation 4 tests, 0 failures. Format, source audit, `flutter analyze` gates per the integration report §15.

Coverage matrix:

| Area | Covered | Gap |
|------|---------|-----|
| Open, suggested corners | Yes (`manual_intake_integration_test.dart`, lifecycle) | — |
| Auto-to-manual fallback | Yes (~735–790, `widget_test.dart` ~850–905) | Fallback then undo (C1); fallback then successful Suggest (C2) |
| No-detection import | Partly (notDetected counts) | Opening the crop screen for a no-detection asset: Preview and Accept are enabled (C3). No test asserts it either way. |
| Edit invalidates preview | Yes (T-stale, lifecycle) | — |
| Accept / cancel / leave | Partly (T-stale dirty-leave path, lifecycle) | Leave and return (no test) |
| Stale result after replace | No test | Replace under an open route is unreachable in production (L4) |
| Late result after cancel | Yes (T-stale ~1206) | — |
| Reversed completion | Yes (T-stale ~1256) | — |
| Boundary: crossed, malformed, implausible, classical score, learned edge | Yes (`boundary_decision_test.dart`) | — |
| Boundary: duplicate points | Behaviour only | No test names duplicates (L2) |
| `forceReview` and `forceReviewReason` | Yes (D9 test, recognition pipeline test) | — |
| T04 handle and hit geometry | Yes, logical, DPR 1 | Not at DPR ≠ 1; no raster check (L5) |
| D7 budget and silent scale | Yes (`full_resolution_budget_test.dart`) | No test for the full-res accepted case with silent scale (§6) |
| `_DelayedEditor.blockPreview` | Declared, read, never set in that file | Dead field (L6) |

---

## 9. Residual risks

1. **Valid measured quads auto-crop on the segmenter path** (`recognition_pipeline.dart`, `boundary_gate_test.dart` 49–80) without calibrated confidence. Intended by existing tests. Product-level question, not a defect.
2. **D7 silent downscale** on the accepted full-resolution path (§6). Policy as decided. A user-visible change needs approval.
3. **D7 bounding-box versus output-area divergence** (§6). The same quad can be refused on the full-res path and accepted at preview scale.
4. **T04 on real devices.** Not proven at DPR ≠ 1, not checked on rasterised pixels (§5.4).
5. **C1–C3 unfixed**, and they reach users through normal taps.
6. **L1 latent exception** from `canonicalQuadCorners` on non-finite input (§7.3). Not reached by any traced input.
7. **Untested leave and return** (§3, §8).
8. **Local Dart and Flutter unavailable.** All test statements here are CI-based. Local analysis is read-only.

---

## 10. Confirmed issues

Each entry: file and line, current behaviour, reason, user impact, a test that would prove it (proposed, **not run**), and a proposed fix (**not applied**).

### C1 — Undo after fallback re-enables Preview and Accept on the full frame (Medium)

- **File and lines:** `lib/presentation/crop_screen.dart` `_undo` 722–735; `_manualRequired` set at 940, cleared at 1438 (tap completion) and 1468 (corner move); Preview 1888; Accept 1894.
- **Current behaviour:** Detection fails on the full frame → fallback (`_manualRequired = true`). The user taps four corners (`_addManualTap` 1438 clears the flag and records the quad). The user taps Undo. `_undo` restores the full-frame state from history, sets `_tapSelection = null`, and does not restore `_manualRequired`. The flag stays `false`. Preview and Accept are then enabled on the full image, and no fallback notice is shown.
- **Reason:** `_undo` restores history state but not the fallback condition. `_enterManualFallback`'s comment at 929–932 states the invariant: "the full frame is never accepted as a detected crop." Undo breaks it.
- **User impact:** A user can save the full image as a crop after a failed detection, with no warning. This is reached by normal interaction. No automatic acceptance occurs; the user has to Preview and Accept.
- **Proposed test (not run):** in `manual_intake_integration_test.dart`, use an editor whose `suggestProposal` returns null. Open the crop. Press "اقتراح حدود المستمسك". Tap four points on `crop-tap-surface`. Tap `find.byTooltip('تراجع')`. Assert that `معاينة التصحيح` is disabled and the fallback notice is shown. **Expected to fail on `7647fdd`.**
- **Proposed fix (not applied):** in `_undo`, after restoring `next`, re-apply the fallback when the restored draft is the full frame and the session's detection has failed. For example, store `_detectionFailed` when `_enterManualFallback` runs, and in `_undo` call `_enterManualFallback()` when `_samePoints(next.draft.corners, CropDraft.fullImage().corners)` and `_detectionFailed`. Alternatively, store the fallback flag inside `_CropEditorState` so history carries it.

### C2 — Successful Suggest after fallback leaves Preview and Accept disabled (Medium)

- **File and lines:** `_suggest` success branch 898–912 (`_change` then notice); `_manualRequired` not cleared; Suggest button 1630 is gated only on `_busy`.
- **Current behaviour:** Fallback is active. The user presses Suggest. A valid proposal is returned. Corners are shown (`_commitState` clears `_tapSelection`), the notice says "اقتراح جديد للمراجعة فقط ... واعرض المعاينة قبل الحفظ" ("review only; preview before saving"), but Preview (1888) and Accept (1894) are disabled because `_manualRequired` is still `true`. The only way out is to drag a corner.
- **Reason:** `_manualRequired` is cleared only on tap completion and corner move (lines 1438, 1468) and at load (358). A successful proposal does not clear it.
- **User impact:** Contradictory UI (the notice asks for a preview; the button is disabled). The user must drag a corner to proceed. This is usability and state consistency, not a safety bypass, since Accept also needs a preview.
- **Proposed test (not run):** fallback → Suggest with a valid proposal → assert Preview is enabled. **Expected to fail on `7647fdd`.**
- **Proposed fix (not applied):** in `_suggest`, in the success branch where `detectionFailed == false`, set `_manualRequired = false` inside the same `setState` as the notice. Keep the rule that Accept requires a current preview.

### C3 — Import with no detection opens the full frame with Preview and Accept enabled (Medium, decision required)

- **File and lines:** `project_service.dart` 694, 709, 760, 796 (`notDetected++`, no crop, no flag). `crop_screen.dart` `_load` 420–475 (no candidate → full frame, `_manualRequired` stays `false`, `resolution.notice` null).
- **Current behaviour:** An asset with no detection opens with the full frame. No banner, no fallback, no notice. Preview and Accept are enabled.
- **Reason:** The fallback is only entered from `_suggest`'s failure path. The import path never enters it. This conflicts with the invariant in `_enterManualFallback`'s comment (C1).
- **User impact:** Same as C1, reached on first open, not after undo. The user chooses to preview and accept. The import report warning (`project_service.dart:712`) is shown in the import flow, not in the crop screen.
- **Proposed test (not run):** import a no-detection asset → open crop → assert the fallback notice is shown and Preview is disabled. **Expected to fail on `7647fdd`.** This assertion changes behaviour and is therefore a decision (below).
- **Proposed fix (not applied):** route the no-candidate `_load` path through `_enterManualFallback()` (or set `_manualRequired` and the fallback notice). **Requires explicit user approval** because it changes the import-time user flow for images that currently open at full frame.

### L1 — `canonicalQuadCorners` throws on non-finite input (Low, latent)

- **File and lines:** `geometry.dart:160–207` (via `Point2` constructor); callers `document_detector.dart:556, 740, 796`.
- **Behaviour:** Non-finite input throws `ValidationException` instead of flowing to `_validQuad` and being rejected.
- **Reachability:** not traced to any real input.
- **Proposed test:** `canonicalQuadCorners([Point2(0,0), …])` never throws for detector-produced quads (property test over random finite inputs); plus a guard test that a NaN input yields a rejected proposal, not an exception.
- **Proposed fix:** `if (quad.any((p) => !p.x.isFinite || !p.y.isFinite)) break;` (or `continue`) before `_orderQuad` at the three call sites, to keep the old quiet rejection.

### L2 — Duplicate-point rejection has no direct test (Low)

- **File:** `geometry.dart:294–318` (`normalizedQuadIssue`, `notConvex`), `quad_set_validity_test.dart`.
- **Proposed test:** `verifyBoundary` on a quad with two identical corners → `rejected` or `needsReview`, never `accepted`, with reason `geometryRejected`.

### L3 — Leave and return not covered (Low)

- **File:** `crop_screen.dart` `_leave` 1068–1094.
- **Proposed test:** dirty draft → leave → "إلغاء التعديلات" → reopen → assert the saved crop and no draft state.

### L4 — Non-cancelable accept survives a target replace (Low, unreachable in production)

- **File:** `crop_screen.dart` `didUpdateWidget` 343–362, `_accept` 995–1066 (`if (!mounted || operation != _operationGeneration) return;` at ~1040).
- **Behaviour:** If the widget is replaced during an accept, the save completes on disk but the screen neither pops nor returns the result.
- **Reachability:** none of the four push sites swaps the asset under an open route.
- **Proposed test:** a `pumpWidget` with a different asset while `applyManualCrop` is held by a Completer; assert the returned project is delivered or the screen refuses the replace.
- **Proposed fix:** either refuse `didUpdateWidget` replacement while a non-cancelable operation runs, or return the saved project to the caller regardless of generation.

### L5 — T04 tolerance proven only at DPR 1 (Low)

- **File:** `crop_corner_hit_layer_test.dart:16–23`.
- **Proposed test:** repeat the handle-centre assertion at `devicePixelRatio` 2.625 and 3.5, asserting `≤ 0.5 / DPR` logical px. Do not widen the existing tolerance.

### L7 — No `verifyBoundary` unit test for `forceReview` on a valid quad (Low)

- **File:** `lib/domain/boundary_decision.dart` (`verifyBoundary`), `test/domain/boundary_decision_test.dart`.
- **Current state:** `forceReview` is covered at the service, pipeline and cascade levels only (§4).
- **Proposed test:** a valid quad with `forceReview: true, forceReviewReason: BoundaryReviewReason.modelDisagreement` → `needsReview`, `cropAuthorization == null`, and reasons contain `modelDisagreement`. **Expected to pass** on `7647fdd` (it documents existing behaviour); its value is coverage at the domain level.

### L6 — Dead test field (Low, hygiene)

- **File:** `test/application/crop_lifecycle_test.dart:26, 47`. `blockPreview` is declared and read but never set.
- **Proposed fix:** either add the preview-blocking test (for invalidate-on-edit during an in-flight preview) or delete the field. Do not weaken existing tests.

---

## 11. Decisions required from the user

1. **C3 (import with no detection):** should a no-candidate crop open in fallback (Preview disabled until four taps or a corner edit), or stay as it is (full frame, Preview enabled)? Changing it is a behaviour change.
2. **D7:** keep the silent downscale on the full-res accepted path and the bounding-box refusal (current policy), or change either one? Any change is a material user-visible D7 change and needs approval. This audit proposes no change.
3. **Valid-quad auto-crop on the segmenter path:** confirm this is the intended product behaviour (§9.1).

---

## 12. Recommended next steps (not executed)

1. Fix C1 and C2 (small, local, `crop_screen.dart`), each with the proposed test, in a new commit on `arena/9c08ad5c-scan-id`. Re-run CI on the new SHA until green.
2. Obtain the decision on C3 before changing it.
3. Add L1–L3 tests. Do not change any existing expectation.
4. Re-audit the new SHA. Do not treat a green `7647fdd` as proof for a later SHA.

---

## 13. Verdict restated

**NOT READY.** C1 and C2 are medium and confirmed by code reading, with no test. C3 is medium and needs a user decision. Protected contracts are unchanged. The 0.5 px tolerance is supported at DPR 1 and is not widened. D7 policy is unchanged and the divergence is documented.
