import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_explanation.dart';

DocumentRecord record({
  double? boundary,
  double? classification,
  double? finalValue,
  List<String> boundaryDiagnostics = const [],
  RecognitionStatus status = RecognitionStatus.recognized,
}) => DocumentRecord(
  id: 'doc-a',
  sourceImageId: 'asset1',
  sides: [
    DocumentSide(
      id: 'side-a',
      side: SideKind.unknown,
      processedAsset: ProcessedAssetRef(
        workingPath: 'projects/p/assets/a/working.png',
        thumbnailPath: 'projects/p/assets/a/thumb.jpg',
        width: 856,
        height: 540,
      ),
      detection: boundary == null
          ? null
          : DetectionRef(
              boundaryDiagnostics: boundaryDiagnostics,
              detectionId: 'asset1-d0',
              producer: 'test',
              version: '1',
              detectionConfidence: Confidence(value: boundary),
            ),
    ),
  ],
  recognition: RecognitionResult(
    documentKind: DocumentKind.unknown,
    status: status,
    confidences: ConfidenceSet(
      classification: classification == null
          ? null
          : Confidence(value: classification),
      finalConfidence: finalValue == null
          ? null
          : Confidence(value: finalValue),
    ),
    preset: const PresetSelection.awaiting(),
  ),
  pairing: PairingState.single,
  provenance: Provenance(
    sourceImageId: 'asset1',
    detectionIds: const ['asset1-d0'],
    processedAssetVersion: 'v1',
    pipelineVersion: 'v1',
  ),
);

void main() {
  test(
    'persisted measured failure is not replaced by a primary score verdict',
    () {
      final source = record(
        boundary: .764,
        classification: .60,
        finalValue: .99,
        boundaryDiagnostics: [
          'اختلف كاشفا الذكاء الاصطناعي على مواضع الزوايا.',
        ],
      );
      final restored = DocumentRecord.fromJson(source.toJson());
      final reasons = recognitionFailureReasons(
        restored,
        hasUsableSuggestion: true,
      ).join(' ');
      expect(reasons, contains('اختلف كاشفا'));
      expect(reasons, isNot(contains('أقل من حد القبول')));
      expect(reasons, isNot(contains('99.0')));
      expect(reasons, contains('ليست إذناً تلقائياً'));
    },
  );

  test(
    'an image that was never analysed says so, without inventing a cause',
    () {
      final reasons = recognitionFailureReasons(
        null,
        hasUsableSuggestion: false,
      );
      expect(reasons.join(' '), contains('لم تُجرَ عملية تعرّف'));
      expect(reasons.join(' '), contains('حدّد الزوايا الأربع'));
    },
  );

  test('the recorded low boundary score is quoted with the 55% threshold', () {
    final reasons = recognitionFailureReasons(
      record(boundary: .46, classification: null, finalValue: .614),
      hasUsableSuggestion: false,
    );
    final text = reasons.join(' ');
    expect(text, contains('46.0٪'));
    expect(text, contains('55٪'));
    expect(text, contains('ليست ضماناً للدقة'));
    expect(text, isNot(contains('61.4٪')));
    expect(text, isNot(contains('الدرجة الإجمالية')));
  });

  test('missing OCR evidence is named as the real classification cause', () {
    final reasons = recognitionFailureReasons(
      record(boundary: .46),
      hasUsableSuggestion: true,
    );
    final text = reasons.join(' ');
    expect(text, contains('لم يُقرأ نص كافٍ'));
    expect(text, contains('لا يخمّن النوع'));
    expect(text, contains('ليست إذناً تلقائياً'));
  });

  test('uncertain classification is explained explicitly', () {
    final reasons = recognitionFailureReasons(
      record(status: RecognitionStatus.uncertain, boundary: .8),
      hasUsableSuggestion: false,
    );
    expect(reasons.join(' '), contains('تعارضت أدلة التصنيف'));
  });

  test('a missing boundary score is an absence, never a fabricated zero', () {
    final reasons = recognitionFailureReasons(
      record(classification: .9, finalValue: .9),
      hasUsableSuggestion: false,
    );
    expect(reasons.join(' '), contains('غير متاحة'));
    expect(reasons.join(' '), isNot(contains('0.0٪')));
  });
}
