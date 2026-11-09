/// Document classification from explicit evidence only. The app can supply
/// OCR keyword evidence, but has no validated visual kind classifier. A
/// filename or boundary aspect never creates a kind; without class evidence
/// the result is `unknown`.
library;

import 'acceptance_policy.dart';
import 'document_kind.dart';
import 'ocr_evidence.dart';
import 'recognition.dart';
import 'recognition_routing.dart';

/// Explicit evidence available for classifying one detected document.
///
/// Detection and geometry confidence are used only in final routing; they do
/// not label the document. Filename/path, pixel dimensions and boundary shape
/// are deliberately not inputs to this type classifier.
class ClassificationInput {
  const ClassificationInput({
    this.detectionConfidence,
    this.geometryConfidence,
    this.ocrKeywords = const [],
    this.ocrConfidence,
    this.thresholds = defaultThresholds,
  });

  /// Measured upstream confidences; absent when the stage did not run.
  final double? detectionConfidence;
  final double? geometryConfidence;

  /// Keyword hits derived from OCR text (the text itself never arrives here).
  final List<OcrKeywordEvidence> ocrKeywords;

  /// Mean OCR line confidence, when OCR ran and recognized anything.
  final double? ocrConfidence;
  final RecognitionThresholds thresholds;
}

/// The classification conclusion plus everything needed to persist it.
class ClassificationOutcome {
  const ClassificationOutcome({
    required this.kind,
    required this.status,
    required this.confidences,
    required this.evidence,
    required this.routing,
    this.candidates = const [],
  });
  final DocumentKind kind;
  final RecognitionStatus status;
  final ConfidenceSet confidences;
  final List<RecognitionEvidence> evidence;
  final RoutingDecision routing;

  /// Every kind that received at least one evidence vote, in stable enum
  /// order — the candidate shortlist for an awaiting-size preset.
  final List<DocumentKind> candidates;
}

/// Text eligibility only. Crop authorization, documented size and shape match
/// are checked independently by SmartIntake. D/G/F cannot vote for a type or
/// veto readable content, and accepted content cannot authorize a crop.
bool qualifiesForAutomaticPlacement(
  ClassificationOutcome outcome, {
  RecognitionThresholds thresholds = defaultThresholds,
}) {
  final scores = outcome.confidences;
  return outcome.kind != DocumentKind.unknown &&
      outcome.status == RecognitionStatus.recognized &&
      outcome.candidates.length == 1 &&
      outcome.candidates.single == outcome.kind &&
      meetsAcceptanceThreshold(
        scores.classification?.value,
        thresholds.classificationAcceptance,
      );
}

/// Version tag recorded as the producer version of classifier confidences.
const classifierVersion = 'explicit-evidence-4';

ClassificationOutcome classifyDocument(ClassificationInput input) {
  final evidence = <RecognitionEvidence>[];
  final votes = <DocumentKind, List<(EvidenceSource, double)>>{};

  void vote(DocumentKind kind, EvidenceSource source, double score) {
    if (kind == DocumentKind.unknown) return;
    votes.putIfAbsent(kind, () => []).add((source, score));
  }

  // OCR keyword evidence is optional and can be supplied only by the OCR
  // adapter. No filename, path, aspect ratio, catalog size or detector score
  // is converted into a document-kind vote.
  for (final keyword in input.ocrKeywords) {
    evidence.add(
      RecognitionEvidence(
        source: EvidenceSource.ocr,
        kind: 'ocr-keyword',
        score: keyword.score,
        reason:
            '${keyword.kind.name}:anchor-groups=${keyword.matchedAnchorGroups}',
      ),
    );
    vote(keyword.kind, EvidenceSource.ocr, keyword.score);
  }

  // Winner: the kind with the highest best-source score; ties broken by the
  // stable enum order so the result is deterministic.
  DocumentKind winner = DocumentKind.unknown;
  var winnerScore = 0.0;
  var runnerUpScore = 0.0;
  final orderedKinds = votes.keys.toList()
    ..sort((a, b) => a.index.compareTo(b.index));
  for (final kind in orderedKinds) {
    var best = 0.0;
    for (final (_, score) in votes[kind]!) {
      if (score > best) best = score;
    }
    if (best > winnerScore) {
      runnerUpScore = winnerScore;
      winnerScore = best;
      winner = kind;
    } else if (best > runnerUpScore) {
      runnerUpScore = best;
    }
  }
  final conflict =
      votes.length > 1 &&
      winnerScore - runnerUpScore < input.thresholds.conflictGap;

  // Only independently corroborated OCR keyword evidence can label a type.
  // Keep its conservative semantic score as C; never blend D/G/OCR mean into C.
  final classificationValue = winner == DocumentKind.unknown
      ? null
      : winnerScore;

  // R4: a winning classification below the floor becomes unknown (but the
  // collected evidence is preserved for review).
  var kind = winner;
  var classification = classificationValue;
  if (classification != null &&
      !meetsAcceptanceThreshold(
        classification,
        input.thresholds.minClassification,
      )) {
    kind = DocumentKind.unknown;
  }

  // Legacy routing bands remain review diagnostics, based on C alone. New
  // results do not manufacture a fused F; older stored F values remain readable.
  final routing = routeRecognition(
    finalValue: classification ?? 0,
    independentSources: 1,
    nonOcrSources: 0,
    availableComponents: [if (classification != null) classification],
    classConflict: conflict || orderedKinds.length > 1,
    thresholds: input.thresholds,
  );

  final status = kind == DocumentKind.unknown
      ? RecognitionStatus.unknown
      : (conflict ||
            orderedKinds.length != 1 ||
            !meetsAcceptanceThreshold(
              classification,
              input.thresholds.classificationAcceptance,
            ))
      ? RecognitionStatus.uncertain
      : RecognitionStatus.recognized;

  Confidence? wrap(double? value, String reason) => value == null
      ? null
      : Confidence(
          value: value,
          reason: reason,
          producer: 'recognition-classifier',
          version: classifierVersion,
        );

  return ClassificationOutcome(
    kind: kind,
    status: status,
    confidences: ConfidenceSet(
      detection: input.detectionConfidence == null
          ? null
          : Confidence(
              value: input.detectionConfidence!,
              reason: 'segmenter support',
              producer: 'document-segmenter',
              version: classifierVersion,
            ),
      geometry: input.geometryConfidence == null
          ? null
          : Confidence(
              value: input.geometryConfidence!,
              reason: 'quad assessment',
              producer: 'quad-assessment',
              version: classifierVersion,
            ),
      ocr: input.ocrConfidence == null
          ? null
          : Confidence(
              value: input.ocrConfidence!,
              reason: 'mean line confidence',
              producer: 'ocr-engine',
              version: classifierVersion,
            ),
      classification: wrap(classification, 'independent semantic OCR anchors'),
    ),
    evidence: List.unmodifiable(evidence),
    routing: routing,
    candidates: List.unmodifiable(orderedKinds),
  );
}
