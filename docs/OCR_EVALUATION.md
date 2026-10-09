# OCR evaluation — Scan ID

**Status: no OCR engine ships in this build. This document records why, and
what would have to be true before one can.**

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

### 2. Tesseract 5 (LSTM) — **viable but not chosen**

| | |
|---|---|
| Arabic | Yes, `ara.traineddata` ships in the standard tessdata sets |
| Licence | Apache-2.0 ([tesseract][tess-license]) |
| Offline | Yes, fully CPU |
| Android | C++ NDK build required; the Flutter wrappers on pub.dev are unmaintained |
| Windows | Official community builds exist (UB Mannheim) |
| Accuracy | Vendor/secondary reporting puts Arabic at roughly 90–96 % on clean 300 DPI print, below its Latin figures; right-to-left scripts "occasionally come out reordered" ([tesseractocr.org][tess-bench], [engine comparison][tess-cmp]) |
| Size | `ara.traineddata` is a single-digit-to-low-tens MB file depending on the `tessdata` / `tessdata_fast` / `tessdata_best` variant |

Apache-2.0 and genuinely offline, so it is not disqualified. It is not chosen
because the Flutter/Android integration is unmaintained, the two-platform
packaging work is unverified here, and its reported Arabic accuracy is the
weakest of the viable options.

### 3. PaddleOCR PP-OCRv5 Arabic — **the recommended candidate, not yet shippable**

| | |
|---|---|
| Arabic | Yes — a dedicated multilingual model, `arabic_PP-OCRv5_mobile_rec` |
| Licence | Apache-2.0 ([PaddlePaddle/PaddleOCR][paddle-license]) |
| Model size | ONNX: `PP-OCRv5_mobile_det.onnx` 4,766,440 B (≈4.5 MiB) + `arabic_PP-OCRv5_mobile_rec.onnx` 7,994,035 B (≈7.6 MiB) ≈ **12.2 MiB** total, plus a 2.4 KB dictionary ([ONNX export][onnx-hf]; [model table][oar-models]) |
| Runtime | Paddle Inference **or** ONNX Runtime; PaddleOCR 3.2.0 (2025-08-21) added a full C++ local deployment path for **Windows** with parity to the Python implementation ([release notes][paddle-rel]) |
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

**No OCR engine is integrated.** The most promising route is ONNX Runtime
Mobile/Desktop plus the PP-OCRv5 Arabic detection and recognition models
(~12.2 MiB of ONNX weights) behind the existing `OcrEngine` interface — but it
is not shippable on the evidence available here, because:

1. **No Arabic accuracy figure is published for the candidate model.** Arabic
   is a cursive, right-to-left script with contextual shaping and ligatures;
   a benchmark measured on Chinese/English text cannot be transferred to Iraqi
   civil documents. There is no real, representative Iraqi document dataset in
   this repository to measure against.
2. **No native runtime has been exercised on either target.** Adding one means
   an Android ABI matrix, a Windows x64 build, a memory budget on a mid-range
   phone, and a cold-start measurement — none of which can be verified from
   this environment (see "Local verification limits" below).
3. **Bundling an unverified native runtime is exactly the failure mode
   ADR-005 and ADR-006 exist to prevent.** ADR-007 makes OCR evidence *optional*:
   classification already continues from geometry, aspect, structure and
   filename evidence, and an unavailable engine is a non-fatal state.

The abstraction stays honest: `UnavailableOcrEngine` is explicit, versioned and
recorded in provenance (`modelVersions['ocr']`), so a later engine drop changes
one implementation and nothing else.

## What must happen before an engine is adopted

1. A new ADR covering runtime choice, ABI matrix, model provenance and hashes,
   licence review, size budget and the build-time-fetch question.
2. A representative, licensed Iraqi document test set (the four catalog
   categories, front and back, several capture qualities) held outside the
   repository.
3. Measured on-device numbers on the lowest supported Android device and on
   Windows x64: Arabic character/word error rate on *label anchor fields only*
   (ADR-007 forbids extracting or persisting personal values), peak memory,
   cold and warm latency per document.
4. Confirmation that OCR evidence only ever enters the classifier as evidence
   and never becomes the sole classifier.

## Local verification limits

This evaluation was produced without a Dart/Flutter SDK in the authoring
environment (the Flutter/Dart download host is not reachable from it), so no
option was benchmarked locally. Every figure above is cited from the upstream
sources linked below; none is a measurement made in this repository.

[mlkit-langs]: https://developers.google.com/ml-kit/vision/text-recognition/v2/languages
[mlkit-arabic]: https://www.b4x.com/android/forum/threads/textrecognition-based-on-mlkit-will-it-support-arabic.161926/
[tess-license]: https://github.com/tesseract-ocr/tesseract
[tess-bench]: https://tesseractocr.org/
[tess-cmp]: https://ghtrends.dev/tesseract-ocr/tesseract/
[paddle-license]: https://github.com/PaddlePaddle/PaddleOCR
[onnx-hf]: https://huggingface.co/vladadu/pp-ocrv5-arabic-mobile-onnx
[oar-models]: https://github.com/GreatV/oar-ocr/blob/main/docs/models.md
[paddle-rel]: https://github.com/PaddlePaddle/PaddleOCR/releases
[ort-flutter]: https://github.com/masicai/flutter_onnxruntime
[ort-mobile]: https://onnxruntime.ai/docs/tutorials/mobile/
