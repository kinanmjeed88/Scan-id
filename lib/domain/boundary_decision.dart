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
/// No new numeric cutoff is invented here. Two pre-existing constants do
/// different jobs and must not be collapsed:
///
/// - [maxAspectClaimRatio] (`2.5`) is the opposite-edge implausibility bound
///   [assessQuad] already uses, reused as an outer claim refusal. Equation:
///   `max(measured, imposed) / min(measured, imposed)`. Above 2.5 the imposed
///   size describes a different document (a ration card versus an ID card is
///   about 3.5×). It is not permission to reshape anything below it.
/// - [shapeTolerance] (`0.04`) is the relative error classification already
///   uses: `(measured / imposed - 1).abs()`. Inside that tolerance the catalog
///   millimetre slot may be used and `sizeConfirmed` may be true. It is not
///   permission to change the warp's output aspect. Perspective correction
///   always keeps the measured aspect. Export and the sheet preview fit the
///   pixels uniformly inside the slot (`BoxFit.contain`); a residual ratio
///   difference becomes a margin, never a stretch.
library;

import 'crop_draft.dart';
import 'document_kind.dart';
import 'geometry.dart';
import 'image_adjustments.dart';
import 'quad_assessment.dart';
import 'validation.dart';

/// Outer refusal for a catalog claim. Dimensionless ratio of two long/short
/// aspects (measured quadrilateral versus imposed catalog size), not a pixel
/// margin and not an output-aspect license.
///
/// It mirrors the 2.5× bound [assessQuad] applies to opposite edges of one
/// quadrilateral — a different measurement (one edge versus the opposite
/// edge, in pixels). Reused so a ration-shaped region cannot be accepted as
/// an ID card. It does not separate ID, residence and passport (those differ
/// by about 4–12 %), and it must not be read as permission to stretch a
/// milder disagreement onto the catalog ratio.
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

  /// Learned model confidence fell below the validation-calibrated auto-accept
  /// threshold; proposed corners remain available for editable user review.
  lowModelConfidence,

  /// One or more corners touch the outer camera frame edge, indicating
  /// potential physical card clipping that requires manual review.
  touchesFrameEdge,

  /// This region came from a multi-document scene whose set-level physical
  /// corroboration was insufficient. Keep it, but do not auto-crop it.
  multiSceneNotCorroborated,

  /// Classical candidate ranking is not a calibrated probability. Preserve a
  /// valid proposal for manual review until a local labelled calibration set
  /// establishes a defensible automatic-accept policy.
  uncalibratedClassicalScore,
}

/// One boundary CLAIM about one document inside one source image.
class BoundaryProposal {
  const BoundaryProposal({
    required this.producer,
    this.corners,
    this.region,
    this.imposedAspect,
    this.imposedKindLabel,
    this.modelConfidence,
    this.minAutoAcceptConfidence,
    this.touchesFrameEdge = false,
    this.forceReview = false,
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

  /// Optional calibrated score emitted by a learned model (`0..1`).
  final double? modelConfidence;

  /// Minimum model confidence required before automatic perspective cropping
  /// is permitted without user confirmation.
  final double? minAutoAcceptConfidence;

  /// True when the proposed quadrilateral touches the outer camera frame edge.
  final bool touchesFrameEdge;

  /// A measured arbitration rule may require review independently of confidence.
  /// This is a decision constraint, not a fabricated score or boundary claim.
  final bool forceReview;
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

  /// Permission to build an automatic perspective crop. Null unless [kind] is
  /// [BoundaryDecisionKind.accepted]. There is no other constructor.
  ///
  /// This permits correcting the accepted quadrilateral. It does not permit
  /// changing its aspect. [catalogShapeMatches] only permits the catalog
  /// millimetre slot and `sizeConfirmed`.
  AutomaticCropAuthorization? get cropAuthorization =>
      kind == BoundaryDecisionKind.accepted
      ? AutomaticCropAuthorization._(this)
      : null;

  /// Whether the measured long/short aspect agrees with the imposed catalog
  /// aspect within [shapeTolerance], the same relative error classification
  /// uses: `(measured / imposed - 1).abs() <= shapeTolerance`.
  ///
  /// False when the decision was not accepted, when no catalog aspect was
  /// claimed, or when the disagreement is larger than classification already
  /// treats as a different shape. Only then may a caller place the image in
  /// the catalog millimetre slot and set `sizeConfirmed`. The warp itself
  /// never adopts that ratio: [recipeFromAcceptedBoundary] has no output-aspect
  /// argument.
  bool get catalogShapeMatches {
    if (kind != BoundaryDecisionKind.accepted) return false;
    final imposed = proposal.imposedAspect;
    final measured = verification.measuredAspect;
    if (imposed == null ||
        measured == null ||
        !imposed.isFinite ||
        !measured.isFinite ||
        imposed <= 0 ||
        measured <= 0) {
      return false;
    }
    return (measured / imposed - 1).abs() <= shapeTolerance;
  }
}

/// The only permission an automatic intake path may use to warp a source.
///
/// Manual crops ([userAuthoredCrop]) and recovery replay of an already stored
/// recipe do not use this type. A caller cannot mint one from corners alone.
class AutomaticCropAuthorization {
  const AutomaticCropAuthorization._(this.decision);

  final BoundaryDecision decision;

  List<Point2> get corners => decision.acceptedCorners!;
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
      verification: BoundaryVerification(
        assessment: null,
        reasons: [
          BoundaryReviewReason.noBoundary,
          if (proposal.forceReview)
            BoundaryReviewReason.multiSceneNotCorroborated,
        ],
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
        reasons: [
          BoundaryReviewReason.geometryRejected,
          if (proposal.forceReview)
            BoundaryReviewReason.multiSceneNotCorroborated,
        ],
      ),
    );
  }
  final measuredAspect = assessment.aspect!;
  final reasons = <BoundaryReviewReason>[
    if (proposal.forceReview) BoundaryReviewReason.multiSceneNotCorroborated,
    if (proposal.producer == BoundaryProducer.detector)
      BoundaryReviewReason.uncalibratedClassicalScore,
  ];

  // Outer claim refusal only. Above [maxAspectClaimRatio] the imposed size
  // is a different document, so the claim is not accepted and no automatic
  // warp runs. A milder disagreement is still not a license to reshape.
  // [BoundaryDecision.catalogShapeMatches] uses [shapeTolerance] and only
  // permits the catalog millimetre slot, never a warp aspect.
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

  final learnedEdgeTouch =
      proposal.producer == BoundaryProducer.learnedModel &&
      proposal.region == null &&
      corners.any(
        (p) => p.x <= 0.016 || p.x >= 0.984 || p.y <= 0.016 || p.y >= 0.984,
      );
  if (proposal.touchesFrameEdge || learnedEdgeTouch) {
    reasons.add(BoundaryReviewReason.touchesFrameEdge);
  }
  final modelConf = proposal.modelConfidence;
  final minAutoConf = proposal.minAutoAcceptConfidence;
  if (modelConf != null && minAutoConf != null) {
    if (!modelConf.isFinite || modelConf < minAutoConf) {
      reasons.add(BoundaryReviewReason.lowModelConfidence);
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

/// Perspective recipe for an automatic crop. Refuses to run without an
/// accepted decision. There is no output-aspect argument: a catalog ratio
/// cannot be smuggled in after acceptance, whether or not
/// [BoundaryDecision.catalogShapeMatches]. The measured quadrilateral's own
/// aspect is the output aspect.
///
/// [maxAspectClaimRatio] is not consulted here. A decision accepted under
/// that outer bound is still not a reshape license. Manual crops build their
/// own [CropDraft] and may set an aspect the user chose; this function is
/// not that path.
///
/// [coordinateFrameCorners] is only a coordinate rewrite of the authorized
/// quadrilateral (the full-resolution JPEG region buffer). It is not a new
/// boundary and is ignored unless [authorization] is accepted.
ImageEditRecipe recipeFromAcceptedBoundary(
  AutomaticCropAuthorization authorization, {
  required int sourceWidth,
  required int sourceHeight,
  ImageAdjustments? adjustments,
  List<Point2>? coordinateFrameCorners,
}) {
  final corners = coordinateFrameCorners ?? authorization.corners;
  require(corners.length == 4, 'زوايا القص التلقائي يجب أن تكون أربعًا.');
  return CropDraft(
    corners: corners,
    adjustments: adjustments,
  ).toRecipe(sourceWidth, sourceHeight);
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
  BoundaryReviewReason.lowModelConfidence =>
    'ثقة كشف الذكاء الاصطناعي دون حد القبول التلقائي؛ حُفظت الزوايا المقترحة للمراجعة والتعديل اليدوي دون قصّ صامت.',
  BoundaryReviewReason.touchesFrameEdge =>
    'تلامس حدود البطاقة حافة الإطار وقد يكون جزء منها مقطوعاً؛ راجع الزوايا يدوياً قبل اعتماد القصّ.',
  BoundaryReviewReason.multiSceneNotCorroborated =>
    'لم تتأكد الأدلة الفيزيائية من تعدد حدود المشهد؛ بقيت المنطقة للمراجعة ولم تُقصّ تلقائياً.',
  BoundaryReviewReason.uncalibratedClassicalScore =>
    'اقتراح حدود هندسي محلي؛ درجته ليست ثقة معايرة، لذا حُفظت الزوايا للمراجعة اليدوية دون قصّ تلقائي.',
};

/// Shown when a boundary was accepted for perspective correction but its
/// measured shape does not match the catalog size within [shapeTolerance].
/// The crop, if saved, keeps the measured aspect and must not be described
/// as a confirmed catalog size.
String catalogShapeUnconfirmedMessage() =>
    'شكل الحدود لا يطابق مقاس النوع ضمن تفاوت التصنيف؛ '
    'صُحح المنظور دون مطّ الناتج، ولم يُؤكَّد المقاس.';
