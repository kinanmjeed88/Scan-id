import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../domain/boundary_decision.dart';
import '../domain/geometry.dart';
import '../domain/quad_assessment.dart';
import 'document_detector.dart';
import 'prepare_image.dart';

/// Measured arbitration between a learned boundary proposal and the local
/// classical detector.
///
/// Problem it solves: two uncalibrated models can both return a geometrically
/// VALID quadrilateral that is nowhere near the physical card in an otherwise
/// clear photo. `assessQuad` only checks the four points as a polygon; it can
/// never notice that they sit in the middle of the card. This module measures
/// every candidate against the image's own gradients and compares them on one
/// scale.
///
/// Edge support is ONE signal, never the sole decision. A printed inner frame,
/// a logo or a strong text row can have sharper gradients than the physical
/// card edge; choosing purely by gradient strength would crop the wrong thing.
/// Before any replacement the candidate must additionally pass geometry,
/// area, frame-edge, measured-region and physical-aspect gates, and an inner
/// quad is never allowed to replace the quad that contains it.
///
/// Honesty constraints:
/// - No score is invented. `QuadEdgeEvidence` is a measured edge-support
///   fraction; classical proposals keep `producer: detector`, so
///   `verifyBoundary` still routes them to manual review.
/// - This module never grants or redefines automatic acceptance. A learned
///   proposal that wins keeps its own score and review flags; a classical win
///   is always forced to review.
/// - Refinement is a bounded coordinate adjustment of the SAME claim, not a
///   new claim, and is rejected when a corner would jump to a distant edge.

/// One measured candidate, with the corners that should actually be shown to
/// the user (refined to nearby edges when that improved measured support).
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

/// Largest corresponding-corner displacement as a fraction of the image
/// diagonal. Shared with the two-model cascade's disagreement rule.
const double boundaryAgreementTolerance = .04;

/// Above this measured-quality margin the classical candidate may replace a
/// materially different learned quad (after all other gates pass).
const double measuredQualityMargin = .10;

/// Minimum fraction of the source a replacement quad may cover. A tiny
/// high-contrast patch is not a document boundary.
const double minPlausibleAreaFraction = .05;

/// A corner this close to the camera frame suggests physical clipping; a
/// replacement is not allowed to introduce that ambiguity. Matches the
/// frame-edge tolerance used by `verifyBoundary`.
const double frameTouchTolerance = .016;

/// Maximum fraction of the image diagonal a snapped corner may move. Beyond
/// this the "nearest strong edge" is a different edge, not a refinement.
const double maxRefinementDisplacement = .04;

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
  if (refined != null &&
      quadFitsImage(refined, image) &&
      (!touchesFrameEdge(refined) || touchesFrameEdge(corners)) &&
      withinRefinementDisplacement(
        corners,
        refined,
        image.width,
        image.height,
      )) {
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

bool withinRefinementDisplacement(
  List<Point2> original,
  List<Point2> refined,
  int width,
  int height,
) =>
    boundaryDisagreement(original, refined, width, height) <=
    maxRefinementDisplacement;

/// Whether [point] lies inside a convex, clockwise quadrilateral.
bool pointInConvexQuad(Point2 point, List<Point2> quad) {
  if (quad.length != 4) return false;
  const epsilon = 1e-6;
  for (var i = 0; i < 4; i++) {
    final a = quad[i];
    final b = quad[(i + 1) % 4];
    final cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x);
    if (cross < -epsilon) return false;
  }
  return true;
}

/// Whether [inner] is strictly contained by [outer]. Used to stop an inner
/// printed frame from winning on gradient strength alone.
bool containsQuad(List<Point2> outer, List<Point2> inner) {
  if (outer.length != 4 || inner.length != 4) return false;
  if (!inner.every((point) => pointInConvexQuad(point, outer))) return false;
  return outer.any((point) => !pointInConvexQuad(point, inner));
}

bool touchesFrameEdge(List<Point2> corners) => corners.any(
  (point) =>
      point.x <= frameTouchTolerance ||
      point.x >= 1 - frameTouchTolerance ||
      point.y <= frameTouchTolerance ||
      point.y >= 1 - frameTouchTolerance,
);

/// Whether every corner stays inside a segmenter-measured normalized region
/// `[left, top, right, bottom]`. Stricter than `verifyBoundary`'s centre/overlap
/// test because this gate decides between two competing claims.
bool quadInRegion(List<Point2> corners, List<double> region) {
  if (region.length != 4 || corners.length != 4) return false;
  const epsilon = 1e-3;
  final left = region[0] - epsilon;
  final top = region[1] - epsilon;
  final right = region[2] + epsilon;
  final bottom = region[3] + epsilon;
  if (right <= left || bottom <= top) return false;
  return corners.every(
    (point) =>
        point.x >= left &&
        point.x <= right &&
        point.y >= top &&
        point.y <= bottom,
  );
}

double areaFractionOf(List<Point2> corners, int width, int height) =>
    assessQuad(
      corners,
      sourceWidth: width,
      sourceHeight: height,
    ).areaFraction ??
    0.0;

double? aspectClaimDisagreement(
  List<Point2> corners,
  int width,
  int height,
  double? imposedAspect,
) {
  if (imposedAspect == null || !imposedAspect.isFinite || imposedAspect <= 0) {
    return null;
  }
  final aspect = assessQuad(
    corners,
    sourceWidth: width,
    sourceHeight: height,
  ).aspect;
  if (aspect == null || !aspect.isFinite || aspect <= 0) {
    return double.infinity;
  }
  return (aspect - imposedAspect).abs() / imposedAspect;
}

/// A candidate may REPLACE another claim only when it is a plausible whole
/// document boundary: strong edges on every side, a real area, no frame-edge
/// ambiguity, and no contradiction of a classifier's physical aspect claim.
/// Edge support alone is explicitly insufficient.
bool isPlausibleBoundary(
  MeasuredBoundaryCandidate candidate,
  int width,
  int height, {
  double? imposedAspect,
}) {
  final assessment = assessQuad(
    candidate.corners,
    sourceWidth: width,
    sourceHeight: height,
  );
  if (!assessment.acceptable) return false;
  if (!candidate.evidence.looksLikeBoundary) return false;
  if ((assessment.areaFraction ?? 0) < minPlausibleAreaFraction) return false;
  if (touchesFrameEdge(candidate.corners)) return false;
  final aspect = assessment.aspect;
  if (imposedAspect != null &&
      imposedAspect > 0 &&
      imposedAspect.isFinite &&
      aspect != null &&
      aspect > 0) {
    final ratio = aspect >= imposedAspect
        ? aspect / imposedAspect
        : imposedAspect / aspect;
    if (ratio > maxAspectClaimRatio) return false;
  }
  return true;
}

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
        : _classicalProposal(measuredClassical);
  }

  final displayedLearned = measuredLearned?.corners ?? learnedCorners;

  // A lone learned claim is kept with its own evidence and review state.
  if (measuredClassical == null) {
    return _withCorners(learned, displayedLearned);
  }

  final classicalCorners = measuredClassical.corners;
  final agrees =
      boundaryDisagreement(
        measuredLearned?.originalCorners ?? learnedCorners,
        measuredClassical.originalCorners,
        width,
        height,
      ) <
      boundaryAgreementTolerance;
  if (agrees) {
    // Independent agreement: keep the learned score and flags untouched, so
    // the existing 55% acceptance path and all of `verifyBoundary`'s safety
    // checks still apply unchanged.
    return _withCorners(learned, displayedLearned);
  }

  // ---- Disagreement: a replacement needs more than sharper gradients. ----
  if (!isPlausibleBoundary(
    measuredClassical,
    width,
    height,
    imposedAspect: learned.imposedAspect,
  )) {
    return _keepLearned(learned, displayedLearned);
  }

  final region = learned.region;
  if (region != null &&
      region.length == 4 &&
      !quadInRegion(classicalCorners, region)) {
    return _keepLearned(learned, displayedLearned);
  }

  // An inner quad with sharper gradients is a printed frame, not the card.
  if (containsQuad(displayedLearned, classicalCorners)) {
    return _keepLearned(learned, displayedLearned);
  }
  // Even sharp learned edges can be a printed inner frame. A plausible,
  // materially different containing outer boundary is contradictory evidence,
  // not permission to discard document margins based on score strength.
  if (containsQuad(classicalCorners, displayedLearned)) {
    return _classicalWins(measuredClassical);
  }
  final learnedPlausible =
      measuredLearned != null &&
      isPlausibleBoundary(
        measuredLearned,
        width,
        height,
        imposedAspect: learned.imposedAspect,
      );
  if (learnedPlausible) {
    final learnedAspectError = aspectClaimDisagreement(
      displayedLearned,
      width,
      height,
      learned.imposedAspect,
    );
    final classicalAspectError = aspectClaimDisagreement(
      classicalCorners,
      width,
      height,
      learned.imposedAspect,
    );
    if (learnedAspectError != null &&
        classicalAspectError != null &&
        classicalAspectError > learnedAspectError + 1e-6) {
      return _keepLearned(learned, displayedLearned);
    }
    if (measuredLearned.evidence.score > 0 &&
        measuredClassical.evidence.score > 0 &&
        measuredClassical.evidence.score < measuredLearned.evidence.score) {
      return _keepLearned(learned, displayedLearned);
    }
  }
  // When the learned quad is an unsupported inner frame, the containing outer
  // quad wins when it measures at least as well.
  if (!learnedPlausible &&
      containsQuad(classicalCorners, displayedLearned) &&
      measuredClassical.evidence.quality >=
          (measuredLearned?.evidence.quality ?? 0)) {
    return _classicalWins(measuredClassical);
  }

  // Never shrink the crop on gradient strength alone.
  if (areaFractionOf(classicalCorners, width, height) + 1e-6 <
      areaFractionOf(displayedLearned, width, height)) {
    return _keepLearned(learned, displayedLearned);
  }

  final learnedQuality = measuredLearned?.evidence.quality ?? 0.0;
  if (measuredClassical.evidence.quality >
      learnedQuality + measuredQualityMargin) {
    return _classicalWins(measuredClassical);
  }
  return _keepLearned(learned, displayedLearned);
}

BoundaryProposal _classicalProposal(MeasuredBoundaryCandidate candidate) =>
    BoundaryProposal(
      producer: BoundaryProducer.detector,
      corners: candidate.corners,
      touchesFrameEdge: touchesFrameEdge(candidate.corners),
    );

BoundaryProposal _classicalWins(MeasuredBoundaryCandidate candidate) =>
    BoundaryProposal(
      producer: BoundaryProducer.detector,
      corners: candidate.corners,
      forceReview: true,
      forceReviewReason: BoundaryReviewReason.modelDisagreement,
    );

BoundaryProposal _keepLearned(BoundaryProposal source, List<Point2> corners) =>
    BoundaryProposal(
      producer: source.producer,
      corners: corners,
      region: source.region,
      imposedAspect: source.imposedAspect,
      imposedKindLabel: source.imposedKindLabel,
      modelConfidence: source.modelConfidence,
      minAutoAcceptConfidence: source.minAutoAcceptConfidence,
      touchesFrameEdge: source.touchesFrameEdge,
      forceReview: true,
      forceReviewReason: source.forceReview
          ? (source.forceReviewReason ?? BoundaryReviewReason.modelDisagreement)
          : BoundaryReviewReason.modelDisagreement,
    );

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
