import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/geometry.dart';

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

  test('a sound quad whose shape can claim the imposed size is accepted '
      'without adopting the catalog aspect', () {
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
    expect(decision.catalogShapeMatches, isTrue);
    expect(decision.verification.reasons, isEmpty);
    expect(decision.verification.measuredAspect, closeTo(1.6, .02));
    final recipe = recipeFromAcceptedBoundary(
      decision.cropAuthorization!,
      sourceWidth: width,
      sourceHeight: height,
    );
    final measured = CropDraft(corners: goodQuad()).toRecipe(width, height);
    final stretched = CropDraft(
      corners: goodQuad(),
      aspectRatio: 85.6 / 53.98,
    ).toRecipe(width, height);
    expect(
      recipe.geometry.outputWidth / recipe.geometry.outputHeight,
      closeTo(
        measured.geometry.outputWidth / measured.geometry.outputHeight,
        1e-9,
      ),
    );
    expect(
      recipe.geometry.outputWidth / recipe.geometry.outputHeight,
      isNot(
        closeTo(
          stretched.geometry.outputWidth / stretched.geometry.outputHeight,
          1e-4,
        ),
      ),
      reason: 'shapeTolerance must not become a warp stretch',
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

  test('an accepted claim keeps the measured aspect even when a manual '
      'draft could impose a different ratio', () {
    final decision = verifyBoundary(
      BoundaryProposal(
        producer: BoundaryProducer.wholeFrameDetector,
        corners: goodQuad(),
        imposedAspect: 85.6 / 53.98,
      ),
      sourceWidth: width,
      sourceHeight: height,
    );
    final automatic = recipeFromAcceptedBoundary(
      decision.cropAuthorization!,
      sourceWidth: width,
      sourceHeight: height,
    );
    final manual = CropDraft(
      corners: goodQuad(),
      aspectRatio: 287 / 52,
    ).toRecipe(width, height);
    expect(
      automatic.geometry.outputWidth / automatic.geometry.outputHeight,
      isNot(
        closeTo(
          manual.geometry.outputWidth / manual.geometry.outputHeight,
          .02,
        ),
      ),
    );
  });

  test('inside 2.5 but outside shapeTolerance accepts the quad and '
      'keeps the measured aspect', () {
    // Measured ~1.60 versus passport 125/88 ≈ 1.420. Factor ≈ 1.13, inside
    // the outer 2.5 refusal, and relative error ≈ 12 %, outside shapeTolerance.
    // Acceptance must not become permission to stretch the warp.
    final decision = verifyBoundary(
      BoundaryProposal(
        producer: BoundaryProducer.wholeFrameDetector,
        corners: goodQuad(),
        imposedAspect: 125 / 88,
      ),
      sourceWidth: width,
      sourceHeight: height,
    );
    expect(decision.kind, BoundaryDecisionKind.accepted);
    expect(decision.catalogShapeMatches, isFalse);
    final measured = recipeFromAcceptedBoundary(
      decision.cropAuthorization!,
      sourceWidth: width,
      sourceHeight: height,
    );
    final stretched = CropDraft(
      corners: goodQuad(),
      aspectRatio: 125 / 88,
    ).toRecipe(width, height);
    expect(
      measured.geometry.outputWidth / measured.geometry.outputHeight,
      isNot(
        closeTo(
          stretched.geometry.outputWidth / stretched.geometry.outputHeight,
          .02,
        ),
      ),
    );
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

  test(
    'a learned-model proposal below minAutoAcceptConfidence needs review',
    () {
      final decision = verifyBoundary(
        BoundaryProposal(
          producer: BoundaryProducer.learnedModel,
          corners: goodQuad(),
          modelConfidence: 0.62,
          minAutoAcceptConfidence: 0.80,
        ),
        sourceWidth: width,
        sourceHeight: height,
      );
      expect(decision.kind, BoundaryDecisionKind.needsReview);
      expect(decision.cropAuthorization, isNull);
      expect(
        decision.verification.reasons,
        contains(BoundaryReviewReason.lowModelConfidence),
      );
    },
  );

  test('a learned-model proposal touching frame edge needs review', () {
    final decision = verifyBoundary(
      BoundaryProposal(
        producer: BoundaryProducer.learnedModel,
        corners: goodQuad(),
        modelConfidence: 0.94,
        minAutoAcceptConfidence: 0.80,
        touchesFrameEdge: true,
      ),
      sourceWidth: width,
      sourceHeight: height,
    );
    expect(decision.kind, BoundaryDecisionKind.needsReview);
    expect(decision.cropAuthorization, isNull);
    expect(
      decision.verification.reasons,
      contains(BoundaryReviewReason.touchesFrameEdge),
    );
  });

  test(
    'verifyBoundary independently catches learned-model corners inside 1.6% frame border even when touchesFrameEdge is false',
    () {
      final decision = verifyBoundary(
        BoundaryProposal(
          producer: BoundaryProducer.learnedModel,
          corners: [
            Point2(0.10, 0.12),
            Point2(0.986, 0.14),
            Point2(0.96, 0.86),
            Point2(0.11, 0.84),
          ],
          modelConfidence: 0.95,
          minAutoAcceptConfidence: 0.55,
          touchesFrameEdge: false,
        ),
        sourceWidth: width,
        sourceHeight: height,
      );
      expect(decision.kind, BoundaryDecisionKind.needsReview);
      expect(decision.cropAuthorization, isNull);
      expect(
        decision.verification.reasons,
        contains(BoundaryReviewReason.touchesFrameEdge),
      );
    },
  );
}
