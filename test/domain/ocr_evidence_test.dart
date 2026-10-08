import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/ocr_evidence.dart';

void main() {
  test('unavailable OCR yields no evidence and no confidence', () {
    final result = OcrTextResult.unavailable(
      unavailableReason: 'no-offline-engine-packaged',
      engineVersion: 'ocr-unavailable-1',
    );
    expect(result.isAvailable, isFalse);
    expect(result.confidence, isNull, reason: 'absence, not zero');
    expect(ocrKeywordEvidence(result), isEmpty);
  });

  test('empty available result has null confidence', () {
    final result = OcrTextResult.available(
      lines: const [],
      engineVersion: 'test-1',
    );
    expect(result.confidence, isNull);
    expect(ocrKeywordEvidence(result), isEmpty);
  });

  test('keyword anchors match with Arabic normalization', () {
    final result = OcrTextResult.available(
      lines: [
        // ة vs ه, diacritics and spacing must not matter.
        OcrLine(text: 'البطاقة الوطنية', confidence: .82),
        OcrLine(text: 'جُمهورِية العِراق', confidence: .9),
      ],
      engineVersion: 'test-1',
    );
    final evidence = ocrKeywordEvidence(result);
    expect(
      evidence.map((e) => e.kind),
      containsAll([DocumentKind.unifiedNationalId, DocumentKind.passport]),
    );
  });

  test('best line per kind wins; text itself never leaks', () {
    final result = OcrTextResult.available(
      lines: [
        OcrLine(text: 'passport', confidence: .4),
        OcrLine(text: 'جواز سفر', confidence: .75),
      ],
      engineVersion: 'test-1',
    );
    final evidence = ocrKeywordEvidence(result);
    expect(evidence, hasLength(1));
    expect(evidence.single.kind, DocumentKind.passport);
    expect(evidence.single.score, .75);
  });

  test('mean line confidence over available lines', () {
    final result = OcrTextResult.available(
      lines: [
        OcrLine(text: 'أ', confidence: .5),
        OcrLine(text: 'ب', confidence: .9),
      ],
      engineVersion: 'test-1',
    );
    expect(result.confidence, closeTo(.7, 1e-9));
  });

  test('line and keyword scores are validated to 0..1', () {
    expect(
      () => OcrLine(text: 'x', confidence: 1.2),
      throwsA(isA<Exception>()),
    );
    expect(
      () => OcrKeywordEvidence(kind: DocumentKind.passport, score: -0.1),
      throwsA(isA<Exception>()),
    );
  });

  test('unrelated text produces nothing', () {
    final result = OcrTextResult.available(
      lines: [OcrLine(text: 'مرحبا بالعالم', confidence: .99)],
      engineVersion: 'test-1',
    );
    expect(ocrKeywordEvidence(result), isEmpty);
  });
}
