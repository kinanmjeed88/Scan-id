import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/ocr_evidence.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_classifier.dart';
import 'package:scan_id/domain/recognition_routing.dart';

void main() {
  test(
    'no independent class evidence stays unknown despite geometry scores',
    () {
      final outcome = classifyDocument(
        const ClassificationInput(
          geometryConfidence: .95,
          detectionConfidence: .8,
        ),
      );
      expect(outcome.kind, DocumentKind.unknown);
      expect(outcome.status, RecognitionStatus.unknown);
      expect(outcome.evidence, isEmpty);
      expect(outcome.confidences.classification, isNull);
      expect(outcome.candidates, isEmpty);
    },
  );

  test('OCR keywords can suggest a kind but cannot auto-accept it alone', () {
    final outcome = classifyDocument(
      ClassificationInput(
        ocrKeywords: [
          OcrKeywordEvidence(kind: DocumentKind.unifiedNationalId, score: .8),
        ],
        ocrConfidence: .8,
      ),
    );
    expect(outcome.kind, DocumentKind.unifiedNationalId);
    expect(outcome.evidence.map((e) => e.kind), ['ocr-keyword']);
    expect(outcome.confidences.ocr?.value, .8);
    expect(outcome.confidences.classification?.value, .8);
    expect(outcome.routing.band, isNot(RecognitionBand.autoCandidate));
  });

  test('no evidence at all stays unknown with empty evidence', () {
    final outcome = classifyDocument(const ClassificationInput());
    expect(outcome.kind, DocumentKind.unknown);
    expect(outcome.status, RecognitionStatus.unknown);
    expect(outcome.evidence, isEmpty);
    expect(outcome.confidences.classification, isNull);
    expect(outcome.candidates, isEmpty);
  });

  test('evidence never contains OCR text, only kind/score/reason', () {
    final outcome = classifyDocument(
      ClassificationInput(
        ocrKeywords: [
          OcrKeywordEvidence(kind: DocumentKind.unifiedNationalId, score: .8),
        ],
        ocrConfidence: .8,
      ),
    );
    for (final evidence in outcome.evidence) {
      expect(evidence.reason, 'unifiedNationalId');
      expect(evidence.kind, 'ocr-keyword');
    }
    expect(outcome.confidences.ocr?.value, .8);
  });

  test('conflicting OCR keyword classes cap routing and mark uncertainty', () {
    final outcome = classifyDocument(
      ClassificationInput(
        ocrKeywords: [
          OcrKeywordEvidence(kind: DocumentKind.passport, score: .82),
          OcrKeywordEvidence(kind: DocumentKind.unifiedNationalId, score: .8),
        ],
        ocrConfidence: .81,
      ),
    );
    expect(outcome.candidates, hasLength(2));
    expect(outcome.status, RecognitionStatus.uncertain);
    expect(outcome.routing.band, isNot(RecognitionBand.autoCandidate));
  });

  test('candidates list every voted kind in stable enum order', () {
    final outcome = classifyDocument(
      ClassificationInput(
        ocrKeywords: [
          OcrKeywordEvidence(kind: DocumentKind.rationCard, score: .4),
          OcrKeywordEvidence(kind: DocumentKind.passport, score: .7),
        ],
      ),
    );
    final sorted = [...outcome.candidates]
      ..sort((a, b) => a.index.compareTo(b.index));
    expect(outcome.candidates, sorted);
  });

  test('deterministic for identical explicit evidence', () {
    final input = ClassificationInput(
      detectionConfidence: .8,
      geometryConfidence: .9,
      ocrKeywords: [
        OcrKeywordEvidence(kind: DocumentKind.residenceCard, score: .78),
      ],
      ocrConfidence: .81,
    );
    final a = classifyDocument(input);
    final b = classifyDocument(input);
    expect(a.kind, b.kind);
    expect(
      a.confidences.finalConfidence?.value,
      b.confidences.finalConfidence?.value,
    );
    expect(a.routing.band, b.routing.band);
  });

  test('final confidence fuses only available independent components', () {
    final evidence = [
      OcrKeywordEvidence(kind: DocumentKind.unifiedNationalId, score: .8),
    ];
    final withUpstream = classifyDocument(
      ClassificationInput(
        ocrKeywords: evidence,
        ocrConfidence: .8,
        geometryConfidence: .95,
        detectionConfidence: .9,
      ),
    );
    final ocrOnly = classifyDocument(
      ClassificationInput(ocrKeywords: evidence, ocrConfidence: .8),
    );
    expect(withUpstream.confidences.detection, isNotNull);
    expect(withUpstream.confidences.geometry, isNotNull);
    expect(ocrOnly.confidences.detection, isNull);
    expect(ocrOnly.confidences.geometry, isNull);
    expect(
      withUpstream.confidences.finalConfidence!.value,
      isNot(ocrOnly.confidences.finalConfidence!.value),
    );
  });
}
