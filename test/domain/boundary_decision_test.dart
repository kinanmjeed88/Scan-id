import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/validation.dart';

/// The Proposal → Verification → Decision contract (boundary audits D1–D3).
/// These tests pin the GATE's required outcomes — what may become a crop —
/// not the internals of any proposer.
void main() {
  const width = 1600;
  const height = 1000;

  // 1280x800 px quad: measured aspect 1.60, ~64% of the frame.
  List<Point2> goodQuad() => [
    Point2(.1, .1),
    Point2(.9, .1),
    Point2(.9, .9),
    Point2(.1, .9),
  ];

  test('a sound quad whose shape can claim the imposed size is accepted', () {
    final decision = verifyBoundary(
      BoundaryProposal(
        producer: BoundaryProducer.wholeFrameDetector,
        corners: goodQuad(),
        imposedAspect: 85.6 / 53.98,
      ),
      sourceWidth: width,
      sourceHeight: height,
    );
    expect(decision.kind, BoundaryDecisionKind.accepted);
    expect(decision.acceptedCorners, hasLength(4));
    expect(decision.cropAuthorization, isNotNull);
    expect(decision.verification.reasons, isEmpty);
    expect(decision.verification.measuredAspect, closeTo(1.6, .02));
    final recipe = recipeFromAcceptedBoundary(
      decision.cropAuthorization!,
      sourceWidth: width,
      sourceHeight: height,
      orientedOutputAspect: 85.6 / 53.98,
    );
    expect(
      recipe.geometry.outputWidth / recipe.geometry.outputHeight,
      closeTo(85.6 / 53.98, .02),
    );
  });

  test('no proposed boundary is a review outcome, never an acceptance', () {
    final decision = verifyBoundary(
      const BoundaryProposal(producer: BoundaryProducer.detector),
      sourceWidth: width,
      sourceHeight: height,
    );
    expect(decision.kind, BoundaryDecisionKind.needsReview);
    expect(decision.acceptedCorners, isNull);
    expect(decision.cropAuthorization, isNull);
    expect(
      decision.verification.reasons,
      contains(BoundaryReviewReason.noBoundary),
    );
  });

  test('a malformed proposal is rejected as not-a-boundary', () {
    final decision = verifyBoundary(
      BoundaryProposal(
        producer: BoundaryProducer.detector,
        corners: [Point2(0, 0), Point2(1, 0), Point2(1, 1)],
      ),
      sourceWidth: width,
      sourceHeight: height,
    );
    expect(decision.kind, BoundaryDecisionKind.rejected);
    expect(decision.acceptedCorners, isNull);
  });

  test('a geometrically implausible quad needs review and cannot crop', () {
    // ~1% of the frame: assessQuad refuses it as too small.
    final decision = verifyBoundary(
      BoundaryProposal(
        producer: BoundaryProducer.detector,
        corners: [
          Point2(.45, .45),
          Point2(.55, .45),
          Point2(.55, .55),
          Point2(.45, .55),
        ],
      ),
      sourceWidth: width,
      sourceHeight: height,
    );
    expect(decision.kind, BoundaryDecisionKind.needsReview);
    expect(decision.acceptedCorners, isNull);
    expect(
      decision.verification.reasons,
      contains(BoundaryReviewReason.geometryRejected),
    );
    expect(decision.verification.assessment?.acceptable, isFalse);
  });

  test('a self-crossed quad needs review and cannot crop', () {
    final decision = verifyBoundary(
      BoundaryProposal(
        producer: BoundaryProducer.detector,
        corners: [
          Point2(.1, .1),
          Point2(.9, .9),
          Point2(.9, .1),
          Point2(.1, .9),
        ],
      ),
      sourceWidth: width,
      sourceHeight: height,
    );
    expect(decision.kind, isNot(BoundaryDecisionKind.accepted));
    expect(decision.acceptedCorners, isNull);
  });

  test('measured shape contradicting the imposed catalog size is review, '
      'not a silent stretch (D3/D10)', () {
    final decision = verifyBoundary(
      BoundaryProposal(
        producer: BoundaryProducer.wholeFrameDetector,
        corners: goodQuad(), // measured 1.60 (an ID-1 shape)
        imposedAspect: 287 / 52, // claimed ration-card shape
        imposedKindLabel: 'البطاقة التموينية',
      ),
      sourceWidth: width,
      sourceHeight: height,
    );
    expect(decision.kind, BoundaryDecisionKind.needsReview);
    expect(decision.acceptedCorners, isNull);
    expect(decision.cropAuthorization, isNull);
    expect(
      decision.verification.reasons,
      contains(BoundaryReviewReason.aspectMismatch),
    );
  });

  test('an accepted claim cannot be warped to a different catalog ratio', () {
    final decision = verifyBoundary(
      BoundaryProposal(
        producer: BoundaryProducer.wholeFrameDetector,
        corners: goodQuad(),
        imposedAspect: 85.6 / 53.98,
      ),
      sourceWidth: width,
      sourceHeight: height,
    );
    expect(
      () => recipeFromAcceptedBoundary(
        decision.cropAuthorization!,
        sourceWidth: width,
        sourceHeight: height,
        orientedOutputAspect: 287 / 52,
      ),
      throwsA(isA<ValidationException>()),
    );
  });

  test('a mild measured-vs-imposed disagreement (perspective-grade) still '
      'accepts: pixel aspect is not a tight claim', () {
    // Drawn/measured 1.50 shape against the ID-1 size 1.586 (factor 1.06,
    // far inside the project's 2.5x implausibility bound).
    final decision = verifyBoundary(
      BoundaryProposal(
        producer: BoundaryProducer.wholeFrameDetector,
        corners: [
          Point2(.1, .1),
          Point2(.85, .1),
          Point2(.85, .9),
          Point2(.1, .9),
        ],
        imposedAspect: 85.6 / 53.98,
      ),
      sourceWidth: width,
      sourceHeight: height,
    );
    expect(decision.kind, BoundaryDecisionKind.accepted);
  });

  test('a quad that does not describe its measured region needs review', () {
    final decision = verifyBoundary(
      BoundaryProposal(
        producer: BoundaryProducer.segmenter,
        corners: goodQuad(),
        region: const [0, 0, .35, .35],
      ),
      sourceWidth: width,
      sourceHeight: height,
    );
    expect(decision.kind, BoundaryDecisionKind.needsReview);
    expect(
      decision.verification.reasons,
      contains(BoundaryReviewReason.quadOutsideRegion),
    );
  });

  test('a quad inside its measured region with no imposed size accepts', () {
    final decision = verifyBoundary(
      BoundaryProposal(
        producer: BoundaryProducer.segmenter,
        corners: [
          Point2(.55, .55),
          Point2(.95, .55),
          Point2(.95, .9),
          Point2(.55, .9),
        ],
        region: const [.5, .5, 1, .95],
      ),
      sourceWidth: width,
      sourceHeight: height,
    );
    expect(decision.kind, BoundaryDecisionKind.accepted);
  });
}
