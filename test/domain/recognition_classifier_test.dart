import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/ocr_evidence.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_classifier.dart';
import 'package:scan_id/domain/recognition_routing.dart';

void main() {
  test('filename label plus matching shape recognises the card', () {
    final outcome = classifyDocument(
      const ClassificationInput(
        name: 'البطاقة الوطنية الموحدة.png',
        width: 1586,
        height: 1000,
        boundaryDetected: true,
        geometryConfidence: .95,
        detectionConfidence: .8,
      ),
    );
    expect(outcome.kind, DocumentKind.unifiedNationalId);
    expect(outcome.status, RecognitionStatus.recognized);
    expect(
      outcome.evidence.map((e) => e.kind),
      containsAll(['filename-label', 'aspect-match']),
    );
    expect(outcome.confidences.classification, isNotNull);
    expect(outcome.confidences.finalConfidence, isNotNull);
    expect(outcome.candidates, contains(DocumentKind.unifiedNationalId));
  });

  test('shape alone classifies without a label', () {
    final outcome = classifyDocument(
      const ClassificationInput(
        name: 'IMG_2041.png',
        width: 1586,
        height: 1000,
        boundaryDetected: true,
        geometryConfidence: .9,
      ),
    );
    expect(outcome.kind, DocumentKind.unifiedNationalId);
    expect(
      outcome.evidence.map((e) => e.kind),
      isNot(contains('filename-label')),
    );
  });

  test('no evidence at all stays unknown with empty evidence', () {
    final outcome = classifyDocument(
      const ClassificationInput(
        name: 'photo.png',
        width: 400,
        height: 400,
        boundaryDetected: false,
      ),
    );
    expect(outcome.kind, DocumentKind.unknown);
    expect(outcome.status, RecognitionStatus.unknown);
    expect(outcome.evidence, isEmpty);
    expect(outcome.confidences.classification, isNull);
    expect(outcome.candidates, isEmpty);
  });

  test('evidence never contains OCR text, only kind/score/reason', () {
    final outcome = classifyDocument(
      ClassificationInput(
        name: 'x.png',
        width: 1586,
        height: 1000,
        boundaryDetected: true,
        ocrKeywords: [
          OcrKeywordEvidence(kind: DocumentKind.unifiedNationalId, score: .8),
        ],
        ocrConfidence: .8,
      ),
    );
    for (final evidence in outcome.evidence) {
      expect(evidence.reason, isNot(contains('البطاقه')));
      expect(
        evidence.kind,
        isIn(['filename-label', 'aspect-match', 'ocr-keyword']),
      );
    }
    expect(outcome.confidences.ocr?.value, .8);
  });

  test('conflicting label and shape caps routing and marks uncertainty', () {
    // Passport label over an ID-1-shaped crop: two kinds with close scores.
    final outcome = classifyDocument(
      const ClassificationInput(
        name: 'جواز السفر.png',
        width: 1586,
        height: 1000,
        boundaryDetected: true,
        geometryConfidence: .95,
        detectionConfidence: .9,
      ),
    );
    expect(outcome.candidates.length, greaterThan(1));
    expect(outcome.routing.band, isNot(RecognitionBand.autoCandidate));
  });

  test('candidates list every voted kind in stable enum order', () {
    final outcome = classifyDocument(
      ClassificationInput(
        name: 'جواز السفر.png',
        width: 1586,
        height: 1000,
        boundaryDetected: true,
        ocrKeywords: [
          OcrKeywordEvidence(kind: DocumentKind.rationCard, score: .4),
        ],
      ),
    );
    final sorted = [...outcome.candidates]
      ..sort((a, b) => a.index.compareTo(b.index));
    expect(outcome.candidates, sorted);
  });

  test('full-frame camera shapes carry no aspect vote', () {
    final outcome = classifyDocument(
      const ClassificationInput(
        name: 'IMG_1.png',
        width: 4000,
        height: 3000,
        boundaryDetected: false,
      ),
    );
    expect(outcome.kind, DocumentKind.unknown);
  });

  test('deterministic: identical inputs give identical outcomes', () {
    const input = ClassificationInput(
      name: 'بطاقة السكن.png',
      width: 1471,
      height: 1000,
      boundaryDetected: true,
      geometryConfidence: .9,
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

  test('final confidence fuses detection, geometry and classification', () {
    final with_ = classifyDocument(
      const ClassificationInput(
        name: 'البطاقة الوطنية الموحدة.png',
        width: 1586,
        height: 1000,
        boundaryDetected: true,
        geometryConfidence: .95,
        detectionConfidence: .9,
      ),
    );
    final without = classifyDocument(
      const ClassificationInput(
        name: 'البطاقة الوطنية الموحدة.png',
        width: 1586,
        height: 1000,
        boundaryDetected: true,
      ),
    );
    expect(with_.confidences.detection, isNotNull);
    expect(with_.confidences.geometry, isNotNull);
    expect(without.confidences.detection, isNull);
    expect(without.confidences.geometry, isNull);
    expect(
      with_.confidences.finalConfidence!.value,
      isNot(without.confidences.finalConfidence!.value),
    );
  });
}
