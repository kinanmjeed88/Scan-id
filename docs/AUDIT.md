# Scan ID — Phase 0 Architecture Audit & Contract

- **Date:** 2026-10-08
- **Branch:** `arena/028443f4-scan-id`
- **Baseline HEAD:** `14a3ee7b46ad6b1c0a5bdb912765e232dfb3ec33`
- **Scope of this document:** architecture audit + architectural contract for the
  Smart Recognition + deterministic A4 layout work. **Documentation only.**
  Companion decisions: [`docs/adr/`](adr/README.md). Prior (historical) audit:
  [`docs/AUDIT_HISTORY.md`](AUDIT_HISTORY.md).

> **Verification disclaimer.** This audit is produced by **static reading** of the
> source, `pubspec.*`, platform manifests and `docs/*` at the baseline HEAD. **No**
> `dart format`, `flutter analyze`, `flutter test`, or Android/Windows build was
> executed in the authoring environment (no local Flutter/Dart/.NET SDK). Every
> statement about *current* behavior is an observation from source and must be
> re-confirmed by CI before any change. Numbers attributed to past CI runs are
> quoted from `docs/STATUS.md` and are **historical claims, not results produced
> here.** Per the reporting contract, anything not executed is reported as
> **NOT VERIFIED**.

---

## A. Repository baseline

| Item | Observed value | Source |
|---|---|---|
| Repository | `kinanmjeed88/Scan-id` | git remote |
| Branch | `arena/028443f4-scan-id` | git |
| HEAD | `14a3ee7b46ad6b1c0a5bdb912765e232dfb3ec33` (merge of PR #5) | git |
| Working tree | **clean** (before Phase 0 docs) | `git status` |
| Flutter constraint | `flutter: '>=3.35.7'` (CI pins **3.35.7 stable**) | `pubspec.yaml`, `.github/workflows/verify.yml` |
| Dart SDK constraint | `>=3.9.0 <4.0.0` | `pubspec.yaml` |
| Persistence | **sembast 3.7.2** (no Isar, no codegen) | `pubspec.yaml`, `lib/persistence/*` |
| Direct deps | flutter, flutter_localizations, file_selector 1.0.3, image 4.5.4, path 1.9.1, path_provider 2.1.5, sembast 3.7.2, pdf 3.12.0, printing 5.14.3, crypto 3.0.7 | `pubspec.yaml` |
| Dev deps | flutter_test, flutter_lints 5.0.0 | `pubspec.yaml` |
| `schemaVersion` | **4**; `Project.fromJson` accepts `{1,2,3,4}` | `lib/domain/project.dart` |
| Legacy fixtures | v1, v2, v3a, v3b, v3c (all `schemaVersion=3` variants except v1/v2) | `test/legacy_schemas/`, `test/persistence/legacy_schema_test.dart` |

**Test inventory (observed from source):** 31 `*_test.dart` files across
`application` (6), `domain` (9), `export` (1), `imaging` (6), `integration` (1),
`persistence` (5), `presentation` (3), `widget_test.dart` (1), plus
`legacy_schemas` fixtures. A source grep counts ~201 `test(...)`/`group(...)`
declarations; presentation/widget suites use `testWidgets(...)` and are not in
that count. **Historical CI claims (from `docs/STATUS.md`, not run here):** e.g.
160 Linux tests green at `eb6da90`; earlier figures 237/230/145 at other SHAs.
The exact current pass/fail count is **NOT VERIFIED** locally and must come from
a CI run on the implementation branch.

---

## B. Current architecture

**domain/** — pure models + deterministic logic, no Flutter/image/db imports
(enforced by `tool/check_source.py`). `project.dart` (`Project`, `ImageAsset`,
`DocumentItem`, `PaperSettings`, `LayoutSettings`, `ExportProfile`, `Margins`);
`document_kind.dart` (`DocumentKind`, `PhysicalSizeMm`, `DocumentSizeCatalog`,
`suggestDocumentType`, `DocumentTypeSuggestion`, `provisionalSize`);
`arrangement.dart` (`arrangeDocuments`, `ArrangementResult`, `AutoLayoutStatus`,
`autoLayoutStatus`); `packing.dart` (`proposePacking`, MaxRects);
`page_layout.dart` (`PageLayout`, `PageViewport`, `inspectLayout`,
`PageAlignment`); `geometry.dart` (`Point2`, `RectMm`, `CropGeometry`,
mm/point conversions); `crop_draft.dart` (`CropDraft`, `ImageEditRecipe`);
`document_edits.dart` (`DocumentEdits`); `edit_history.dart` (`EditHistory`,
session undo/redo); `validation.dart` (`require`, typed readers, `validId`,
`validName`, `validAssetPath`, reserved-Windows-name guard); `image_limits.dart`
(20 MiB / 16 MP / 200 assets / 500 items); `export_plan.dart`,
`export_naming.dart`,
`image_adjustments.dart`.

**imaging/** — no Widgets. `document_detector.dart`
(`suggestDocumentCorners`/`detectDocumentCorners`: classical, deterministic,
single quad or `null`); `perspective.dart` (`PerspectiveMap` 8-param homography,
`warpPerspective`, `renderPerspective`); `prepare_image.dart`
(`decodeForProcessing`, `prepareImage`, `normalizeChannels`);
`image_header.dart` (`inspectImageHeader`), `safe_png.dart`,
`auto_adjustments.dart`.

**application/** — `project_service.dart` (`ProjectService`: `create`, `rename`,
`importImages`, `arrangeImportedImages` (auto-intake: open→suggest→classify→
crop-to-catalog-aspect→create item→arrange→save), `applyCrop`,
`replaceImage`, `moveAsset`, `removeAsset`, `deleteProject`, orphan/staging
maintenance, `suggestAutoAdjustments`); `contracts.dart` (ports + result types);
`image_reader.dart` (`readBoundedImage`); `camera_capture.dart`,
`native_camera.dart`, `native_documents.dart`; `output_service.dart`;
`layout_session.dart`; `backup_transfer.dart`; `project_backups.dart`;
`project_recovery.dart`; `ids.dart`.

**persistence/** — sembast store `projects`; `local_project_repository.dart`
(optimistic `revision`, `RecoveryCheckpoints`, explicit `recover`, never
delete/recreate on corruption); `local_asset_repository.dart`
(`importImage`/`replaceImage` in `Isolate.run`, staging→publish, immutable
original); `local_image_editor.dart`
(`open`/`suggest`/`preview`/`createRevision` in isolates);
`local_project_backups.dart` (`.scanid`: magic + length-prefixed manifest ≤16
MiB + payloads, SHA256 per file, zip-slip/size guards, restore as new project);
`local_project_recovery.dart`; `local_storage_maintenance.dart`;
`recovery_checkpoints.dart`; `safe_files.dart` (symlink/`..`/root confinement).

**export/** — `document_exporter.dart`: PDF = vector A4 page + embedded working
images positioned in mm (`pw.Positioned`/`pw.Transform.rotate`), **no text**;
PNG/JPG raster at 300/600 DPI (`renderPage`), JPEG DPI metadata patched; memory
budgets (40 MP embedded, 96 MiB encoded); runs in isolate. Print via `printing`
(`output_service.dart`). Share: Android `ExportFileProvider` (scoped to
`scan-exports/`, not exported), Windows reveal-in-folder.

**presentation/** — `app.dart`, `project_screen.dart`, `crop_screen.dart`
(mandatory preview, rejectable proposal, session undo), `layout_screen.dart` +
`ribbon.dart` (Word-like ribbon, ±1 mm tools, type picker, catalog dialog,
auto-enhance), `editor_controller.dart` (`LayoutEditorController`, single editor
state), `page_canvas.dart` (only mm→px site; `_DocumentPanGestureRecognizer`),
`sheet_view.dart`, `export_screen.dart`, `shortcuts.dart`, `shared.dart`.

**Android/** — `android/app/src/main/AndroidManifest.xml`: **no INTERNET**,
`allowBackup=false`, `fullBackupContent=false`, `dataExtractionRules` set;
system camera via `ACTION_IMAGE_CAPTURE` + `CaptureFileProvider` (no CAMERA
permission); `ExportFileProvider`. `debug`/`profile` manifests add INTERNET
(Flutter template; not in release). Native glue in `MainActivity.kt`.

**Windows/** — CMake runner; PDFium pinned (chromium/8086, SHA256 verified at
build); storage under LocalAppData; save via system picker; reveal-folder share.

**Contracts / ports** (`lib/application/contracts.dart`) — `ProjectRepository`,
`AssetRepository`, `ImageEditor`, `StorageMaintenance`; result/config types
`ReplacementFiles`, `EditorSource`, `OrphanFiles`, `ShareTarget`, `ImportSource`
(in `project_service.dart`); exceptions `StorageException`, `RevisionConflict`.

---

## C. Existing reusable components (MUST reuse, not duplicate)

| Component | File | Role in recognition work |
|---|---|---|
| `DocumentSizeCatalog` | `domain/document_kind.dart` | the canonical, persisted, editable preset registry (National ID 85.6×53.98 ISO ID-1; Passport 125×88 TD3; Residence 92.4×62.8 *editable default*; Ration 52×287 *editable default*) |
| `suggestDocumentType` / `DocumentTypeSuggestion` | `domain/document_kind.dart` | seed classifier producing `{kind, confidence, reason}`; extend with OCR/geometry evidence, never replace |
| `suggestDocumentCorners` / `detectDocumentCorners` | `imaging/document_detector.dart` | classical detection foundation; extend to multi-document + confidence |
| `CropGeometry` / `RectMm` / `Point2` | `domain/geometry.dart` | canonical geometry + convex/ordered validation |
| `PerspectiveMap` / `warpPerspective` | `imaging/perspective.dart` | projective correction + processing (reused for `ProcessedDocumentAsset`) |
| `decodeForProcessing` / `prepareImage` / `normalizeChannels` | `imaging/prepare_image.dart` | decode/normalize/thumbnail; the PREPROCESS stage |
| `ImageAsset` original/working/thumb model | `domain/project.dart`, `persistence/*` | immutable source + derived working/thumbnail pattern (SourceImage) |
| `LocalImageEditor` | `persistence/local_image_editor.dart` | isolate offload for open/suggest/preview/revision |
| `arrangeDocuments` + `AutoLayoutStatus` | `domain/arrangement.dart` | deterministic A4 engine + visible statuses (extend with keep-together + `unplaced`) |
| `proposePacking` | `domain/packing.dart` | deterministic MaxRects (reused by compact strategy) |
| Existing A4 editor + `PageLayout` + `DocumentEdits` | `presentation/*`, `domain/page_layout.dart`, `domain/document_edits.dart` | the one and only editor; recognition results enter here |
| Existing undo (`EditHistory`, session) | `domain/edit_history.dart` | undo/redo for editor + recognition commands |
| Existing export (PDF/PNG/JPG/print/share) | `export/*`, `application/output_service.dart` | recognized items are ordinary items; export unchanged |
| Backup/restore (`.scanid`) + recovery + maintenance | `persistence/*` | must round-trip new state; excludes models/OCR text |
| Persistence ports + validation + limits + offline posture | `application/contracts.dart`, `domain/validation.dart`, `domain/image_limits.dart`, manifests | invariants and safety backbone reused as-is |

---

## D. Missing architecture (actual gaps to build)

1. **Multi-document detection & segmentation** — detector returns one quad; no
per-candidate id/`detectionConfidence`/visibility/quality; no overlap
resolution. 2. **Geometry confidence** — no `geometryConfidence` from named,
measurable factors; no scored geometry stage (only binary `CropGeometry`
validation). 3. **Orientation stage** — no explicit orientation proposal (only
quarter-turn adjustments chosen by the user). 4. **`ProcessedDocumentAsset`** —
a crop rewrites the *same* asset's working image; no first-class per-detection
derived asset with transform/DPI/version. 5. **`DocumentInstance` /
`DocumentSide`** — no logical-document or front/back model; no
`UncertainPairing`. 6. **OCR** — none (`OCRAnalyzer` behind an interface,
evidence-only). 7. **Evidence fusion + five confidence dimensions** —
`DocumentItem` carries a single `recognitionConfidence`; no
`detection/geometry/ocr/classification/ final` separation, no R1–R4 rules, no
bands. 8. **Preset resolver / variants / snapshots** — catalog has one size per
type; no
   `PresetVariant`, no `DocumentPresetResolver`, no per-item preset snapshot.
9. **Provenance chain** — no `sourceImageId→detectionId→documentInstanceId→side→
   model/recognition versions` record.
10. **User-override separation** — overrides are in-place edits that zero the
    confidence (anti-pattern; see ADR-004); no separate override layer.
11. **Review queue / detail UI** and «تجريبي» badge; **feature flag** (none
    exists; lite auto-intake is currently always-on default).
12. **Worker abstraction / cancellation** — one-shot `Isolate.run`; no bounded
    concurrency, streaming progress, cooperative cancellation, or session reuse.
13. **Re-run reconciliation** — no IoU-based matching / "recognition changed"
    flagging / override preservation on re-run.
14. **Keep-together layout groups** — engine has no group constraint.
15. **Explicit schema migration to v5** — implicit parsing only (ADR-010/011).
16. **Evaluation / benchmark infrastructure** and **CI import guard**.

---

## E. Explicit non-goals (never recreate in Scan-id)

Scan-id does **not** contain, and must **never** gain, any of the following
unrelated diagnostic systems (confirmed absent at baseline; see the source-scope
finding accepted earlier):

- `PdfContentProbe` / any PDF content probe.
- `CanonicalLayout` (as an external diagnostic construct).
- A DOCX exporter (no `python-docx`, no `word/document.xml`, no `w:r`).
- A vector-PDF **text** renderer (PDF export embeds images only; there is no
  drawn text, no advance-width/baseline/ascent/descent geometry).
- The "14-failure report" and its diagnostic harness.
- `F-A` / `debugPhaseTiming` / `R4-DIAG` / font-registration diagnostics, or any
  runtime font-loading path (the app deliberately avoids `GoogleFonts`/runtime
  fonts).

These contexts must not be recreated, ported, or inferred here. `akrym1582/
ExcelRenderer` is an unrelated third-party repository and is **not** a source
for Scan-id.

---

## F. Concept mapping (spec → current → extension → new? → persistence impact)

Prevents accidental duplication of existing models.

| Spec concept | Current implementation | Required extension | New entity? | Persistence impact (schema v5) |
|---|---|---|---|---|
| SourceImage | `ImageAsset` (immutable original + working + thumb) | none (reuse) | no | existing |
| DetectedDocument | — | new: id, sourceImageId, polygon, bbox, `detectionConfidence`, quality/visibility, producer+version | **yes** | new collection/field (v5) |
| DocumentInstance | — | new: 1–2 sides, pairing state | **yes** | new (v5) |
| DocumentSide | — | new: front/back/unknown | **yes** | new (v5) |
| ProcessedDocumentAsset | derived `working` under `edits/<id>` | elevate to first-class per-detection asset: corners, transform, output size, effective DPI, version; regenerable | **yes** | new ref (v5) |
| DocumentLayoutItem | `DocumentItem` (mm x/y/w/h, rotation, page, lock, `documentKind`, `recognitionConfidence`, `sizeConfirmed`) | add preset snapshot, provenance, override ref, group id | extend | additive fields (v5) |
| DocumentType | `DocumentKind` + `suggestDocumentType` | extend evidence (OCR/geometry), keep filename+aspect seeds | extend | existing + evidence (v5) |
| Preset | `DocumentSizeCatalog` (one size/type) | add `PresetVariant` + resolver + per-item snapshot | **yes** (variants) | additive (v5) |
| RecognitionEvidence | `DocumentTypeSuggestion.reason` (string) | structured evidence: per-source scores + reasons, versions | **yes** | new (v5); **no OCR text/field values** |
| Confidence | `DocumentItem.recognitionConfidence` (single) | five dimensions + fusion + R1–R4 + bands | **yes** | additive (v5) |
| UserOverride | in-place edits zeroing confidence | separate override layer; effective = override else AI | **yes** | new (v5) |
| ReviewItem | — (statuses via `AutoLayoutStatus`) | review queue model ordered by urgency | **yes** (UI/domain) | derived; minimal persisted state |
| LayoutGroup | — | generic keep-together group in engine | **yes** | group id on items (v5) |
| Provenance | `ImageAsset.transforms` log | full chain + versions + confidences + override flags | **yes** | new (v5) |

**Target confidence model (design target; provisional, NOT empirically validated):**
five separate scores — `detectionConfidence`, `geometryConfidence`,
`ocrConfidence`, `classificationConfidence`, `finalConfidence`.
`classificationConfidence` = weighted geometric mean over **available** sources
(visual 0.4 / OCR 0.3 / structure 0.3; unavailable sources excluded, never
zero). `finalConfidence` = weighted geometric mean of detection 0.2 / geometry
0.3 / classification 0.5. Hard rules: **R1** auto-eligibility needs ≥2
independent sources, ≥1 non-OCR; **R2** any component below its floor (prov.
0.5) caps to review; **R3** top-class conflict caps to review ("conflict");
**R4** winning `classificationConfidence` below prov. 0.60 ⇒ `Unknown`.
Bands (provisional): `finalConfidence ≥ 0.90` auto-candidate; `0.70–<0.90`
review; `< 0.70` unresolved/manual. Default automation mode = `reviewAll`;
`autoAcceptHighConfidence` ships disabled. These numbers are unvalidated
hyperparameters until a real-dataset calibration exists.

---

## G. Data-flow (target pipeline)

Legend: **[E]** existing · **[X]** extension required · **[N]** new stage.

```
IMPORT            [E] ProjectService.importImages / AssetRepository.importImage
→ VALIDATE       [E] readBoundedImage + inspectImageHeader + withinImageBudget →
PREPROCESS     [E] decodeForProcessing / prepareImage / normalizeChannels →
DETECT         [X] suggestDocumentCorners → multi-candidate +
detectionConfidence → SEGMENT        [N] independent units; deterministic
overlap resolution (IoU/area/confidence/validity) + candidate-quality gate
(ADR-012) → REFINE GEOMETRY[X] CornerRefiner + geometryConfidence + typed
GeometryInvalid → PERSPECTIVE    [E] PerspectiveMap / warpPerspective →
ProcessedDocumentAsset → ORIENTATION    [N] geometry + structure proposal
(asset-only; layout rotation separate) → OCR            [N] OCRAnalyzer
(evidence-only; label anchors/structure; no field values) → CLASSIFICATION [X]
DocumentClassifier over geometry+structure+aspect+OCR (+ optional visual) →
EVIDENCE FUSION[N] fusion per §F (five confidences, R1–R4) → CONFIDENCE     [N]
finalConfidence + band + reasons → DOCUMENT TYPE  [X] DocumentKind (+ Unknown on
insufficient evidence) → PRESET         [N] DocumentPresetResolver → variant /
presetConfidence / awaitingSize shortlist → FRONT/BACK     [N] pairing →
DocumentInstance/DocumentSide / UncertainPairing → USER REVIEW    [N] review
queue + override layer (authoritative; AI never overwrites) → LAYOUT ITEM    [X]
DocumentLayoutItem (mm size from preset; provenance; override; group id) → A4
AUTO LAYOUT [E] arrangeDocuments / proposePacking (sole coordinate authority; +
keep-together [X]) → EXISTING EDITOR[E] LayoutEditorController / PageCanvas /
ribbon (correct AI results here) → EXPORT         [E] DocumentExporter
(PDF/PNG/JPG/print/share) — unchanged
```

Every stage degrades gracefully: a failure is recorded with a typed reason and
the pipeline continues where it can; no stage silently destroys the source or an
existing workflow.

---

## H. AI vs deterministic boundary (invariant)

**AI / recognition may PROPOSE:** detection (where, how many), corners, geometry
estimate + `geometryConfidence`, orientation, OCR evidence (anchors/structure),
classification candidates + per-source evidence, preset candidates +
`presetConfidence`, and the five confidence values with reasons.

**Deterministic systems DECIDE:** geometry validity (convex/ordered/non-degenerate
via `CropGeometry`; impossible geometry is rejected, never repaired), physical
dimensions **after confirmation** (from the catalog/preset or an explicit user
size — never inferred from pixels), and all A4 placement (page, x, y, rotation,
packing, collision avoidance, page count) via `arrangeDocuments`/`proposePacking`,
and export coordinates via `DocumentExporter`.

This boundary is an **invariant**: AI output is evidence + a confirmed physical
size; it is never a coordinate. Violations are architectural defects.

---

## I. Failure / fallback contract

| Stage failure | Fallback (no source or workflow destroyed) |
|---|---|
| Detector failure | existing smart-crop proposal, else manual crop |
| Segmentation failure | single-document path / manual review |
| Geometry failure | `GeometryInvalid` → manual crop/review (never auto-repair) |
| Perspective failure | retain source; manual workflow |
| OCR failure | continue with visual/geometry/structure evidence |
| Classifier failure / insufficient evidence | `Unknown` → manual type selection |
| Preset uncertainty | `awaitingSize` + candidate shortlist → user selects |
| Low confidence (< 0.70, or any R1–R3 cap) | review queue (never silently accepted) |
| AI unavailable (flag off / no model / worker down) | existing fully-manual workflow |

Optional stages (OCR) degrade evidence but never abort the pipeline. One failed
document never affects others in its image; one failed image never affects the
batch; zero documents is a valid success.

---

## J. Performance / memory contract (risks only; no invented numbers)

Known cost centers to be bounded and later measured by the benchmark harness
(Phase 7) and Tier B device runs:

- **Full-resolution decode** — detection must decode at reduced size (existing
  detector uses ~480/1200 px rasters); full resolution is read only to warp the
  needed region per document. At most one full-res bitmap per worker.
- **600 DPI output** — an A4 page at 600 DPI is ~4961×7016; a single RGB page
buffer is on the order of ~100 MiB before codec/source (existing export already
budgets 40 MP embedded / 96 MiB encoded and rasters one page at a time).
- **Multiple documents per source** — N derived assets per image multiply warp
  and encode cost; must be bounded and streamed, not batched in memory.
- **OCR memory** — model session + per-image tensors; session created once per
  worker and reused; buffers released deterministically.
- **Model loading** — cold-start cost and RAM; measured per candidate; no runtime
  download.
- **Isolate transfer** — large buffers cross by transfer/file hand-off, not
  repeated copying.
- **Concurrency** — one image at a time on Android, up to two on Windows
  (initial), bounded queue; batches above the chunk limit are queued with
  progress, never rejected.

**Actual RAM/latency/size budgets are established by CI/benchmark evidence and
Tier B device runs; none are asserted here.** The Tier A criterion is "no growth
with batch size": live image buffers and native handles return to baseline after
every image and after cancellation, asserted via resource accounting (not RSS on
shared runners).

---

## K. OCR / model evaluation plan (no model added yet)

No OCR/ML dependency is introduced in Phase 0. Before any model becomes a
production dependency it must pass an ADR + evaluation evidence. Compare **at
least** PaddleOCR **PP-OCRv5 Arabic Mobile** recognition and a suitable
detection companion, plus **at least one** viable alternative/runtime where
meaningful, on **synthetic or redacted** samples only (no real identity
documents in the repo/CI).

Evaluation dimensions: Arabic recognition accuracy (CER/WER + evidence-level
accuracy), model size, runtime (ONNX/other), Android support, Windows support,
CPU-only operation, RAM, offline packaging, license (prefer permissive; verify
PaddleOCR Apache-2.0 and the Arabic model's actual availability/form), Flutter
integration complexity (native FFI vs pure Dart), and cold-start/loading cost.
Also evaluate the CV/inference runtime (native FFI bindings vs pure Dart) with
the same lens.

**Gate:** model + runtime choice requires owner approval (Phase 5) after the ADR
and evaluation report. No model becomes a production dependency before ADR
approval and evaluation evidence.

---

## L. Test strategy (future layers; no results invented)

- **Domain:** invariants (`require` paths), confidence/fusion property tests
  (monotonicity, caps, missing-source handling, determinism), pairing +
  `UncertainPairing`, preset resolution + variants + snapshots, deterministic
  layout (incl. keep-together, ration-card 52×287 case, locked items).
- **Imaging:** multi-document detection, corner refinement + `geometryConfidence`,
  perspective round-trip (≤ 0.5 source px on vectors), orientation.
- **Application:** state machine, progress, cancellation (**via test hooks, not
  timing**), failure isolation, reconciliation/idempotency (re-run keeps
  overrides; no duplicate logical documents; sources untouched).
- **Persistence:** v1/v2/v3a/v3b/v3c/v4 → v5, v5→v5 unchanged, malformed,
  unsupported-future (typed reject), interrupted-migration rollback, pre-upgrade
  snapshot, backup/restore round-trip.
- **UI:** review, override, manual fallback, RTL, keyboard/mouse/touch, and
  accessibility parity with the existing editor.
- **Integration:** Android and Windows real builds in CI; existing workflow test
  extended.
- **Benchmark:** memory trend, per-document time at 1/5/10/20 images + chunk
  limit, model init, cancellation, concurrency; resource-accounting assertions.

All **pre-existing tests must stay green** (regression). No assertion may be
weakened; no test moved to make the build pass; no sleeps/`pumpAndSettle` hacks.

---

## M. CI / verification contract

A phase is not complete unless CI provides actual evidence for: `dart format`
(clean), `flutter analyze --fatal-infos` (zero errors/warnings), `flutter test`
(all green incl. pre-existing), Android build (+ APK privacy/permission audit:
no INTERNET), Windows build (+ startup), independent export verification
(PyMuPDF/Pillow), migration tests, the full regression suite, and (once present)
the recognition import guard and benchmark resource assertions.

If a check cannot be executed in a given environment, the report must state
**NOT VERIFIED** with the reason. Successful validation is never inferred from
static source inspection.

---

## N. Import / generated-code audit rule

Before and after every implementation phase:
1. inspect **all changed imports**;
2. inspect **generated-code dependencies** if any are introduced;
3. inspect **adjacent files** that consume changed APIs;
4. run **full** `flutter analyze`, not only file-local checks;
5. run the **full relevant test suite**;
6. **build** supported targets (Android + Windows).

This rule exists to prevent the class of missing-import / missing-generated-
extension failures seen in unrelated projects. (Scan-id currently has no code
generation; if any is ever introduced, its generated files' imports are audited
explicitly.)

---

## O. Phase gates

| Gate | Name | Must be satisfied before |
|---|---|---|
| Gate 0 | Audit + ADRs complete (this document) | any implementation |
| Gate 1 | Domain/schema design approved | migration implementation |
| Gate 2 | Geometry vertical slice validated (detect→segment→refine→perspective→orientation→minimal hand-off) | OCR work |
| Gate 3 | Preset/pairing/layout-group behavior validated (determinism, ration-card, unknown-size) | review/override UI |
| Gate 4 | Review/override/reconciliation validated | OCR runtime integration |
| Gate 5 | OCR runtime selected by evidence (+ ADR + owner approval) | classifier fusion |
| Gate 6 | Classifier/evidence fusion validated (property tests, R1–R4, bands) | benchmark/eval |
| Gate 7 | Benchmark/evaluation evidence (synthetic; resource accounting) | release |
| Gate 8 | Release/regression/privacy gate; feature-flag default-on only with owner approval | shipping recognition on by default |

A later gate must **not** be implemented merely because an earlier gate is
incomplete. Recognition stays behind an off-by-default feature flag until Gate 8
owner approval.

---

## P. Defects found (carried forward; see `docs/AUDIT_HISTORY.md`)

No new production defects are introduced by Phase 0 (documentation only). The
known defects/lessons from the prior audit remain the regression baseline and
are preserved in `docs/AUDIT_HISTORY.md` (baseline gaps G1–G9; PR #4 defects
R1–R6; S1–S7 lessons). Two are directly relevant to this work and are restated
as forward obligations, not fixed here:

- **Override/confidence conflation** (ADR-004): `DocumentEdits.setKind` sets
  `recognitionConfidence: 0`; Phase 4 must separate the override layer.
- **Implicit migration** (ADR-010/011): `Project.fromJson` parses 1–4 with
  defaults; Phase 1 must add the explicit, snapshot-protected v4→v5 migration.

## Q. Reliability audit (2026-10-09) — false-positive documents and derived-asset provenance

Added after implementation; the Phase 0 baseline above is unchanged. Decision
record: [ADR-012](adr/ADR-012.md).

Two defects were reproduced against the code and fixed. Both are restated here
with their code paths so the regression tests have something to point at.

**Q.1 Background fragments became ordinary documents (§G SEGMENT).**
`segmentDecoded` filtered merged components only by `area >= total * .015`,
`width >= 10`, `height >= 10`, `fill >= .4`, `width * height <= total * .95`.
`fill >= .4` is satisfied trivially by any *solid* region — which is what a
shadow strip, a table edge or a vignette band is — and there was no aspect
bound, no frame-contact test, no usable-crop minimum and no candidate cap.
`multi` is true at `deduplicated.length >= 2 && quads >= 1`, so one real card
plus one junk strip was enough to take the multi path, and
`SmartIntake._applyMultiDocument` then iterated **all** regions creating a
derived asset, a `DocumentRecord` and a `DocumentItem` for each. Unresolved
regions got an axis-aligned crop with `trustworthy: false`, which routes to
`autoLayoutStatus() == sizeUnconfirmed` and renders in `OffSheetTray`. The extra
editor items were therefore real documents with real crop files, not a rendering
fault. `SegmentCandidate.reason` was read by nobody, so the one diagnostic that
existed was discarded and a `region-too-small` region still became a document.

**Q.2 Derived assets could be committed without anything explaining them
(§H invariant, ADR-003).** `_sourceAssetIds` classified an asset as derived
*solely* from document-record path matching, so anything no record named was an
authoritative SOURCE. `_applyMultiDocument` and `_refreshDocument` wrote each
derived file and saved the asset list per region, while records and items were
merged only at the end of `run()` / `reprocess()`. A failure, `RevisionConflict`
or cancellation in between left record-less derived crops persisted; `Project`
validation (`items.every((i) => assetIds.contains(i.assetId))`) then made the
final `copyWith` throw, the batch aborted, and the next reprocess re-analysed
the crop as a photograph and appended a duplicate document.

**Q.3 Measured evidence for the bounds.** The fixture set this repository ships
(`test/imaging`, `test/application`) run through a port of the segmenter's own
arithmetic — its Otsu binning, 360 px working frame with
`Interpolation.average`, 2 px border median, 8 % region margin and `.round()`
semantics — with `img.fillRect`'s inclusive corners and `copyResize`'s kernels
taken from the pinned `image` 4.x source:

| population | aspect | frame sides | crop short side |
|---|---|---|---|
| genuine documents | 1.26 – 5.49 | 0 – 1 | 215 – 670 px |
| strips, slivers, vignettes | 12.00 – 22.50 | 2 – 3 | 43 – 104 px |

The genuine aspect maximum **is** the ration-card proportion (287 / 52 = 5.52
catalogued), which fixes the aspect bound at 8.0 — 1.46× above it and 33 % below
the narrowest strip. The genuine aspect minimum is a card rotated 18° in the
photo, whose axis-aligned box is 1.26 with fill 0.61. The 48 px crop floor sits
4.5× below the smallest genuine document crop and is a floor, not a
discriminator: an artificial 14-region grid used only to exercise the candidate
cap reaches 139 px and is still 2.9× above it.

No content gate ships. An internal-structure ("ink") measure — the fraction of a
crop differing from the crop's own median — scores **0.000** for BOTH a genuine
low-contrast card and a solid dark strip on these fixtures, because both are
uniform, so no separating threshold exists between them; on real documents a
faded, washed-out or blank-margin card is low-structure too. That is the
structural reason the shipped gates read only geometry and frame contact.

**Q.4 Residual risk, accepted.** A crisp solid strip drawn to the ration card's
own catalogued proportion measures 5.62 against the genuine card's 5.49, and
both are accepted. The two are geometrically indistinguishable, so the strip is
treated as ambiguous: preserved, routed to review under
`AutomationMode.reviewAll`, never silently accepted. A soft-edged strip (the
common shadow case) cannot claim a catalog size at all, because `sizeConfirmed`
requires a trustworthy boundary.

> **Corrected by R.2.** The two numbers in that paragraph came from different
> measurement bases — 5.62 is the *work-frame box* aspect and 5.49 the *preview
> region* aspect — so they did not compare the band with the card. Measured on
> one harness, the band is lower than the genuine card on every aspect basis and
> higher on fill. The conclusion (indistinguishable, preserved, reviewed) is
> unchanged and now stronger: there is no bound that refuses the artifact
> first. See [R.2](#r2-the-ration-proportion-residual-risk-re-measured) and
> [ADR-012](adr/ADR-012.md).

**Q.5 Diagnostic inventory.** What was lost downstream, and where it now goes:

| diagnostic | before | now |
|---|---|---|
| `SegmentCandidate.reason` | written, read by nobody | redundant with `corners == null`; the value that mattered became a typed `RegionRejection` |
| a region too small to crop | emitted as a candidate, then became a document | `RegionRejection.unusableCrop`, reported |
| refused regions | not representable | `SegmentationResult.rejected` → one aggregated Arabic message + `AutomaticLayoutReport.rejectedRegions` |
| `assessQuad` rejection reason | surfaced | unchanged (`حدود مرفوضة هندسياً (name)`) |
| `ImageAnalysis.issues` | surfaced as warnings | unchanged |
| unresolved boundary | off-sheet with `sizeConfirmed: false`, indistinguishable from a document that merely lacks a category | `hasUnresolvedBoundary` → `OffSheetTray` badge + its own review reason |
| `DetectionAnalysis.orientation` | computed, consumed by nobody, and fed a normalized long/short ratio so it was constant per kind | input corrected (`cropHeldAspect`); still unconsumed — every branch is `confident: false`, so applying it would need a real signal (OCR or content), which does not ship |
| derived-asset origin | inferred from record paths only | `ImageAsset.derivedFrom`, recorded at creation, preserved across revisions and replacements, backfilled only where records prove it, broken chains reported |

## R. Reliability audit, second pass (2026-10-09) — refusal feedback, residual risk

Added after the ADR-012 implementation was verified on CI. §Q above and the
Phase 0 baseline are unchanged except for the correction note on Q.4. Decision
record: [ADR-012](adr/ADR-012.md). This pass found one real defect (R.1),
corrected one recorded measurement (R.2), and verified one invariant that had no
test (R.4). No threshold, preset or routing rule was changed.

**R.1 Refusal feedback never reached the editor's own import door (§G SEGMENT,
§I failure contract).** `SegmentationResult.rejected` →
`ImageAnalysis.rejectedRegions` → `rejectedRegionsMessage` produced exactly one
aggregated Arabic warning per photo, and that warning was carried into
`AutomaticLayoutReport.warnings` — but the report's own refusal count
(`rejectedRegions`) was read by *nothing* in `lib/presentation/`. Tracing every
entry point:

| entry point | path | refusals before | refusals now |
|---|---|---|---|
| project screen → `startWithImagePicker` | `_import` → `IntakeRunner.run` → banner `warnings.take(3)` | listed, but a 4th warning pushed the aggregate out of the banner entirely | banner shows `intakeSummaryText`, whose second line is `rejectedHeadline` |
| project screen → file drop / share target | same `IntakeRunner` | same loss | same fix |
| A4 editor → `Key('rb-import')` | `LayoutEditorController.importImages` → `_say` | **nothing at all** — only cropped / recognised / not-detected counts | `_say` line 2 is `rejectedSummary` |
| A4 editor → `Key('rb-reprocess')` | `LayoutEditorController.reprocessImages` → `_say` | **nothing at all** | same summary from the reprocess report |
| review queue | `reviewReasonsFor` | unaffected | unaffected |

Two details of the existing surfaces shaped the fix. `_say` shows a `SnackBar`,
so a second call replaces the first — the refusal therefore had to be merged
into the *same* message, not added after it. And the banner renders
`warnings.take(3)` plus a `وتوجد N تنبيهات أخرى.` tail, so a busy batch could
drop the aggregate while still claiming to have shown everything; the headline
gets its own line of the summary instead, and `intakeSummaryText` is a pure
function so both are testable without a widget tree.

The categories the message names are the four the gates actually decide —
`frameArtifact`, `implausibleAspect`, `unusableCrop`, `candidateCap` — joined
with `، ` in `RegionRejection.values` order, each named **once** whatever the
count. A reason nobody decided is absent from the tally: `AutomaticLayoutReport`
asserts `rejectedByReason.values.fold(0, +) == rejectedRegions` at construction,
so the count and the breakdown can never tell the user two different stories.
Nothing was invented: no per-region list, no coordinates, no confidence the
pipeline did not compute, and no word implying text was read (there is no OCR
engine — see §K and RECOGNITION §6).

**R.2 The ration-proportion residual risk, re-measured.** Q.4's two numbers came
from different bases. One harness, one fixture construction (1200 × 1600 photo,
uniform desk, an ID card in the upper half, a 1000 × 181 region in the lower
half — 5.5249 as drawn against 287 / 52 = 5.5192 catalogued), preview 900 ×
1200, Otsu 114.4:

| basis | crisp shadow band | genuine printed ration card |
|---|---|---|
| work-frame box aspect — what the 8.0 bound reads | **5.6000** | **5.6250** |
| preview region aspect | **5.4785** | **5.4997** |
| derived crop aspect (158 × 866 / 158 × 869) | 5.4810 | 5.5000 |
| fill | **1.000** | **0.986** |
| frame border sides | 0 | 0 |
| area fraction | 0.0922 | 0.0913 |

Both are accepted, and the band is the *less* extreme of the two on every aspect
basis — so an aspect bound placed between them refuses the genuine card first,
which is why 8.0 stays where it is (1.46× above the catalogued extreme, 33 %
below the narrowest measured artifact). On fill the band is the *more* extreme
(1.000 vs 0.986), so a `fill >= .99 ⇒ artifact` rule separates them by 1.4 % and
loses blank paper, printed pages and washed-out or faded genuine cards, which
also measure fill 1.000. Population overlap is total on the remaining signals:
border sides 0 – 1 for both, crop short side 158 px for both. There is no
threshold in this data.

The measured cost of the shipped geometry-only gates is recorded too, because it
is real and it is not zero: two narrow cards laid edge to edge with **no** desk
between them form one connected component of aspect 11.25 (sides 0), which
`implausibleAspect` refuses, so that photo takes the single-document path and
yields one document instead of two. The same three documents with a visible gap
yield all three. The refusal is reported with its category, the original is
untouched, and either card can be cropped by hand from the library — which is
the conservative behaviour the constraint asked to preserve, not a silent loss.
`test/application/ration_proportion_test.dart` pins both directions plus a
positive control, and asserts the indistinguishability as equality of decisions
rather than as a threshold.

What that test measured when it first ran on CI is worth recording, because it
is a real observation rather than a prediction. For the shadow band and the
genuine card the pipeline produced, in both cases: 2 documents, 2 items, 0
refused regions, every record in the review queue, and the narrow one classified
`rationCard` with a catalog-confirmed size of aspect 5.52. The two runs differed
in exactly one respect — which way round the confirmed 287 mm card was placed
(287 × 52 for one fixture, 52 × 287 for the other), although their crops differ
by 3 px. That is a placement outcome, not a recognition decision, and the
recognition claim above is unaffected; but it is a genuine sensitivity of the
placement path to sub-millimetre crop differences at the extreme card length
(287 mm fits A4 only with margins of at most 5 mm, so rotation there is a
knife-edge), it predates this work, and it is not addressed here because
consuming an orientation estimate is forbidden while every branch of
`DetectionAnalysis.orientation` reports `confident: false`.

**R.3 There is no routing headroom to exploit (§H invariant).**
`const automationMode` is `AutomationMode.reviewAll`, and
`reviewReasons(record)` is non-empty for every record carrying a recognition
block unless the user resolved it (`مؤهل تلقائياً — بانتظار التأكيد`, `ثقة
متوسطة`, `ثقة منخفضة`, `بلا ثقة نهائية`, `حدود غير محسومة — يحتاج القص إلى
مراجعة`, `بانتظار تحديد المقاس`). A genuine ration card and the shadow band
therefore already enter the same review queue for the same stated reason,
through `review_screen.dart` via `reviewReasonsFor`. Routing is what *bounds*
the residual risk in R.2; it cannot also be tuned to reduce it. Suppressing
review for narrow regions would be the only lever left, and it moves risk the
wrong way.

**R.4 Provenance verified across every rewrite path (ADR-003, §H invariant).**
The four places that build a replacement `ImageAsset` were audited —
`ProjectService.replaceImage`, `LocalProjectRecovery.rebuildDerived`,
`LocalProjectBackups.create` / `restore`, and the derived-asset creation in
`_applyMultiDocument` / `_appendNewDocument`. All four already carried
`derivedFrom`, so **no production code changed**: no regression was reproduced,
and the constraint for this task was to change code only on a concrete
regression or an unhandled path. What was missing was tests, and
`test/application/provenance_rewrite_paths_test.dart` now covers the paths
`derived_provenance_test.dart` did not: replacement keeps `derivedFrom` while
the paths really move (`transforms.last` starts `replaced:`); `rebuildDerived`
revises **every** asset and keeps it for each, with the source never becoming
derived and asset ids stable; backup → restore keeps it under a new project id
with the same asset ids, because the relationship is id-based and only paths are
remapped; and — the classification consequence — an asset whose recorded origin
still exists but whose document record never got committed is **not**
re-analysed as a source (`_sourceAssetIds` excludes it), while an ambiguous
record-less asset with no `derivedFrom` stays a source and
`reconcileDerivedProvenance` reports no change rather than guessing.

**R.5 Still not verified.** No physical-device testing was done; no real Iraqi
document photograph took part in any measurement; no OCR engine ships; the
residual risk in R.2 is established on synthetic fixtures and is bounded by
mandatory review and immutable originals, not eliminated.

---

*End of Phase 0 audit. Implementation begins only after Gate 0 owner approval;
the next gate (Gate 1) governs the domain/schema design and the v5 migration.*
