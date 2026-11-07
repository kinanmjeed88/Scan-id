/// Offline OCR engine contract. The application composition root supplies the
/// local PP-OCRv5 engine; other hosts can use [UnavailableOcrEngine], and a
/// missing model remains an explicit, non-fatal state. OCR keyword evidence is
/// not a calibrated probability of document type, and recognized text is not
/// persisted. Without class evidence, classification remains unknown.
library;

import 'dart:typed_data';

import '../domain/ocr_evidence.dart';
import 'cancellation.dart';

abstract interface class OcrEngine {
  /// Stable engine identifier recorded in provenance/model versions.
  String get version;

  /// Whether a local OCR backend is configured. False lets the pipeline avoid
  /// decoding/cropping another image only to report unavailability.
  bool get isEnabled;

  /// Recognizes text from the bytes provided by the pipeline (an isolated crop
  /// when safe, or the full preview for a single-image fallback). Ordinary
  /// recognition failure is reported as an unavailable/empty result; only
  /// [OperationCancelled] propagates. Callers must not persist recognized text.
  Future<OcrTextResult> recognize(
    Uint8List imageBytes, {
    CancellationToken? token,
  });
}

/// Default for hosts that do not configure OCR. Deterministic and honest — it
/// never fabricates text or confidence; the app supplies its own local engine.
class UnavailableOcrEngine implements OcrEngine {
  const UnavailableOcrEngine();

  @override
  String get version => 'ocr-unavailable-1';

  @override
  bool get isEnabled => false;

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
