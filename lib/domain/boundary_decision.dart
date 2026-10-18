/// Proposal → Verification → Decision for document boundaries.
///
/// This is the contract the boundary audits (docs/reports/
/// DOCUMENT_BOUNDARY_AUDIT_2026-10-17.md and the second critical review)
/// found missing: a detected quadrilateral used to travel straight from a
/// proposer (the classical corner detector, the segmenter, or a future
/// learned model) into a saved crop, with no stage whose job is to decide
/// whether that proposal may become a crop at all.
///
/// The three roles are deliberately separate and separately testable:
///
/// - [BoundaryProposal] — a CLAIM: "these corners may bound a document",
///   plus the evidence context the claim arrived with (its producer, the
///   measured region it came from, the physical aspect a classifier wants
///   to impose on it). A proposal is never a crop permission.
/// - [verifyBoundary] — verification over the proposal using the existing,
///   named geometry measurements ([assessQuad]) plus structural agreement
///   checks (the proposal must describe the region it claims, and its
///   measured shape must not contradict the size that would be imposed on
///   it). Verification NEVER invents a probability: it emits measured
///   values and machine-readable reason codes.
/// - [BoundaryDecision] — the only gate a crop path may consult:
///   [BoundaryDecisionKind.accepted] is the sole outcome allowed to become
///   an automatic crop; every other outcome keeps the source whole and
///   routes to manual review or refusal with its reasons attached.
///
/// Honesty constraint (second review §2): re-measuring edge evidence that
/// already selected a candidate is NOT independent statistical
/// confirmation, and nothing here claims it is. This gate's value is that
/// rejection becomes possible at all after a proposer has spoken, that the
/// measured-vs-imposed aspect disagreement (previously hidden by forcing
/// the catalog aspect onto the warp) becomes an explicit review reason,
/// and that ambiguous cases fail safe instead of failing silently.
///
/// No acceptance threshold is invented here. The aspect-claim bound reuses
/// the project's own pre-existing geometric-implausibility limit — the 2.5×
/// opposite-side ratio at which [assessQuad] already refuses a quadrilateral
/// as physically implausible. A claimed size whose aspect differs from the
/// measured shape by more than that factor is not a stretch, it is a
/// different document; milder disagreements (ordinary perspective and
/// detector noise routinely produce them in raw pixel space) keep the
/// established catalog behaviour.
library;

import 'geometry.dart';
import 'quad_assessment.dart';

/// Largest factor by which a measured shape and an imposed physical aspect
/// may disagree before the claim is treated as describing a different
/// document. Mirrors the 2.5× implausibility bound `assessQuad` already
/// applies to opposite-side ratios — reused, not tuned.
const double maxAspectClaimRatio = 2.5;

/// Who produced a boundary claim. Recorded so a later proposer (e.g. a
/// learned model behind its own licence/evidence gate) can be swapped in
/// without changing the decision contract or rewriting provenance.
enum BoundaryProducer {
  detector,
  segmenter,
  wholeFrameDetector,
  manual,
  learnedModel,
}

/// The three outcomes a boundary claim may receive.
///
/// Only [accepted] may become an automatic crop. [needsReview] keeps every
/// pixel of the source available for a manual boundary; [rejected] means
/// the claim is not a boundary at all (its evidence stays attached).
enum BoundaryDecisionKind { accepted, needsReview, rejected }

/// Machine-readable reasons a decision was not [BoundaryDecisionKind.accepted].
/// Rendered for users by the caller; never silently dropped.
enum BoundaryReviewReason {
  /// The proposer found no quadrilateral.
  noBoundary,

  /// The quadrilateral is not even a candidate boundary (wrong point count).
  notABoundary,

  /// Geometry validation failed; [BoundaryVerification.assessment] names why.
  geometryRejected,

  /// The measured shape contradicts the physical aspect that classification
  /// would impose on the crop — the disagreement the catalog-aspect warp
  /// used to hide by stretching.
  aspectMismatch,

  /// The quadrilateral does not describe the measured region it came from.
  quadOutsideRegion,
}

/// One boundary CLAIM about one document inside one source image.
class BoundaryProposal {
  const BoundaryProposal({
    required this.producer,
    this.corners,
    this.region,
    this.imposedAspect,
    this.imposedKindLabel,
  });

  /// Normalized corners (CropGeometry order), or null when the proposer
  /// found no trustworthy quadrilateral.
  final List<Point2>? corners;

  /// Normalized `[left, top, right, bottom]` measured region this claim
  /// came from, when a segmenter measured one.
  final List<double>? region;

  final BoundaryProducer producer;

  /// Long/short aspect of the physical size a classifier wants to impose
  /// on this crop, when one was claimed. Compared against the MEASURED
  /// aspect; a contradiction is a review reason, never a silent stretch.
  final double? imposedAspect;

  /// Human-readable label of the kind behind [imposedAspect], for messages.
  final String? imposedKindLabel;
}

/// What verification measured about a proposal. Every field is a measured
/// value or an explicit absence — nothing is fabricated to fill a gap.
class BoundaryVerification {
  const BoundaryVerification({
    required this.assessment,
    required this.reasons,
    this.measuredAspect,
  });

  /// Geometry assessment of the corners, null when there were none to assess.
  final QuadAssessment? assessment;

  /// Why this proposal may not be auto-cropped; empty when it may.
  final List<BoundaryReviewReason> reasons;

  /// Long/short aspect measured from the quadrilateral in pixel space,
  /// present only for an accepted-geometry proposal.
  final double? measuredAspect;

  bool get hasUsableGeometry => assessment?.acceptable ?? false;
}

/// The gated outcome. A crop path must switch on [kind]; constructing a
/// crop from a proposal that has no [BoundaryDecision] is a contract bug.
class BoundaryDecision {
  const BoundaryDecision({
    required this.kind,
    required this.proposal,
    required this.verification,
  });

  final BoundaryDecisionKind kind;
  final BoundaryProposal proposal;
  final BoundaryVerification verification;

  /// The corners a crop may use — present only when [kind] is accepted.
  List<Point2>? get acceptedCorners =>
      kind == BoundaryDecisionKind.accepted ? proposal.corners : null;
}

/// Verifies [proposal] against the source dimensions it was measured on.
///
/// Conservative by construction: absent or contradictory evidence ends in
/// review, not acceptance, and nothing here crops, saves or mutates.
BoundaryDecision verifyBoundary(
  BoundaryProposal proposal, {
  required int sourceWidth,
  required int sourceHeight,
}) {
  final corners = proposal.corners;
  if (corners == null) {
    return BoundaryDecision(
      kind: BoundaryDecisionKind.needsReview,
      proposal: proposal,
      verification: const BoundaryVerification(
        assessment: null,
        reasons: [BoundaryReviewReason.noBoundary],
      ),
    );
  }
  if (corners.length != 4) {
    return BoundaryDecision(
      kind: BoundaryDecisionKind.rejected,
      proposal: proposal,
      verification: const BoundaryVerification(
        assessment: null,
        reasons: [BoundaryReviewReason.notABoundary],
      ),
    );
  }
  final assessment = assessQuad(
    corners,
    sourceWidth: sourceWidth,
    sourceHeight: sourceHeight,
  );
  if (!assessment.acceptable) {
    return BoundaryDecision(
      kind: BoundaryDecisionKind.needsReview,
      proposal: proposal,
      verification: BoundaryVerification(
        assessment: assessment,
        reasons: const [BoundaryReviewReason.geometryRejected],
      ),
    );
  }
  final measuredAspect = assessment.aspect!;
  final reasons = <BoundaryReviewReason>[];

  // Measured shape vs imposed physical size. The warp used to force the
  // catalog aspect onto the rectified output, which made even a wild
  // disagreement invisible. Only a disagreement beyond the project's own
  // implausibility factor (see library doc) is gated: within it, pixel-space
  // aspect is too perspective-sensitive to overrule the established
  // classification; beyond it, the imposed size describes a different
  // document than the one measured, and cropping would fabricate it.
  final imposed = proposal.imposedAspect;
  if (imposed != null && imposed > 0 && imposed.isFinite) {
    final claimRatio = measuredAspect >= imposed
        ? measuredAspect / imposed
        : imposed / measuredAspect;
    if (claimRatio > maxAspectClaimRatio) {
      reasons.add(BoundaryReviewReason.aspectMismatch);
    }
  }

  // The quadrilateral must describe the region it was proposed from: its
  // centre must lie inside the measured region and it must overlap it.
  final region = proposal.region;
  if (region != null && region.length == 4) {
    var minX = 1.0, minY = 1.0, maxX = 0.0, maxY = 0.0;
    var centreX = 0.0, centreY = 0.0;
    for (final point in corners) {
      if (point.x < minX) minX = point.x;
      if (point.y < minY) minY = point.y;
      if (point.x > maxX) maxX = point.x;
      if (point.y > maxY) maxY = point.y;
      centreX += point.x / 4;
      centreY += point.y / 4;
    }
    final overlaps =
        maxX > region[0] &&
        minX < region[2] &&
        maxY > region[1] &&
        minY < region[3];
    final centreInside =
        centreX >= region[0] &&
        centreX <= region[2] &&
        centreY >= region[1] &&
        centreY <= region[3];
    if (!overlaps || !centreInside) {
      reasons.add(BoundaryReviewReason.quadOutsideRegion);
    }
  }

  return BoundaryDecision(
    kind: reasons.isEmpty
        ? BoundaryDecisionKind.accepted
        : BoundaryDecisionKind.needsReview,
    proposal: proposal,
    verification: BoundaryVerification(
      assessment: assessment,
      reasons: List.unmodifiable(reasons),
      measuredAspect: measuredAspect,
    ),
  );
}

/// Arabic, user-facing explanation of one review reason. The caller owns
/// prefixing the image name; this text owns saying what happens next.
String boundaryReviewReasonMessage(
  BoundaryReviewReason reason,
) => switch (reason) {
  BoundaryReviewReason.noBoundary =>
    'لم تُقترح حدود للمستمسك؛ بقيت الصورة كاملة لتُقصّ يدوياً.',
  BoundaryReviewReason.notABoundary =>
    'اقتراح الحدود غير صالح شكلاً؛ بقيت الصورة كاملة لتُقصّ يدوياً.',
  BoundaryReviewReason.geometryRejected =>
    'الحدود المقترحة مرفوضة هندسياً؛ بقيت الصورة كاملة لتُقصّ يدوياً قبل أي قصّ.',
  BoundaryReviewReason.aspectMismatch =>
    'شكل الحدود المقترحة لا يطابق مقاس النوع المتعرّف عليه؛ لم يُفرض المقاس ولم يُقصّ تلقائياً — راجع القص يدوياً.',
  BoundaryReviewReason.quadOutsideRegion =>
    'الحدود المقترحة لا تصف المنطقة المقاسة؛ بقيت الصورة كاملة لتُقصّ يدوياً.',
};
