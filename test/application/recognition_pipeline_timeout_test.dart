import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/application/ocr_engine.dart';
import 'package:scan_id/application/recognition_pipeline.dart';
import 'package:scan_id/application/recognition_worker.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/ocr_evidence.dart';

/// Reported failure: the import reached «تحليل الصور» and stopped at `0 / 1`.
///
/// The pipeline must always produce an analysis. An OCR engine that never
/// answers is the case that used to hang, because the engine call was awaited
/// with no bound at all.
class _StalledOcrEngine implements OcrEngine {
  final Completer<OcrTextResult> _never = Completer<OcrTextResult>();

  @override
  String get version => 'ocr-stalled-1';

  @override
  bool get isEnabled => true;

  @override
  Future<OcrTextResult> recognize(
    Uint8List imageBytes, {
    CancellationToken? token,
  }) => _never.future;
}

Uint8List _preview() {
  final image = img.Image(width: 60, height: 40);
  img.fill(image, color: img.ColorRgb8(250, 250, 250));
  return Uint8List.fromList(img.encodePng(image));
}

Future<ImageAnalysis> _analyzeWith(
  OcrEngine engine, {
  required Duration budget,
}) {
  final pipeline = RecognitionPipeline(
    suggestSingle: (_) async => null,
    ocr: engine,
    ocrBudget: budget,
  );
  return pipeline.analyze(
    PipelineImageInput(
      assetId: 'asset-stall',
      previewBytes: _preview(),
      sourceWidth: 60,
      sourceHeight: 40,
      importIndex: 0,
    ),
  );
}

void main() {
  test('a stalled OCR engine cannot hold the analysis open', () async {
    final stopwatch = Stopwatch()..start();
    final analysis = await _analyzeWith(
      _StalledOcrEngine(),
      budget: const Duration(milliseconds: 60),
    );
    stopwatch.stop();

    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)));
    expect(analysis.detections, hasLength(1));
    expect(
      analysis.detections.single.classification.kind,
      DocumentKind.unknown,
      reason: 'no text means no evidence and no automatic kind',
    );
    expect(
      analysis.issues.any(
        (issue) => issue.category == RecognitionErrorCategory.ocrFailure,
      ),
      isTrue,
      reason: 'the timeout is reported instead of being silent',
    );
  });

  test('the analysis still ends when the OCR stage throws', () async {
    final analysis = await _analyzeWith(
      _ThrowingOcrEngine(),
      budget: const Duration(seconds: 5),
    );

    expect(analysis.detections, hasLength(1));
    expect(
      analysis.detections.single.classification.kind,
      DocumentKind.unknown,
    );
    expect(
      analysis.issues.any(
        (issue) => issue.category == RecognitionErrorCategory.ocrFailure,
      ),
      isTrue,
    );
  });
}

class _ThrowingOcrEngine implements OcrEngine {
  @override
  String get version => 'ocr-throwing-1';

  @override
  bool get isEnabled => true;

  @override
  Future<OcrTextResult> recognize(
    Uint8List imageBytes, {
    CancellationToken? token,
  }) async => throw StateError('synthetic engine failure');
}
