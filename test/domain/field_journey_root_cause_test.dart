import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/ocr_evidence.dart';
import 'package:scan_id/domain/quad_assessment.dart';
import 'package:scan_id/domain/recognition_classifier.dart';

/// Pins the two root causes established by the field-journey investigation
/// (docs/reports/FIELD_JOURNEY_ROOT_CAUSE_2026-11-11.md).
///
/// These tests assert the CURRENT, documented behaviour. They do not change a
/// threshold, a gate or a policy; each one encodes an arithmetic or lexical
/// fact that explains a reported outcome so a future change cannot silently
/// re-open the same diagnosis.
void main() {
  group('geometry score cannot express "the card is large"', () {
    test('area credit saturates at 15% of the frame', () {
      // A quad covering 16% and one covering 81% of the frame both sit above
      // the 15% saturation point, so the area term stops rewarding size there:
      // both score 1.0. Geometry confidence is therefore not a statement about
      // how much of the frame the document fills.
      final justOver = assessQuad(
        _rect(.20, .20, .60, .60),
        sourceWidth: 1000,
        sourceHeight: 1000,
      );
      final frameFilling = assessQuad(
        _rect(.05, .05, .95, .95),
        sourceWidth: 1000,
        sourceHeight: 1000,
      );
      expect(justOver.acceptable, isTrue);
      expect(frameFilling.acceptable, isTrue);
      expect(justOver.areaFraction, greaterThan(.15));
      expect(justOver.areaFraction, lessThan(.20));
      // Both already earn full area credit, so both score 1.0: a 16% quad and
      // an 81% quad are indistinguishable to this confidence.
      expect(justOver.geometryConfidence, greaterThan(.99));
      expect(frameFilling.geometryConfidence, greaterThan(.99));
      expect(
        frameFilling.geometryConfidence! - justOver.geometryConfidence!,
        lessThan(.01),
      );
    });

    test('a 5.7% quad with 9.1% geometry is arithmetically degenerate', () {
      // .5*angle + .3*edge + .2*(area/.15); with area .057 the area term is
      // .076, so a 0.091 total leaves only .015 for the shape terms: the quad
      // must be strongly skewed. A well-formed quad of that size scores >= .87.
      final square = assessQuad(
        _rect(.05, .05, .29, .32),
        sourceWidth: 1204,
        sourceHeight: 803,
      );
      expect(square.acceptable, isTrue);
      expect(square.areaFraction, closeTo(.057, .012));
      // A convex, near-rectangular quad of this area cannot score 0.091.
      expect(square.geometryConfidence, greaterThan(.80));
    });

    test('a frame-filling card yields an area fraction far above 5.7%', () {
      final card = assessQuad(
        _rect(.10, .12, .90, .88),
        sourceWidth: 1204,
        sourceHeight: 803,
      );
      expect(card.areaFraction, greaterThan(.55));
      // So a reported 5.7% cannot describe a card that fills the frame.
      expect(card.areaFraction, greaterThan(.10));
    });
  });

  group('a classical candidate can never be auto-accepted', () {
    test('classical proposals always carry uncalibratedClassicalScore', () {
      final decision = verifyBoundary(
        BoundaryProposal(
          producer: BoundaryProducer.detector,
          corners: _rect(.10, .10, .90, .90),
        ),
        sourceWidth: 1200,
        sourceHeight: 900,
      );
      expect(decision.kind, BoundaryDecisionKind.needsReview);
      expect(
        decision.verification.reasons,
        contains(BoundaryReviewReason.uncalibratedClassicalScore),
      );
      expect(decision.cropAuthorization, isNull);
    });

    test('a classical win that forced review can never be corroborated', () {
      // _classicalWins sets forceReview + modelDisagreement; the catalog gate
      // requires a single uncalibratedClassicalScore reason and forceReview
      // false, so this path is structurally barred from acceptance.
      final decision = verifyBoundary(
        BoundaryProposal(
          producer: BoundaryProducer.detector,
          corners: _rect(.10, .10, .90, .90),
          forceReview: true,
          forceReviewReason: BoundaryReviewReason.modelDisagreement,
        ),
        sourceWidth: 1200,
        sourceHeight: 900,
      );
      expect(decision.verification.reasons, hasLength(2));
      expect(
        decision.verification.reasons,
        contains(BoundaryReviewReason.modelDisagreement),
      );
      final corroborated = corroborateClassicalBoundaryWithCatalog(
        decision: decision,
        classification: classifyDocument(
          const ClassificationInput(ocrKeywords: []),
        ),
        catalog: const DocumentSizeCatalog(),
      );
      expect(corroborated.kind, BoundaryDecisionKind.needsReview);
      expect(corroborated.cropAuthorization, isNull);
    });
  });

  group('classification scores the evidence pair, not OCR confidence', () {
    test('a high-confidence single hit yields no classification evidence', () {
      // One group firing, at 0.95 OCR confidence, must produce nothing: a
      // title alone is not a document type.
      final evidence = ocrKeywordEvidence(
        OcrTextResult.available(
          engineVersion: 'field-diagnosis',
          lines: [OcrLine(text: 'البطاقة الوطنية', confidence: .95)],
        ),
      );
      expect(evidence, isEmpty);
    });

    test('evidence score is the lower confidence of the anchor/support '
        'pair', () {
      final evidence = ocrKeywordEvidence(
        OcrTextResult.available(
          engineVersion: 'field-diagnosis',
          lines: [
            OcrLine(text: 'البطاقة الوطنية', confidence: .95),
            OcrLine(text: 'الرقم الوطني', confidence: .62),
          ],
        ),
      );
      expect(evidence, hasLength(1));
      // The classification score is the weaker of the two, never the OCR mean
      // and never the stronger line: a 77.7% OCR mean cannot raise it.
      expect(evidence.single.score, closeTo(.62, 1e-9));
    });

    test('a title with no independent support group stays unknown', () {
      final outcome = classifyDocument(
        ClassificationInput(
          ocrKeywords: ocrKeywordEvidence(
            OcrTextResult.available(
              engineVersion: 'field-diagnosis',
              lines: [OcrLine(text: 'جواز السفر', confidence: .93)],
            ),
          ),
        ),
      );
      expect(outcome.kind, DocumentKind.unknown);
      expect(outcome.status.name, 'unknown');
    });

    test('a title with an independent support group classifies', () {
      final outcome = classifyDocument(
        ClassificationInput(
          ocrKeywords: ocrKeywordEvidence(
            OcrTextResult.available(
              engineVersion: 'field-diagnosis',
              lines: [
                OcrLine(text: 'البطاقة الوطنية', confidence: .9),
                OcrLine(text: 'الرقم الوطني', confidence: .88),
              ],
            ),
          ),
        ),
      );
      expect(outcome.kind, DocumentKind.unifiedNationalId);
      expect(outcome.candidates, hasLength(1));
      expect(qualifiesForAutomaticPlacement(outcome), isTrue);
    });

    test('a ministry header alone is support, never an anchor', () {
      // The ministry block is issuer evidence only and must not classify a
      // card by itself. (The card does print «البطاقة الوطنية» under this
      // block, in its smallest type; measured with the app's own OCR graphs,
      // that line is read too garbled to match, which is why the printed
      // national number is a structural anchor: see
      // national_number_anchor_test.dart.)
      final outcome = classifyDocument(
        ClassificationInput(
          ocrKeywords: ocrKeywordEvidence(
            OcrTextResult.available(
              engineVersion: 'field-diagnosis',
              lines: [
                OcrLine(text: 'جمهورية العراق وزارة الداخلية', confidence: .92),
                OcrLine(
                  text: 'مديرية الأحوال المدنية والجوازات والإقامة',
                  confidence: .9,
                ),
              ],
            ),
          ),
        ),
      );
      // The issuer group hits, but without a title/MRZ anchor and a second
      // independent group there is no evidence for any kind.
      expect(outcome.kind, DocumentKind.unknown);
    });
  });
}

List<Point2> _rect(double l, double t, double r, double b) => [
  Point2(l, t),
  Point2(r, t),
  Point2(r, b),
  Point2(l, b),
];
