/// Evaluation metrics for OCR transcripts and document classification
/// (ADR-010).
///
/// These are the numbers the project is allowed to quote, so they are defined
/// once, here, and covered by unit tests instead of being recomputed — possibly
/// differently — by each report script:
///
/// * **CER** — total Levenshtein edits over code points, divided by the number of
///   reference code points;
/// * **WER** — the same edit count over whitespace-separated words, divided by
///   the number of reference words;
/// * **precision / recall / F1** — the usual definitions, with the correct zero
///   denominators (a metric with no positive prediction or no positive truth is
///   reported as null, never as 0 or 1, because "undefined" and "perfect" are
///   different facts).
///
/// A rate above 1 is possible and meaningful: more edits than reference units.
library;

import 'dart:math' as math;

import 'document_kind.dart';
import 'validation.dart';

/// Levenshtein distance between [reference] and [hypothesis], by code point.
int editDistance(String reference, String hypothesis) {
  final left = reference.runes.toList();
  final right = hypothesis.runes.toList();
  if (left.isEmpty) return right.length;
  if (right.isEmpty) return left.length;
  var previous = List<int>.generate(right.length + 1, (index) => index);
  var current = List<int>.filled(right.length + 1, 0);
  for (var i = 1; i <= left.length; i++) {
    current[0] = i;
    for (var j = 1; j <= right.length; j++) {
      final cost = left[i - 1] == right[j - 1] ? 0 : 1;
      current[j] = math.min(
        math.min(current[j - 1] + 1, previous[j] + 1),
        previous[j - 1] + cost,
      );
    }
    final swap = previous;
    previous = current;
    current = swap;
  }
  return previous[right.length];
}

/// Character error rate of one transcript against one reference.
///
/// Both strings are compared as they are; callers that want diacritic- and
/// ligature-insensitive scoring normalise first and must say so in the report.
double characterErrorRate(String reference, String hypothesis) {
  final referenceLength = reference.runes.length;
  final distance = editDistance(reference, hypothesis);
  if (referenceLength == 0) {
    // Nothing to read: the only defensible rate is "no edits produced nothing",
    // and any inserted character is an error relative to a unit-less reference.
    return distance == 0 ? 0 : 1;
  }
  return distance / referenceLength;
}

List<String> _words(String value) => value
    .trim()
    .split(RegExp(r'\s+'))
    .where((word) => word.isNotEmpty)
    .toList();

/// Word error rate of one transcript against one reference.
double wordErrorRate(String reference, String hypothesis) {
  final referenceWords = _words(reference);
  final hypothesisWords = _words(hypothesis);
  // The edit count has to be over words, not over the joined string: joining
  // would score a reordered sentence as a single character edit.
  final wordDistance = _wordEditDistance(referenceWords, hypothesisWords);
  if (referenceWords.isEmpty) return wordDistance == 0 ? 0 : 1;
  return wordDistance / referenceWords.length;
}

int _wordEditDistance(List<String> reference, List<String> hypothesis) {
  if (reference.isEmpty) return hypothesis.length;
  if (hypothesis.isEmpty) return reference.length;
  var previous = List<int>.generate(hypothesis.length + 1, (index) => index);
  var current = List<int>.filled(hypothesis.length + 1, 0);
  for (var i = 1; i <= reference.length; i++) {
    current[0] = i;
    for (var j = 1; j <= hypothesis.length; j++) {
      final cost = reference[i - 1] == hypothesis[j - 1] ? 0 : 1;
      current[j] = math.min(
        math.min(current[j - 1] + 1, previous[j] + 1),
        previous[j - 1] + cost,
      );
    }
    final swap = previous;
    previous = current;
    current = swap;
  }
  return previous[hypothesis.length];
}

/// Precision/recall/F1 for one class, with undefined ratios kept null.
class ClassScores {
  const ClassScores({
    required this.kind,
    required this.truePositives,
    required this.falsePositives,
    required this.falseNegatives,
    required this.support,
  });

  final DocumentKind kind;
  final int truePositives;
  final int falsePositives;
  final int falseNegatives;

  /// Number of samples whose reference label is [kind].
  final int support;

  double? get precision {
    final denominator = truePositives + falsePositives;
    return denominator == 0 ? null : truePositives / denominator;
  }

  double? get recall {
    final denominator = truePositives + falseNegatives;
    return denominator == 0 ? null : truePositives / denominator;
  }

  double? get f1 {
    final p = precision;
    final r = recall;
    if (p == null || r == null || p + r == 0) return null;
    return 2 * p * r / (p + r);
  }
}

/// The full evaluation of one labelled classification run.
class ClassificationReport {
  ClassificationReport({
    required List<(DocumentKind actual, DocumentKind predicted)> samples,
  }) : samples = List.unmodifiable(samples) {
    require(samples.isNotEmpty, 'تقييم التصنيف يحتاج عينة واحدة على الأقل.');
  }

  final List<(DocumentKind actual, DocumentKind predicted)> samples;

  int get sampleCount => samples.length;

  /// Samples whose prediction is [DocumentKind.unknown]: the pipeline declined
  /// to choose, which is a review request rather than a wrong answer.
  int get unknownCount =>
      samples.where((sample) => sample.$2 == DocumentKind.unknown).length;

  /// Share of samples that asked for a manual decision. `unknown` and a
  /// mismatch with the reference are both reasons to review.
  double get reviewRate => unknownCount / samples.length;

  double get accuracy =>
      samples.where((sample) => sample.$1 == sample.$2).length / samples.length;

  /// Per-class scores in enum order.
  List<ClassScores> get classes => [
    for (final kind in DocumentKind.values)
      ClassScores(
        kind: kind,
        truePositives: _count(kind, kind),
        falsePositives: samples
            .where((sample) => sample.$2 == kind && sample.$1 != kind)
            .length,
        falseNegatives: samples
            .where((sample) => sample.$1 == kind && sample.$2 != kind)
            .length,
        support: samples.where((sample) => sample.$1 == kind).length,
      ),
  ];

  /// Micro-averaged accuracy over the labelled classes (unknown excluded), which
  /// is the honest aggregate when the test set has no samples for a class.
  double get labelledAccuracy {
    final labelled = samples
        .where(
          (sample) =>
              sample.$1 != DocumentKind.unknown &&
              sample.$2 != DocumentKind.unknown,
        )
        .toList();
    if (labelled.isEmpty) return 0;
    return labelled.where((sample) => sample.$1 == sample.$2).length /
        labelled.length;
  }

  /// Confusion counts keyed by `actual → predicted`.
  Map<DocumentKind, Map<DocumentKind, int>> get confusion => {
    for (final actual in DocumentKind.values)
      actual: {
        for (final predicted in DocumentKind.values)
          predicted: samples
              .where((sample) => sample.$1 == actual && sample.$2 == predicted)
              .length,
      },
  };

  int _count(DocumentKind actual, DocumentKind predicted) => samples
      .where((sample) => sample.$1 == actual && sample.$2 == predicted)
      .length;
}
