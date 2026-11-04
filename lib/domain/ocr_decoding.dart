/// CTC decoding for PP-OCR recognition output.
///
/// The recognition export returns one probability row per output timestep over
/// `blank + dictionary + space`. Greedy CTC decoding collapses repeated classes
/// and drops the blank, and the mean probability of the characters that
/// survived is the line confidence the pipeline records.
///
/// The stage is deliberately free of Flutter and of the model: it takes the flat
/// tensor and the alphabet, so a decoder regression is a unit test rather than a
/// device experiment (ADR-010).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'validation.dart';

/// Strength of the "these rows are already softmaxes" test.
const double _probabilityRowTolerance = .2;

/// One decoded recognition row.
class DecodedOcrLine {
  const DecodedOcrLine({required this.text, required this.confidence});

  /// Recognised characters in model order. Never logged, never persisted by the
  /// pipeline — only derived evidence leaves the run.
  final String text;

  /// Mean probability of the characters in [text]; 0 when nothing was decoded.
  final double confidence;

  bool get isEmpty => text.isEmpty;
}

/// Builds the class table the recognition graph was trained with.
///
/// Index 0 is the CTC blank; the exported dictionary follows; the last class is
/// the space character the PP-OCR exports append when `use_space_char` is on.
List<String> buildOcrAlphabet(List<String> dictionary) {
  require(dictionary.isNotEmpty, 'قاموس OCR فارغ.');
  return List<String>.unmodifiable(['', ...dictionary, ' ']);
}

/// Parses a one-character-per-line dictionary file.
///
/// Lines are code points, not UTF-16 units: the Arabic PP-OCRv5 dictionary
/// contains two supplementary-plane characters, and splitting by byte or by
/// `String.length` would silently shift every index after them.
List<String> parseOcrDictionary(String source) {
  final characters = <String>[];
  for (final rawLine in source.split('\n')) {
    final line = rawLine.replaceAll('\r', '');
    if (line.isEmpty) continue;
    final runes = line.runes.toList();
    require(runes.length == 1, 'سطر قاموس OCR يجب أن يكون حرفاً واحداً.');
    characters.add(String.fromCharCode(runes.first));
  }
  require(characters.length > 100, 'قاموس OCR أصغر من المتوقع.');
  return List<String>.unmodifiable(characters);
}

/// Whether the returned rows are probabilities (they sum to ~1 per timestep).
///
/// A re-exported, quantised or differently exported graph can return logits.
/// Testing the rows keeps the decoder correct for both without a per-model code
/// path; a softmax applied to probabilities would flatten them and destroy the
/// confidence the pipeline reports.
bool rowsLookLikeProbabilities(
  Float32List values, {
  required int timeSteps,
  required int classes,
}) {
  if (timeSteps <= 0 || classes <= 0) return false;
  if (values.length != timeSteps * classes) return false;
  var negative = 0;
  final sampleSteps = math.min(timeSteps, 32);
  for (var step = 0; step < sampleSteps; step++) {
    final offset = step * classes;
    var total = 0.0;
    for (var index = 0; index < classes; index++) {
      final value = values[offset + index];
      if (!value.isFinite) return false;
      if (value < 0) negative++;
      total += value;
    }
    if (negative > 0) return false;
    if ((total - 1).abs() > _probabilityRowTolerance) return false;
  }
  return true;
}

/// Softmax over every row, for a graph that returns logits.
Float32List probabilitiesFromLogits(
  Float32List values, {
  required int timeSteps,
  required int classes,
}) {
  require(
    timeSteps > 0 && classes > 0 && values.length == timeSteps * classes,
    'أبعاد مخرجات OCR غير صالحة.',
  );
  final result = Float32List(values.length);
  for (var step = 0; step < timeSteps; step++) {
    final offset = step * classes;
    var maximum = double.negativeInfinity;
    for (var index = 0; index < classes; index++) {
      final value = values[offset + index];
      if (value.isFinite && value > maximum) maximum = value;
    }
    if (!maximum.isFinite) continue;
    var total = 0.0;
    for (var index = 0; index < classes; index++) {
      final value = values[offset + index];
      final exponent = value.isFinite ? math.exp(value - maximum) : 0.0;
      result[offset + index] = exponent;
      total += exponent;
    }
    if (!(total > 0)) continue;
    for (var index = 0; index < classes; index++) {
      result[offset + index] = result[offset + index] / total;
    }
  }
  return result;
}

/// Greedy CTC decode of one recognition row.
///
/// [values] is the flat `timeSteps × classes` tensor for a single line (batch 1).
/// Classes beyond the alphabet are dropped rather than guessed: a model whose
/// exported dictionary appends entries this build does not know must never
/// invent characters for them.
DecodedOcrLine decodeCtcLine({
  required Float32List values,
  required int timeSteps,
  required int classes,
  required List<String> alphabet,
  double minConfidence = .3,
  int maxCharacters = 256,
}) {
  require(timeSteps > 0 && classes > 0, 'أبعاد مخرجات OCR غير صالحة.');
  require(
    values.length == timeSteps * classes,
    'حجم مخرجات OCR لا يطابق أبعادها.',
  );
  require(alphabet.isNotEmpty, 'قاموس OCR فارغ.');
  require(
    minConfidence.isFinite && minConfidence >= 0 && minConfidence <= 1,
    'حد ثقة OCR غير صالح.',
  );
  final buffer = StringBuffer();
  var total = 0.0;
  var kept = 0;
  var previous = -1;
  for (var step = 0; step < timeSteps; step++) {
    final offset = step * classes;
    var bestIndex = 0;
    var best = values[offset];
    for (var index = 1; index < classes; index++) {
      final value = values[offset + index];
      if (value > best) {
        best = value;
        bestIndex = index;
      }
    }
    // CTC collapse: a repeated class is one emission, and moving to the blank
    // ends it. `previous` advances on every timestep, blanks included.
    if (bestIndex == previous) continue;
    previous = bestIndex;
    if (bestIndex == 0) continue;
    if (!best.isFinite) continue;
    if (bestIndex >= alphabet.length) continue;
    if (best < minConfidence) continue;
    total += best.clamp(0.0, 1.0).toDouble();
    kept++;
    if (buffer.length < maxCharacters) buffer.write(alphabet[bestIndex]);
  }
  if (kept == 0) return const DecodedOcrLine(text: '', confidence: 0);
  final text = buffer.toString().trim();
  if (text.isEmpty) return const DecodedOcrLine(text: '', confidence: 0);
  return DecodedOcrLine(text: text, confidence: total / kept);
}

/// [text] with its code points in reverse order.
///
/// Arabic is read right-to-left. Different exports emit logical (reading) order
/// or visual (left-to-right) order, and this build cannot verify which on a
/// device. Evidence matching therefore tests both orders instead of assuming
/// one: a wrong assumption then costs nothing, while a fabricated bidi pass
/// could reverse text that was already correct.
String reversedRunes(String text) {
  final runes = text.runes.toList();
  return String.fromCharCodes(runes.reversed);
}
