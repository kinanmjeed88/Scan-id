import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/domain/geometry.dart';

// A proposal that leaves the document's text outside is not that document's
// boundary. Measured on the first field photo: the card fills the frame, the
// only proposal was a sliver covering 5.7% of it, and most of the sixteen
// text lines read from the frame had their centres outside that sliver.
//
// Pure numbers: no image, no text.

List<Point2> _rect(double l, double t, double r, double b) => [
  Point2(l, t),
  Point2(r, t),
  Point2(r, b),
  Point2(l, b),
];

void main() {
  final sliver = _rect(.40, .30, .60, .85);

  group('quadExcludesText', () {
    test('text that lies mostly outside contradicts the quad', () {
      expect(
        quadExcludesText(sliver, [
          Point2(.80, .10),
          Point2(.80, .50),
          Point2(.10, .90),
          Point2(.50, .50),
        ]),
        isTrue,
      );
    });

    test('text that lies mostly inside does not', () {
      expect(
        quadExcludesText(sliver, [
          Point2(.50, .40),
          Point2(.50, .50),
          Point2(.50, .60),
          Point2(.90, .90),
        ]),
        isFalse,
      );
    });

    test('an even split is not "most": the quad is left as it was', () {
      expect(
        quadExcludesText(sliver, [
          Point2(.50, .40),
          Point2(.50, .60),
          Point2(.90, .10),
          Point2(.10, .90),
        ]),
        isFalse,
      );
    });

    test('with nothing located there is nothing to compare', () {
      expect(quadExcludesText(sliver, const []), isFalse);
    });

    test('a shape that is not four points is not tested', () {
      expect(
        quadExcludesText(
          [Point2(0, 0), Point2(1, 0), Point2(1, 1)],
          [Point2(.9, .9)],
        ),
        isFalse,
      );
    });

    test('the answer does not depend on the winding of the corners', () {
      final centres = [Point2(.80, .10), Point2(.80, .50), Point2(.50, .50)];
      final reversed = sliver.reversed.toList();
      expect(quadExcludesText(sliver, centres), isTrue);
      expect(quadExcludesText(reversed, centres), isTrue);
      final inside = [Point2(.45, .40), Point2(.55, .70)];
      expect(quadExcludesText(sliver, inside), isFalse);
      expect(quadExcludesText(reversed, inside), isFalse);
    });

    test('a centre on the edge counts as inside', () {
      expect(quadExcludesText(sliver, [Point2(.40, .50)]), isFalse);
      expect(quadExcludesText(sliver, [Point2(.39, .50)]), isTrue);
    });
  });

  group('refuseProposalExcludingText', () {
    final decision = verifyBoundary(
      BoundaryProposal(
        producer: BoundaryProducer.learnedModel,
        corners: sliver,
        modelConfidence: .21,
        minAutoAcceptConfidence: .55,
      ),
      sourceWidth: 422,
      sourceHeight: 303,
    );
    final refused = refuseProposalExcludingText(decision);

    test('starts from a proposal that was only held for review', () {
      expect(decision.kind, BoundaryDecisionKind.needsReview);
      expect(decision.verification.hasUsableGeometry, isTrue);
    });

    test('refuses it with the one decisive reason', () {
      expect(refused.kind, BoundaryDecisionKind.rejected);
      expect(refused.verification.reasons, [
        BoundaryReviewReason.excludesDocumentText,
      ]);
      expect(refused.cropAuthorization, isNull);
      expect(refused.acceptedCorners, isNull);
    });

    test('keeps what was measured for the audit', () {
      expect(identical(refused.proposal, decision.proposal), isTrue);
      expect(
        identical(
          refused.verification.assessment,
          decision.verification.assessment,
        ),
        isTrue,
      );
    });

    test('tells the person the whole image was kept', () {
      final message = boundaryReviewReasonMessage(
        BoundaryReviewReason.excludesDocumentText,
      );
      expect(message, contains('الصورة كاملة'));
      expect(message.length, lessThanOrEqualTo(200));
    });
  });
}
