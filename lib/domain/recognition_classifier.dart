/// Document classification (ADR-007) from explicit evidence only. This build
/// has no validated visual kind classifier and no packaged OCR engine, so a
/// filename or boundary aspect can never create a kind; without independent
/// evidence the result is `unknown`.
library;

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

/// Version tag recorded as the producer version of classifier confidences.
const classifierVersion = 'explicit-evidence-1';

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
        reason: keyword.kind.name,
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

  // Preserve the existing source-weight policy for any evidence types that
  // are available. Absent sources stay absent; in this build only OCR keywords
  // can vote for a kind. A conflict caps routing rather than zeroing the mean.
  double? sourceScore(EvidenceSource source) {
    final list = votes[winner];
    if (list == null) return null;
    double? best;
    for (final (s, score) in list) {
      if (s == source && (best == null || score > best)) best = score;
    }
    return best;
  }

  final classificationValue = winner == DocumentKind.unknown
      ? null
      : weightedGeometricMean([
          (.4, sourceScore(EvidenceSource.aspect)),
          (.3, sourceScore(EvidenceSource.ocr)),
          (.3, sourceScore(EvidenceSource.structure)),
        ]);

  // R4: a winning classification below the floor becomes unknown (but the
  // collected evidence is preserved for review).
  var kind = winner;
  var classification = classificationValue;
  if (classification != null &&
      classification < input.thresholds.minClassification) {
    kind = DocumentKind.unknown;
  }

  final finalValue = weightedGeometricMean([
    (.2, input.detectionConfidence),
    (.3, input.geometryConfidence),
    (.5, classification),
  ]);

  final sources = {for (final e in evidence) e.source};
  final routing = routeRecognition(
    finalValue: finalValue ?? 0,
    independentSources: sources.length,
    nonOcrSources: sources.where((s) => s != EvidenceSource.ocr).length,
    availableComponents: [
      if (input.detectionConfidence != null) input.detectionConfidence!,
      if (input.geometryConfidence != null) input.geometryConfidence!,
      if (classification != null) classification,
    ],
    classConflict: conflict,
    thresholds: input.thresholds,
  );

  final status = kind == DocumentKind.unknown
      ? RecognitionStatus.unknown
      : (conflict || routing.band == RecognitionBand.unresolved)
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
      classification: wrap(classification, 'weighted evidence fusion'),
      finalConfidence: wrap(finalValue, routing.reasons.join(',')),
    ),
    evidence: List.unmodifiable(evidence),
    routing: routing,
    candidates: List.unmodifiable(orderedKinds),
  );
}
