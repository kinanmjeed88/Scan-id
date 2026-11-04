import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/ocr_metrics.dart';
import 'package:scan_id/domain/validation.dart';

void main() {
  group('edit distance', () {
    test('identical and empty strings', () {
      expect(editDistance('', ''), 0);
      expect(editDistance('abc', 'abc'), 0);
      expect(editDistance('', 'abc'), 3);
      expect(editDistance('abc', ''), 3);
    });

    test('counts a substitution as one edit', () {
      expect(editDistance('abc', 'abd'), 1);
      expect(editDistance('كتاب', 'كتاب'), 0);
      expect(editDistance('كتاب', 'كتتب'), 1);
    });

    test('counts insertions and deletions', () {
      expect(editDistance('abc', 'abxc'), 1);
      expect(editDistance('abxc', 'abc'), 1);
    });

    test('compares code points, not UTF-16 units', () {
      expect(editDistance('𝑢', '𝜓'), 1);
      expect(editDistance('𝑢', ''), 1);
    });
  });

  group('error rates', () {
    test('CER is edits over reference characters', () {
      expect(characterErrorRate('ABCD', 'ABXD'), .25);
      expect(characterErrorRate('ABCD', 'ABCD'), 0);
      expect(characterErrorRate('', ''), 0);
      expect(characterErrorRate('', 'A'), 1);
      expect(
        characterErrorRate('AB', 'XYZ'),
        greaterThan(1),
        reason: 'a rate above 1 is meaningful, not a bug',
      );
    });

    test('WER is edits over reference words', () {
      expect(wordErrorRate('one two three', 'one two'), closeTo(1 / 3, 1e-9));
      expect(wordErrorRate('one two', 'one too'), .5);
      expect(wordErrorRate('one two', 'one two'), 0);
      expect(wordErrorRate('', ''), 0);
      expect(wordErrorRate('', 'extra'), 1);
    });

    test('a reordered sentence is not one word edit', () {
      expect(wordErrorRate('a b c', 'c b a'), greaterThan(0));
    });
  });

  group('classification report', () {
    ClassificationReport report() => ClassificationReport(
      samples: const [
        (DocumentKind.unifiedNationalId, DocumentKind.unifiedNationalId),
        (DocumentKind.unifiedNationalId, DocumentKind.unifiedNationalId),
        (DocumentKind.civilStatusId, DocumentKind.residenceCard),
        (DocumentKind.unknown, DocumentKind.unknown),
        (DocumentKind.rationCard, DocumentKind.unknown),
      ],
    );

    test('counts samples, unknowns and the review rate', () {
      final value = report();

      expect(value.sampleCount, 5);
      expect(
        value.unknownCount,
        2,
        reason: 'one predicted unknown, one actual',
      );
      expect(value.reviewRate, .4);
      expect(value.accuracy, .6);
    });

    test('per-class precision, recall and F1 use honest denominators', () {
      final scores = report().classes;
      final national = scores.firstWhere(
        (entry) => entry.kind == DocumentKind.unifiedNationalId,
      );
      final residence = scores.firstWhere(
        (entry) => entry.kind == DocumentKind.residenceCard,
      );
      final ration = scores.firstWhere(
        (entry) => entry.kind == DocumentKind.rationCard,
      );

      expect(national.support, 2);
      expect(national.precision, 1);
      expect(national.recall, 1);
      expect(national.f1, 1);

      expect(residence.precision, 0, reason: 'predicted, but wrong document');
      expect(residence.recall, isNull, reason: 'no residence sample at all');

      expect(ration.support, 1);
      expect(ration.recall, 0, reason: 'the only sample was declined');
      expect(ration.precision, isNull, reason: 'never predicted');
    });

    test('confusion counts every pair and sums to the sample count', () {
      final confusion = report().confusion;

      final nationalRow = confusion[DocumentKind.unifiedNationalId]!;

      expect(nationalRow[DocumentKind.unifiedNationalId], 2);
      expect(
        confusion[DocumentKind.civilStatusId]![DocumentKind.residenceCard],
        1,
      );
      expect(confusion[DocumentKind.rationCard]![DocumentKind.unknown], 1);
      var total = 0;
      for (final row in confusion.values) {
        for (final count in row.values) {
          total += count;
        }
      }
      expect(total, 5);
    });

    test('labelled accuracy ignores declined samples', () {
      // Three decoded samples: two correct, one wrong.
      expect(report().labelledAccuracy, closeTo(2 / 3, 1e-9));
    });

    test('an empty sample set is rejected', () {
      expect(
        () => ClassificationReport(samples: const []),
        throwsA(isA<ValidationException>()),
      );
    });
  });
}
