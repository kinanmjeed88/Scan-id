import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/domain/frame_edge_band.dart';
import 'package:scan_id/domain/geometry.dart';

/// Unit tests for the frame-edge gate and the acceptance-score gate inside
/// [verifyBoundary]. Pure geometry and scores: no image, no model.
void main() {
  const width = 1000;
  const height = 700;

  List<Point2> interior() => [
    Point2(.2, .2),
    Point2(.8, .2),
    Point2(.8, .8),
    Point2(.2, .8),
  ];

  group('the edge gate measures in the producer\'s band', () {
    test('a legacy-band claim keeps the historical 1.6 percent behaviour', () {
      final decision = verifyBoundary(
        BoundaryProposal(
          producer: BoundaryProducer.learnedModel,
          corners: [
            Point2(.10, .12),
            Point2(.986, .14),
            Point2(.96, .86),
            Point2(.11, .84),
          ],
          modelConfidence: .95,
          minAutoAcceptConfidence: .55,
        ),
        sourceWidth: width,
        sourceHeight: height,
      );
      expect(
        decision.verification.reasons,
        contains(BoundaryReviewReason.touchesFrameEdge),
      );
    });

    test('a wider derived band flags a corner the legacy band missed', () {
      // One heatmap cell inside the right border on a 1000x700 frame. The
      // derived band is wider than 0.016 on the short axis, so a corner that
      // the fixed constant called "strictly interior" is now correctly called
      // contact on the BOTTOM side.
      final band = FrameEdgeBand.quantisation(
        frameWidth: width,
        frameHeight: height,
        inputPixels: 256,
        heatmapCells: 64,
      );
      expect(band.bottom, greaterThan(.016));
      final decision = verifyBoundary(
        BoundaryProposal(
          producer: BoundaryProducer.learnedModel,
          corners: [
            Point2(.2, .2),
            Point2(.8, .2),
            Point2(.8, 1 - band.bottom),
            Point2(.2, 1 - band.bottom),
          ],
          modelConfidence: .95,
          minAutoAcceptConfidence: .55,
          edgeBand: band,
        ),
        sourceWidth: width,
        sourceHeight: height,
      );
      expect(
        decision.verification.reasons,
        contains(BoundaryReviewReason.touchesFrameEdge),
      );
      expect(decision.cropAuthorization, isNull);
    });

    test('a corner two cells inside is not contact even with a wide band', () {
      final band = FrameEdgeBand.quantisation(
        frameWidth: width,
        frameHeight: height,
        inputPixels: 256,
        heatmapCells: 64,
      );
      final decision = verifyBoundary(
        BoundaryProposal(
          producer: BoundaryProducer.learnedModel,
          corners: [
            Point2(.2, .2),
            Point2(.8, .2),
            Point2(.8, 1 - 2 * band.bottom),
            Point2(.2, 1 - 2 * band.bottom),
          ],
          modelConfidence: .95,
          minAutoAcceptConfidence: .55,
          edgeBand: band,
        ),
        sourceWidth: width,
        sourceHeight: height,
      );
      expect(
        decision.verification.reasons,
        isNot(contains(BoundaryReviewReason.touchesFrameEdge)),
      );
      expect(decision.kind, BoundaryDecisionKind.accepted);
    });

    test('the band never widens the gate for a classical proposal', () {
      // A classical detector flags frame contact itself; its band stays legacy
      // so its behaviour does not change.
      final decision = verifyBoundary(
        BoundaryProposal(
          producer: BoundaryProducer.detector,
          corners: interior(),
        ),
        sourceWidth: width,
        sourceHeight: height,
      );
      expect(decision.proposal.edgeBand.left, FrameEdgeBand.agentlessBand);
    });
  });

  group('a score that passed is never reported as having failed', () {
    test('an uncorroborated but high score gets no low-confidence reason', () {
      // RC-09: a proposal kept in review only because the second detector was
      // missing must not also claim its score failed the bar.
      final decision = verifyBoundary(
        BoundaryProposal(
          producer: BoundaryProducer.learnedModel,
          corners: interior(),
          modelConfidence: .93,
          minAutoAcceptConfidence: .55,
          forceReview: true,
          forceReviewReason: BoundaryReviewReason.modelNotCorroborated,
        ),
        sourceWidth: width,
        sourceHeight: height,
      );
      expect(
        decision.verification.reasons,
        isNot(contains(BoundaryReviewReason.lowModelConfidence)),
      );
      expect(
        decision.verification.reasons,
        contains(BoundaryReviewReason.modelNotCorroborated),
      );
      expect(decision.cropAuthorization, isNull);
    });

    test('a score that did fail still gets the reason', () {
      final decision = verifyBoundary(
        BoundaryProposal(
          producer: BoundaryProducer.learnedModel,
          corners: interior(),
          modelConfidence: .40,
          minAutoAcceptConfidence: .55,
        ),
        sourceWidth: width,
        sourceHeight: height,
      );
      expect(
        decision.verification.reasons,
        contains(BoundaryReviewReason.lowModelConfidence),
      );
    });

    test('a malformed score fails closed rather than passing', () {
      for (final score in <double?>[
        null,
        -.01,
        1.01,
        double.nan,
        double.infinity,
      ]) {
        final decision = verifyBoundary(
          BoundaryProposal(
            producer: BoundaryProducer.learnedModel,
            corners: interior(),
            modelConfidence: score,
            minAutoAcceptConfidence: .55,
          ),
          sourceWidth: width,
          sourceHeight: height,
        );
        expect(decision.cropAuthorization, isNull, reason: '$score');
        expect(
          decision.verification.reasons,
          contains(BoundaryReviewReason.lowModelConfidence),
          reason: '$score',
        );
      }
    });

    test('a malformed stated minimum fails closed', () {
      for (final minimum in <double>[-.1, 1.5, double.nan]) {
        final decision = verifyBoundary(
          BoundaryProposal(
            producer: BoundaryProducer.learnedModel,
            corners: interior(),
            modelConfidence: .93,
            minAutoAcceptConfidence: minimum,
          ),
          sourceWidth: width,
          sourceHeight: height,
        );
        expect(decision.cropAuthorization, isNull, reason: '$minimum');
        expect(
          decision.verification.reasons,
          contains(BoundaryReviewReason.lowModelConfidence),
          reason: '$minimum',
        );
      }
    });
  });
}
