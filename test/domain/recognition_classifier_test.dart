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
          OcrKeywordEvidence(
            kind: DocumentKind.unifiedNationalId,
            score: .8,
            matchedAnchorGroups: 2,
          ),
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

  test('OCR alone never authorizes automatic size or A4 placement', () {
    for (final kind in const [
      DocumentKind.unifiedNationalId,
      DocumentKind.civilStatusId,
      DocumentKind.residenceCard,
      DocumentKind.rationCard,
    ]) {
      final outcome = classifyDocument(
        ClassificationInput(
          ocrKeywords: [
            OcrKeywordEvidence(kind: kind, score: .99, matchedAnchorGroups: 2),
          ],
          ocrConfidence: .99,
          geometryConfidence: .99,
          detectionConfidence: .99,
        ),
      );
      expect(outcome.kind, kind);
      expect(outcome.status, RecognitionStatus.recognized);
      expect(outcome.routing.band, RecognitionBand.review);
      expect(outcome.routing.reasons, contains('R1:insufficient-sources'));
    }
  });

  test('weak text evidence below the classification floor stays unknown', () {
    final outcome = classifyDocument(
      ClassificationInput(
        ocrKeywords: [
          OcrKeywordEvidence(
            kind: DocumentKind.civilStatusId,
            score: .4,
            matchedAnchorGroups: 2,
          ),
        ],
      ),
    );
    expect(outcome.kind, DocumentKind.unknown);
    expect(outcome.status, RecognitionStatus.unknown);
    expect(outcome.evidence, hasLength(1));
    expect(outcome.candidates, [DocumentKind.civilStatusId]);
    expect(outcome.routing.band, RecognitionBand.unresolved);
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
          OcrKeywordEvidence(
            kind: DocumentKind.unifiedNationalId,
            score: .8,
            matchedAnchorGroups: 2,
          ),
        ],
        ocrConfidence: .8,
      ),
    );
    for (final evidence in outcome.evidence) {
      expect(evidence.reason, 'unifiedNationalId:anchor-groups=2');
      expect(evidence.kind, 'ocr-keyword');
    }
    expect(outcome.confidences.ocr?.value, .8);
  });

  test('conflicting OCR keyword classes cap routing and mark uncertainty', () {
    final outcome = classifyDocument(
      ClassificationInput(
        ocrKeywords: [
          OcrKeywordEvidence(
            kind: DocumentKind.passport,
            score: .82,
            matchedAnchorGroups: 2,
          ),
          OcrKeywordEvidence(
            kind: DocumentKind.unifiedNationalId,
            score: .8,
            matchedAnchorGroups: 2,
          ),
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
          OcrKeywordEvidence(
            kind: DocumentKind.rationCard,
            score: .4,
            matchedAnchorGroups: 2,
          ),
          OcrKeywordEvidence(
            kind: DocumentKind.passport,
            score: .7,
            matchedAnchorGroups: 2,
          ),
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
        OcrKeywordEvidence(
          kind: DocumentKind.residenceCard,
          score: .78,
          matchedAnchorGroups: 2,
        ),
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
      OcrKeywordEvidence(
        kind: DocumentKind.unifiedNationalId,
        score: .8,
        matchedAnchorGroups: 2,
      ),
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
  group('automatic placement confidence gate', () {
    ClassificationOutcome outcome({
      double? type = .70,
      double? total = .70,
      double? detection = .70,
      DocumentKind kind = DocumentKind.unifiedNationalId,
      RecognitionStatus status = RecognitionStatus.recognized,
      List<DocumentKind> candidates = const [DocumentKind.unifiedNationalId],
    }) => ClassificationOutcome(
      kind: kind,
      status: status,
      candidates: candidates,
      confidences: ConfidenceSet(
        classification: type == null ? null : Confidence(value: type),
        finalConfidence: total == null ? null : Confidence(value: total),
        detection: detection == null ? null : Confidence(value: detection),
      ),
      evidence: const [],
      routing: const RoutingDecision(band: RecognitionBand.review, reasons: []),
    );

    test('a real fusion of exact 70% evidence remains eligible', () {
      final fused = classifyDocument(
        ClassificationInput(
          detectionConfidence: .70,
          geometryConfidence: .70,
          ocrKeywords: [
            OcrKeywordEvidence(
              kind: DocumentKind.unifiedNationalId,
              score: .70,
              matchedAnchorGroups: 2,
            ),
          ],
          ocrConfidence: .70,
        ),
      );
      expect(qualifiesForAutomaticPlacement(fused), isTrue);
    });

    test('at and above 70 qualifies while lower scores do not', () {
      expect(qualifiesForAutomaticPlacement(outcome()), isTrue);
      expect(
        qualifiesForAutomaticPlacement(outcome(type: .71, total: .71)),
        isTrue,
      );
      expect(qualifiesForAutomaticPlacement(outcome(type: .699)), isFalse);
      expect(qualifiesForAutomaticPlacement(outcome(total: .699)), isFalse);
    });
    test(
      'unknown, conflict, missing type or total and weak component stay pending',
      () {
        expect(qualifiesForAutomaticPlacement(outcome(type: null)), isFalse);
        expect(qualifiesForAutomaticPlacement(outcome(total: null)), isFalse);
        expect(
          qualifiesForAutomaticPlacement(outcome(detection: .49)),
          isFalse,
        );
        expect(
          qualifiesForAutomaticPlacement(outcome(kind: DocumentKind.unknown)),
          isFalse,
        );
        expect(
          qualifiesForAutomaticPlacement(
            outcome(status: RecognitionStatus.uncertain),
          ),
          isFalse,
        );
        expect(
          qualifiesForAutomaticPlacement(
            outcome(
              candidates: [
                DocumentKind.unifiedNationalId,
                DocumentKind.passport,
              ],
            ),
          ),
          isFalse,
        );
      },
    );
  });
}
