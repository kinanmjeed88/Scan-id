/// Offline OCR engine contract (ADR-007: OCR is evidence, never the sole
/// classifier; ADR-005: strictly offline).
///
/// No OCR engine ships in this build. The evaluated candidate (PaddleOCR
/// PP-OCRv5 Arabic mobile, `arabic_PP-OCRv5_mobile_rec`) requires a native
/// inference runtime per platform (Android ABI builds + Windows x64), model
/// packaging of tens of megabytes, and a licensing/performance review on
/// both targets — none of which can be verified safely in this phase (see
/// docs/RECOGNITION.md §6). Rather than compromise the Windows target or
/// bundle an unverified native dependency, the production pipeline runs
/// against this abstraction with [UnavailableOcrEngine]: OCR unavailability
/// is an explicit, non-fatal state and classification continues from the
/// remaining evidence sources.
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
