import 'dart:developer' as developer;
import 'dart:typed_data';

import '../application/cancellation.dart';
import '../domain/boundary_decision.dart';
import '../domain/geometry.dart';
import 'docquad_model.dart';
import 'prepare_image.dart';

/// Strict two-model policy: run DocQuadNet first, then DocAligner on every
/// image because neither model has an independently calibrated score for the
/// target document set. A DocAligner result may stand alone only when the
/// primary is unusable; when both return usable corners they must agree
/// geometrically, and then the primary's corners are retained unchanged.
/// Material disagreement keeps DocQuadNet's corners visible with an explicit
/// review reason (never averages points or authorizes a crop). If the second
/// model fails, null deliberately sends intake to its existing classical path.
class BoundaryProposalCascade implements BoundaryProposalModel {
  BoundaryProposalCascade({
    required this.primary,
    required this.secondary,
    this.materialDisagreementFraction = 0.04,
  }) : assert(materialDisagreementFraction > 0);

  final BoundaryProposalModel primary;
  final BoundaryProposalModel secondary;

  /// Largest corresponding-corner displacement divided by image diagonal.
  /// This is a conservative routing threshold, not a detection-accuracy claim.
  final double materialDisagreementFraction;

  @override
  String get modelId => '${primary.modelId}->${secondary.modelId}';

  @override
  Future<BoundaryProposal?> suggestProposal(
    Uint8List preview, {
    CancellationToken? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final source = decodeForProcessing(preview);
    final first = await _attempt(primary, preview, cancellation);
    cancellation?.throwIfCancelled();
    // Always execute the second AI detector: current confidence scores are not
    // calibrated on Iraqi cards, so geometry-valid DocQuad output is still an
    // uncertain proposal and cannot suppress the independent second opinion.
    final second = await _attempt(secondary, preview, cancellation);
    cancellation?.throwIfCancelled();

    final firstValid = _usable(first, source.width, source.height);
    final secondValid = _usable(second, source.width, source.height);
    if (firstValid && secondValid) {
      if (_materiallyDisagrees(
        first!.corners!,
        second!.corners!,
        source.width,
        source.height,
      )) {
        return BoundaryProposal(
          producer: first.producer,
          corners: first.corners,
          modelConfidence: first.modelConfidence,
          minAutoAcceptConfidence: first.minAutoAcceptConfidence,
          forceReview: true,
          forceReviewReason: BoundaryReviewReason.modelDisagreement,
        );
      }
      // Do not combine outputs. Keep the already validated primary proposal;
      // confidence remains review-only under its own producer policy.
      return first;
    }
    if (!firstValid && secondValid) return second;

    // A primary-only result is not enough: stage 2 was required precisely
    // because neither model has a calibrated, independently safe accept gate.
    // Null lets LocalImageEditor invoke the existing classical detector.
    return null;
  }

  Future<BoundaryProposal?> _attempt(
    BoundaryProposalModel model,
    Uint8List preview,
    CancellationToken? cancellation,
  ) async {
    try {
      return await model.suggestProposal(
        preview,
        cancellation: cancellation,
      );
    } on OperationCancelled {
      rethrow;
    } on Object catch (error, stackTrace) {
      // Preserve a local diagnostic without exposing image bytes or blocking
      // the next independent model/fallback stage.
      developer.log(
        'Boundary detector ${model.modelId} failed; continuing cascade.',
        name: 'scan_id.boundary',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  bool _usable(BoundaryProposal? proposal, int width, int height) {
    if (proposal == null) return false;
    try {
      return verifyBoundary(
        proposal,
        sourceWidth: width,
        sourceHeight: height,
      ).verification.hasUsableGeometry;
    } on Object {
      return false;
    }
  }

  bool _materiallyDisagrees(
    List<Point2> first,
    List<Point2> second,
    int width,
    int height,
  ) {
    final diagonal = (width * width + height * height).toDouble();
    if (first.length != 4 || second.length != 4 || diagonal <= 0) return true;
    for (var i = 0; i < 4; i++) {
      final dx = (first[i].x - second[i].x) * width;
      final dy = (first[i].y - second[i].y) * height;
      if ((dx * dx + dy * dy) / diagonal >
          materialDisagreementFraction * materialDisagreementFraction) {
        return true;
      }
    }
    return false;
  }
}
