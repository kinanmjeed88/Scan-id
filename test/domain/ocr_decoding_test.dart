import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/ocr_decoding.dart';
import 'package:scan_id/domain/validation.dart';

/// A dictionary of [count] distinct Arabic code points, one per line.
String dictionarySource({int count = 120, String? first}) {
  final characters = [
    for (var index = 0; index < count; index++)
      String.fromCharCode(0x0627 + index % 20),
  ];
  if (first != null) characters[0] = first;
  return characters.join('\n');
}

/// A one-hot recognition row with [steps] timesteps and [classes] classes.
Float32List oneHotRows({
  required int steps,
  required int classes,
  required int index,
  double probability = .9,
}) {
  final values = Float32List(steps * classes);
  for (var step = 0; step < steps; step++) {
    values[step * classes + index] = probability;
    if (probability < 1) values[step * classes] = 1 - probability;
  }
  return values;
}

void main() {
  group('dictionary', () {
    test('parses one code point per line', () {
      final dictionary = parseOcrDictionary(dictionarySource());

      expect(dictionary, hasLength(120));
      expect(dictionary.first, 'ا');
    });

    test('keeps supplementary-plane characters as single entries', () {
      final dictionary = parseOcrDictionary(dictionarySource(first: '𝑢'));

      expect(dictionary, hasLength(120));
      expect(dictionary.first, '𝑢');
      expect(dictionary.first.length, 2, reason: 'one code point, two units');
    });

    test('tolerates CRLF line endings', () {
      final source = dictionarySource().replaceAll('\n', '\r\n');

      expect(parseOcrDictionary(source), hasLength(120));
    });

    test('rejects an empty or implausibly small dictionary', () {
      expect(() => parseOcrDictionary(''), throwsA(isA<ValidationException>()));
      expect(
        () => parseOcrDictionary('a\nb\nc'),
        throwsA(isA<ValidationException>()),
      );
    });

    test('rejects a line that is not a single character', () {
      final lines = dictionarySource().split('\n')..[10] = 'اب';

      expect(
        () => parseOcrDictionary(lines.join('\n')),
        throwsA(isA<ValidationException>()),
      );
    });

    test('the alphabet is blank, then the dictionary, then a space', () {
      final alphabet = buildOcrAlphabet(const ['ا', 'ب']);

      expect(alphabet, ['', 'ا', 'ب', ' ']);
      expect(alphabet, hasLength(4));
    });
  });

  group('row interpretation', () {
    test('softmax rows are recognised as probabilities', () {
      final values = Float32List.fromList([.1, .7, .2, .3, .3, .4]);

      expect(
        rowsLookLikeProbabilities(values, timeSteps: 2, classes: 3),
        isTrue,
      );
    });

    test('logits are not mistaken for probabilities', () {
      final values = Float32List.fromList([-1.5, 3.2, .4, 8, -2, 1]);

      expect(
        rowsLookLikeProbabilities(values, timeSteps: 2, classes: 3),
        isFalse,
      );
    });

    test('a negative row can never be a probability row', () {
      final values = Float32List.fromList([.9, .9, -.5, .2]);

      expect(
        rowsLookLikeProbabilities(values, timeSteps: 2, classes: 2),
        isFalse,
      );
    });

    test('logits are converted with a per-row softmax', () {
      final values = Float32List.fromList([0, 0, 1, 1]);

      final probabilities = probabilitiesFromLogits(
        values,
        timeSteps: 2,
        classes: 2,
      );

      expect(probabilities[0], closeTo(.5, 1e-6));
      expect(probabilities[1], closeTo(.5, 1e-6));
      expect(probabilities[2], closeTo(.7310585, 1e-6));
      expect(probabilities[3], closeTo(.2689414, 1e-6));
    });
  });

  group('CTC decoding', () {
    const alphabet = ['', 'a', 'b', ' '];

    test('collapses repeats and drops blanks', () {
      final values = Float32List(6 * 4);
      void put(int step, int index, double value) {
        values[step * 4 + index] = value;
      }

      put(0, 1, .9);
      put(1, 1, .8);
      put(2, 0, .9);
      put(3, 2, .7);
      put(4, 2, .6);
      put(5, 1, .5);

      final decoded = decodeCtcLine(
        values: values,
        timeSteps: 6,
        classes: 4,
        alphabet: alphabet,
      );

      expect(decoded.text, 'aba');
      expect(decoded.confidence, closeTo((.9 + .7 + .5) / 3, 1e-6));
    });

    test('an all-blank row decodes to nothing, not to a guess', () {
      final decoded = decodeCtcLine(
        values: oneHotRows(steps: 5, classes: 4, index: 0),
        timeSteps: 5,
        classes: 4,
        alphabet: alphabet,
      );

      expect(decoded.isEmpty, isTrue);
      expect(decoded.confidence, 0);
    });

    test('a character below the confidence floor is dropped', () {
      final decoded = decodeCtcLine(
        values: oneHotRows(steps: 4, classes: 4, index: 1, probability: .2),
        timeSteps: 4,
        classes: 4,
        alphabet: alphabet,
      );

      expect(decoded.isEmpty, isTrue);
    });

    test('classes past the alphabet are dropped, never fabricated', () {
      final decoded = decodeCtcLine(
        values: oneHotRows(steps: 4, classes: 6, index: 5),
        timeSteps: 4,
        classes: 6,
        alphabet: alphabet,
      );

      expect(decoded.isEmpty, isTrue);
    });

    test('a repeated character separated by a blank is kept twice', () {
      final values = Float32List(3 * 4);
      values[0 * 4 + 1] = .9;
      values[1 * 4 + 0] = .9;
      values[2 * 4 + 1] = .9;

      final decoded = decodeCtcLine(
        values: values,
        timeSteps: 3,
        classes: 4,
        alphabet: alphabet,
      );

      expect(decoded.text, 'aa');
    });

    test('a mismatched tensor size is rejected', () {
      expect(
        () => decodeCtcLine(
          values: Float32List(3),
          timeSteps: 2,
          classes: 4,
          alphabet: alphabet,
        ),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  test('reversing preserves supplementary-plane code points', () {
    expect(reversedRunes('ابج'), 'جبا');
    expect(reversedRunes('𝑢𝜓'), '𝜓𝑢');
    expect(reversedRunes(''), '');
  });
}
