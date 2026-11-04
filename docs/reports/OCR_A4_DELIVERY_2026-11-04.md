## What this delivers

The pipeline is now end-to-end: **acquisition → quality → boundary review → on-device OCR → multi-evidence kind → size catalog → dimension confirmation → A4 eligibility → preview/export**, with the OCR engine shipped inside the app and no network at runtime.

### 1. A real OCR engine, not a seam

| | |
|---|---|
| Detection | PP-OCRv5 mobile DB, ONNX, 4,826,518 B, `sha256 a4319856…` |
| Recognition | PP-OCRv5 mobile **Arabic**, ONNX, 7,998,947 B, `sha256 799113eb…` |
| Source | `PaddlePaddle/PP-OCRv5_mobile_det_onnx@e6f4fa85`, `PaddlePaddle/arabic_PP-OCRv5_mobile_rec_onnx@14aaedcd` |
| Licence | Apache-2.0 (weights and runtime), licence bundled in `assets/legal/` |
| Runtime | `flutter_onnxruntime` — already a dependency for the boundary models, so **no new dependency** |
| Platforms | Android and Windows, same engine, same weights |
| Network | none at runtime; weights are fetched at build time by `tool/fetch_ocr_models.py`, which verifies **size and SHA-256** and writes atomically |
| Scripts | Arabic + Latin + digits, 747-character dictionary committed (`assets/ocr/ppocrv5_arabic_dict.txt`) |

Tensors and post-processing follow the exported `inference.yml` exactly: long side 960 / stride 32 / BGR / ImageNet normalisation for detection, DB thresholds 0.3 / 0.6 / unclip 1.5, 48 px recognition height with `v/127.5 − 1`, greedy CTC over `blank + dictionary + space`.

Work is bounded and honest: 32 lines and a 25 s budget per document, cancellation is the only thrown exception, and every failure becomes an explicit `unavailable` with a safe reason (`model-unavailable`, `engine-failure`, `time-budget-exceeded`). A missing model is never reported as "no text", and a low-confidence line is dropped rather than guessed.

### 2. Classification uses evidence, never one common word

* Kind is inferred from **text read off the image**, matched as keyword anchors on **two different lines**, anchors shorter than three characters are ignored, and matching works in logical order **and** right-to-left visual order.
* Geometry/aspect is a single weak signal (weight 0.2 in the second fusion stage); detection quality and classification are kept separate from geometry confidence.
* Below threshold the kind stays `unknown` and the user decides; an automatic result never overwrites a confirmed manual choice.

### 3. Size catalog with provenance

New `documentSizeRecords` is the single source of truth and `presetStatusFor` is derived from it, so the externally visible statuses are unchanged:

| Kind | Provenance | Source |
|---|---|---|
| `unifiedNationalId` | documented | ISO/IEC 7810 ID-1 |
| `passport` | documented | ICAO Doc 9303 TD3 |
| `residenceCard` | estimated | **no published size found (2026-11-04)** — not auto-confirmable |
| `rationCard` | estimated | **no published size found (2026-11-04)** — not auto-confirmable |
| `civilStatusId` | missing | no size at all; fields stay empty until the user measures |

`docs/PHYSICAL_SIZES.md` records source, reference, unit, verification date and documentation status for each, plus what was searched and not found. No size was invented, and the civil-status record deliberately has no dimensions.

### 4. Shipped policy

`main.dart` composes the engine **and** enables the pipeline (`smartRecognitionEnabled: appSmartRecognitionEnabled`). The host/test default stays `false`, so every pre-existing suite keeps the precondition it was written against, and `tool/check_detector_retirement.py` now fails if the composition root stops enabling recognition.

### 5. Gates that make this auditable later

* `tool/check_detector_retirement.py` allowlists **every** ONNX weight by byte length and SHA-256 (not just DocAligner), pins the OCR dictionary digest, and asserts the engine contract (isolate use, DB decode, CTC decode, no network in the adapters, engine wired in `main.dart`, real inference executed in CI).
* `tool/format_report.py` publishes the formatter's own diff as check-run annotations; `tool/ci_gate.py` now forwards nested gate annotations first, so a failure is diagnosable from the API alone.

## Evidence on `cdb663b`

| Check | Result |
|---|---|
| `android` job — `dart format`, `flutter analyze`, **all Flutter tests**, APK build, instrumentation, signing | **pass** (18m59s) |
| `windows / windows` — build, native scaler regressions, DocQuad ONNX inference, **real PP-OCRv5 inference**, portable ZIP | **pass** (6m39s) |
| `Android debug/diagnostic differential` | **pass** |
| Declared test inventory | **1017** Dart/Flutter tests (`tool/check_source.py`) |
| Model digests | verified on every run, on every platform |

New tests in this PR: DB box decoding (11), detection/recognition tensors (9), CTC + dictionary decoding (12), engine contract with a fake runtime (9), evidence/classifier ordering and anchor floor, size provenance (7), CER/WER/precision/recall/F1 metrics (13), and `integration_test/ocr_inference_test.dart`, which **runs both real models on Windows** and asserts Latin text, Arabic letters and determinism.

## What is proven, and what is not

**Proven:** the weights download and verify; ONNX Runtime loads them on Windows and Android; the full Dart path from image bytes to `OcrTextResult` works; the Arabic model emits Arabic script; the deterministic stages (DB, CTC, tensors, dictionary) are covered by unit tests; format, analyze and all tests pass; the label/QA/size/eligibility/export chain still passes its regression suites.

**Not proven — and not claimed anywhere in the docs or UI:**

1. **Arabic reading accuracy on real Iraqi documents.** There is no corpus of real cards with independently verified reference text that we are allowed to use, so **no CER/WER, recall or confidence is published**. The CI pages are drawn with the system font; they prove the graph runs and produces Arabic, not that it reads a photographed card with glare, shadow, compression and security printing.
2. **Field-level extraction** (names, numbers, dates) — same reason.
3. **On-device latency and memory** — unmeasured.
4. **Classification accuracy per kind** — the metric harness exists (`lib/domain/ocr_metrics.dart`), the dataset does not.
5. **Residence / ration card dimensions** — the current values are placeholders and are labelled `estimated` everywhere; nothing uses them to auto-confirm a size.
6. **`civilStatusId` size** — intentionally absent; the user measures it.

`docs/OCR_ENGINE.md` §7 documents exactly how to close gaps 1–4 once a permitted dataset exists.

## Consequential decisions recorded

* Auto-confirmation of a size still requires a **documented standard** (or a user measurement) **plus** an aspect match, so an estimated size can never be silently trusted.
* Manual confirmed sizes, kind re-selection, `other` defaults on the crop path, and manual polygons are untouched; `Project.schemaVersion` stays 5.
* The legacy `UnavailableOcrEngine` is still the default for hosts and tests; it reports `unavailable`, never "no text".
* No release is created by this PR.

🤖 Generated with [Arena.ai](https://arena.ai) Agent Mode
