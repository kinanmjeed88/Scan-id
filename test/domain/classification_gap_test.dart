import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/classification_gap.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/recognition.dart';

ConfidenceSet _withOcr(double? value) =>
    ConfidenceSet(ocr: value == null ? null : Confidence(value: value));

RecognitionEvidence _vote(DocumentKind kind) => RecognitionEvidence(
  source: EvidenceSource.ocr,
  kind: 'ocr-keyword',
  score: .5,
  reason: '${kind.name}:anchor-groups=2',
);

void main() {
  test('a classified kind has nothing to explain', () {
    expect(
      classificationUnknownReason(
        kind: DocumentKind.rationCard,
        status: RecognitionStatus.recognized,
        confidences: const ConfidenceSet(),
        evidence: const [],
      ),
      isNull,
    );
  });

  test('no readable text names the OCR path, not the kind', () {
    final reason = classificationUnknownReason(
      kind: DocumentKind.unknown,
      status: RecognitionStatus.unknown,
      confidences: const ConfidenceSet(),
      evidence: const [],
    );
    expect(reason, contains('لم تُقرأ أسطر نصية'));
  });

  test('readable text without a distinctive anchor is reported as such', () {
    final reason = classificationUnknownReason(
      kind: DocumentKind.unknown,
      status: RecognitionStatus.unknown,
      confidences: _withOcr(.74),
      evidence: const [],
    );
    expect(reason, contains('74٪'));
    expect(reason, contains('لا يحمل'));
  });

  test('the explanation names the evidence groups that fired', () {
    final reason = classificationUnknownReason(
      kind: DocumentKind.unknown,
      status: RecognitionStatus.unknown,
      confidences: _withOcr(.6),
      evidence: [
        RecognitionEvidence(
          source: EvidenceSource.ocr,
          kind: 'ocr-keyword',
          score: .5,
          reason: 'residenceCard:anchor-groups=2:groups=title,household',
        ),
      ],
    );
    expect(reason, contains('بطاقة السكن'));
    expect(reason, contains('العنوان المطبوع'));
    expect(reason, contains('حقول رب الأسرة'));
  });

  test('a reason without group ids adds no evidence sentence', () {
    final reason = classificationUnknownReason(
      kind: DocumentKind.unknown,
      status: RecognitionStatus.unknown,
      confidences: _withOcr(.5),
      evidence: [_vote(DocumentKind.rationCard)],
    );
    expect(reason, isNot(contains('الأدلة المرصودة')));
  });

  test('evidence under the floor names the kind that matched', () {
    final reason = classificationUnknownReason(
      kind: DocumentKind.unknown,
      status: RecognitionStatus.unknown,
      confidences: _withOcr(.5),
      evidence: [_vote(DocumentKind.rationCard)],
    );
    expect(reason, contains('البطاقة التموينية'));
    expect(reason, contains('دون حد التصنيف'));
  });

  test('competing kinds are all named, never silently dropped', () {
    final reason = classificationUnknownReason(
      kind: DocumentKind.unknown,
      status: RecognitionStatus.uncertain,
      confidences: _withOcr(.55),
      evidence: [
        _vote(DocumentKind.residenceCard),
        _vote(DocumentKind.rationCard),
      ],
    );
    expect(reason, contains('بطاقة السكن'));
    expect(reason, contains('البطاقة التموينية'));
  });

  test('evidence without an ocr-keyword entry is ignored safely', () {
    final reason = classificationUnknownReason(
      kind: DocumentKind.unknown,
      status: RecognitionStatus.unknown,
      confidences: _withOcr(.6),
      evidence: [
        RecognitionEvidence(
          source: EvidenceSource.geometry,
          kind: 'quad-assessment',
          score: .9,
        ),
      ],
    );
    expect(reason, contains('لا يحمل'));
  });
}
