# OCR evaluation — Scan ID

**Status (2026-10-26): no OCR engine ships in this build. This document records
why, and what would have to be true before one can.**
**Source revision audited:** `d142e85ab927e7c5503c61c9b105216409d1e69a` on `arena/84234269-scan-id`; GitHub Actions run `40335966175` built/tested Android and Windows successfully, but contains no OCR runtime or CER/WER test.

The current classifier does not infer document kind from filenames, paths,
image dimensions, or boundary aspect. With `UnavailableOcrEngine`, it receives
no independent kind evidence and returns `unknown`; boundary analysis remains
independent. The historical classification policy described in older reports
is superseded by the explicit-evidence implementation.

The abstraction in `lib/application/ocr_engine.dart` is deliberately honest:
the production pipeline runs against `UnavailableOcrEngine`, whose version
string is `ocr-unavailable-1` and which reports an explicit, non-fatal
unavailable state. Nothing in this repository claims OCR capability.

Related locked decisions: ADR-005 (offline-first, no runtime model download),
ADR-007 (OCR is evidence, never the sole classifier), ADR-006 (classical CV
first).

## What the engine would have to satisfy

| Requirement | Why |
|---|---|
| Arabic text recognition | Iraqi national ID, residence card, ration card and passport are Arabic-first documents |
| Android (arm64, and armv7 while it is still shipped) | primary target |
| Windows x64 | primary target |
| Fully offline execution | ADR-005; the release Android manifest declares no INTERNET permission |
| Permissive, reviewable licence | bundled and shipped in a binary |
| Model size acceptable for a mobile app | download and on-device footprint |
| CPU-only inference within a phone memory budget | no GPU assumption |
| One engine for both platforms | two engines means two accuracy profiles for the same document |
| Maintainable packaging | no build-time network fetch that breaks reproducible builds |

## Options evaluated

### 1. ML Kit Text Recognition v2 (Google) — **rejected**

- **Arabic: not supported.** The API recognises *scripts*, not languages, and
  the supported set is Latin, Chinese, Devanagari, Japanese and Korean
  ([supported languages][mlkit-langs]; [community confirmation][mlkit-arabic]).
- **Windows: not available.** The SDK is Android/iOS only.
- Requires Google Play Services, which conflicts with the offline, no-GMS
  posture of this app.

Disqualified on the first two counts — it cannot serve the product at all.

### 2. Tesseract 5 (LSTM) — **Android candidate; shared Android/Windows integration not adopted**

| | |
|---|---|
| Arabic | Yes; official `ara.traineddata` is available |
| Licence | Apache-2.0 ([Tesseract][tess-license]; `tessdata_fast` is separately Apache-2.0) |
| Offline | Yes, CPU inference; model files can be bundled |
| Android | `adaptech-cz/Tesseract4Android` 4.9.0 is an actively maintained Android library (Tesseract 5.5.1, Android API 21+) ([tag source][tesseract4android]), but its published dependency is built through JitPack. It is not itself a Flutter plugin, and this repository has not built or measured it. |
| Windows | No shared Windows Flutter package was verified. The community Flutter package [`flusseract` 0.1.3][flusseract] declares Windows, but its CMake non-Android path searches `/usr/local/lib` for pre-installed Tesseract/Leptonica, and its Android Gradle module sets `minSdkVersion 31`; it is not a drop-in solution for this app's Android support range or a verified Windows build. |
| Model size | The official [`tessdata_fast`][tessdata-fast] Arabic model is 1,432,056 bytes and English is 4,113,088 bytes. No model was added to the app. |
| Project accuracy/latency | **Not measured.** There is no adjudicated Arabic/Latin OCR reference set and neither target engine was run. General OCR percentages from unrelated datasets are not transferable and are deliberately not used as evidence. |

Tesseract remains a credible Android-only research candidate, not a selected
product engine. Pairing it with `Windows.Media.Ocr` would create two different
recognizers and accuracy profiles; parity and confidence calibration have not
been measured. The available Flutter bridges either omit Windows or have
unverified build/minimum-SDK constraints. We therefore keep
`UnavailableOcrEngine` rather than claim cross-platform OCR or add an unbuilt
native dependency. Source review is not a build test.

### 3. PaddleOCR PP-OCRv5 Arabic — **a research candidate only; not selected or shippable**

| | |
|---|---|
| Arabic | Yes — a dedicated multilingual model, `arabic_PP-OCRv5_mobile_rec` |
| Licence | Apache-2.0 ([PaddlePaddle/PaddleOCR][paddle-license]) |
| Model size | A third-party ONNX export reports `PP-OCRv5_mobile_det.onnx` 4,766,440 B + `arabic_PP-OCRv5_mobile_rec.onnx` 7,994,035 B (about 12.2 MiB total) plus a small dictionary ([ONNX export][onnx-hf]; [model table][oar-models]). These artifacts were not downloaded, hash-pinned, license-checked individually, or validated in this repository. |
| Runtime | Paddle Inference **or** ONNX Runtime; PaddleOCR 3.2.0 added a C++ local deployment path for **Windows** ([release notes][paddle-rel]). A matching Android ABI/package path and parity on the two application targets were not verified. |
| Offline | Yes — models are bundled artefacts, never fetched at runtime |
| Accuracy | PaddleOCR publishes 81.29 % average accuracy for `PP-OCRv5_mobile_rec`, but that figure is for the general (Chinese/English) model. **No Arabic benchmark was found.** This is a real gap, not a detail. |

### 4. ONNX Runtime as the shared runtime

`flutter_onnxruntime` (MIT, verified publisher) wraps ONNX Runtime 1.28.0 on
Android (Maven `onnxruntime-android`) and 1.28.3 on Windows/Linux
([README][ort-flutter]).

- Pre-built Android AAR is ~24.4 MB; a model-specific custom build drops it to
  ~7.5 MB (arm64 `.so` 16.3 MB → 3.96 MB) ([ONNX Runtime mobile][ort-mobile]).
- **Caveat for ADR-005:** the plugin downloads the native libraries from
  official repositories *at install/build time*. That does not break runtime
  offline operation, but it does make the build depend on network access, which
  affects reproducible and air-gapped builds and must be reviewed explicitly.

### 5. Windows.Media.Ocr (built into Windows 10/11)

Supports Arabic through a language pack, offline, with zero added app size.
**Rejected as the primary engine**: Android has no equivalent, so using it
would mean two engines with two accuracy profiles for the same Iraqi document —
which is worse for the user than having no OCR and saying so.

## Decision

**No OCR engine is integrated or selected.** ONNX Runtime plus a PP-OCRv5
Arabic detection/recognition export is one research route behind the existing
`OcrEngine` interface; the approximately 12.2 MiB size is a third-party report,
not a verified project artifact. It is not shippable on the evidence available
here, because:

1. **No suitable Arabic accuracy figure is published for the candidate model.** Arabic
   is a cursive, right-to-left script with contextual shaping and ligatures;
   a benchmark measured on Chinese/English text cannot be transferred to Iraqi
   civil documents. A small local-only sample exists under `Mostmskat/`, but it
   has no independently reviewed OCR transcriptions, no session-separated
   evaluation split, and no permission to send its pixels or text to CI/services.
   It cannot support an Arabic OCR accuracy claim.
2. **No OCR runtime has been exercised on either target.** The existing
   document detector uses a small custom pure-Dart ONNX runtime, but its operator
   set was implemented for ScanIdDocNet and is not proven to run OCR graphs.
   Reusing it or adding a native/runtime package requires an Android ABI matrix,
   a Windows x64 build, a phone memory budget, and cold-start measurements —
   none of which can be verified from this environment.
3. **Bundling an unverified native runtime is exactly the failure mode
   ADR-005 and ADR-006 exist to prevent.** ADR-007 makes OCR evidence *optional*:
   boundary and geometry analysis continue, but absent independent kind evidence
   the classifier returns `unknown`. Filename, aspect, and pixel dimensions do
   not substitute for OCR or a validated visual classifier.

The abstraction stays honest: `UnavailableOcrEngine` is explicit, versioned and
recorded in provenance (`modelVersions['ocr']`), so a later engine drop changes
one implementation and nothing else.

## Local-only work performed on 2026-10-25

A separate boundary-pipeline behavior screen read the 19 still JPEGs in the
local `Mostmskat/` directory after EXIF normalization. It deliberately did not
read OCR text, the video, or the `.scanid` backup, and it does not evaluate OCR.
The run completed on the Python ONNX mirror; with no independent labels it is
not an accuracy benchmark and says nothing about CER/WER. Its aggregate-only
method and limits are documented in
[`scan-id-local-evaluation-2026-10-25.md`](reports/scan-id-local-evaluation-2026-10-25.md).
The still-image directory is excluded from all GitHub Actions checkouts using
sparse partial checkout; CI also checks that exclusion rule. No image, text,
per-image outcome, OCR model, or OCR output was added to CI or this report. As of 2026-10-26 the 21 files under `Mostmskat/` remain on the authorized local disk but are removed from the current index and ignored. Their prior Git history (including the base branch) is not erased by the tip deletion; no history rewrite or public purge was attempted.

A second local screen on 2026-10-26 processed the same 19 still images for
boundary behavior only: zero decode/inference errors, no OCR engine call, and no
text read or saved. It is not an OCR evaluation; the aggregate boundary results
and limits are in [`MODEL_EVALUATION.md`](reports/MODEL_EVALUATION.md).

The existing OCR-evidence unit tests use synthetic fixed strings only to test
normalization and keyword-rule behavior. They are not image-derived transcripts,
reference text, or an OCR accuracy dataset; they do not support CER/WER.

## Local reference audit (2026-10-26)

The local `.scanid` container was inspected through its header and manifest only;
image payloads and personal text were not extracted or printed. Its project
metadata has no reference/transcript/OCR fields. No authorized Arabic/Latin
transcription set was found in the repository paths inventoried. Therefore no
CER/WER was computed. The local annotation studio can hold a manually verified full transcript in a
private JSON export; no such transcripts have been created or reviewed yet. The
protocol for double transcription, adjudication, privacy, normalization and
acceptance criteria is in [`LOCAL_EVALUATION_PROTOCOL.md`](LOCAL_EVALUATION_PROTOCOL.md).
This tooling does not provide an OCR engine or evidence that labels exist.

## What must happen before an engine is adopted

1. A new ADR covering runtime choice, ABI matrix, model provenance and hashes,
   licence review, size budget and the build-time-fetch question.
2. A representative, licensed Iraqi document test set (the four catalog
   categories, front and back, several capture qualities) with independent,
   reviewed OCR references and session-separated splits. The unlabelled local
   sample is not an OCR benchmark and must remain outside CI and external services.
3. Measured on-device numbers on the lowest supported Android device and on
   Windows x64: Arabic character/word error rate on *label anchor fields only*
   (ADR-007 forbids extracting or persisting personal values), peak memory,
   cold and warm latency per document.
4. Confirmation that OCR evidence only ever enters the classifier as evidence
   and never becomes the sole classifier.

## Local verification limits

No OCR option was benchmarked in this environment: Dart/Flutter is unavailable,
and no Arabic/Latin OCR references are labeled. Figures in the option tables
are source-reported, not project measurements. The local boundary behavior
screen above is not an OCR run and cannot produce CER/WER.

[mlkit-langs]: https://developers.google.com/ml-kit/vision/text-recognition/v2/languages
[mlkit-arabic]: https://www.b4x.com/android/forum/threads/textrecognition-based-on-mlkit-will-it-support-arabic.161926/
[tess-license]: https://github.com/tesseract-ocr/tesseract
[tessdata-fast]: https://github.com/tesseract-ocr/tessdata_fast
[tesseract4android]: https://github.com/adaptech-cz/Tesseract4Android/tree/4.9.0
[flusseract]: https://github.com/letterassist-ai/flusseract/tree/10cf98c63063c9e70a17dc370edc58023d3083b8
[paddle-license]: https://github.com/PaddlePaddle/PaddleOCR
[onnx-hf]: https://huggingface.co/vladadu/pp-ocrv5-arabic-mobile-onnx
[oar-models]: https://github.com/GreatV/oar-ocr/blob/main/docs/models.md
[paddle-rel]: https://github.com/PaddlePaddle/PaddleOCR/releases
[ort-flutter]: https://github.com/masicai/flutter_onnxruntime
[ort-mobile]: https://onnxruntime.ai/docs/tutorials/mobile/
