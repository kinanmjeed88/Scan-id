import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../domain/boundary_decision.dart';
import '../domain/geometry.dart';
import 'document_detector.dart';
import 'prepare_image.dart';

/// Measured arbitration between a learned boundary proposal and the local
/// classical detector.
///
/// Problem it solves: two uncalibrated models can both return a geometrically
/// VALID quadrilateral that is nowhere near the physical card in an otherwise
/// clear photo. `assessQuad` only checks the four points as a polygon; it can
/// never notice that they sit in the middle of the card. This module measures
/// every candidate against the image's own gradients and keeps the best
/// MEASURED one, optionally snapping its corners to the nearest strong edges.
///
/// Honesty constraints:
/// - No score is invented. `QuadEdgeEvidence` is a measured edge-support
///   fraction; classical proposals keep `producer: detector`, so
///   `verifyBoundary` still routes them to manual review.
/// - Independent corroboration for automatic cropping is NOT claimed here: a
///   learned proposal that wins keeps its own score and review flags.
/// - Refinement is a coordinate adjustment of the SAME claim, not a new claim.

/// One measured candidate, with the corners that should actually be shown to
/// the user (refined to edges when that improved measured support).
class MeasuredBoundaryCandidate {
  const MeasuredBoundaryCandidate({
    required this.corners,
    required this.originalCorners,
    required this.evidence,
    required this.wasRefined,
  });

  final List<Point2> corners;
  final List<Point2> originalCorners;
  final QuadEdgeEvidence evidence;
  final bool wasRefined;
}

class BoundaryMeasurements {
  const BoundaryMeasurements({
    required this.sourceWidth,
    required this.sourceHeight,
    this.learned,
    this.classical,
  });

  final int sourceWidth;
  final int sourceHeight;
  final MeasuredBoundaryCandidate? learned;
  final MeasuredBoundaryCandidate? classical;
}

/// Runs in an isolate: decode once, detect the classical candidate once, and
/// measure BOTH quads against the same gradient fields.
///
/// [encodedLearnedCorners] is `[x0..x3, y0..y3]`, a plain payload that cannot
/// carry a native model handle into the isolate.
BoundaryMeasurements measureBoundaryCandidates(
  Uint8List preview,
  List<double>? encodedLearnedCorners,
) {
  final image = decodeForProcessing(preview);
  List<Point2>? learnedCorners;
  if (encodedLearnedCorners != null && encodedLearnedCorners.length == 8) {
    learnedCorners = [
      for (var i = 0; i < 4; i++)
        Point2(encodedLearnedCorners[i], encodedLearnedCorners[i + 4]),
    ];
  }
  final classicalCorners = detectDocumentCornersScored(image)?.corners;
  return BoundaryMeasurements(
    sourceWidth: image.width,
    sourceHeight: image.height,
    learned: learnedCorners == null ? null : _measure(image, learnedCorners),
    classical: classicalCorners == null
        ? null
        : _measure(image, classicalCorners),
  );
}

MeasuredBoundaryCandidate? _measure(img.Image image, List<Point2> corners) {
  if (!quadFitsImage(corners, image)) return null;
  final original = measureQuadEdges(image, corners);
  if (original == null) return null;
  final refined = refineQuadToEdges(image, corners);
  if (refined != null && quadFitsImage(refined, image)) {
    final refinedEvidence = measureQuadEdges(image, refined);
    if (refinedEvidence != null &&
        refinedEvidence.quality >= original.quality) {
      return MeasuredBoundaryCandidate(
        corners: refined,
        originalCorners: corners,
        evidence: refinedEvidence,
        wasRefined: true,
      );
    }
  }
  return MeasuredBoundaryCandidate(
    corners: corners,
    originalCorners: corners,
    evidence: original,
    wasRefined: false,
  );
}

/// Largest corresponding-corner displacement as a fraction of the image
/// diagonal. Shared with the two-model cascade's disagreement rule.
double boundaryDisagreement(
  List<Point2> first,
  List<Point2> second,
  int width,
  int height,
) {
  if (first.length != 4 || second.length != 4) return 1;
  final diagonal = math.sqrt(width * width + height * height.toDouble());
  if (!diagonal.isFinite || diagonal <= 0) return 1;
  var worst = 0.0;
  for (var i = 0; i < 4; i++) {
    final dx = (first[i].x - second[i].x) * width;
    final dy = (first[i].y - second[i].y) * height;
    worst = math.max(worst, math.sqrt(dx * dx + dy * dy) / diagonal);
  }
  return worst;
}

/// Above this measured-quality margin the classical candidate wins over a
/// materially different learned quad. Small differences keep the learned
/// proposal (and its score/flags) visible for review.
const double measuredQualityMargin = .10;

/// Chooses the proposal to show for editing. Never authorizes a crop.
BoundaryProposal? arbitrateBoundaryProposal({
  required BoundaryProposal? learned,
  required BoundaryMeasurements measurements,
}) {
  final measuredLearned = measurements.learned;
  final measuredClassical = measurements.classical;
  final width = measurements.sourceWidth;
  final height = measurements.sourceHeight;
  final learnedCorners = learned?.corners;
  final learnedValid =
      learned != null && learnedCorners != null && learnedCorners.length == 4;

  if (!learnedValid) {
    return measuredClassical == null
        ? null
        : BoundaryProposal(
            producer: BoundaryProducer.detector,
            corners: measuredClassical.corners,
          );
  }

  // A lone learned proposal: keep its evidence and review state, but show
  // corners snapped to measured edges when that improved support.
  if (measuredClassical == null) {
    return _withCorners(learned!, measuredLearned?.corners ?? learnedCorners!);
  }

  final classicalCorners = measuredClassical.corners;
  final agrees =
      boundaryDisagreement(
        measuredLearned?.originalCorners ?? learnedCorners!,
        measuredClassical.originalCorners,
        width,
        height,
      ) <
      .04;
  if (agrees) {
    return _withCorners(learned!, measuredLearned?.corners ?? learnedCorners!);
  }

  final learnedQuality = measuredLearned?.evidence.quality ?? 0.0;
  final classicalQuality = measuredClassical.evidence.quality;
  if (classicalQuality > learnedQuality + measuredQualityMargin) {
    // The learned points do not sit on the visible edges; the independent
    // edge-based candidate measures better. It is still review-only.
    return BoundaryProposal(
      producer: BoundaryProducer.detector,
      corners: classicalCorners,
      forceReview: true,
      forceReviewReason: BoundaryReviewReason.modelDisagreement,
    );
  }
  return BoundaryProposal(
    producer: learned!.producer,
    corners: measuredLearned?.corners ?? learnedCorners!,
    region: learned.region,
    imposedAspect: learned.imposedAspect,
    imposedKindLabel: learned.imposedKindLabel,
    modelConfidence: learned.modelConfidence,
    minAutoAcceptConfidence: learned.minAutoAcceptConfidence,
    touchesFrameEdge: learned.touchesFrameEdge,
    forceReview: true,
    forceReviewReason: BoundaryReviewReason.modelDisagreement,
  );
}

BoundaryProposal _withCorners(BoundaryProposal source, List<Point2> corners) =>
    BoundaryProposal(
      producer: source.producer,
      corners: corners,
      region: source.region,
      imposedAspect: source.imposedAspect,
      imposedKindLabel: source.imposedKindLabel,
      modelConfidence: source.modelConfidence,
      minAutoAcceptConfidence: source.minAutoAcceptConfidence,
      touchesFrameEdge: source.touchesFrameEdge,
      forceReview: source.forceReview,
      forceReviewReason: source.forceReviewReason,
    );
