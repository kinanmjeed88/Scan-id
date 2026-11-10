import 'dart:developer' as developer;
import 'dart:math' as math;
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
    final (first, firstError) = await _attempt(primary, preview, cancellation);
    cancellation?.throwIfCancelled();
    // Always execute the second AI detector: current confidence scores are not
    // calibrated on Iraqi cards, so geometry-valid DocQuad output is still an
    // uncertain proposal and cannot suppress the independent second opinion.
    final (second, secondError) = await _attempt(
      secondary,
      preview,
      cancellation,
    );
    cancellation?.throwIfCancelled();

    final firstValid = _usable(first, sourceWidth, sourceHeight);
    final secondValid = _usable(second, sourceWidth, sourceHeight);
    final traces = [
      _traceOf(primary, first, errorType: firstError, usable: firstValid),
      _traceOf(secondary, second, errorType: secondError, usable: secondValid),
    ];
    if (firstValid && secondValid) {
      final disagreement = _disagreementFraction(
        first!.corners!,
        second!.corners!,
        sourceWidth,
        sourceHeight,
      );
      if (_materiallyDisagrees(disagreement)) {
        return first
            .withDiagnostics(
              traces: traces,
              disagreementFraction: disagreement,
            )
            .withReview(
              forceReview: true,
              forceReviewReason: BoundaryReviewReason.modelDisagreement,
            );
      }
      // Agreement alone is not corroboration by a weak or review-only model.
      // Both independent decisions must authorize their geometry and score.
      if (!_accepted(first, sourceWidth, sourceHeight) ||
          !_accepted(second, sourceWidth, sourceHeight)) {
        return _uncorroborated(
          first,
          traces: traces,
          disagreement: disagreement,
        );
      }
      return first.withDiagnostics(
        traces: traces,
        disagreementFraction: disagreement,
      );
    }
    // Preserve either lone proposal for the user without turning an absent
    // second opinion into permission for an automatic perspective crop.
    if (firstValid) {
      return _uncorroborated(first!, traces: traces);
    }
    if (secondValid) {
      return _uncorroborated(second!, traces: traces);
    }
    // Neither detector produced usable geometry. The proposal carries no
    // corners but keeps the factual trace, so the decision and the journey
    // report can say WHICH detector was missing and WHY.
    return BoundaryProposal(
      producer: BoundaryProducer.learnedModel,
      forceReview: true,
      forceReviewReason: BoundaryReviewReason.modelNotCorroborated,
      traces: traces,
    );
  }

  /// True when the measured corner displacement exceeds the shared tolerance,
  /// so the two models are describing different quadrilaterals. The number
  /// itself is kept for the audit trail; this predicate is the decision.
  bool _materiallyDisagrees(double disagreementFraction) =>
      disagreementFraction > materialDisagreementFraction;

  BoundaryDetectorTrace _traceOf(
    BoundaryProposalModel model,
    BoundaryProposal? proposal, {
    required String? errorType,
    required bool usable,
  }) {
    if (errorType != null) {
      return BoundaryDetectorTrace(
        modelId: model.modelId,
        outcome: BoundaryDetectorOutcome.failed,
        errorType: errorType,
      );
    }
    if (proposal?.corners == null) {
      return BoundaryDetectorTrace(
        modelId: model.modelId,
        outcome: BoundaryDetectorOutcome.noQuad,
      );
    }
    return BoundaryDetectorTrace(
      modelId: model.modelId,
      outcome: usable
          ? BoundaryDetectorOutcome.proposal
          : BoundaryDetectorOutcome.geometryRejected,
      confidence: proposal!.modelConfidence,
    );
  }

  BoundaryProposal _uncorroborated(
    BoundaryProposal proposal, {
    List<BoundaryDetectorTrace> traces = const [],
    double? disagreement,
  }) => proposal
      .withDiagnostics(traces: traces, disagreementFraction: disagreement)
      .withReview(
        forceReview: true,
        forceReviewReason:
            proposal.forceReviewReason ??
            BoundaryReviewReason.modelNotCorroborated,
      );

  Future<(BoundaryProposal?, String?)> _attempt(
    BoundaryProposalModel model,
    Uint8List preview,
    CancellationToken? cancellation,
  ) async {
    try {
      final proposal = await model.suggestProposal(
        preview,
        cancellation: cancellation,
      );
      return (proposal, null);
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
      return (null, '${error.runtimeType}');
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

  /// Largest corner displacement between the two models, as a fraction of the
  /// image diagonal. A malformed pair reports total disagreement (1.0) rather
  /// than a friendly zero.
  double _disagreementFraction(
    List<Point2> first,
    List<Point2> second,
    int width,
    int height,
  ) {
    final diagonalSquared = (width * width + height * height).toDouble();
    if (first.length != 4 || second.length != 4 || diagonalSquared <= 0) {
      return 1;
    }
    var worst = 0.0;
    for (var i = 0; i < 4; i++) {
      final dx = (first[i].x - second[i].x) * width;
      final dy = (first[i].y - second[i].y) * height;
      final fraction = math.sqrt((dx * dx + dy * dy) / diagonalSquared);
      if (fraction > worst) worst = fraction;
    }
    return worst;
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
