# Unknown Document Size & A4 Placement — Root-Cause Audit

> **تحديث الحالة 2026-11-04:** الأقسام أدناه سجل تاريخي لتدقيق بدأ في 2026-11-02 على الفرع `arena/9c08ad5c-scan-id`. كانت عبارة «PR #39 مفتوح» صحيحة وقت ذلك التدقيق فقط؛ تحققت الحالة لاحقاً في GitHub وهي **MERGED منذ 2026-11-03**. لا تحاول إعادة فتحه أو تغيير حالته. هذا التقرير التاريخي لا يصف الفرع الحالي `arena/4ffb2204-scan-id` ولا نتائج بواباته. متابعة السبب الجذري ومسارات القياس اليدوي وOCR الصناعي وA4 في [`تقرير تكامل 2026-11-04`](OCR_CLASSIFICATION_A4_INTEGRATION_2026-11-04.md)؛ لم يُشغّل محرك OCR إنتاجي، ولا تُنسب نتائج CI من SHA سابق إلى التغييرات الحالية.

---

Historical audit date: 2026-11-02 (Asia/Baghdad)
Historical branch: `arena/9c08ad5c-scan-id` (PR #39 was OPEN at the time)
Audit phase mode: read-only. The implementation batch that followed is recorded in §13; this line does not describe it. No commit, push, merge, close, or force push was performed during that read-only phase.

## 0. Summary (العربية)

- **السؤال:** لماذا لا تدخل المستمسكات ذات الحدود الأربعة المكتشفة إلى ورقة A4 أحياناً عندما يكون النوع غير معروف، أو المقاس غير مؤكد، أو المستمسك خارج الترتيب التلقائي؟
- **الخلاصة:** السبب الرئيسي في هذا البناء **تصميمي** (مقصود في الكود)، وليس خللاً هندسياً: العنصر يبقى خارج الورقة حتى يؤكد المستخدم **المقاس**، والنوع غير المعروف يمنع التأكيد. "المقاس غير المؤكد" **ليس** دليلاً على أن الحدود غير صالحة هندسياً.
- **هل يفسّر التقرير فشل A4 المبلَّغ عنه؟** **جزئياً فقط.** يفسّر الآلية التي تمنع الوضع التلقائي بدليل كود مباشر. لا يستطيع التقرير إثبات أن هذه الآلية هي سبب الصورتين المحددتين، لأنني لم أتمكن من رؤية الصورتين في هذه الجلسة، ولا توجد ملفات صور لهما في مساحة العمل، ولا يمكن تشغيل Dart/Flutter محلياً.
- **اكتشافان جديدان مهمان:**
  1. **تحيّز نسبة الأبعاد للمنظور المائل** (CONFIRMED في الهندسة الاصطناعية): المقدِّر المستخدم في `assessQuad` و`CropDraft.toRecipe` يعطي خطأ يصل إلى نحو 13% عند ميل 30° وحدها. في هذا البناء يظهر أثره مباشرةً في القص الحر (بدون قفل نسبة، أي عندما يكون النوع غير معروف). بوابة الكتالوج `catalogShapeMatches` لا يستدعيها أي كود إنتاجي حالياً، ولا يكشف `geometryConfidence` هذا الخطأ.
  2. **مسارا تأكيد للمقاس يتجاوزان اعتماد القص**: تغيير النوع أو المقاس من الشريط يضبط `sizeConfirmed = true` دون أي تحقق من القص أو الحدود (NEEDS PRODUCT DECISION).
  3. **تصحيحات Phase 6:** F-D صار NOT REPRODUCED + NEEDS PRODUCT DECISION لأن تعليق `CropScreen` يذكر النية صراحةً. F-K صُحِّح. F-M (بوابة بلا فحص للإطار الكامل) أُضيف كفجوة كامنة. لم أتمكن من رؤية أي صورة في هذه الجلسة، ولا توجد ملفات صور للصورتين في مساحة العمل.
- **حكم تدقيق PR #39 السابق يبقى NOT READY** (C1 و C2 من فئة Medium). هذا التقرير لا يغيّر ذلك الحكم.

---

## 1. Reference state and SHA verification

| Item | Verified value | Method | Status |
|---|---|---|---|
| Local `HEAD` | `cc4ab7a` (stale) | `git log -1` | Stale, not the PR head. Not reset (per instructions). |
| `origin/arena/9c08ad5c-scan-id` | `7647fdd` | `git rev-parse --short origin/...` | Verified |
| PR #39 head | `7647fdd` | prior verification | Verified; PR OPEN, not draft, `mergedAt` null |
| CI on `7647fdd` | push run `41467081513` and PR run `41467089128` green; Flutter `+897: All tests passed`; Android instrumentation `androidTests=4 failures=0` | `gh run list` filtered client-side | Verified as CI results |
| CI on `5ab017c` | red (`android`, "D9 UI: forced review blocks accept"), superseded by `7647fdd` | check-run annotations | Verified; not current |
| Working tree | Equals `7647fdd` | `diff -rq --exclude=.git` against `git archive 7647fdd` (450 files): no differences. `git ls-tree` check: no `7647fdd` file missing on disk. | Verified |
| Stale index note | `git diff --stat 7647fdd` reports 1312 deletions in 9 files. These are files that exist on disk but not in the stale index. They are not missing files. | `git diff`, `ls-tree` | Explained; index left as is |
| Screenshots named in the request | **Not in the workspace and not in the conversation.** Searched `/` and `/home/user` by name and mtime: none found. | `find` | **NOT REPRODUCED** (no input) |

**Consequence:** no finding below is a reproduction from the user's images. Every behavioural claim is a code-read or a synthetic/pure-geometry result, and says so.

**Runtime status:** Local Dart and Flutter are unavailable. No test result is claimed. Runtime proof is a CI plan in §10.

---

## 2. Reconstructed Unknown Size questions 1–11 (with answers)

The original wording of questions 1–11 is not preserved in my working context. The list below uses the 11 questions this audit scope implies. **Please confirm the mapping.**

| # | Question (reconstructed) | Answer | Evidence | Label |
|---|---|---|---|---|
| 1 | Does this build run catalog type/size recognition on imports? | No. `SmartRecognitionFlag` and `MultiDocumentSegmentationFlag` are both `false`. Import routes to `_arrangeLegacyImportedImages`. | `lib/application/smart_recognition_flag.dart:17`; `lib/application/multi_document_segmentation_flag.dart:8`; `project_service.dart` ~393–440 | CONFIRMED |
| 2 | What state does an imported image with four detected corners get? | `DocumentKind.unknown`, `recognitionConfidence` 0, `provisionalSize` (aspect only, 80 mm long edge, 150 mm cap, 8:1 floor), `sizeConfirmed` false, `pageIndex` null. Warning "لم يُتعرّف على نوع المستمسك". | `project_service.dart` ~800–835; `document_kind.dart` 404–420 | CONFIRMED |
| 3 | Do four detected corners make the item eligible for A4? | **No.** A quad is only a suggestion (`withSuggestedCrop`) unless an automatic authorization exists. Type and size are still unknown. | `project_service.dart` 757–765; §4 | CONFIRMED |
| 4 | Is "unknown size" a geometric invalidity? | **No.** The code says so: "Unknown size is reported independently and is not a paper overflow" (`project_service.dart` 150–158). Geometric validity (`assessQuad`, `verifyBoundary`) is separate. | `project_service.dart` 150–158 | NOT A BUG |
| 5 | Where is automatic placement excluded? | `autoLayoutStatus` returns `sizeUnconfirmed` before the fit check. `arrangeDocuments` moves only `sizeConfirmed && !locked` items. UI shows «مقاس غير مؤكد · خارج الترتيب التلقائي». | `arrangement.dart` ~47–60, 139–200; `sheet_view.dart:550` | CONFIRMED |
| 6 | How does the user make the item eligible? | Two routes: (a) `CropScreen` with `confirmForSheet` (manual boundary + kind or custom size), or (b) ribbon kind buttons / kind menu / size fields, which call `setKind` or `resize` directly. Route (b) does not check crop or boundary. | `layout_screen.dart` ~157–168, 522, 821, 874–885; `editor_controller.dart` 436–446, 549–554; `document_edits.dart` 30–50 | CONFIRMED (route b: NEEDS PRODUCT DECISION, see F-C) |
| 7 | Does the known-kind manual path check the measured aspect against the catalog? | Not in `validateManualBoundary`. The auto path does (`catalogShapeMatches`). The normal UI prevents mismatch through the draft aspect-ratio lock (`crop_screen.dart` ~634, 693–697), which kind selection sets. | `manual_boundary.dart` 98–275; `CropScreen` `_selectDocumentKind` | LIKELY (defence-in-depth gap; normal path not affected) |
| 8 | Does export distort the image? | No. `containedDocumentRect` letterboxes. On-screen views use `BoxFit.contain`. `export_plan.dart` 67 warns when the aspect differs by more than 1%. | `document_exporter.dart` ~222–250; `export_plan.dart` 62–70 | NOT A BUG |
| 9 | Does EXIF orientation swap the aspect and block placement? | No evidence. `prepare_image.dart` bakes EXIF on import, so stored dimensions are oriented. Editor decoding does not double-bake (`decodeForProcessing`). PNG `eXIf` is not parsed by `package:image` 4.5.4, so PNG orientation was not verified. | `local_asset_repository.dart` ~147–160; `prepare_image.dart` 55–66; package:image 4.5.4 source | NOT REPRODUCED |
| 10 | Does a manual re-crop update the item's printed size? | **No.** `applyManualCrop` writes a new asset revision and clears the suggestion, but does not change item `width`/`height`. If the new aspect differs from the item's catalog size, the export letterboxes and warns. | `project_service.dart` ~1064–1090; `crop_screen.dart` 398 (`initialAspect` is const `null`), 1047 | LIKELY (F-D; not reproduced; no test) |
| 11 | Does save and reload preserve `sizeConfirmed`? | Yes. It is serialized. On load, an unconfirmed item is forced off-sheet (`pageIndex` null). Schema v5 is unchanged. | `project.dart` ~655–672 | CONFIRMED |

---

## 3. Per-stage data-path trace

| Stage | File / function | Inputs | Outputs | Failure condition |
|---|---|---|---|---|
| S0 Import | `local_asset_repository.dart` `_import` (~147–160) → `prepare_image.dart` (55–66) | image bytes | `ImageAsset` with oriented `width`/`height`, transform `exif-orientation` | decode failure → exception |
| S1 Legacy arrange | `project_service.dart` `arrangeImportedImages` (~393–440) → `_arrangeLegacyImportedImages` (~745–850) | asset, `rawProposal?.corners` (~690–700) | item: unknown kind, provisional size, `sizeConfirmed` false, `pageIndex` null; suggestion persisted only when `assessment.acceptable` and source is detector or learnedModel (757–765) | no candidate → full frame, no notice (C3) |
| S2 Quad assessment | `quad_assessment.dart` `assessQuad` (~80–165) | 4 normalized corners, source size | `QuadAssessment` (rejected reasons, `aspect`, `geometryConfidence`, `areaFraction`) | rejections: `notConvex`, `tooSmall` (<2% area), `degenerateEdges` (<4 px or ratio >2.5), `implausibleAspect` (>12) |
| S3 Boundary gate | `boundary_decision.dart` `verifyBoundary` (~276–390) | assessment, detector evidence, catalog | `accepted` only if reason list empty; else `needsReview` or `rejected` | see §5 |
| S4 Automatic authorization | `AutomaticCropAuthorization` (only on `accepted`) | `accepted` decision | authorization, applied by `applyAuthorizedCrop` → `_applyCrop` (auto) | no authorization → suggestion only |
| S5 Manual crop | `crop_screen.dart`; `validateManualBoundary` (`manual_boundary.dart` 98–275); `requireValidManualBoundary` | 4 corners, source size, kind/custom size | validated recipe | invalid quad never reaches crop (protected rule) |
| S6 Type | `DocumentEdits.setKind` (`document_edits.dart` ~30–50), via `editor_controller.setKind` (436–446) and `rec.setKindWithOverride` (`recognition_overrides.dart` 53–) | kind | catalog size and `sizeConfirmed` true (known kinds); "other" keeps size; unknown → unconfirmed, unplaced | unknown kind → cannot confirm via manual validation |
| S7 Size | `project.catalog.sizeFor(kind, landscape: asset.width >= asset.height)`; custom size; `DocumentEdits.resize` (sets `sizeConfirmed` true) | kind or typed mm | item `width`/`height`, `sizeConfirmed` | no kind and no custom size → `requireConfirmedSize` rejects |
| S8 Recipe | `CropDraft.toRecipe` (`crop_draft.dart` 66–101) | normalized corners, source size | `ImageEditRecipe` with output estimated from averaged opposite edges | over-budget source → throws; output scaled by `min(1, sqrt(maxImportPixels/(w·h)))` (D7; unchanged) |
| S9 Apply | `applyAuthorizedCrop`/`_applyCrop` (auto; re-derives mm via cleaned asset); `applyManualCrop` (`project_service.dart` ~1064–1090; does **not** change item mm); `confirmManualBoundary` (sets kind, catalog size, `sizeConfirmed`) | recipe | new asset revision; `userAuthoredCrop` true | see F-D for stale mm |
| S10 Eligibility (sheet) | `PageLayout.checked` (`page_layout.dart` 60–82): `pageIndex` requires `sizeConfirmed`, within printable bounds; `packing.dart` 36–41, 74–80 | project | valid, or refused via `require(...)` | unconfirmed item on the page → refused |
| S11 Persistence | `DocumentItem.toJson`/`fromJson` (`project.dart` ~640–672) | item | saved `sizeConfirmed`; unconfirmed → off-sheet on load | none |
| S12 Export | `export_plan.dart` 18–26 (refuses unconfirmed items in pages); 62–70 (warns on >1% aspect mismatch); `document_exporter.dart` 222–250 (`containedDocumentRect`) | project | PDF/raster letterboxed | unconfirmed → refused |

---

## 4. Separation table

| Dimension | Decided by | Value in the reported case (4 corners, unknown type, unconfirmed size) | Blocks A4 placement? | Notes |
|---|---|---|---|---|
| **Boundary validity** (geometry) | `assessQuad`, `requireValidManualBoundary` | Can be valid (quad stored as suggestion when `acceptable`) | **No** | Unknown size is not invalid geometry. |
| **Crop approval** (automatic) | `verifyBoundary` → `AutomaticCropAuthorization` | Not granted (see §5) | **No, by itself**. Affects which aspect the item uses (full frame) | Crop is not a placement gate in `PageLayout.checked` (see F-C). |
| **Crop approval** (user) | `applyManualCrop`, `confirmManualBoundary` (`userAuthoredCrop`) | Not yet given | **No, by itself** | Same as above. |
| **Type recognition** | `DocumentKind` (`recognitionConfidence` 0) | `unknown` (recognition is disabled in this build) | Indirectly: no catalog size, so `sizeConfirmed` stays false | `setKind` can change it without a crop (F-C). |
| **Size recognition** | `provisionalSize` (aspect only) vs `sizeConfirmed` | Provisional, unconfirmed | **Yes** (`PageLayout`, `packing`, `export_plan`, `arrangement`) | This is the real gate. |
| **Recipe validity** | `CropDraft.toRecipe`, `withinImageBudget`, `CropGeometry` | Not evaluated for this item | **No** (only the crop operation) | D7 unchanged. |
| **Manual eligibility** | `validateManualBoundary` (`requireConfirmedSize`) | Requires kind or custom size | **Yes**, for the manual route | Ribbon route bypasses this (F-C). |
| **Automatic eligibility** | `autoLayoutStatus`, `arrangeDocuments` | `sizeUnconfirmed` | **Yes**, for auto-arrangement only | Manual placement still possible after confirmation. |

---

## 5. Boundary Gate and protected-contract review

### 5.1 `verifyBoundary` (read-only)

- Returns `accepted` only when the reason list is empty.
- Null corners → `needsReview`.
- Length ≠ 4 → `rejected` (`notABoundary`).
- Unacceptable `assessQuad` → `needsReview`.
- `forceReview` adds `forceReviewReason ?? multiSceneNotCorroborated`.
- The `detector` source always adds `uncalibratedClassicalScore`.
- The `learnedModel` source adds `lowModelConfidence` when below `minAutoAcceptConfidence`.
- Both models use `minAutoAcceptConfidence = 1.01`. Confidence cannot exceed 1.0, so **no automatic acceptance** is possible in this build.
- Only `accepted` creates `AutomaticCropAuthorization`.

**Implication (CONFIRMED by code):** in this build, every detected quad from the classical detector is `needsReview`, and no learned-model quad can reach `accepted`. So a detected four-corner quad never becomes an automatic crop. It remains a stored suggestion until the user acts. This is the main mechanism behind "four corners detected but not on A4" for this build.

### 5.2 Protected contracts (status after this audit)

| Protected item | Status | Touched by any finding? |
|---|---|---|
| DocQuadNet, DocAligner, cascade | unchanged | No |
| `minAutoAcceptConfidence: 1.01` | unchanged; **this is the mechanism in §5.1** | Explained only; any change needs explicit user approval |
| `modelDisagreement`, `uncalibratedClassicalScore` | unchanged | Explained only |
| DocAligner adapter, DocQuadNet SHA-256 | unchanged | No |
| `tool/check_detector_retirement.py` | unchanged | No |
| `Project.schemaVersion = 5` | unchanged; no saved fields added | No |
| `scan-id-local-annotations-v2` | unchanged | No |
| `suggestedPolygon` / `polygon` separation | unchanged | No |
| EXIF and `prepare_image.dart` | unchanged; no new evidence | No |
| App version, signing, identity | unchanged | No |

**Fix plans in §11 that touch these need explicit approval.** The aspect fix (P1) changes `assessQuad`, which feeds `aspectMismatch` in `verifyBoundary`, so it changes gate decisions and is a user-visible output change.

---

## 6. Findings register

Labels: CONFIRMED, LIKELY, NOT REPRODUCED, NOT A BUG, NEEDS PRODUCT DECISION.

| ID | Title | Label | Summary |
|---|---|---|---|
| **F-A** | Four detected corners do not reach A4 by design in this build | **CONFIRMED** (mechanism); **NEEDS PRODUCT DECISION** (whether intended) | §5.1 gate + §4 size gate. Explains the reported pattern as a design gate, not a crash. |
| **F-B** | Unknown type and unconfirmed size treated as "not on sheet" | **NOT A BUG** | Documented in code; not a geometric failure. |
| **F-C** | Kind and size confirmation bypass crop approval | **CONFIRMED** (code path); **NEEDS PRODUCT DECISION** (intended?) | Ribbon kind buttons (`layout_screen.dart` 522, 822) → `editor_controller.setKind` (436–) → `DocumentEdits.setKind` (`document_edits.dart` ~30–55) sets the catalog size and `sizeConfirmed` true with no crop or boundary check. Size fields (874–885) and drag resize (`endDrag`) → `DocumentEdits.resize` (~60–) do the same. Also reachable: revert (`manual_boundary.dart` ~536–570) and crop-save adoption (`editor_controller.dart` 855–885). `DocumentItem` stores no size source and no link to crop approval. §11A.6–§11A.7. |
| **F-D** | Re-crop of a confirmed item does not update its printed size | **NOT REPRODUCED** (mechanism CONFIRMED by code); **NEEDS PRODUCT DECISION** | `applyManualCrop` (`project_service.dart` ~1064–1090) writes a new asset revision and does not change item mm. The design intent is written down: `crop_screen.dart` 396–398 states that a category size is not permission to reshape pixels, so `initialAspect` is `null` on purpose. The result is that an item's box and its saved crop can differ in aspect. Export then letterboxes (`containedDocumentRect`) and warns without blocking (`export_plan.dart` 45–76). No test asserts item mm after re-crop (`stage1_a4_workflow_test.dart` ~1186–1230 checks asset pixels). §11A.8. |
| **F-E** | Aspect estimator is biased under single-axis perspective tilt | **CONFIRMED** (formula and synthetic geometry); **NOT REPRODUCED** on user images | §7. Live path in this build: the `CropDraft.toRecipe` output aspect when `aspectRatio` is null (free crop, unknown kind). The printed content is then stretched by the bias relative to the card, and contain-fit letterboxes it. With a ratio lock, the output aspect is the lock and the estimator does not set it. `BoundaryDecision.catalogShapeMatches` (`boundary_decision.dart` 244–256) has no production caller. The only similar check is inactive (`smart_recognition.dart` 1791–1800; flag off). `aspectMismatch` (2.5×, `boundary_decision.dart` 346) is not reached at biases up to about 28%. §11A.9. |
| **F-F** | C1, C2, C3 (and aliases F1, F2, F3) from the PR #39 audit | **CONFIRMED** (code-read, unexecuted) | §8. C1 = old F3; C2 = old F1; C3 = old F2. |
| **F-G** | Smart recognition and multi-document segmentation | **NOT REPRODUCED** | Both flags are off; the code was not exercised. |
| **F-H** | EXIF orientation, PNG `eXIf` | **NOT REPRODUCED** | No evidence. Import bakes EXIF for JPEG. PNG not verified. |
| **F-I** | Orientation consistency in `confirmManualBoundary` | **NOT A BUG** | `warpPerspective` applies `quarterTurns` after the warp (`imaging/perspective.dart` ~177–179). Stored revision dimensions are therefore physical. `updated.width >= updated.height` matches the validated turned recipe. Not executed. |
| **F-J** | Known-kind manual path lacks a measured-aspect check | **LIKELY** (defence-in-depth gap) | See Unknown Size Q7. Normal UI is protected by the draft aspect-ratio lock (`crop_screen.dart` ~634, 693–697), which kind selection sets. |
| **F-K** | Whole-frame auto-crop path | **NOT A BUG** (production) | Production `LocalImageEditor.suggest` (`local_image_editor.dart` 149–150) returns `suggestProposal(...)?.corners`. That is either classical corners (`detectDocumentCornersScored`, `document_detector.dart` 61; null on failure) or the learned proposal. It never returns the full frame. `wholeFrameDetector` appears only in test doubles (`boundary_gate_test.dart` 263 uses `_FixedSuggest`). See F-M. |
| **F-L** | D7 16 MP limit and silent downscale | **NOT A BUG** (policy unchanged) | §9. Refusal message is accurate for the refusal branch only. |
| **F-M** | Gate has no geometric whole-frame check | **NOT A BUG** (production); latent hardening gap | `verifyBoundary` decides only from producer flags and `assessQuad`. A full-frame quad passes `assessQuad` (synthetic mirror: acceptable, geometryConfidence 1.0, aspect 1.333 on 3000×4000). With producer `wholeFrameDetector`, no `forceReview`, and no `touchesFrameEdge`, the gate would accept it. Production cannot reach this path (F-K). `boundary_gate_test.dart` 263 pins the accept outcome of a valid quad on this test-double path. Hardening is P3-8 and needs approval, because it touches the gate. |

---

## 7. F-E: aspect estimator under perspective (synthetic, pure geometry)

**Code under test (same formula in two places):**
- `assessQuad` (`quad_assessment.dart` ~133–163): `width = (top+bottom)/2`, `height = (left+right)/2`, `aspect = max/min`.
- `CropDraft.toRecipe` (`crop_draft.dart` 66–101): output width and height from averaged pixel edge lengths, using `(size−1)` scaling.

**Method (not in the repo; `/tmp/audit_sim/aspect_sim.py`):**
- Planar card 85.6 × 54 mm (true aspect 1.585), projected through a pinhole camera `K = [[f,0,W/2],[0,f,H/2],[0,0,1]]` with rotation `Rx(tilt)·Ry(yaw)`, image 3000 × 4000 px, f = 3500 px, distance chosen so the card spans about 59% of width (170 mm).
- The estimator is replicated exactly as in code. Corners are normalized to `[0,1]`.
- Noise: uniform ±3 px per corner, 300 trials.

**Results (aspect error vs true 1.585):**

| Tilt (x) | Yaw (y) | Exact corners | ±3 px noise (mean / max) | Corner-angle max deviation | `angleScore` (`geometryConfidence` part) |
|---|---|---|---|---|---|
| 0° | 0° | +0.04% | 0.15% / 0.55% | 0° | 1.00 |
| 10° | 0° | +1.36% | 1.35% / 1.80% | 2.5° | 0.95 |
| 20° | 0° | +5.62% | 5.61% / 6.10% | 5.0° | 0.89 |
| 30° | 0° | **+13.11%** | 13.09% / 13.67% | 7.6° | 0.83 |
| 40° | 0° | **+24.71%** | 24.70% / 25.41% | 10.6° | 0.77 |
| 20° | 20° | +0.89% | 0.88% / 1.33% | — | — |
| 30° | 30° | +5.58% | 5.56% / 6.05% | 28.4° | 0.37 |

**Sensitivity to focal length (pure tilt):** f = 2000 px gives +4.7% at 20° and +10.8% at 30°; f = 6000 px gives +6.0% and +14.2%. The bias persists across focal lengths.

**Reading the result:**
- Corner noise of ±3 px contributes at most about 1.3% on average. The **systematic tilt bias dominates**.
- `geometryConfidence` stays high (`angleScore` 0.83 at 30° pure tilt). It does not reflect the aspect error.
- Under a 30° pure tilt the rectified output is about 13% too wide relative to the card. The warp then stretches the card content horizontally, and the item's catalog size letterboxes it. This applies only when no ratio lock is set (`CropDraft.toRecipe` 80–90); see §11A.9.
- `verifyBoundary`'s `aspectMismatch` also uses this estimator, but its 2.5× bound (`boundary_decision.dart` 69, 343–347) is not reached at these errors.

**Limits (stated plainly):** synthetic pinhole model only. No real photo was measured. The user's images are not available. The result is **CONFIRMED for the estimator under this geometry**; the **user-visible impact on real images is NOT REPRODUCED**. Any fix needs a derivation (for example a planar-homography aspect with a focal prior) and user approval, because it changes recipe output (see §11, P1).

**Existing coverage:** no test in the grep scope asserts aspect accuracy under tilt. The tilted-quad tests in `full_resolution_manual_crop_test.dart` (260–267, 581–595) check remapping and corner preservation, not aspect.

---

## 8. C1, C2, C3, F1, F2 — audit and State Transition Table

Labels in the PR #39 audit: C1 = F3 (Medium), C2 = F1 (Medium), C3 = F2 (decision item). **F1 and F2 in this report are aliases of C2 and C3.**

Flags: `MR` = `_manualRequired`; base = full-frame base image.

| From state | Event | Code point | To state | Preview enabled | Accept enabled | Label |
|---|---|---|---|---|---|---|
| **A** Fallback (MR true, full frame) | Auto-detect fails and manual fallback opens | `_enterManualFallback` (~940) sets MR true, only when the draft is the full frame; `_load` (358) resets MR to false first | A | No | No | expected |
| A | Four manual taps (`_addManualTap` ~1438) | `_addManualTap` clears MR | B (MR false, valid quad) | Yes | Yes | expected |
| B | **Undo** to full-frame base (722–735) | `_undo` restores base with MR **false** | **C1 state**: full frame, controls enabled | **Yes** | **Yes** | **CONFIRMED (C1, Medium)** |
| A | **Successful Suggest** (`_suggest`, result applied) | `_suggest` does not clear MR | **C2 state**: valid quad, MR still true | **No** | **No** | **CONFIRMED (C2, Medium)** |
| A | Import with no detection (`project_service.dart` 708–712, 760, 796) | `_load` finds no candidate, opens full frame; MR false, no notice | **C3 state**: full frame, controls enabled, no notice | Yes | Yes | **NEEDS PRODUCT DECISION (C3)** |
| B | Move a corner (`_moveCorner` ~1468) | clears MR | B | Yes | Yes | expected |
| any | `_commitState`, `_undo`, or `_clearPreview` | clears preview; sets dirty; bumps `_draftRevision` | — | per state | per state | expected |

**Code-read notes:**
- `_manualRequired` is cleared only in `_addManualTap` (~1438), `_moveCorner` (~1468), and `_load` (358).
- `_suggest` discards its result if `identical(_state, startState)` is false.
- `_accept` requires `!_manualRequired && _hasCurrentPreview`.
- No test covers C1, C2, or C3. `crop_lifecycle_test.dart` does not contain these scenarios. Its `_DelayedEditor.blockPreview` is declared but never set in that file.

---

## 9. D7 re-check (no change; no silent-downscale change)

| Path | Quantity checked | Behaviour | Test |
|---|---|---|---|
| `CropDraft.toRecipe` (`crop_draft.dart` 66–101) | source `withinImageBudget`, then output scale `min(1, sqrt(maxImportPixels/(w·h)))` | throws over budget; **silently scales** output when estimated output is too large | `full_resolution_budget_test.dart` 133–150 (8000×2000 skewed quad: scale 0.8751, output 3808×4200, area 15,993,600) |
| `CropGeometry` (`geometry.dart` ~385–410) | output area | refuses over-budget output | line 159 |
| `requireFullResolutionCropFits` (`full_resolution_manual_crop.dart` ~95–105) | bounding-box span | refuses above 16 MP, **no** downscale | lines 59–73 (4800 px diamond refused) |
| `open` | long edge | capped at 1200 px (working copy) | — |

- The two budget paths act on **different quantities** (bounding-box span vs estimated output area). No test asserts a shared outcome.
- The `CropScreen` refusal message is accurate only for the refusal branch. The success branch can still scale silently through `toRecipe`. Do not present the message as a global guarantee.
- **D7 is not changed by this audit.** Any user-visible D7 change needs explicit user approval.

---

## 10. Test inventory, gap list, and CI plan

### 10.1 Relevant existing tests (as found; not executed locally)

| File | Covers |
|---|---|
| `test/application/boundary_gate_test.dart` | gate decisions (existing) |
| `test/application/crop_lifecycle_test.dart` | crop lifecycle; **not** C1, C2, C3 |
| `test/application/full_resolution_manual_crop_test.dart` | full-res manual crop; tilted-quad remap (260–267, 581–595); asset px after crop |
| `test/application/document_export_pipeline_test.dart` | export pipeline; re-crop (99, 185); `setKind` use |
| `test/application/stage1_a4_workflow_test.dart` | A4 workflow; re-crop asset px (1186–1230) |
| `test/application/project_service_test.dart`, `image_edit_test.dart` | import and crop |
| `test/application/smart_recognition_test.dart` | smart path (flag off in build) |
| `test/application/manual_intake_integration_test.dart` | manual intake; C-related states |
| `test/application/recognition_pipeline_test.dart` | pipeline |
| `test/application/automatic_layout_test.dart`, `false_positive_document_test.dart` | `sizeUnconfirmed` and arrangement |
| `test/domain/arrangement_test.dart`, `recognition_routing_test.dart`, `recognition_test.dart` | arrangement and routing |
| `test/domain/document_edits_test.dart`, `recognition_overrides_test.dart` | `setKind`, `resize`; **no** crop precondition test |
| `test/domain/manual_quad_selection_test.dart` | 20° tilt keeps TL/TR (60–) — orientation, not aspect |
| `test/domain/nearest_corner_test.dart`, `quad_set_validity_test.dart` | corner selection and validity |
| `test/imaging/full_resolution_budget_test.dart` | D7 (59–159) |
| `test/presentation/off_sheet_tray_test.dart`, `unresolved_candidate_badge_test.dart` | off-sheet UI |
| `test/presentation/editor_ribbon_test.dart` | ribbon, `setKind` (route b) |
| `test/presentation/crop_corner_hit_layer_test.dart` | hit layer |
| `test/persistence/schema_v5_migration_test.dart` | schema v5 |

### 10.2 Gap list

| Gap | Covers finding | Status |
|---|---|---|
| G1: no test for C1 (undo to full frame re-enables controls) | C1 | missing |
| G2: no test for C2 (successful Suggest after fallback leaves controls disabled) | C2 | missing |
| G3: no test for C3 (import with no detection: notice and controls) | C3 | missing (decision pending) |
| G4: no test that `setKind`/`resize` refuses an uncropped asset | F-C | missing (policy pending) |
| G5: no test that item mm is unchanged or re-derived after `applyManualCrop` | F-D | missing |
| G6: no test that aspect error under tilt is bounded | F-E | missing; needs derivation |
| G7: no unit test for `verifyBoundary` `forceReview` on a valid quad | L7 (PR #39) | missing |
| G8: `_DelayedEditor.blockPreview` declared but unused in `crop_lifecycle_test.dart` | L6 (PR #39) | dead code |
| G9: leave-and-return flow | L3 (PR #39) | missing |
| G10: DPR ≠ 1 for T04 | L5 (PR #39) | missing |

### 10.3 CI plan (runtime proof — not executed locally)

Any fix in §11 must be proven only by CI on its final SHA:
1. `dart format --output=none --set-exit-if-changed` (format gate; check annotation title `format`).
2. `python3 tool/check_source.py` (source audit).
3. `flutter analyze`.
4. `flutter test` with the new targeted test files for the fix (named per §11), plus full suite.
5. Build jobs (Android, Windows, and the others already in the workflow).
6. Re-run until green on the same SHA. A green earlier SHA is not proof.

---

## 11. Prioritised fix plan (P0–P3)

Each fix is **independent and unexecuted**. Each names the file, function, failing condition, current behaviour, correct behaviour, required test, and risk.

Priority meaning: P0 = evidence and decisions needed before any code; P1 = correctness, needs approval; P2 = behaviour change, needs decision; P3 = test or latent hygiene.

### P0 — Evidence and decisions (no code)

| ID | Item | Needed from |
|---|---|---|
| P0-1 | Provide the two screenshots (or equivalent synthetic repro). Without them, F-A is a mechanism, not a reproduction. | User |
| P0-2 | Confirm the reconstructed Unknown Size question list (§2). | User |
| P0-3 | Decide whether four detected corners should place without user confirmation (F-A). This touches protected `minAutoAcceptConfidence` and the classical-source reason. **Not changed here.** | User (protected) |
| P0-4 | Decide C3 (import without detection: full frame with controls enabled). | User (decision item) |
| P0-5 | Decide whether ribbon kind and size confirmation should require a crop (F-C). | User |

### P1 — Correctness (requires explicit approval)

| ID | File / function | Failing condition | Current behaviour | Correct behaviour | Required test | Risk |
|---|---|---|---|---|---|---|
| **P1-1** (F-E; re-classified in §11A.9 as decision-gated: derivation first) | `quad_assessment.dart` `assessQuad` (~133–163) and `crop_draft.dart` `toRecipe` (66–101) | tilt about one axis (≥10°) | aspect from averaged opposite edges; error +1.4% at 10°, +13% at 30° (synthetic) | aspect from a planar homography with a derived focal prior; error bounded by a stated derivation | synthetic tilt suite with known card aspect; expected bound derived in the test comment; **no tolerance widened without derivation** | changes gate decisions (`aspectMismatch`) and recipe output (user-visible). Needs approval. Keep 16 MP and D7 unchanged. Do not change P1 weight (1.15). |
| **P1-2** (C2 = F1, PR #39 Medium) | `crop_screen.dart` `_suggest` success path | successful Suggest after fallback | MR stays true; Preview and Accept disabled with a valid quad | clear MR when a current valid quad is applied | new widget test G2; existing lifecycle tests unchanged | low; UI state only. Required before PR #39 READY. |
| **P1-3** (C1 = F3, PR #39 Medium) | `crop_screen.dart` `_undo` (722–735) | undo to full-frame base | MR false; Preview and Accept enabled for the full frame | restore MR to the value at the base (true for fallback) | new widget test G1 | low; UI state only. Required before PR #39 READY. |

### P2 — Behaviour change (decision needed)

| ID | File / function | Failing condition | Current behaviour | Correct behaviour | Required test | Risk |
|---|---|---|---|---|---|---|
| **P2-1** (F-C) | `editor_controller.dart` `setKind` (436–446); `layout_screen.dart` 522, 821; `document_edits.dart` `setKind`/`resize` | category or size set on an uncropped asset | `sizeConfirmed` true; uncropped full frame placed at catalog size | either require a valid crop for placement, or keep and document the route | new domain test G4 (policy decided first) | user-visible; blocks an existing workflow. Approval needed. |
| **P2-2** (F-D) | `project_service.dart` `applyManualCrop` (~1064–1090); `crop_screen.dart` (398, 1047) | re-crop of a confirmed item with a different aspect | item mm unchanged; export letterboxes | re-derive catalog size or require re-confirmation | new application test G5 | user-visible: printed size may change. Approval needed. |
| **P2-3** (C3) | `project_service.dart` ~708–712, 760, 796; `crop_screen.dart` `_load` (358) | import with no detection | full frame with controls enabled, no notice | notice and MR true (manual required) | new test G3 | depends on P0-4 decision. |
| **P2-4** (F-C, adoption) | `editor_controller.dart` `adoptCrop` `staleIds` condition (855–885); `DocumentEdits.setKind` | a crop saved on an asset whose confirmed, off-sheet natural item has a typed (resized) size | `setKind` re-applies the catalog size silently; the typed size is lost with no notice | keep the typed size, or notify; re-derive only when the kind changes (decision) | new test: typed size survives crop adoption; expectation changes only after the decision, documented as spec-driven | user-visible silent data change; needs decision and approval |

### P3 — Tests and latent hygiene (no user-visible change)

| ID | File / function | Failing condition | Current | Correct | Required test | Risk |
|---|---|---|---|---|---|---|
| P3-1 (L1) | `canonicalQuadCorners` | non-finite input | throws | reject with a typed result (latent; `Point2` rejects non-finite at construction, so unreachable through `unorderedQuadIssue`) | unit test with a constructed non-finite input | low |
| P3-2 (L2) | `geometry.dart` duplicate-point handling | duplicate corners | `notConvex` (proven) | add an explicit test | domain test | none |
| P3-3 (L3, G9) | leave-and-return flow | leave and return | untested | add test | widget test | low |
| P3-4 (L5, G10) | T04 hit tolerance | DPR ≠ 1 | tested at DPR 1 only | add DPR 2 and 3 cases; **do not change `_pxTol`** without derivation | widget test | low |
| P3-5 (L6, G8) | `crop_lifecycle_test.dart` `_DelayedEditor.blockPreview` | unused | dead field | remove or use it | none | none |
| P3-6 (L7, G7) | `boundary_decision.dart` `verifyBoundary` `forceReview` on valid quad | forceReview with valid quad | covered indirectly | direct unit test | domain test | none |
| P3-7 | `CropScreen` refusal message | success branch can scale silently via `toRecipe` | message applies to refusal only | clarify message text or add a doc note; no D7 change | none beyond existing D7 tests | user-visible text: needs approval if shown to users |
| P3-8 (F-M) | `boundary_decision.dart` `verifyBoundary` (276–400) | full-frame quad from a producer with no review reason | accepted (test-double path only) | a geometric whole-frame check or a producer rule, decided by the user | domain test: full-frame quad with `wholeFrameDetector` is not accepted | protected gate: needs approval; latent in production |

---

## 11A. Phase 6 validation (second pass, read-only)

### 11A.1 Reference re-verified

- Remote branch and PR #39 head: `7647fdd`. PR #39 is OPEN, not a draft, `mergeStateStatus` CLEAN, `mergedAt` null.
- Local `HEAD` is `cc4ab7a` (stale). The working tree matches `7647fdd`: `git archive 7647fdd` compared with the working tree (excluding `.git` and `docs/`) shows no differences. `git status` lists entries from the stale index. They were not reconciled and nothing was reset.
- CI on `7647fdd`: push run `41467081513` and PR run `41467089128`, both success (client-side filter on `gh run list --json`). These results cover that SHA only. No local Dart or Flutter run was made.

### 11A.2 Screenshot status

- The request refers to two screenshots. **I could not view any image in this session.** I searched `/tmp`, `/home`, `/mnt`, `/data`, `/workspace`, `/srv`, and `/root` for image files. The only hits were repository design assets under `design/` and a diff/patch pair in `/tmp/arena-workspace` (not images).
- No finding in this report uses screenshot evidence. A reproduction needs the source image or a synthetic equivalent (P0-1). Nothing is claimed about the content of the screenshots.

### 11A.3 Corrections to the earlier text

| Item | Earlier text | Corrected text | Basis |
|---|---|---|---|
| F-K | Production supplies corners only from `rawProposal?.corners` | `LocalImageEditor.suggest` returns `suggestProposal(...)?.corners`, which can be classical corners. It never returns a full frame. | `local_image_editor.dart` 98–150; `document_detector.dart` 61 |
| F-D | LIKELY | NOT REPRODUCED + NEEDS PRODUCT DECISION. The `initialAspect = null` choice is documented intent. | `crop_screen.dart` 396–398 |
| F-E, catalog gate | Can block automatic catalog confirmation | No production caller. The only similar check is in the inactive smart path. | `grep catalogShapeMatches lib` |
| F-E, live impact | Stated generally | Live only for free crops (no ratio lock). With a lock, the output aspect is the lock. | `crop_draft.dart` 80–90 |
| F-E, `aspectMismatch` | Same bias applies | The 2.5× bound is not reached at these errors. | `boundary_decision.dart` 69, 343–347 |
| Export example | (none) | Synthetic contain-fit arithmetic, no image: a 3:4 photo in an 85.6×54 mm box uses 47% of the box width; an A4-ratio image uses 89%. | Arithmetic only |

### 11A.4 Gate validation by path (F-A)

Four detected corners are **review-only** in every production path of this build. Both learned models use `minAutoAcceptConfidence: 1.01`, and the classical detector always adds `uncalibratedClassicalScore`. These are protected and unchanged.

| Path | Producer / editor | Gate result | Reasons | Stored as suggestion | Reaches crop draft | Auto-authorised | Label |
|---|---|---|---|---|---|---|---|
| DocQuadNet valid | learnedModel, `docquad_model.dart` ~127–134 | needsReview | `lowModelConfidence` | yes (usable geometry) | yes | no | CONFIRMED |
| DocAligner valid | learnedModel, `docaligner_model.dart` ~139–146 | needsReview | `lowModelConfidence` | yes | yes | no | CONFIRMED |
| Cascade disagreement | `boundary_proposal_cascade.dart` 30–110 | needsReview | `forceReview` + `modelDisagreement` | yes if usable | yes | no | CONFIRMED |
| Cascade, only primary valid | cascade returns null | falls back to classical | none | depends on fallback | depends on fallback | no | CONFIRMED (code) |
| Classical valid | detector, `local_image_editor.dart` 90–140 | needsReview | `uncalibratedClassicalScore` | yes | yes | no | CONFIRMED |
| Classical invalid geometry | detector | needsReview | `geometryRejected` | no (no usable geometry) | no | no | CONFIRMED. Naming note: `needsReview` is shared with valid-but-unaccepted quads. The kind alone does not separate them; `hasUsableGeometry` does. NOT A BUG. |
| Corner count not 4 | any | rejected | `notABoundary` | no | no | no | CONFIRMED |
| No detection | `detectDocumentCornersScored` returns null | notDetected | none | no | full frame, MR false (C3) | no | NEEDS PRODUCT DECISION (C3) |
| Saved suggestion invalid at open | `_usableSuggestedCorners` (`crop_screen.dart` 154–) runs `assessQuad` | rejected from draft | n/a | stored only if acceptable (`project_service.dart` 757–765) | no | no | CONFIRMED |
| Manual approval of a valid classical proposal | `applyManualCrop` (`project_service.dart` ~1064) | validated by `requireValidManualBoundary` | n/a | n/a | yes, crop persisted; suggestion cleared | n/a (user-authored) | CONFIRMED (code). No line-by-line assertion traced for this exact flow. |
| Whole-frame quad via test double | `wholeFrameDetector` in a test editor | accepted | none | n/a | yes | yes | NOT A BUG (production); F-M |

**Answer.** A valid detected quad is not a boundary-validity failure. The rows for valid detections (DocQuadNet, DocAligner, classical) are needsReview by design. The only geometric rejection among the four-corner cases is the invalid-geometry row.

### 11A.5 Separation check

The separation table in §4 still holds. Phase 6 adds no change to it.

### 11A.6 F-C caller trace and the five permission questions

| Path | Entry point | Guard before setting `sizeConfirmed` | Effect | Label |
|---|---|---|---|---|
| Ribbon kind | `layout_screen.dart` 522 / 822 → `editor_controller.setKind` (436–) → `DocumentEdits.setKind` | none for crop or boundary | catalog size; `sizeConfirmed` true | CONFIRMED |
| Size fields, drag resize | `layout_screen.dart` 874–885; `resizeActive` 549; `endDrag` 1107–1170 → `DocumentEdits.resize` | none | typed size; `sizeConfirmed` true | CONFIRMED (documented as deliberate in `document_edits.dart`) |
| Review confirm | `recognition_overrides.confirmRecognition` 83–121 → `setKind` | `sideHasUnresolvedBoundary` (`recognition_routing.dart` 185) | catalog size; `sizeConfirmed` true | CONFIRMED (guarded) |
| Revert, same asset, resolved, natural kind | `manual_boundary.revertManualCropOnProject` ~536–570 | boundary-resolved check only | `setKind` on unlocked, natural, resolved items. If one was unconfirmed, it becomes confirmed. | CONFIRMED (code); reachability LIKELY, low |
| Revert, same asset, unresolved | same function, `if` branch | n/a | kind reset to linked recognition kind (or unknown); size provisional; `sizeConfirmed` false | CONFIRMED |
| Crop-save adoption | `editor_controller.adoptCrop` 855–885 | none | for natural items on the asset: `setKind` when orientation mismatches (any `sizeConfirmed`), or when confirmed and off-sheet. The second case re-applies the catalog size. | CONFIRMED (code) |
| Ribbon re-click after revert | same as the ribbon row | none | `setKind` again → `sizeConfirmed` true. The ribbon button is not disabled when selected (code read, not run). | CONFIRMED (code) |

Trigger for `editor_controller.dart` 873 (open item from the earlier pass): it is the `staleIds` loop in `adoptCrop` (855–885), as in the last row.

**Answers to the permission questions:**

1. *Known kind on an uncropped full-frame image?* **Yes**, through the ribbon row. CONFIRMED.
2. *Known kind on an unapproved suggestion?* **Yes.** A suggestion is not a crop; `asset.crop` stays null. Same as question 1. CONFIRMED.
3. *Known kind on invalid geometry?* **Not reachable as a stored crop.** Crops are validated before save. This path never reads geometry. NOT A BUG for stored crops.
4. *Size confirmed without a physical basis?* **Yes.** For natural kinds the basis is the catalog size of the document type, which is not checked against the content. For a typed size, the basis is the user's assertion. CONFIRMED.
5. *Export or packing of content that does not fit its box?* **Yes.** Export letterboxes and warns, without blocking (`export_plan.dart` 45–76). CONFIRMED.

**Data-model fact.** `DocumentItem` has a bare `sizeConfirmed` flag, with no size-source field and no link to crop approval. Nothing in the model can tell why an item is confirmed.

**Most user-visible adoption effect.** A natural-kind item on an off-sheet page, resized to a typed size, is reset to the catalog size the next time its asset is re-cropped and saved (`adoptCrop` second clause). This is CONFIRMED on the code path. No comment in the code explains it. It goes to the user as P2-4.

### 11A.7 Options for F-C (decision; nothing implemented)

- **Option A: split kind selection from size confirmation.** Kind selection sets the kind and provisional size; `sizeConfirmed` stays false until an explicit "confirm size" action. *Data:* no schema change (the flag's meaning changes in the UI only). *Migration:* none for stored flags; the user decides whether existing ribbon-confirmed uncropped items are flagged. *Tests:* expectations in `document_edits_test` (~30–160), `stage1_a4_workflow_test` (~695, ~752), `document_export_pipeline_test` (~108), ribbon tests, and `automatic_layout_test` (~155) change. Each change is spec-driven and must be documented. *Risk:* extra user step; UX change.
- **Option B: require an approved crop before size confirmation.** Confirm only when `asset.crop != null` or `asset.userAuthoredCrop`. Otherwise the kind is set but `sizeConfirmed` stays false, the item stays off-sheet, and a notice explains why. *Data:* no new field; reads existing ones. *Migration:* existing confirmed items are unchanged; the user decides whether to re-check them. *Risk:* intentionally uncropped full-frame photos stop being placeable until the user accepts a full-frame crop. This interacts with C3 (P2-3).
- **Option C: narrow fix in `adoptCrop` only (P2-4).** Keep a typed size on a confirmed off-sheet item when a crop is saved. Leave the orientation clause as is. *Risk:* small behaviour change for confirmed items; still needs approval.

**Suggested order, for discussion:** C first, because it removes the silent overwrite with the smallest change. Then decide between A and B. The user decides. This report does not implement any option.

### 11A.8 F-D: decision and reproduction plan

- **Mechanism:** CONFIRMED by code (`applyManualCrop` ~1064–1090 does not change item mm).
- **Intent:** documented in `crop_screen.dart` 396–398. The category size is not permission to reshape pixels.
- **Decision options:** (a) keep item mm and warn at export; (b) re-derive item mm from the new crop aspect for natural kinds, which changes stored size; (c) require re-confirmation after re-crop.
- **Reproduction plan (CI, not run):** confirm an item at the catalog size, then call `applyManualCrop` with a 1.0-aspect recipe. Assert that item mm is unchanged and that the export plan warns. Under option (b) or (c), this assertion becomes a spec-driven expectation change and must be documented as such.
- **Label:** NOT REPRODUCED (no run). The mechanism is confirmed; the defect depends on the decision.

### 11A.9 F-E: derivation limit and options

- **Derivation limit (reasoning, not a closed-form proof).** For single-axis tilt, the quad shows one finite vanishing point. Without a second finite vanishing point, the aspect and the focal length are not separable from the quad alone. The simulation confirms this from the other side: the bias changes with focal length (about +4.7% to +6.0% at 20°, and +10.8% to +14.2% at 30°, for f from 2000 to 6000 px). A fixed focal prior would therefore be wrong for other cameras. I did not derive a closed-form focal estimate, so no fix is proposed as ready.
- **Where it acts (live):** `CropDraft.toRecipe` output aspect when `aspectRatio` is null. The unknown-kind free crop is exactly this case. `confirmManualBoundary` takes the recipe from the draft (`project_service.dart` ~1111) and does **not** re-warp. A kind chosen after a free crop therefore sets the catalog size on an image whose content aspect is still the biased one. The printed card is stretched by the bias and then letterboxed. CONFIRMED by code; magnitude NOT REPRODUCED on images.
- **Where it does not act:** with a ratio lock, the output aspect is the lock. `assessQuad.aspect` is used only by the 2.5× `aspectMismatch` bound, which is not reached. `catalogShapeMatches` has no production caller.
- **Options:** (a) document the limitation now; (b) when a tilted quad is cropped freely, show the user the limit (UI text needs approval); (c) a homography aspect with a focal prior. (c) changes recipe output, which is a D7-class user-visible change. It needs a derivation, real-corpus measurement (T16/T17 are not implemented), and explicit user approval.
- **Not allowed:** tightening or widening `shapeTolerance` or the 2.5× bound to hide the bias.
- **Classification change:** P1-1 is re-classified as decision-gated. It needs a derivation before any code.

### 11A.10 C1, C2, C3: status after Phase 6

The State Transition Table in §8 is unchanged after this pass.

- **C1 (Medium, CONFIRMED by code):** the fallback's four taps record a state. One Undo restores the full-frame base. `_manualRequired` lives outside `_CropEditorState`, so it stays false, and Preview and Accept are enabled on the full frame. Not covered by any test.
- **C2 (Medium, CONFIRMED by code):** a successful Suggest after a failed one leaves `_manualRequired` true, so Preview and Accept stay disabled on a valid quad. The notice promises recovery, which only a corner nudge provides. Not covered by any test.
- **C3 (decision, CONFIRMED by code):** import with no detection opens the full frame with controls enabled and no notice. The same happens for a saved invalid suggestion. Not covered by any test. Policy decision: P0-4 and P2-3.

### 11A.11 Test inventory: Phase 6 additions to the gap list

- **G7 (new):** no test that a typed size survives crop adoption (P2-4).
- **G8 (new):** no test that a free-aspect crop of a tilted quad keeps the estimator's aspect, or that a ratio lock fixes it (F-E). This is a characterisation test, not an accuracy test.
- **G9 (new):** no test that a full-frame quad from a non-proposal producer is not accepted (F-M). Existing `boundary_gate_test.dart` 263 pins the opposite for a valid quad.
- **G1–G6 (existing gap list in §10.2)** are unchanged.

Existing tests were read by name only in this pass. No test was executed.

### 11A.12 Open items (not traced or not verified)

- No real-image reproduction (no images available).
- PNG `eXIf` handling (F-H): not verified.
- Whether the ribbon button is disabled when its kind is selected: code read only, not run.
- `adoptCrop` and revert behaviour: traced in code, not executed.
- Exact assertions of `manual_intake_integration_test.dart` 147 and 199: named, not read line by line.
- Reconciliation of the stale local index: not performed (no reset).

### 11A.13 Decision matrix (for the user)

| # | Decision | Options | Suggested (for discussion) | Approval required because |
|---|---|---|---|---|
| D-a | Should four-corner valid detections place without confirmation? (P0-3) | keep review-only (current) / change | keep | protected: `minAutoAcceptConfidence 1.01`, `uncalibratedClassicalScore` |
| D-b | F-C: confirmation without crop (P2-1) | A / B / keep | C first, then A or B | user-visible; permission change |
| D-c | F-D: printed size after re-crop (P2-2) | keep and warn / re-derive / re-confirm | keep and warn | user-visible |
| D-d | F-E: free-aspect tilt (P1-1) | document / warn / homography with focal prior | document now; homography only after derivation and corpus | D7-class user-visible output change |
| D-e | C3: full frame after no detection (P0-4, P2-3) | gate / keep | gate | policy |
| D-f | `adoptCrop` silent catalog reset (P2-4) | keep / keep typed size | keep typed size | silent data change |
| D-g | F-M whole-frame gate check (P3-8) | add / keep | decide with D-a | protected gate |

Not affected by this report, and not to be changed without explicit approval: D2 (classical-first), the D7 16 MP limit and silent downscale, the P1 weight 1.15, and every protected contract listed in §5.2.

### 11A.14 Consistency with the fix plan

§11 is updated: P1-1 is decision-gated; P2-4 (adoption) and P3-8 (whole-frame gate check) are added. Each fix remains independent and unexecuted. No code, test, schema, or AI contract was changed in this pass. No commit, push, merge, or PR change was made.


---

## 12. Final conclusion

1. **Does this report explain the A4 failure?** **Partially.** It explains the mechanism by which four detected corners do not reach A4 in this build: the classical detector never auto-accepts (`minAutoAcceptConfidence 1.01` and the `uncalibratedClassicalScore` reason), the item remains a suggestion with full-frame aspect, and the unknown kind leaves `sizeConfirmed` false, which excludes it from automatic arrangement and placement. This is **by design** (F-A, F-B). It does **not** prove that this mechanism is the cause for the user's specific screenshots, which I could not view in this session (§11A.2).
2. **Is "unknown size" a geometric invalidity?** **No.** The code keeps geometric validity separate (§4).
3. **Real defects found:** the perspective aspect bias (F-E, CONFIRMED on synthetic geometry), the two confirmation bypasses (F-C), the printed size that does not follow a re-crop (F-D: mechanism CONFIRMED, NOT REPRODUCED, NEEDS PRODUCT DECISION), and the PR #39 C1 and C2 states (F-F).
4. **No runtime claim.** Nothing here is a test result. Runtime proof must come from CI on a future SHA, as in §10.3.
5. **PR #39 verdict remains NOT READY** until C1 and C2 are fixed (P1-2, P1-3), and the protected and decision items are resolved by the user.

**Nothing in §11 has been executed.** Each fix needs explicit approval, as listed.

## 13. Implementation batch (PR #39, branch `arena/9c08ad5c-scan-id`): fixes, tests, status

Status of this section: **code written and not compiled locally (Dart and
Flutter are unavailable here). The compiled results are CI results from GitHub
Actions run `41524485716` on `ce5d800`, listed in §13.6.** The verdict stays
NOT READY: the items in §13.4 are open.

### 13.1 Findings and status after this batch

| Finding | Status before | Change in this batch | Status now |
|---|---|---|---|
| C1 Undo restores ungated full frame | CONFIRMED (code read) | Gate is part of the history state (`_CropEditorState.manualRequired`). Undo/redo restore it. Fallback replaces the current entry, so undo never reaches an ungated full frame. Taps, valid suggestion, and corner drag clear the gate; the reset button keeps it. | FIXED (CI green on `ce5d800`) |
| C2 Suggest after fallback | CONFIRMED | Only a valid suggestion clears the gate (`_change(..., clearManualRequired: true)`). Malformed or stale results keep the gate and the corners. The fallback instruction stays while the gate is set. | FIXED (CI green on `ce5d800`) |
| C3 No candidate → silent full frame | CONFIRMED; NEEDS PRODUCT DECISION (now in scope per implementation request) | A new draft with no usable boundary starts gated, with the Arabic instruction. An invalid saved suggestion starts gated with its reason. An explicit extraction (`extractDerived`) and a saved crop keep their own paths. | FIXED (CI green on `ce5d800`) |
| F-C kind confirms size without crop | CONFIRMED | `DocumentEdits.setKind`: a known kind confirms only with an approved crop (`asset.crop != null`). Without one, the size is provisional, unconfirmed, and unplaced. `other` keeps the current confirmation. A typed or manual resize still confirms. | FIXED (CI green on `ce5d800`) |
| adoptCrop silently resets confirmed sizes | CONFIRMED (via `setKind` loop) | Only provisional, unconfirmed natural sizes are re-oriented (`refreshProvisionalSize`). Confirmed sizes are never changed. | FIXED (CI green on `ce5d800`) |
| Revert path confirms sizes | CONFIRMED | `manual_boundary.revertManualCropOnProject` uses `refreshProvisionalSize` and does not confirm. | FIXED (CI green on `ce5d800`) |
| F-E aspect from four corners | CONFIRMED (averaged-edge bias) | New `lib/domain/physical_aspect.dart`: vanishing points, focal `f² = −(a·b)`, unit-square homography, `W/H = |K⁻¹g0| / |K⁻¹g1|`. Used only in `CropDraft.toRecipe` for free crops, only when determinable. Area is kept, so D7 is unchanged. It never sets physical size. | IMPLEMENTED (CI green on `ce5d800`) |
| F-D re-crop changes size | Mechanism CONFIRMED; NOT REPRODUCED | No code change. Item mm stay on re-crop. The existing non-blocking export warning (`export_plan.dart`, ratio differs by more than .01) is the conflict signal. No new test added. | PARTIAL: tests not yet added |
| F-K / F-M proposal validation | Reviewed; no reproduction | No code change. `_usableSuggestedCorners` → `assessQuad` validates before any draft. Repeated points, self-intersection, and winding are covered by `assessQuad` tests in the existing suite. Whole-frame gate hardening is not changed. | NOT IMPLEMENTED in this batch (listed in §13.4) |
| A4 eligibility unification | Mapped (§4, §5) | Invariants preserved: `PageLayout.checked` and `arrangeDocuments` still require `sizeConfirmed`. The F-C change makes unconfirmed items unplaced, so they cannot reach A4 by kind alone. No new unified eligibility type. | PARTIAL: no new unified type or tests |
| D7 16 MP limit and silent downscale | CONFIRMED unchanged | `toRecipe` keeps `withinImageBudget`, `maxImportPixels`, and the floor. The physical step runs before the budget step and keeps the same area. The refusal in `requireFullResolutionCropFits` is untouched. | UNCHANGED (verified by reading) |

### 13.2 Decisions made in this batch

- **C3 is implemented** (the implementation request put it in scope). The gate is
  the state, not a screen variable. Preview and accept check `_manualRequired`,
  which reads the state.
- **The starting full frame is never an approved boundary.** This applies even
  when a valid proposal is loaded beside it. Undo back to that frame is gated.
  This is stricter than before, and it is what C1 requires.
- **Choosing a kind alone never makes an item placeable.** `other` keeps the
  current confirmation. This follows the implementation request.
- **F-E uses a derived method, not a guess.** Two-axis perspective is recovered
  from the four corners. Single-axis tilt and in-plane rotation alone are not
  determinable and fall back to the averaged-edge shape, which the derivation
  shows is exact for affine views. The VP-only ratio formula was rejected because
  Python showed about −27 % error.
- **No change** to thresholds, `minAutoAcceptConfidence: 1.01`, the cascade,
  DocQuadNet, DocAligner, `Project.schemaVersion`, the annotation schema, EXIF,
  the 16 MP limit, or signing.

### 13.3 Spec-driven test expectation changes (documented; not weakened)

Each change is an intentional consequence of the rules above. The assertions that
still hold were kept.

1. `test/domain/document_edits_test.dart`
   - "choosing a category applies its catalog size immediately" became "…without
     a crop applies the catalog size only": `sizeConfirmed` expected `false` (was
     `true`).
   - "selecting a document kind preserves unconfirmed crop geometry" became "a
     suggested quadrilateral is not an approved crop": `sizeConfirmed` expected
     `false` (was `true`).
   - "unknown takes the document off the sheet, other keeps it" now confirms with
     a typed size before `other`.
   - New tests: approved crop confirms; confirmed uncropped item goes off the
     sheet on category change; `other` without confirmation stays unconfirmed;
     `refreshProvisionalSize` re-orients only unconfirmed sizes.
2. `test/application/stage1_a4_workflow_test.dart` (two places): simulated user
   confirmation via `setKind other` replaced with an explicit `resize` (typed
   size).
3. `test/application/document_export_pipeline_test.dart`: `setKind other` on the
   approved crop replaced with `resize` (typed size), because the approved crop
   no longer confirms by kind.
4. `test/application/manual_intake_integration_test.dart`
   - Proposal test: after Undo to the starting frame, Preview is blocked (C1). The
     redo and preview steps that follow are unchanged.
   - Invalid-preview test and reused-route test: four valid taps before Preview.
     The reused-route assertion is now the tapped corner (x ≈ .2), not x = 0.
5. `test/widget_test.dart`: Undo to the starting frame blocks Preview; four taps,
   then Preview. The "original corner" assertion became the tapped corner.
6. `test/presentation/stage1_manual_confirmation_widget_test.dart`: taps before
   the preview of the untouched frame (three places); taps again after Undo to the
   starting frame. The derived-extract path is unchanged.

New tests (CI has not run them):
- `test/domain/physical_aspect_test.dart`: two-axis exact cases; roll 0–45°;
  asymmetric perspective; four image sizes and focal lengths; fixed ±2 px pattern
  (bounds 1 % and 3.5 %, observed .61 % and 2.53 %); single-axis and roll-only
  return null; degenerate input returns null; `toRecipe` rectifies a two-axis
  crop; `toRecipe` keeps the averaged shape for a rectangle.
- `test/application/crop_lifecycle_test.dart`: no candidate starts gated; invalid
  saved suggestion starts gated; undo and redo through the gate; valid Suggest
  lifts the gate; malformed Suggest keeps it.

### 13.4 Not completed in this batch (honest list)

- A4 eligibility: no unified eligibility type and no tests for the eight-case
  matrix in the request.
- F-D: no new re-crop tests (confirmed catalog re-crop, manual re-crop,
  orientation change, save/reload, export after re-crop).
- F-K/F-M: no whole-frame gate hardening, no new tests for repeated points,
  self-intersection, or ordering.
- `packing.dart` and the export review: read in earlier phases; not changed.
- Real-corpus measurement of F-E: not available in this sandbox.
- Migration of legacy confirmed uncropped items: none (documented residual).

### 13.5 CI plan (to be executed by GitHub Actions on the final SHA)

Required gates, unchanged: format (`dart format --output=none
--set-exit-if-changed`), `tool/check_source.py`, `flutter analyze`, `flutter test`
(all files above), Windows and Android builds, Android 16 instrumentation. A
green result is valid only on the SHA that produced it. Unreadable logs are
reported as unreadable.

### 13.6 CI closure for the batch (run `41524485716`, SHA `ce5d800`)

Every required gate passed on `ce5d800`. The results below are CI results, not
local ones.

| Gate | Result on `ce5d800` |
|---|---|
| Format (`dart format --output=none --set-exit-if-changed`) | exit 0; 222 files, 0 changed |
| Source audit (`tool/check_source.py`) | exit 0; 221 Dart files; domain boundaries checked |
| `flutter analyze --fatal-infos` | exit 0 |
| `flutter test --reporter expanded` | `+915: All tests passed!`; zero `[E]` markers |
| Android debug build and APK checks | success (job `125548580720`) |
| Android instrumentation | `androidTests=4 failures=0 skipped=0` |
| Android 16 startup evidence | success; first home frame on API 36 emulator (x86_64, not ARM64 device evidence) |
| Windows build | success (job `125548581528`) |
| APK differential | success (job `125548581640`) |

**Runs in this round, in order** (all on the same branch; none was green until the last):

| Run | SHA | Result (`[E]`-marked failures) | Cause and fix |
|---|---|---|---|
| `41518846746` | `f89a518` | 3: lifecycle undo, T-stale, widget undo | Expectations and timing; see the fixes below |
| `41519990215` | `c245968` | 2: T-stale, widget undo | Lifecycle expectation corrected; T-stale is a product issue (below) |
| `41521117407` | `7dc50e7` | 3: widget undo, T04 pan, T04 nearest handle | Gate kept during the drag fixes T-stale; T04 reference measured after the release shift |
| `41522190868` | `998f2ec` | 1: widget undo | Toggle label flipped to "cancel", but the surface was absent |
| `41523422386` | `184d613` | 1: widget undo | Diagnostic: canvas, result, and corner-0 all absent (0) |
| `41524485716` | `ce5d800` | **0: all pass** | — |
| `41527303468` | `b03d6c1` | infrastructure: cancelled at the 50-minute job limit in the emulator step `Android native instrumentation` (21:31 to 22:09 UTC); every other gate passed; rerun refused by GitHub | Same code re-pushed as an empty commit; the emulator step is not a code failure (it passed on `ce5d800`) |
| `41534968235` | `95ccef6` | **0: all pass** (`+915`, `androidTests=4 failures=0`, Android 16 success) | Final green SHA of this round |

**Root causes found in this round**

1. **T-stale (product, CONFIRMED by arithmetic):** the first valid corner move
   lifted the fallback gate and removed the status line during the drag. The
   canvas moved up 32 px under the pointer, so every later move put the corner
   32 px low (normalized y 0.069, the observed error). **Fix:** the gate and the
   status line stay during the gesture; the drag end lifts the gate (through
   `_change(..., clearManualRequired: true)`), when the boundary has been checked
   for crossing edges. Preview stays blocked while a drag is in progress.
   Normalized corners do not depend on the release shift.
2. **Widget undo (test timing, CONFIRMED by the Suggest feedback):** Suggest shows
   a six-second snackbar (`showMessage`). The test waited five seconds, so the
   snackbar could still cover the lower controls. The earlier comment said four
   seconds; it is corrected. **Fix:** a two-second wait after Undo, before tapping
   the toggle.
3. **Widget undo (layout, CONFIRMED by the diagnostic):** in the narrow layout the
   canvas is the first child of a lazy `ListView`. Reaching the tap-mode toggle,
   which sits below the 440 px canvas, scrolls the canvas out of the built range,
   so `crop-source-image`, `crop-result`, and `crop-corner-0` were all absent. The
   toggle itself worked. **Fix:** the helper drags the list back from the toggle
   (a drag does not press a button) before it asserts the surface. This is a test
   helper change. Real users see the same culling and nothing is lost: the state
   is kept, and the canvas rebuilds when they scroll up.

**Correction to an earlier note:** `41518846746` did not fail the exporter test.
The three `[E]`-marked failures in that run were the lifecycle undo test, T-stale,
and the widget undo test. The exporter name appeared only as a progress line. The
exporter test has passed in every run since, and the isolated export run
(`export-isolation`, 11 tests) passed in about 10 s. The original exporter failure
was therefore a misreading, not a reproduced failure. Its status is NOT
REPRODUCED.

**Spec-driven and measurement changes added in this round** (each is listed in
§13.3 as well; none weakens an assertion):

7. `test/application/crop_lifecycle_test.dart` "undo after fallback never restores
   an ungated full frame": after Undo, the tap surface is absent and corner-0 is
   present. The earlier expectation was a batch error. Undo restores the gated
   frame with draggable corners, not four-tap mode.
8. `test/widget_test.dart` "crop proposal can be undone": asserts the tap-mode
   toggle is enabled after Undo; waits two seconds for the Suggest snackbar;
   enters four-tap mode through the toggle and drags the list back; the expectation
   of four valid taps and Preview is unchanged.
9. `test/presentation/crop_corner_hit_layer_test.dart` T04 "pan" and "hit picks the
   nearest handle": the pointer is mapped onto the canvas measured before the
   press, because the status line now leaves at drag end. The old reference was
   measured after the release shift, which is 32 px away.
10. `test/application/manual_intake_integration_test.dart` `dirtyDraft`: two frames
    instead of one. `pumpAndSettle` was rejected because a pending suggestion keeps
    a progress indicator animating, and it would time out.
11. `test/presentation/crop_tap_helpers.dart` `ensureCropTapMode`: asserts the
    surface opens, reports the toggle's rect and label on failure, and scrolls
    back after the toggle.

**Decision added in this round:** a corner drag keeps the fallback gate until the
drag ends (`lib/presentation/crop_screen.dart`, `_moveCorner` and `onDragEnd`). This
is a UX change in drag timing only: the gate is not lifted earlier, and the notice
does not disappear under the pointer. It needs no user approval, because it changes
no protected contract and no user-visible rule.

**Still open after `ce5d800`** (the verdict is NOT READY until these are closed or
the user accepts them as residual):

- A4 eligibility: no unified eligibility type and no tests for the eight-case
  matrix (§13.4).
- F-D: no re-crop tests (§13.4).
- F-K/F-M: no whole-frame gate hardening and no tests for repeated points,
  self-intersection, or ordering (§13.4).
- F-E: no real-corpus measurement; the Python grid is pure geometry, not Dart
  evidence.
- Exporter: NOT REPRODUCED; a diagnostic isolation step and the test-log artifact
  stay in `verify.yml` as non-gating evidence.

## 14. Phase 8 batch (PR #39, commit `ace6bb3`): one implementation batch

Status of this section: **code and tests written in one batch, then repaired
in §14.10. Dart and Flutter are unavailable in this sandbox, so nothing here is a
local run. Each result is a GitHub Actions result on the SHA named in §14.10.** A
status is VERIFIED only when CI ran the relevant test on that SHA. The verdict is
NOT READY (§14.9).

### 14.1 Findings and status

| ID | Finding | Evidence before the batch | Change | Status |
|---|---|---|---|---|
| F-K | `hasApprovedCrop` was `crop != null`, so a full frame stored by an adjustment, rotation, or enhancement counted as an approved crop. `setKind` then confirmed a catalog size without a boundary decision. | CONFIRMED by code read (`DocumentEdits.hasApprovedCrop`, `setKind`, `editor_controller` ~1002/1041/1071 `crop ?? fullImage`). | `ImageAsset.hasApprovedCrop` = `crop != null && (userAuthoredCrop \|\| !isFullFrameCorners(crop.corners))`. `isFullFrameCorners` (tolerance 1e-6) is in `geometry.dart`. `DocumentEdits.hasApprovedCrop`, `crop_screen` initial crop, revert guard, `resetCropToOriginal` guard, and the layout reset-crop enable all use it. | FIXED; tests in `test/domain/full_frame_approval_test.dart` and `crop_lifecycle_test.dart`. VERIFIED on `b7d9065` (§14.10). |
| F-K gate | A stored full frame started with no gate, so Preview was enabled. | CONFIRMED by code read (`crop == null` branches, `crop_screen.dart`). | `crop_screen` treats an unapproved stored frame as no crop, so the base frame is gated and the saved suggestion is used. Test: "an adjusted full frame is not a saved crop". | FIXED; VERIFIED on `b7d9065`. |
| C1 | Reset to the original full frame could leave Preview and Accept enabled. | CONFIRMED by code read (`manualRequired: _manualRequired` on reset). | Reset sets `manualRequired: true`, the same as Undo to the starting frame. Test: "restoring the full frame re-gates Preview and Accept". | FIXED; VERIFIED on `b7d9065`. |
| F-C | `setKind` confirmed a catalog size for a full frame with no approved boundary (through the old `hasApprovedCrop`), and a category choice replaces a typed size. | CONFIRMED by code read. | Crop-approval part FIXED through F-K: `hasApprovedCrop` means an approved boundary, so nothing is confirmed without one. The overwrite on an explicit category choice keeps the HEAD rule (`7a39191`): the category's catalog size applies, and it is confirmed only with an approved crop. The Phase 8 keep-confirmed variant was reverted in `bc25121` because it kept a previous category's size and failed three existing tests (§14.10). | Crop-approval part: VERIFIED on `b7d9065`. Explicit-overwrite rule: **NEEDS PRODUCT DECISION** (a category choice can replace a typed size; the user accepts or changes this). |
| F-A4 | A4 eligibility rules are spread across `arrangement`, `page_layout`, `export_plan`, `packing`, and `project_service`. Is there a divergent decision? | Read every site (§14.2). All placement sites key on `sizeConfirmed` and `locked`, and no site accepts an unconfirmed size. | **No shared type was added.** The task allows one only when the audit proves a divergent decision, and none was proven. The eight-case matrix tests the production paths (`PageLayout.checked`, `autoLayoutStatus`, `ExportPlan`, `Project` reload) directly. | NOT REPRODUCED as a divergence; matrix tests added; VERIFIED on `b7d9065`. |
| F-D | Re-crop: does it change the physical size? | CONFIRMED by code read. `applyManualCrop` writes only an asset revision; the item's mm stays the same. Save confirms only when `confirmForSheet \|\| kindOrSizeChanged`. Export warns when the crop ratio differs from the sheet (`export_plan.dart`). | No change to the size path. Tests in `test/application/recrop_size_test.dart`: confirmed catalog re-crop, typed size re-crop, provisional size never confirmed silently, turned picture keeps its printed size, ratio mismatch through the existing export warning, save and reload. | VERIFIED on `b7d9065` (5 tests in the 959-test run). |
| F-E | Physical aspect from four corners: which cases are determinable and how accurate are they? | Python port (§14.5). Pure geometry only. | Dart tests (`test/domain/physical_aspect_test.dart`) cover the Python cases: two-axis perspective, roll up to 45°, asymmetric perspective, sizes and focal lengths, fixed two-pixel corner noise, strong two-axis perspective with roll (40/40 and 50/35, roll 15°, bound 0.1 %), single-axis tilt and roll as null, degenerate input as null. | Synthetic geometry only. Dart tests VERIFIED on `b7d9065`. Real-image accuracy: **BLOCKED** (no licensed reference set, §14.6). |
| F-N | Narrow layout: a lazy `ListView` culled the canvas when the tools scrolled, which lost the canvas, the corners, and the manual selection. | CONFIRMED by counts in `184d613` and by the code (`ListView` in the narrow branch). | The canvas is a fixed-height `SizedBox`; only the tools scroll (`Expanded(SingleChildScrollView(_tools()))`). The canvas stays mounted. The helper `ensureCropTapMode` is unchanged from `7a39191` (its scroll-back is harmless and was kept). Test: `test/presentation/crop_narrow_layout_test.dart`. | VERIFIED on `b7d9065` (the narrow test passes in the 959-test run). |
| Exporter | The exporter test failure in an early run. | No `[E]` marker in any later run (§13.6). | No change. | NOT REPRODUCED. |
| D7 | 16 MP limit and the silent downscale. | Unchanged. | None. Protected. The existing `full_resolution_budget_test.dart` runs in CI. | NOT CHANGED. |
| Smart recognition | `_confirmedCatalogSize` can accept with a null `crop`, so recognition and `asset.crop` could disagree. | Read only. | None. Unreachable while `minAutoAcceptConfidence = 1.01`. | NOT REACHABLE (latent; documented). |

### 14.2 Eligibility audit (read of every site)

- `arrangement.dart`: `autoLayoutStatus` (`locked` first, then `sizeConfirmed`, then fit); `arrangeDocuments` (movable = `sizeConfirmed`, unlocked, unfixed; a page-placed unconfirmed item goes to `unplaced`); `_compactPass` (locks a confirmed unplaced item).
- `page_layout.dart`: `PageLayout.checked` requires `sizeConfirmed` for any item with `pageIndex`.
- `export_plan.dart`: included items must be confirmed; printable bounds are checked there too.
- `packing.dart`: items on the page must be confirmed; pending items must be confirmed.
- `project.dart`: `Project.fromJson` keeps `pageIndex` only for a confirmed size.
- `project_service.dart`: `AutomaticLayoutReport.unplaced` and `awaitingSize` use the same `sizeConfirmed` fact.
- `layout_screen.dart`: move-to-page tooltip and enable.

Every site reads `sizeConfirmed` and, where relevant, `locked`. Nothing reads the
boundary to decide placement. An unconfirmed item is refused at each site, and a
valid boundary does not change that. **No divergent decision was proven, so no
shared type was added.** The matrix in `test/domain/item_eligibility_test.dart`
checks each state through these production paths.

The matrix separates geometry validity (boundary approved), kind known, size
confirmed, manual placement, automatic placement, and export. It has eight cases:
no approved boundary; a stored full frame (not an approval); approved boundary
with unknown kind; known kind with unconfirmed size; manual confirmed size;
catalog confirmed size; needs review (a saved suggestion); valid for manual
placement only (locked); and valid for automatic placement. Plus the unapproved
missing-asset and reload checks.

### 14.3 Full-frame and default-quad paths (F-K / F-M)

Producers and consumers checked against `assessQuad`, `canonicalQuadCorners`, and
the `CropScreen` gate:

- Full-frame producers that store `crop` without a decision: `editor_controller`
  adjustment, auto-enhance, and rotation revisions (`crop ?? fullImage`). These are
  the F-K root. They are not approvals after this batch.
- Legitimate full-frame paths: `local_project_recovery.dart` (recovery of a
  saved full frame); `resetManualCrop` (`crop: null`); the explicit extraction
  path (`extractDerived`). None is changed.
- Not approvals: the legacy polygon in `project.dart`, and `fullFrameRegion` in
  `smart_recognition.dart`.
- Gate: a stored unapproved frame, a reset, and an invalid saved suggestion all
  start or return to the gated state. A kind change never approves a boundary
  (`setKind` does not touch `crop`).
- `assessQuad` rejects repeated or near-coincident points, self-intersection,
  wrong point order, non-convex shape, out-of-image coordinates, non-finite
  values, and collapsed area. The tests in `full_frame_approval_test.dart` use
  these values and check the rejection reason.

Existing gate lifecycle tests (CI-verified in earlier phases, unchanged) cover:
detect-fail then Undo and Redo; an invalid saved suggestion; a valid Suggest that
lifts the gate; a malformed Suggest that keeps it; and Preview and Accept blocked
while the frame is unapproved.

### 14.4 Spec-driven test changes (documented; no assertion weakened)

Changes in the Phase 8 batch that remain in the tree after `bc25121`:

1. `test/domain/document_edits_test.dart`: **reverted to `7a39191`.** The Phase 8
   rewrites of the category-change expectations were removed with the keep-confirmed
   `setKind` change. The HEAD expectations stand unchanged.
2. `test/presentation/crop_tap_helpers.dart`: **reverted to `7a39191`.** The
   scroll-back drag was not removed; the narrow fix does not depend on it.
3. `test/domain/item_eligibility_test.dart` (reload cases, spec-driven): the reload
   assertion follows `Project.fromJson`. An unconfirmed item leaves its page on
   reload, by design. The old expectation (keeps `pageIndex`) was wrong.
4. `test/domain/item_eligibility_test.dart` (missing asset, spec-driven): the test
   asserts that `Project` refuses an item whose asset is missing
   (`ValidationException`). The earlier expectation (loads unconfirmed) was wrong,
   because no model state can hold such an item.
5. `test/presentation/crop_narrow_layout_test.dart` (spec-driven): after four taps
   the tap surface is closed, as C3 requires. The test now asserts that the surface
   is closed and that the corner handles and tapped positions survive scrolling. It
   taps at 35/65 % of the surface, away from the corner handle hit areas.
6. `test/application/crop_lifecycle_test.dart`: the test "an adjusted full frame is
   not a saved crop" builds the stored full frame directly. The helper comment was
   shortened to fit 80 columns.
7. New tests (additions, not replacements): `test/domain/full_frame_approval_test.dart`,
   `test/domain/item_eligibility_test.dart`, `test/application/recrop_size_test.dart`,
   `test/presentation/crop_narrow_layout_test.dart`, the two `crop_lifecycle_test.dart`
   tests, and the strong-perspective and noise tests in `physical_aspect_test.dart`.

### 14.5 F-E: Dart and Python evidence

The derivation is in `lib/domain/physical_aspect.dart`: f² = −(a·b) from the two
vanishing points, and W/H = |K⁻¹g0| / |K⁻¹g1| from the unit-square homography.
λ cancels. Single-axis tilt, affine views, and in-plane roll alone do not fix f,
so the result is null. The caller keeps its averaged-edge estimate, which is
exact for an affine view.

Python port (`tool/evidence/physical_aspect_results.json`, pure geometry, not a
Dart run). Relative error in the physical ratio:

| Case | Determinable | Error |
|---|---|---|
| Two-axis 25/25, five ratios, 3000×4000, f 3500 | yes | −0.012 % |
| Two-axis 25/25, roll 0 / 10 / 20 / 30 / 45 | yes | −0.012 / −0.013 / −0.017 / −0.028 / +0.118 % |
| Asymmetric tilt 20/20, 30/30, 30/−30, 40/25, 15/35, 10/45 | yes | −0.010 to −0.025 % |
| Sizes 1200×1600 to 6000×4000 | yes | −0.006 to −0.029 % |
| Strong two-axis 40/40 roll 0 | yes | −0.017 % |
| Strong two-axis 40/40 roll 15 | yes | −0.023 % |
| Strong two-axis 50/35 roll 15 | yes | −0.047 % |
| Fixed ±2 px corner pattern, 30/30 | yes | +0.606 % |
| Fixed ±2 px corner pattern, 40/25 roll 20 | yes | −2.53 % |
| Fixed ±2 px corner pattern, 40/40 roll 15 | yes | −0.503 % |
| x-tilt only, y-tilt only, in-plane roll only | no (null) | — |

Limits. The Dart test bounds are set from these numbers, not from a Dart run.
The noise-free bounds are derived from exact arithmetic (no noise, exact
inversion), and the noise bounds come from the measured pattern. Lighting does
not enter the estimator (it reads corners only), so it is not a tested input.
These are synthetic geometric results. They are not real-image accuracy claims.

### 14.6 Real-image F-E: BLOCKED

No licensed or personal reference images were used (task constraint). No
reference set with known physical dimensions was available in this sandbox, and
the sandbox allows no image download. Real-image accuracy is therefore **BLOCKED**.
This batch makes no claim about real photographs.

### 14.7 Narrow layout (F-N)

The canvas is in a `SizedBox` of height `min(preferred, maxHeight)`, and the tools
are in `Expanded(SingleChildScrollView)`. The canvas is never removed from the
tree, so the crop context, the corner handles, and the four taps survive tool
scrolling. The widget test scrolls the tools down and back up and checks that the
surface is closed after four taps (as C3 requires), the corner handles remain, and
each tapped corner stays within 0.5 px. The canvas is outside the scrolling area,
so scrolling the tools does not rebuild it. No memory or frame-time measurement
was taken in this sandbox. The test passes in the 959-test run on `b7d9065`.

### 14.8 CI (see §14.10 for the per-commit results)

The batch was pushed as `ace6bb3` (failed at format), then `7551bcb`, `3483b4f`,
and `ab2692d` (format and 11 test failures), `bc25121` (2 test failures), and
`b7d9065` (every test passed; Android 16 evidence failed; §14.10).

### 14.9 Verdict

**NOT READY.** Open items: F-E real-image accuracy (BLOCKED, §14.6); the product
decisions D2, D7, the unknown-kind placement policy, and the explicit category
overwrite (F-C, §14.1); the Android 16 startup evidence on the final SHA (§14.10);
and the drag-time notice wording (§14.10, LOW). The verdict changes only when the
product decisions are accepted and every required gate, including Android 16, is
green on one SHA.


### 14.10 Repair round: `bc25121`, `b7d9065` (CI results)

CI on `ab2692d` failed with 11 `[E]` results and a format gate. The `[E]` lines
and annotations were read in full. Root causes and changes:

| ID | Problem | Root cause (from CI annotations) | Change | Tests | Status |
|---|---|---|---|---|---|
| F-C regression | `setKind` kept a confirmed size without an approved crop. | The keep-confirmed rule let a previous category's catalog size survive a category change. It failed `review_screen_test`, `editor_ribbon_test`, and `recognition_overrides_test` (expected `[125, 88]`, got `85.6`). The existing tests were right; the change was wrong. | `document_edits.dart` and `document_edits_test.dart` reverted to `7a39191`. Only `hasApprovedCrop` now delegates to `ImageAsset.hasApprovedCrop`. | The three existing tests pass in the 959-test run. | FIXED (regression reverted) |
| Reload, 5 cases | Reloaded unconfirmed items were expected to keep `pageIndex`. | `Project.fromJson` drops `pageIndex` for an unconfirmed item by design. The test was wrong. | Spec-driven change (§14.4 item 3). | `item_eligibility_test.dart` reload cases | VERIFIED on `b7d9065` |
| Missing asset | Expected an orphan item to load unconfirmed. | `Project` refuses it at construction (`ValidationException`: an item refers to a missing image). No state can hold it. | Spec-driven change (§14.4 item 4). | `item_eligibility_test.dart` | VERIFIED on `b7d9065` |
| F-N tap points | Taps at 20/80 % of the surface hit the corner handle layer (hit-test warning). | The test tapped inside the corner handles' hit areas. | Taps at 35/65 %. The surface is closed after four taps; corners survive scrolling (§14.4 item 5). | `crop_narrow_layout_test.dart` | VERIFIED on `b7d9065` |
| Adjusted full frame | Test depended on an editor revision. | Set-up, not product behaviour. | The stored full frame is built directly and the test asserts it is gated. | `crop_lifecycle_test.dart` | VERIFIED on `b7d9065` |
| Format gate, `recrop_size_test.dart` | Flagged across four commits. | The file had four constructs the formatter rewrites: a multi-line field initializer, a `for` over a list literal, an inline `copyWith` argument, and the `_Harness` field initializer. The earlier edits changed only the layout of single calls. | File rewritten without those constructs; same five tests. | Format: `226 files (0 changed)` on `b7d9065` | VERIFIED on `b7d9065` |
| F-M gate tests | Detect fails, then Undo/Redo; invalid suggestion, then Preview or Accept. | Existing gate tests cover these paths. | None needed. Covered by `crop_lifecycle_test.dart`: "undo after fallback never restores an ungated full frame", and "a malformed suggestion after fallback keeps the gate", which asserts Preview and Accept are null. | Passed on `b7d9065` | VERIFIED on `b7d9065` (domain and gate level) |
| Gate bypass via kind change | Can a category change lift the gate? | The gate is crop-screen state (`_CropEditorState.manualRequired`); a category change does not reach it. | None. Domain test: a category cannot confirm a size from an adjusted full frame. | `full_frame_approval_test.dart` | VERIFIED on `b7d9065` (domain). Gate level: by code read |
| Android 16 startup evidence | `b7d9065` FAILED: "The reports are missing: app.first_home_frame". | The logcat check passed, so the first home frame was reached, but the pulled report lacked the mark. The startup code has no diff since `7a39191` (`lib/main.dart` and the diagnostics files are unchanged). The collector's own comment records the race: a mark can reach the platform channel after its report is written, and the collector waits a fixed 12 s. | Not changed in this round. Rerun on the documentation commit to separate infrastructure from a deterministic defect (§13.5 rule). If it fails again, the collector should wait for the mark rather than a fixed delay. | — | FLAKY, open (LOW to MEDIUM): one failure on `b7d9065`, one pass on `f920238` with the same product code. The collector race is not fixed in this batch. |
| Drag-time notice | The crossing notice clears on the next valid move during a drag. | By design: `_moveCorner` clears `_error` when the draft is valid again. The drag-end gate lift is present (`7dc50e7`, `onDragEnd` calls `_change(..., clearManualRequired: true)`). Earlier notes that the lift was missing were wrong. | None. The notice reflects the current state. | — | LOW. Documented; no gate defect |

Final CI, after the documentation commits:

- `c5e6772` (docs only): `android` CANCELLED at the 50-minute job limit (started 08:52:33, cancelled 09:43:01). All 959 tests had already passed. The same product code took 20.5 minutes on `b7d9065`. Classified as infrastructure: no product change.
- `f920238` (empty re-push; push run `41613355714`): **all four jobs succeeded.** `android`: `All tests passed! +959`, format `226 files (0 changed)`, source audit PASS, `androidTests=4 failures=0 skipped=0`, DocQuad exit 0. `Android debug/diagnostic differential`: success. `windows / windows`: `All tests passed!`. `Android 16 startup evidence`: success, 3 reports, first home frame reached on API 36 (x86_64).
- Last green SHA with all four jobs: `f920238`. The documentation commit after it is recorded in the PR body and the final answer.

Test results on `b7d9065` (push run `41603371892`; the first run with all tests green):

- `android` job: success. `All tests passed! +959`, 0 failures. Format `226 files (0 changed)`. Source audit PASS. Instrumentation `androidTests=4 failures=0 skipped=0`. DocQuad inference exit 0.
- `Android debug/diagnostic differential`: success.
- `windows / windows`: success.
- `Android 16 startup evidence`: failure (row above).

Not proven:

- F-E real-image accuracy (BLOCKED: no licensed references). The Dart tests use synthetic geometry only. Lighting does not enter the estimator, which uses only the corners, so it is not a tested variable.
- Per-case relative errors come from the Python port (§14.5). The Dart tests assert bounds and do not print the errors.
- The explicit category overwrite (F-C) is a product decision, not a fixed defect.

### 14.11 CI incident on `0dc9d07` (android job) and the diagnostic fix

Premise check: the failing step is **`Android native instrumentation (BitmapRegionDecoder)`** (step 39 of the `android` job, `tool/run_android_instrumentation.sh`), not "Android debug APK". That step (45) was skipped. The signing-guard step (24) succeeded: its single attempt printed the expected guard message, and no retry was needed.

Evidence and limits:

- The `flutter test` step passed: `+959: All tests passed!`, with no failures.
- The step exited 255. The job log and the instrumentation artifact could not be downloaded (blob access fails in this sandbox, as recorded in §13 and in the repository notes). The annotation channel holds only the step-level error.
- The script emits `android-runtime-inference-failure` when Gradle or DocQuad fails, and `startup-diagnostic` for startup failures. Neither annotation is present, and the success notice is absent. So the script ended in its unguarded `adb` and startup phase, before the summary. This is inferred from the script's control flow, not proven by a log line.
- The runner had reported "No space left on device" on `b1d3884`'s run. That is evidence of disk pressure on the runner, but this run's log has no disk message, so it is not claimed as the cause.

Change (no product change, no exit status changed):

- `tool/run_android_instrumentation.sh`: an ERR trap that reports the failing line and command when errexit is active. It is silent inside the `set +e` capture regions. The exit status is unchanged (tested locally: a failing `sh -c 'exit 255'` still ends the script with 255).
- The same script prints the host headroom (`rootFreeKiB`, `memAvailableMiB`) at start, so a disk or memory shortage can be checked against the next failing run.

Test: the trap was checked with local bash only (not CI). The workflow file is unchanged; `tool/check_source.py` and `tool/check_workflow_permissions.py` pass; `verify.yml` parses as YAML with the four jobs.

Status: the root cause is **not proven**. The trap is the fix for the observability gap; the next failing run will name the command.

Result of the change (push run `41668904144`, SHA `d2f3c89`): all four jobs succeeded.

- `android`: `+959: All tests passed!`; format `226 files (0 changed)`; source audit PASS; `androidTests=4 failures=0 skipped=0`; DocQuad exit 0. The host notice at the start of the instrumentation step reported `rootFreeKiB=70034236`, `memAvailableMiB=3976`. The signing guard: attempt 1 of 2 failed with the guard message, as required.
- `Android debug/diagnostic differential`: success. `windows / windows`: success (`+3: All tests passed!`). `Android 16 startup evidence`: success (3 reports, first home frame reached on API 36, x86_64).

The 0dc9d07 failure did not recur on the same product code. The cause is still not proven. The ERR trap did not fire on `d2f3c89`, so there is no new evidence about the 255 command.
