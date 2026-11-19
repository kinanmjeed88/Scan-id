import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/domain/geometry.dart';

/// The «موافقة على القص المقترح» option turns a MEASURED and USABLE boundary
/// into an authorized crop even when its aspect does not match a catalog shape.
///
/// These tests pin the two halves of that promise, because they are opposite
/// risks:
///
/// * it must actually work for a boundary the app measured as usable;
/// * it must NOT become a way around geometry validation — an unusable quad, a
///   missing quad or a frame artifact stays refused.
void main() {
  const width = 1600;
  const height = 1000;

  /// A well-formed quad filling most of the frame. Its measured aspect is 1.6,
  /// which disagrees with the ID-1 catalog aspect (1.586) only slightly, so the
  /// disagreement that forces review is supplied by the catalog aspect instead.
  List<Point2> goodQuad() => [
    Point2(.1, .1),
    Point2(.9, .1),
    Point2(.9, .9),
    Point2(.1, .9),
  ];

  test('a usable boundary that review refused becomes authorized when the user '
      'approves it, and the approval is recorded as a human decision', () {
    final decision = verifyBoundary(
      BoundaryProposal(
        producer: BoundaryProducer.learnedModel,
        corners: goodQuad(),
        // A square-ish imposed aspect the measured quad cannot claim, so the
        // gate refuses automatic cropping and queues it for review.
        imposedAspect: 1.0,
        minAutoAcceptConfidence: .55,
        modelConfidence: .30,
      ),
      sourceWidth: width,
      sourceHeight: height,
    );
    expect(
      decision.kind,
      isNot(BoundaryDecisionKind.accepted),
      reason: 'this fixture must start refused, or the test proves nothing',
    );
    expect(decision.verification.hasUsableGeometry, isTrue);
    expect(decision.cropAuthorization, isNull);

    final approved = decision.approvedByUser();
    expect(approved.kind, BoundaryDecisionKind.accepted);
    expect(approved.cropAuthorization, isNotNull);
    // A person approved it, and that fact survives for the report.
    expect(approved.verification.userApproved, isTrue);
    // The approval changes the VERDICT only: the numbers are untouched, so a
    // reader can still see that the catalog shape did not match.
    expect(approved.verification.measuredAspect, isNotNull);
    expect(
      approved.verification.measuredAspect,
      closeTo(decision.verification.measuredAspect!, 1e-12),
    );
    expect(
      approved.cropAuthorization!.corners,
      decision.proposal.corners,
      reason: 'approval must not move the measured corners',
    );
  });

  test('approval still refuses a boundary with no usable geometry', () {
    // A quad collapsed to a degenerate sliver: measured, but not usable.
    final decision = verifyBoundary(
      BoundaryProposal(
        producer: BoundaryProducer.learnedModel,
        corners: [
          Point2(.5, .5),
          Point2(.5, .5),
          Point2(.5, .5),
          Point2(.5, .5),
        ],
      ),
      sourceWidth: width,
      sourceHeight: height,
    );
    expect(decision.verification.hasUsableGeometry, isFalse);
    final approved = decision.approvedByUser();
    expect(
      approved.kind,
      isNot(BoundaryDecisionKind.accepted),
      reason: 'a user approval is an approval of geometry the app measured, '
          'not a licence to crop a degenerate quad',
    );
    expect(approved.cropAuthorization, isNull);
    expect(approved.verification.userApproved, isFalse);
  });

  test('approval cannot invent a boundary that was never proposed', () {
    final decision = verifyBoundary(
      const BoundaryProposal(producer: BoundaryProducer.detector),
      sourceWidth: width,
      sourceHeight: height,
    );
    expect(decision.kind, BoundaryDecisionKind.needsReview);
    final approved = decision.approvedByUser();
    expect(approved.cropAuthorization, isNull);
    expect(approved.acceptedCorners, isNull);
  });

  test('approving an already-accepted decision is a no-op', () {
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
    final approved = decision.approvedByUser();
    // Nothing is relabelled: an automatic acceptance must not be reported as a
    // human approval.
    expect(approved.verification.userApproved, isFalse);
    expect(approved.kind, BoundaryDecisionKind.accepted);
  });
}
