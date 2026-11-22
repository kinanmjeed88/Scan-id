import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/domain/frame_edge_band.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/imaging/boundary_proposal_cascade.dart';
import 'package:scan_id/imaging/docquad_model.dart';

/// Integration tests for the two-model cascade's own arithmetic.
///
/// SYNTHETIC MODELS: every detector below is a double that returns fixed
/// coordinates. Nothing here measures detection accuracy, and no number in this
/// file may be reported as a model result.
void main() {
  final preview = Uint8List.fromList(
    img.encodePng(img.Image(width: 1000, height: 700)),
  );

  List<Point2> quad({double left = .12, double right = .88}) => [
    Point2(left, .12),
    Point2(right, .12),
    Point2(right, .88),
    Point2(left, .88),
  ];

  BoundaryProposal learned(List<Point2> corners, {double score = .4}) =>
      BoundaryProposal(
        producer: BoundaryProducer.learnedModel,
        corners: corners,
        modelConfidence: score,
        minAutoAcceptConfidence: .55,
      );

  test('a cyclic re-indexing of the same quad is not a disagreement', () async {
    // The same four physical corners, numbered from a different corner. This is
    // the RC-08 defect: corner i was paired with corner i, so a model whose
    // channels start elsewhere looked like it had found a different document.
    final primary = learned(quad(), score: .95);
    final secondary = learned([
      quad()[1],
      quad()[2],
      quad()[3],
      quad()[0],
    ], score: .95);
    final cascade = BoundaryProposalCascade(
      primary: _FakeModel('primary', primary),
      secondary: _FakeModel('secondary', secondary),
    );

    final proposal = await cascade.suggestProposal(preview);

    expect(proposal!.forceReview, isFalse);
    expect(proposal.disagreementFraction, closeTo(0, 1e-9));
    expect(
      proposal.forceReviewReason,
      isNot(BoundaryReviewReason.modelDisagreement),
    );
  });

  test('a real displacement is still reported as a disagreement', () async {
    final cascade = BoundaryProposalCascade(
      primary: _FakeModel('primary', learned(quad(), score: .95)),
      secondary: _FakeModel(
        'secondary',
        learned(quad(left: .2, right: .96), score: .95),
      ),
    );

    final proposal = await cascade.suggestProposal(preview);

    expect(proposal!.forceReview, isTrue);
    expect(proposal.forceReviewReason, BoundaryReviewReason.modelDisagreement);
    expect(proposal.disagreementFraction, greaterThan(.04));
  });

  test(
    'a lone strong proposal reports its own score, not a substitute',
    () async {
      // RC-09: a proposal that was never corroborated must keep the score the
      // model actually produced, so nothing downstream can read a routing
      // constant as if it were measured confidence.
      final cascade = BoundaryProposalCascade(
        primary: _FakeModel('primary', learned(quad(), score: .93)),
        secondary: _FakeModel('secondary')..fail = true,
      );

      final proposal = await cascade.suggestProposal(preview);

      expect(proposal!.modelConfidence, .93);
      expect(
        proposal.forceReviewReason,
        BoundaryReviewReason.modelNotCorroborated,
      );
    },
  );

  test(
    'a low lone proposal keeps its low score rather than being rounded up',
    () async {
      final cascade = BoundaryProposalCascade(
        primary: _FakeModel('primary', learned(quad(), score: .21)),
        secondary: _FakeModel('secondary')..fail = true,
      );

      final proposal = await cascade.suggestProposal(preview);

      expect(proposal!.modelConfidence, .21);
    },
  );

  test('an edge band from the winning producer survives the cascade', () async {
    // The band is a property of the model that produced the corners. If the
    // cascade rebuilt the proposal without it, the edge gate would silently
    // fall back to the legacy constant and re-measure the wrong thing.
    const band = FrameEdgeBand(
      left: .011,
      top: .023,
      right: .011,
      bottom: .023,
    );
    final cascade = BoundaryProposalCascade(
      primary: _FakeModel('primary', learned(quad(), score: .95), band: band),
      secondary: _FakeModel(
        'secondary',
        learned(quad(), score: .95),
        band: band,
      ),
    );

    final proposal = await cascade.suggestProposal(preview);

    expect(proposal!.edgeBand.left, band.left);
    expect(proposal.edgeBand.top, band.top);
  });
}

/// A detector double. It returns a fixed proposal and never runs a model.
class _FakeModel implements BoundaryProposalModel {
  _FakeModel(this.modelId, [this.proposal, FrameEdgeBand? band])
    : emittedBand = band ?? FrameEdgeBand.legacy;

  @override
  final String modelId;
  final BoundaryProposal? proposal;
  final FrameEdgeBand emittedBand;
  bool fail = false;

  @override
  Future<BoundaryProposal?> suggestProposal(
    Uint8List preview, {
    CancellationToken? cancellation,
  }) async {
    if (fail) throw StateError('synthetic model failure');
    final source = proposal;
    if (source == null) return null;
    return BoundaryProposal(
      producer: source.producer,
      corners: source.corners,
      region: source.region,
      modelConfidence: source.modelConfidence,
      minAutoAcceptConfidence: source.minAutoAcceptConfidence,
      touchesFrameEdge: source.touchesFrameEdge,
      forceReview: source.forceReview,
      forceReviewReason: source.forceReviewReason,
      edgeBand: emittedBand,
    );
  }
}
