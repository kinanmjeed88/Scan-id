/// Front/back pairing engine. Proposes pairs of single-sided documents from
/// one import batch, with an explicit pairing confidence built from named
/// evidence. Same document type ALONE is never sufficient: without an
/// identifier match (an OCR capability that is currently unavailable) the
/// combined confidence is capped below the automatic-acceptance threshold, so
/// a proposal can only reach `ambiguous` (user review) — unrelated cards are
/// never silently paired.
library;

import 'document_kind.dart';
import 'recognition.dart';
import 'recognition_routing.dart';

/// One single-sided document considered for pairing.
class PairCandidate {
  const PairCandidate({
    required this.documentId,
    required this.kind,
    required this.aspect,
    required this.importIndex,
    required this.sourceImageId,
    this.captureId,
    this.identifierMatchScore,
  });
  final String documentId;
  final DocumentKind kind;

  /// Long edge / short edge of the processed side.
  final double aspect;

  /// Position of the source image inside the import batch.
  final int importIndex;
  final String sourceImageId;
  final String? captureId;

  /// Score of a matching document identifier across the two sides, when OCR
  /// evidence provides one. Null while OCR is unavailable.
  final double? identifierMatchScore;
}

/// A proposed pair with its evidence trail.
class PairProposal {
  const PairProposal({
    required this.firstDocumentId,
    required this.secondDocumentId,
    required this.confidence,
    required this.resolution,
    required this.reasons,
  });
  final String firstDocumentId;
  final String secondDocumentId;
  final double confidence;

  /// [PairingState.paired] only at or above the auto-accept threshold;
  /// otherwise [PairingState.ambiguous] (routed to review).
  final PairingState resolution;
  final List<String> reasons;
}

/// Hard cap on pairing confidence when no identifier evidence exists, keeping
/// identifier-free pairs below the auto-accept threshold by construction.
const identifierFreePairingCap = .85;

double _pairScore(
  PairCandidate a,
  PairCandidate b, {
  required int sameKindCount,
  required List<String> reasons,
}) {
  // Adjacency: consecutive imports are the strongest batch signal.
  final gap = (a.importIndex - b.importIndex).abs();
  final adjacency = gap <= 1
      ? .9
      : gap == 2
      ? .6
      : .35;
  reasons.add('adjacency:$gap');

  // Shape agreement: both sides of one card share the physical outline.
  final ratio = a.aspect / b.aspect;
  final aspectDelta = (ratio - 1).abs();
  final aspectScore = (1 - aspectDelta / .08).clamp(0.0, 1.0) * .9 + .05;
  reasons.add('aspect-delta:${aspectDelta.toStringAsFixed(3)}');

  // Uniqueness: exactly two candidates of this kind in the batch.
  final uniqueness = sameKindCount == 2 ? .9 : .5;
  reasons.add('same-kind-count:$sameKindCount');

  final identifier =
      (a.identifierMatchScore != null && b.identifierMatchScore != null)
      ? (a.identifierMatchScore! < b.identifierMatchScore!
            ? a.identifierMatchScore
            : b.identifierMatchScore)
      : null;
  if (identifier != null) reasons.add('identifier-match');

  final fused =
      weightedGeometricMean([
        (.3, adjacency),
        (.2, aspectScore),
        (.2, uniqueness),
        (.3, identifier),
      ]) ??
      0;
  if (identifier == null && fused > identifierFreePairingCap) {
    reasons.add('cap:no-identifier');
    return identifierFreePairingCap;
  }
  return fused;
}

/// Proposes pairs among [candidates]. Deterministic: candidates are matched
/// greedily by descending confidence, ties broken by document id; each
/// document joins at most one proposal; proposals below the review threshold
/// are dropped (the documents stay single).
List<PairProposal> proposePairs(
  List<PairCandidate> candidates, {
  RecognitionThresholds thresholds = defaultThresholds,
}) {
  final kindCounts = <DocumentKind, int>{};
  for (final c in candidates) {
    kindCounts[c.kind] = (kindCounts[c.kind] ?? 0) + 1;
  }
  final scored = <PairProposal>[];
  for (var i = 0; i < candidates.length; i++) {
    for (var j = i + 1; j < candidates.length; j++) {
      final a = candidates[i], b = candidates[j];
      if (a.documentId == b.documentId) continue;
      // Two detections from the SAME source image are different physical
      // cards lying on one photo, never two sides of one card.
      if (a.sourceImageId == b.sourceImageId) continue;
      if (a.kind != b.kind || a.kind == DocumentKind.unknown) continue;
      final reasons = <String>[];
      final score = _pairScore(
        a,
        b,
        sameKindCount: kindCounts[a.kind] ?? 0,
        reasons: reasons,
      );
      if (score < thresholds.review) continue;
      final ordered = a.documentId.compareTo(b.documentId) <= 0;
      scored.add(
        PairProposal(
          firstDocumentId: ordered ? a.documentId : b.documentId,
          secondDocumentId: ordered ? b.documentId : a.documentId,
          confidence: score,
          resolution: score >= thresholds.autoAccept
              ? PairingState.paired
              : PairingState.ambiguous,
          reasons: List.unmodifiable(reasons),
        ),
      );
    }
  }
  scored.sort((x, y) {
    final byScore = y.confidence.compareTo(x.confidence);
    if (byScore != 0) return byScore;
    final byFirst = x.firstDocumentId.compareTo(y.firstDocumentId);
    if (byFirst != 0) return byFirst;
    return x.secondDocumentId.compareTo(y.secondDocumentId);
  });
  final taken = <String>{};
  final result = <PairProposal>[];
  for (final proposal in scored) {
    if (taken.contains(proposal.firstDocumentId) ||
        taken.contains(proposal.secondDocumentId)) {
      continue;
    }
    taken.add(proposal.firstDocumentId);
    taken.add(proposal.secondDocumentId);
    result.add(proposal);
  }
  return List.unmodifiable(result);
}
