/// Structured OCR output used as recognition EVIDENCE (ADR-007).
///
/// These values live in memory for the duration of one pipeline run. The
/// recognized text itself is never persisted, never logged and never placed in
/// a backup; only derived keyword scores (without the text) reach
/// `RecognitionEvidence`.
library;

import 'document_kind.dart';
import 'geometry.dart';
import 'validation.dart';

/// Whether an OCR engine could run at all.
enum OcrAvailability { available, unavailable }

/// One recognized text line with its measured confidence and, when the engine
/// provides it, a normalized bounding quadrilateral.
class OcrLine {
  OcrLine({required this.text, required this.confidence, this.bounds}) {
    require(
      confidence.isFinite && confidence >= 0 && confidence <= 1,
      'ثقة سطر OCR يجب أن تكون بين 0 و1.',
    );
    if (bounds != null) {
      require(bounds!.length == 4, 'حدود سطر OCR يجب أن تكون أربع نقاط.');
    }
  }
  final String text;
  final double confidence;
  final List<Point2>? bounds;
}

/// The complete outcome of one OCR attempt. Unavailability is an explicit
/// state, never an invented empty success; a failed engine reports
/// [OcrAvailability.unavailable] with a machine-safe reason.
class OcrTextResult {
  OcrTextResult.available({
    required this.lines,
    required this.engineVersion,
    this.orientationQuarterTurns,
  }) : availability = OcrAvailability.available,
       unavailableReason = null;

  OcrTextResult.unavailable({
    required this.unavailableReason,
    required this.engineVersion,
  }) : availability = OcrAvailability.unavailable,
       lines = const [],
       orientationQuarterTurns = null;

  final OcrAvailability availability;
  final List<OcrLine> lines;

  /// Orientation proposal from the engine (0–3 quarter turns), when provided.
  final int? orientationQuarterTurns;
  final String? unavailableReason;
  final String engineVersion;

  bool get isAvailable => availability == OcrAvailability.available;

  /// Mean line confidence, or null when no line was recognized. Absence of
  /// OCR evidence is represented by null, never by a fabricated zero.
  double? get confidence {
    if (!isAvailable || lines.isEmpty) return null;
    var sum = 0.0;
    for (final line in lines) {
      sum += line.confidence;
    }
    return sum / lines.length;
  }
}

/// A document-kind keyword hit derived from OCR text. Carries the kind and a
/// score only — the matched text never leaves the pipeline run.
class OcrKeywordEvidence {
  OcrKeywordEvidence({required this.kind, required this.score}) {
    require(
      score.isFinite && score >= 0 && score <= 1,
      'درجة دليل OCR يجب أن تكون بين 0 و1.',
    );
  }
  final DocumentKind kind;
  final double score;
}

/// Keyword anchors for Iraqi document kinds. Normalization mirrors the
/// filename matcher in `document_kind.dart` (diacritics, ة/ه, ى/ي, spacing).
const _ocrAnchors = {
  DocumentKind.unifiedNationalId: [
    'البطاقهالوطنيه',
    'بطاقهوطنيه',
    'وزارهالداخليه',
    'مديريهالاحوالالمدنيه',
    'nationalcard',
    'nationalid',
  ],
  DocumentKind.passport: [
    'جوازسفر',
    'جمهوريهالعراق',
    'passport',
    'republicofiraq',
  ],
  DocumentKind.residenceCard: ['بطاقهالسكن', 'بطاقهسكن', 'residencecard'],
  DocumentKind.rationCard: ['البطاقهالتموينيه', 'بطاقهتموينيه', 'rationcard'],
};

String _normalize(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[\u064B-\u065F\u0670]'), '')
    .replaceAll('ة', 'ه')
    .replaceAll('ى', 'ي')
    .replaceAll(RegExp(r'[\s_\-.]+'), '');

/// Derives keyword evidence from [result]. Scores are the confidences of the
/// lines that contained an anchor (best line per kind); the text itself is
/// discarded here and never stored.
List<OcrKeywordEvidence> ocrKeywordEvidence(OcrTextResult result) {
  if (!result.isAvailable) return const [];
  final best = <DocumentKind, double>{};
  for (final line in result.lines) {
    final normalized = _normalize(line.text);
    if (normalized.isEmpty) continue;
    for (final entry in _ocrAnchors.entries) {
      if (entry.value.any(normalized.contains)) {
        final previous = best[entry.key];
        if (previous == null || line.confidence > previous) {
          best[entry.key] = line.confidence;
        }
      }
    }
  }
  final kinds = best.keys.toList()..sort((a, b) => a.index.compareTo(b.index));
  return List.unmodifiable([
    for (final kind in kinds)
      OcrKeywordEvidence(kind: kind, score: best[kind]!),
  ]);
}
