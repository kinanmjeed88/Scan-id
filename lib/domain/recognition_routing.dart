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

/// Whether the user explicitly resolved this record: confirmed it, overrode
/// its kind/side/pairing, or dismissed the review entry.
bool isUserResolved(DocumentRecord record) => record.overrides.any(
  (o) =>
      o.fields.contains(reviewConfirmedField) ||
      o.documentKind != null ||
      o.side != null ||
      o.pairing != null ||
      o.dismissed == true,
);

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
  if (record.pairing == PairingState.ambiguous) {
    reasons.add('اقتران وجهين غير مؤكد');
  }
  return List.unmodifiable(reasons);
}

/// Whether [record] is in the review queue.
bool recordNeedsReview(
  DocumentRecord record, [
  RecognitionThresholds thresholds = defaultThresholds,
]) => reviewReasons(record, thresholds).isNotEmpty;
