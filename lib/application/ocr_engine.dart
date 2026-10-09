/// Offline OCR engine contract (ADR-007: OCR is evidence, never the sole
/// classifier; ADR-005: strictly offline).
///
/// **No OCR engine ships in this build. Do not describe this app as having
/// OCR.**
///
/// The full option evaluation — ML Kit, Tesseract 5, PaddleOCR PP-OCRv5
/// Arabic, ONNX Runtime, Windows.Media.Ocr — with licences, model sizes and
/// what must be measured before any engine is adopted, is recorded in
/// `docs/OCR_EVALUATION.md` (summary in `docs/RECOGNITION.md` §6). The
/// leading candidate, PaddleOCR PP-OCRv5 Arabic mobile
/// (`arabic_PP-OCRv5_mobile_rec`), needs a native inference runtime per
/// platform (Android ABIs + Windows x64), ~12 MiB of bundled ONNX weights and
/// an on-device benchmark that does not exist yet: no Arabic accuracy figure
/// is published for it, and there is no representative Iraqi document set in
/// this repository to measure one against.
///
/// Rather than compromise the Windows target or bundle an unverified native
/// dependency, the production pipeline runs against this abstraction with
/// [UnavailableOcrEngine]: OCR unavailability is an explicit, non-fatal state
/// and classification continues from the remaining evidence sources.
library;

import 'dart:typed_data';

import '../domain/ocr_evidence.dart';
import 'cancellation.dart';

abstract interface class OcrEngine {
  /// Stable engine identifier recorded in provenance/model versions.
  String get version;

  /// Recognizes text on a processed document image. Must never throw for
  /// ordinary recognition failure — it reports an unavailable/empty result;
  /// only [OperationCancelled] propagates.
  Future<OcrTextResult> recognize(
    Uint8List imageBytes, {
    CancellationToken? token,
  });
}

/// The shipped default: OCR is not available on this build. Deterministic,
/// allocation-free, and honest — it never fabricates text or confidence.
class UnavailableOcrEngine implements OcrEngine {
  const UnavailableOcrEngine();

  @override
  String get version => 'ocr-unavailable-1';

  @override
  Future<OcrTextResult> recognize(
    Uint8List imageBytes, {
    CancellationToken? token,
  }) async {
    token?.throwIfCancelled();
    return OcrTextResult.unavailable(
      unavailableReason: 'no-offline-engine-packaged',
      engineVersion: version,
    );
  }
}
