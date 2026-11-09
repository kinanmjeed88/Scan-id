import 'dart:developer' as developer;
import 'dart:typed_data';

import '../application/cancellation.dart';
import '../application/import_trace.dart';
import '../domain/boundary_decision.dart';
import '../domain/acceptance_policy.dart';
import '../domain/geometry.dart';
import 'docquad_model.dart';
import 'prepare_image.dart';

/// Strict two-model policy: run DocQuadNet first, then DocAligner on every
/// image because neither model has an independently calibrated score for the
/// target document set. When both return usable corners they must agree
/// geometrically, and then the primary's corners are retained unchanged.
/// Material disagreement or a lone proposal remains visible for manual review;
/// neither bypasses independent corroboration or authorizes a crop.
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
    final (sourceWidth, sourceHeight) = await ImportTrace.stage(
      'preprocessing',
      () => _previewDimensions(preview, cancellation),
      phase: 'boundary-preview',
    );
    final first = await _attempt(primary, preview, cancellation);
    cancellation?.throwIfCancelled();
    // Always execute the second AI detector: current confidence scores are not
    // calibrated on Iraqi cards, so geometry-valid DocQuad output is still an
    // uncertain proposal and cannot suppress the independent second opinion.
    final second = await _attempt(secondary, preview, cancellation);
    cancellation?.throwIfCancelled();

    final firstValid = _usable(first, sourceWidth, sourceHeight);
    final secondValid = _usable(second, sourceWidth, sourceHeight);
    if (firstValid && secondValid) {
      if (_materiallyDisagrees(
        first!.corners!,
        second!.corners!,
        sourceWidth,
        sourceHeight,
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
      // Agreement alone is not corroboration by a weak or review-only model.
      // Both independent decisions must authorize their geometry and score.
      if (!_accepted(first, sourceWidth, sourceHeight) ||
          !_accepted(second, sourceWidth, sourceHeight)) {
        return _uncorroborated(first);
      }
      return first;
    }
    // Preserve either lone proposal for the user without turning an absent
    // second opinion into permission for an automatic perspective crop.
    if (firstValid) return _uncorroborated(first!);
    if (secondValid) return _uncorroborated(second!);
    return null;
  }

  BoundaryProposal _uncorroborated(BoundaryProposal proposal) =>
      BoundaryProposal(
        producer: proposal.producer,
        corners: proposal.corners,
        region: proposal.region,
        imposedAspect: proposal.imposedAspect,
        imposedKindLabel: proposal.imposedKindLabel,
        modelConfidence: proposal.modelConfidence,
        minAutoAcceptConfidence: proposal.minAutoAcceptConfidence,
        touchesFrameEdge: proposal.touchesFrameEdge,
        forceReview: true,
        forceReviewReason:
            proposal.forceReviewReason ??
            BoundaryReviewReason.modelNotCorroborated,
      );

  Future<BoundaryProposal?> _attempt(
    BoundaryProposalModel model,
    Uint8List preview,
    CancellationToken? cancellation,
  ) async {
    try {
      return await model.suggestProposal(preview, cancellation: cancellation);
    } on OperationCancelled {
      rethrow;
    } on Object catch (error) {
      // Exception messages may contain paths or document content. Retain only
      // the fixed model id and error type while continuing to the fallback.
      developer.log(
        'Boundary detector ${model.modelId} failed '
        'type=${error.runtimeType}; continuing cascade.',
        name: 'scan_id.boundary',
      );
      return null;
    }
  }

  bool _accepted(BoundaryProposal? proposal, int width, int height) =>
      proposal != null &&
      meetsAcceptanceThreshold(
        proposal.modelConfidence,
        boundaryAcceptanceThreshold,
      ) &&
      verifyBoundary(proposal, sourceWidth: width, sourceHeight: height).kind ==
          BoundaryDecisionKind.accepted;

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

// Decode in an isolated scope without capturing the cascade or native models.
Future<(int, int)> _previewDimensions(
  Uint8List preview,
  CancellationToken? cancellation,
) => runCancellableIsolate(
  () {
    final source = decodeForProcessing(preview);
    return (source.width, source.height);
  },
  cancellation: cancellation,
  debugName: 'boundary-preview',
);
