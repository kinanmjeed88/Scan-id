# Boundary / instance audit — report

Reference commit: `8c9200372df8b9be0bb2a4c66b0b87002ac53ac8` (base `searchidf`)
Final commit on this branch: `59a1f687f8ae43fd029b11527e5db41b02b9cdd6`
Verified green run: [44408120801](https://github.com/kinanmjeed88/Scan-id/actions/runs/44408120801)
Branch: `arena/d2061602-scan-id`

Everything below is either a measured number or an explicit statement that the
number could not be computed. No result in this document was estimated.

---

## 1. Dataset

| Item | Status |
|---|---|
| Source | `scanid_boundary_annotation_candidates.zip` (repo root, 9.3 MB) |
| Download / inspection | Inspected: 116 entries — 57 originals, 57 machine overlays, `boundary_candidates.json` (44 quads), an `.xlsx` index |
| Formats / sizes | 2 PNG, 1 WEBP, 54 JPEG; 194×259 … 4961×7016 |
| EXIF orientation | Present on images 014–029, value `1` on all of them ⇒ **no rotation case exists in this set** |
| Extracted to | `local-data/boundary-dataset/` — git-ignored, never committed |

No other dataset was used for any measurement.

### OpenCV candidates

The packaged 44 quads were **not** treated as truth. They are axis-aligned
rectangles on 35 of 57 images, carry `verified: false`, and were only ever used
as a candidate to be checked against the original pixels.

---

## 2. Reviewed ground truth

57 images reviewed at native resolution. Instances were drawn from machine
proposals (packaged + `tool/boundary_evaluation/auto_propose.py`) and then
**certified by inspecting the rectified warp** — a crop either contains the whole
document or it does not, which is the only decision procedure that is honest
about a few-percent corner error.

**Final count: 67 document instances** (not 75 — the earlier count was wrong and
was corrected against the pixels).

| Status | Count |
|---|---|
| `confirmed` | 36 |
| `needs_review` | 17 |
| `undetermined` | 14 |

- Coordinates: 4 points, `TL → TR → BR → BL`, normalized to the original image
  size, stored per instance with the source pixel size asserted.
- 49 of 67 instances have a quad; 18 could not be bounded at all and are recorded
  as `undetermined` with a reason, never with an invented rectangle.
- 6 images hold more than one document (images 1, 4, 5, 7, 8, 39); image 1 holds 6.
- Two merges are explicitly forbidden and recorded: image 4 #1 (aspect 6.73 spans
  both cards) and image 7 #1 (spans both held cards).
- Structural verification: 49 quads checked, 49 passed, 0 failed
  (`tool/boundary_evaluation/verify_ground_truth.py`).
- Limitation: a single reviewer. Two reviewers plus adjudication are still
  required before these labels can be called final.

---

## 3. Architecture findings

### 3.1 One document per photo is the shipped behaviour

`multiDocumentSegmentationEnabled` is `false`
(`lib/application/multi_document_segmentation_flag.dart:8`) and `defaultSegment`
returns an empty result (`lib/application/recognition_pipeline.dart:210`). In
production a photo therefore yields **at most one** document, from the
whole-frame detector. Two cards in one photo cannot both be produced, whatever
the detector quality.

Measured ceiling of that configuration on this dataset: **57 of 67 instances**
(recall 0.8507); the 10 later documents in multi-document photos are lost before
any detector runs.

### 3.2 Region stage quality (measured, `tool/boundary_evaluation/segmenter_port.py`)

| Metric | Value |
|---|---|
| Predicted regions | 60 |
| Matched at IoU ≥ 0.5 | 28 |
| Instance precision | **0.4667** |
| Instance recall | **0.5714** |
| Instance F1 | **0.5138** |
| Mean IoU of matches | **0.7034** |
| Corner error, mean (normalized) | **0.0928** |
| Corner error, RMS | **0.1136** |
| Documents lost or merged into one region | **8** |
| Spurious regions | 32 |
| Images yielding no region at all | 13 |

The corner numbers are the floor of the region stage: it only has a rectangle,
so its corners are the rectangle's, not the card's.

### 3.3 Defect found and fixed: document identity across reprocessing

`lib/application/smart_recognition.dart` matched an existing `DocumentRecord` to
a region by `detectionId`, which is `"<asset>-d<N>"` — the region's **position**
in the list (`regionDetectionId`, `recognition_pipeline.dart:221`). Position is
stable only while the list is. When a reprocess measured the same cards in
another order, or one region fewer, `d0` named the other card, and the pass then

- appended a second record for a document the project already held (one photo of
  two cards becoming four documents), or
- refreshed card A's record with card B's crop — the worse outcome, because the
  user then sees the wrong image attached to a card they already reviewed.

Fixed by resolving identity from the **measured region rectangle**: persisted in
the record's detection trace (`region=l,t,r,b`), used to match by
intersection-over-union (threshold 0.6) before any positional id, with the
positional id kept only as a fallback for records written before the region was
persisted. A claimed record leaves the claimable list, so one record can never be
refreshed twice in a pass and two regions can never resolve to one document.

### 3.4 Defect investigated and NOT shipped: frame-border gate

A measured proposal whose corner sits within 1.6 % of the photo border was going
to be treated as "the photo cut this document" and sent to review. Measured
against the reviewed truth it does not separate the two cases:

| Band | Flagged | of which warps were certified complete (of 36) |
|---|---|---|
| 0.5 % | 8 | 4 |
| 1.0 % | 11 | 5 |
| 1.6 % | 14 | **8** |
| 2.0 % | 15 | 9 |
| 3.0 % | 21 | 15 |

Many photographs are framed so the card exactly fills the frame. The gate was
implemented, measured, and reverted; the measurement is kept
(`tool/boundary_evaluation/frame_band_measurement.py`) so the decision is
auditable. Shipping it would have sent 8 verified-complete crops to manual
review and broken six existing tests.

### 3.5 Two fixes implemented and REJECTED on measurement

| Experiment | Result |
|---|---|
| Occupancy-valley split of a merged two-card component | 162 regions for 60 predicted; precision 0.4667 → **0.1358**, recall 0.5714 → 0.4490. A page's own margins and text bands form the same profile as a gap between cards |
| Adaptive-threshold fallback mask when Otsu finds nothing | precision 0.4667 → **0.4375**, recall unchanged at 0.5714, 4 more spurious regions |

Neither is in the source. Both are reproducible from the port's flags
(`--no-split` default, `--adaptive`).

### 3.6 OCR per instance

`prepareOcrRegion` (`lib/imaging/ocr_region.dart:36`) warps the accepted quad, or
crops the measured region, or — only for a single-document photo with no separate
region — uses the whole preview. The pipeline reads text only inside this
document's authorized quad or its measured region
(`recognition_pipeline.dart:646`), so **text cannot mix between instances**; the
wider re-read is bounded by the region, never the frame, and an isolated region
without its own measured area is never widened. Existing tests already pin this
(`recognition_pipeline_evidence_scope_test.dart`, "documents sharing a frame stay
isolated").

EXIF is baked once, and only when the orientation tag is not null or 1
(`prepare_image.dart`); the native scaler/cropper paths receive the orientation
explicitly.

---

## 4. Metrics that could NOT be computed, and why

| Metric | Status |
|---|---|
| OCR CER / WER / character accuracy / field accuracy | **Not computed.** No reviewed text ground truth exists: producing it requires reading the documents, and the brief forbids putting personal text in the repository or any log. It must be built and stored in approved private storage, then measured where the OCR engine runs (CI/device). |
| Classification precision / recall / F1 / confusion matrix / unknown rate | **Not computed** for the same reason: classification is driven by OCR keywords and catalog shape, and per-instance OCR text was not extracted against truth. |
| End-to-end detection on the full-resolution pipeline | **Not computed.** The runnable Dart pipeline cannot execute in this environment (see §5), so these numbers come from a faithful Python port of the region stage, not from the shipped binary. |
| Perspective / warp quality per instance | Partially: warp sheets were inspected to certify 36 quads; no numeric reprojection error beyond the IoU/corner figures above. |

---

## 5. Toolchain constraint

No Flutter/Dart SDK is reachable from this environment (SDK and CDN hosts refuse
connections; npm and PyPI cannot supply a Dart VM). Therefore:

- **no `flutter analyze`, `flutter test` or `flutter build` was executed locally**;
- every Dart change in this branch was compiled, analysed and tested **only** by
  CI, on the pushed commit.

---

## 6. Verification actually run

On `59a1f68` (run [44408120801](https://github.com/kinanmjeed88/Scan-id/actions/runs/44408120801)) — **all jobs green**:

| Step | Result |
|---|---|
| Source integrity audit (321 Dart files) | success |
| Detector retirement and manual-only contract | success |
| Android ONNX JNI release keep rules | success |
| Workflow permissions audit | success |
| Dart format gate | **success** |
| Flutter analyze (`--fatal-infos`) | **success** |
| Flutter tests (full suite) | **success** |
| Export tests in isolation | success |
| Android debug APK build | success |
| Android signed R8 release intake regression | success |
| Android instrumentation evidence | 8/8 tests, 0 failures |
| Windows build | success |

Local checks: `python3 tool/check_source.py` and
`python3 tool/check_detector_retirement.py` pass; the ground-truth builder and
both evaluation scripts run reproducibly (identical numbers before and after the
sandbox reset).

The run before it (`75f949c`) failed only on the Android 16 startup evidence
step — `adb: device emulator-5554 not found` while installing the diagnostic APK,
after the build and every test had passed. That is an emulator infrastructure
failure, not a code failure; the commit was re-run and passed.

Earlier runs on this branch failed and were fixed, each at its root cause:
format gate (4 formatter diffs), analyze (`goodQuad` was local to `main`), tests
(the frame-border gate mis-routing six fixtures — which is why it was reverted).

---

## 7. Tests added

| Test | What it pins |
|---|---|
| `reprocess_test.dart` "another order does not duplicate them" | a pass that measures the same cards in reversed order keeps 2 documents and each record still describes **its own** card |
| `recognition_pipeline_test.dart` "two measured regions stay two regions" | N measured regions ⇒ N analyses, distinct ids, measured bounds kept, none dropped |
| `document_segmenter_test.dart` "two cards touching … are two regions" | **skipped, deliberately**: asserts the known limitation (adjacent cards merge) so removing the skip is the acceptance check for a real instance detector |

Requirement coverage that already existed and was verified rather than
duplicated: single document, both cards' sides, tilted/trapezoidal cards,
perspective correction failure, OCR failure preserving image and crop, OCR
isolation between instances, preview→original mapping, EXIF baked exactly once.

---

## 8. Remaining work, in priority order

1. **Instance separation for adjacent/overlapping cards** — the root cause of 8 of
   49 measurable documents. Needs a detector that models documents; thresholded
   masks cannot, as measured in §3.5.
2. **Turn region segmentation on, or replace it.** The production flag disables
   multi-document intake entirely, capping recall at 0.8507 before any detector
   quality applies. Precision 0.4667 is *not* good enough to enable as-is.
3. **Text ground truth in approved private storage**, then OCR and classification
   metrics, which are the only way to judge the OCR stage honestly.
4. **Second reviewer + adjudication** for the 17 `needs_review` and 14
   `undetermined` instances.

---

## 9. Files

Evaluation (committed, contain no image data and no personal text):
`tool/boundary_evaluation/{segmenter_port,auto_propose,build_ground_truth,verify_ground_truth,frame_band_measurement,production_path_baseline}.py`

Generated outputs stay under `local-data/` (git-ignored):
`baseline_region.json`, `baseline_production_path.json`,
`frame_band_measurement.json`, `boundary-dataset/ground_truth_quad.json`.
