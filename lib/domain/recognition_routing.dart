/// Central confidence routing for Smart Recognition (AUDIT.md §F).
///
/// Every numeric threshold of the recognition runtime lives here, so routing
/// behavior is adjusted in one place. The numbers are PROVISIONAL routing
/// heuristics, not calibrated probabilities and not accuracy claims
/// (docs/RECOGNITION.md §4): no real-dataset calibration exists yet.
library;

import 'dart:math' as math;

import 'recognition.dart';

/// How recognition conclusions are routed to the user.
enum AutomationMode {
  /// Every recognized document enters the review queue until the user
  /// confirms or corrects it. Nothing is silently accepted.
  reviewAll,

  /// Documents in the auto-accept band skip the review queue. Ships
  /// disabled (AUDIT.md §F) until a real evaluation dataset justifies it.
  autoAcceptHighConfidence,
}

/// The shipped automation mode. reviewAll: recognition proposes, the user
/// disposes; high-confidence results are marked eligible but still reviewable.
///
/// Scope honesty (boundary audits, second review §1.1): this mode governs
/// only whether a Smart Recognition RECORD stays listed in that pipeline's
/// review queue. It never gated cropping, derived-asset creation or A4
/// placement in any intake path, and the legacy single-document path —
/// which creates no recognition record at all — is guarded instead by the
/// boundary decision gate in `boundary_decision.dart`. Do not cite this
/// mode as crop-safety evidence.
const automationMode = AutomationMode.reviewAll;

/// Provisional routing thresholds (AUDIT.md §F). Routing heuristics only.
class RecognitionThresholds {
  const RecognitionThresholds({
    this.autoAccept = .9,
    this.review = .7,
    this.componentFloor = .5,
    this.minClassification = .6,
    this.conflictGap = .15,
  });

  /// finalConfidence at or above this is an automatic-acceptance candidate.
  final double autoAccept;

  /// finalConfidence at or above this (but below [autoAccept]) is review.
  final double review;

  /// R2: any available component below this floor caps routing to review.
  final double componentFloor;

  /// R4: a winning classification below this becomes [RecognitionStatus.unknown].
  final double minClassification;

  /// R3: two leading classes closer than this gap are a conflict (review cap).
  final double conflictGap;
}

/// The shared default thresholds used by the production pipeline.
const defaultThresholds = RecognitionThresholds();

/// Confidence band of a fused final confidence (AUDIT.md §F).
enum RecognitionBand { autoCandidate, review, unresolved }

/// Band of [value] under [thresholds] — the raw band, before R1–R3 caps.
RecognitionBand bandFor(
  double value, [
  RecognitionThresholds thresholds = defaultThresholds,
]) => value >= thresholds.autoAccept
    ? RecognitionBand.autoCandidate
    : value >= thresholds.review
    ? RecognitionBand.review
    : RecognitionBand.unresolved;

/// Weighted geometric mean over the AVAILABLE components only. Absent (null)
/// components are excluded and their weight redistributed — never treated as
/// zero (an unavailable source is absence of evidence, not negative evidence).
/// Returns null when nothing is available.
double? weightedGeometricMean(List<(double, double?)> parts) {
  var logSum = 0.0;
  var weightSum = 0.0;
  for (final (weight, value) in parts) {
    if (value == null) continue;
    // A true zero would force the mean to zero regardless of other evidence;
    // clamp to a tiny positive floor so one zero source stays influential
    // without erasing all other evidence.
    logSum += weight * math.log(value.clamp(1e-6, 1.0));
    weightSum += weight;
  }
  if (weightSum <= 0) return null;
  return math.exp(logSum / weightSum).clamp(0.0, 1.0);
}

/// A routing decision with machine-readable reasons. The fused value is kept
/// honest; caps change the BAND, never the stored confidence value.
class RoutingDecision {
  const RoutingDecision({required this.band, required this.reasons});
  final RecognitionBand band;
  final List<String> reasons;
}

/// Applies the §F hard rules (R1–R3) to the raw band of [finalValue]:
///
/// - R1: automatic acceptance needs at least two independent evidence
///   sources, at least one of them non-OCR; otherwise cap to review.
/// - R2: any available component below [RecognitionThresholds.componentFloor]
///   caps to review.
/// - R3: a reported top-class conflict caps to review.
RoutingDecision routeRecognition({
  required double finalValue,
  required int independentSources,
  required int nonOcrSources,
  required List<double> availableComponents,
  required bool classConflict,
  RecognitionThresholds thresholds = defaultThresholds,
}) {
  var band = bandFor(finalValue, thresholds);
  final reasons = <String>[];
  if (band == RecognitionBand.autoCandidate) {
    if (independentSources < 2 || nonOcrSources < 1) {
      band = RecognitionBand.review;
      reasons.add('R1:insufficient-sources');
    }
    if (availableComponents.any((v) => v < thresholds.componentFloor)) {
      band = RecognitionBand.review;
      reasons.add('R2:component-floor');
    }
  }
  if (classConflict && band == RecognitionBand.autoCandidate) {
    band = RecognitionBand.review;
    reasons.add('R3:class-conflict');
  }
  if (reasons.isEmpty) reasons.add('band:${band.name}');
  return RoutingDecision(band: band, reasons: List.unmodifiable(reasons));
}

/// Marker recorded in [UserOverride.fields] when the user confirms a
/// recognition result from the review queue.
const reviewConfirmedField = 'review-confirmed';

/// Marker recorded in [UserOverride.fields] when the user explicitly confirms
/// manual 4-corner boundary geometry on an asset or candidate region.
///
/// Kept distinct from [DetectionRef.polygon] so manual user confirmation never
/// fabricates or mutates automatic detector evidence (ADR-004).
const manualBoundaryConfirmedField = 'manual-boundary-confirmed';

/// Side-scoped marker recorded in [UserOverride.fields] when manual 4-corner
/// geometry is confirmed for a specific [DocumentSide.id].
String manualBoundaryConfirmedSideField(String sideId) =>
    '$manualBoundaryConfirmedField:$sideId';

bool _hasSideScopedBoundaryToken(UserOverride override) => override.fields.any(
  (field) => field.startsWith('$manualBoundaryConfirmedField:'),
);

/// Whether the user has explicitly confirmed manual 4-corner geometry for
/// [side] of [record].
bool sideHasManualBoundaryOverride(DocumentRecord record, DocumentSide side) {
  final sideToken = manualBoundaryConfirmedSideField(side.id);
  if (record.overrides.any((override) => override.fields.contains(sideToken))) {
    return true;
  }
  if (record.sides.length == 1) {
    return record.overrides.any(
      (override) =>
          !_hasSideScopedBoundaryToken(override) &&
          ((override.corners != null && override.corners!.length == 4) ||
              override.fields.contains(manualBoundaryConfirmedField)),
    );
  }
  return side.processedAsset.corners != null &&
      side.processedAsset.corners!.length == 4 &&
      record.overrides.any(
        (override) =>
            !_hasSideScopedBoundaryToken(override) &&
            override.fields.contains(manualBoundaryConfirmedField),
      );
}

/// Whether [side] of [record] still has an unresolved detector boundary.
bool sideHasUnresolvedBoundary(DocumentRecord record, DocumentSide side) =>
    side.detection != null &&
    side.detection!.polygon == null &&
    !sideHasManualBoundaryOverride(record, side);

/// Whether the user has explicitly confirmed manual 4-corner geometry on at
/// least one side of [record], without claiming an automatic detector produced
/// it.
bool hasManualBoundaryOverride(DocumentRecord record) => record.sides.any(
  (side) => sideHasManualBoundaryOverride(record, side),
);

/// Marker in [UserOverride.fields] distinguishing a new detached dismissal
/// tombstone from schema-v5 records that already used `dismissed` while their
/// layout item and pair were still present.
const dismissalTombstoneField = 'dismissal-tombstone';

/// Whether this record uses the current detached-tombstone representation.
bool isDismissalTombstone(DocumentRecord record) => record.overrides.any(
  (override) =>
      override.dismissed == true &&
      override.fields.contains(dismissalTombstoneField),
);

/// Whether the user explicitly dismissed this recognition candidate as not a
/// document. The evidence and provenance stay on the record; current explicit
/// dismissal also marks a detached tombstone and removes its layout items.
bool isDismissed(DocumentRecord record) =>
    record.overrides.any((override) => override.dismissed == true);

/// Whether the user resolved the entire review record, rather than one field.
/// Kind and pairing overrides are scoped to their own reasons; they must not
/// hide an unresolved boundary or an independent recognition concern.
bool isUserResolved(DocumentRecord record) =>
    isDismissed(record) ||
    record.overrides.any((o) => o.fields.contains(reviewConfirmedField));

/// Why a record needs review, if it does. Derived state (never persisted):
/// the queue is recomputed from evidence + overrides, so it can never drift.
List<String> reviewReasons(
  DocumentRecord record, [
  RecognitionThresholds thresholds = defaultThresholds,
]) {
  if (isUserResolved(record)) return const [];
  final recognition = record.recognition;
  if (recognition == null) return const [];
  final reasons = <String>[];
  final kindWasOverridden = record.overrides.any(
    (override) => override.documentKind != null,
  );
  if (!kindWasOverridden) {
    final finalConfidence = recognition.confidences.finalConfidence?.value;
    if (finalConfidence == null) {
      reasons.add('بلا ثقة نهائية');
    } else {
      switch (bandFor(finalConfidence, thresholds)) {
        case RecognitionBand.autoCandidate:
          if (automationMode == AutomationMode.reviewAll) {
            reasons.add('مؤهل تلقائياً — بانتظار التأكيد');
          }
        case RecognitionBand.review:
          reasons.add('ثقة متوسطة');
        case RecognitionBand.unresolved:
          reasons.add('ثقة منخفضة');
      }
    }
    if (recognition.status == RecognitionStatus.uncertain) {
      reasons.add('تصنيف غير حاسم');
    }
    if (recognition.status == RecognitionStatus.unknown) {
      reasons.add('نوع غير معروف');
    }
    if (recognition.preset.awaitingSize) {
      reasons.add('بانتظار تحديد المقاس');
    }
  }
  // An unresolved boundary is independent of the selected category. Even
  // after the user corrects the kind, an untrusted/missing polygon still needs
  // a manual crop; a field-level override must not hide that action.
  if (hasUnresolvedBoundary(record)) {
    reasons.add('حدود غير محسومة — يحتاج القص إلى مراجعة');
  }
  final pairingWasOverridden = record.overrides.any(
    (override) => override.pairing != null,
  );
  if (!pairingWasOverridden && record.pairing == PairingState.ambiguous) {
    reasons.add('اقتران وجهين غير مؤكد');
  }
  return List.unmodifiable(reasons);
}

/// Whether [record] is in the review queue.
bool recordNeedsReview(
  DocumentRecord record, [
  RecognitionThresholds thresholds = defaultThresholds,
]) => reviewReasons(record, thresholds).isNotEmpty;

/// Whether [record] stands for a region whose BOUNDARIES recognition could not
/// resolve: a side that carries a detection but no polygon.
///
/// This is the distinction the editor owes the user between two things that
/// both look like "a document without a confirmed size":
///
/// - an unresolved recognition CANDIDATE — a measured region kept deliberately
///   for review, whose crop was never rectified because no trustworthy
///   quadrilateral existed. Nothing was invented for it, and the way to finish
///   it is a manual crop of the immutable original;
/// - an ordinary item that simply has no category yet.
///
/// Derived state, never persisted: it is read from the recorded detection, so
/// it cannot drift from the evidence. A side with NO detection at all (a pure
/// manual item, or a legacy record — `synthesizeLegacyRecords` always records a
/// polygon, truthful even when it is the whole frame) is not an unresolved
/// candidate: no detector ran, so there is nothing that failed to resolve.
bool hasUnresolvedBoundary(DocumentRecord record) =>
    record.sides.any((side) => sideHasUnresolvedBoundary(record, side));
