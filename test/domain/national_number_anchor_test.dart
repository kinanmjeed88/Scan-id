import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/ocr_decoding.dart';
import 'package:scan_id/domain/ocr_evidence.dart';
import 'package:scan_id/domain/recognition_classifier.dart';

// The printed national number as a structural anchor of the unified card.
//
// Measured on the field photos with the app's own OCR graphs: the card's
// title is its smallest print and is read too garbled to match, even within
// the fuzzy tolerance, while the twelve-digit number under it, the field
// labels and the issuer line are read. A number identifies a format rather
// than naming the document, so it anchors the card only together with two
// further independent groups, and its own printed label is not one of them.
//
// Every string here is a dictionary phrase or a synthetic number. No
// document's number, name or text appears.

/// Twelve digits opening with a plausible year: the FORMAT of a national
/// number, deliberately nobody's.
const _number = '199000000000';

List<OcrKeywordEvidence> _evidence(List<(String, double)> lines) =>
    ocrKeywordEvidence(
      OcrTextResult.available(
        engineVersion: 'national-number-test',
        lines: [
          for (final (text, confidence) in lines)
            OcrLine(text: text, confidence: confidence),
        ],
      ),
    );

ClassificationOutcome _classify(List<(String, double)> lines) =>
    classifyDocument(ClassificationInput(ocrKeywords: _evidence(lines)));

void main() {
  group('the number anchors the card with two independent groups', () {
    test('number, a field label and the issuer evidence the unified card', () {
      final evidence = _evidence([
        (_number, 1),
        ('الاسم', .82),
        ('وزارة الداخلية', .74),
      ]);
      expect(evidence, hasLength(1));
      expect(evidence.single.kind, DocumentKind.unifiedNationalId);
      expect(evidence.single.matchedGroups, [
        nationalNumberGroupId,
        'fields',
        'issuer',
      ]);
      expect(evidence.single.matchedAnchorGroups, 3);
    });

    test('the score is the weakest link the anchor needed', () {
      // Two groups are required, so the second strongest bounds the score...
      expect(
        _evidence([
          (_number, 1),
          ('الاسم', .9),
          ('وزارة الداخلية', .5),
        ]).single.score,
        closeTo(.5, 1e-9),
      );
      // ...and a weakly read number bounds it too.
      expect(
        _evidence([
          (_number, .55),
          ('الاسم', .9),
          ('وزارة الداخلية', .8),
        ]).single.score,
        closeTo(.55, 1e-9),
      );
    });

    test('above the acceptance score it is a single recognized kind', () {
      final outcome = _classify([
        (_number, 1),
        ('الاسم', .9),
        ('وزارة الداخلية', .8),
      ]);
      expect(outcome.kind, DocumentKind.unifiedNationalId);
      expect(outcome.candidates, hasLength(1));
      expect(qualifiesForAutomaticPlacement(outcome), isTrue);
    });

    test('below the acceptance score it is never an automatic choice', () {
      final outcome = _classify([
        (_number, 1),
        ('الاسم', .9),
        ('وزارة الداخلية', .5),
      ]);
      expect(qualifiesForAutomaticPlacement(outcome), isFalse);
    });

    test('one further group is not enough', () {
      expect(_evidence([(_number, 1), ('الاسم', .9)]), isEmpty);
      expect(_evidence([(_number, 1), ('وزارة الداخلية', .9)]), isEmpty);
      expect(_evidence([(_number, 1)]), isEmpty);
    });

    test('the label of the number is not evidence independent of it', () {
      // «الرقم الوطني» restates the anchor: with the issuer alone there are
      // still only two independent groups.
      expect(
        _evidence([
          (_number, 1),
          ('الرقم الوطني', .95),
          ('وزارة الداخلية', .9),
        ]),
        isEmpty,
      );
      expect(
        _evidence([(_number, 1), ('الرقم الوطني', .95), ('الاسم', .9)]),
        isEmpty,
      );
      // With both independent groups present the label adds nothing and is
      // not listed.
      final evidence = _evidence([
        (_number, 1),
        ('الرقم الوطني', .95),
        ('الاسم', .9),
        ('وزارة الداخلية', .8),
      ]);
      expect(evidence.single.matchedGroups, isNot(contains('identifier')));
      expect(evidence.single.score, closeTo(.8, 1e-9));
    });
  });

  group('only the format is tested', () {
    List<OcrKeywordEvidence> withSupports(String line) =>
        _evidence([(line, 1), ('الاسم', .9), ('وزارة الداخلية', .9)]);

    test('a line that is not exactly twelve year-led digits is no anchor', () {
      for (final line in [
        '19900000000', // eleven digits
        '1990000000000', // thirteen digits
        '210000000000', // no plausible year
        '180000000000',
        '070000000000', // a phone-like number
        '1990-0000-0000', // separators: a date or a reference, not the number
        '1990/01/01',
        'A99000000000',
        '199000000000 IRQ', // the number inside a longer line
        'الرقم 199000000000',
      ]) {
        expect(withSupports(line), isEmpty, reason: 'line shape: $line');
      }
    });

    test('digit script and inner spacing do not change the number', () {
      for (final line in [
        _number,
        '1990 0000 0000',
        '١٩٩٠٠٠٠٠٠٠٠٠', // Arabic-Indic digits
        '۱۹۹۰۰۰۰۰۰۰۰۰', // Extended Arabic-Indic digits
        '200000000000',
      ]) {
        expect(withSupports(line), hasLength(1), reason: 'line shape: $line');
      }
    });

    test('the evidence carries group ids only, never the digits', () {
      final evidence = withSupports(_number).single;
      for (final id in evidence.matchedGroups) {
        expect(evidenceGroupLabels.containsKey(id), isTrue);
        expect(evidenceGroupLabel(id), isNot(contains(_number)));
      }
      expect(evidenceGroupLabel(nationalNumberGroupId), isNot('دليل آخر'));
    });
  });

  group('reading order', () {
    test('labels in the engine visual order corroborate the same number', () {
      // The engine emits Arabic lines in visual order; a number reads the
      // same either way, so it is offered in both views.
      final evidence = _evidence([
        (_number, 1),
        (reversedRunes('الاسم'), .82),
        (reversedRunes('وزارة الداخلية'), .74),
      ]);
      expect(evidence.single.kind, DocumentKind.unifiedNationalId);
      expect(evidence.single.score, closeTo(.74, 1e-9));
    });

    test('groups are still never paired across the two views', () {
      expect(
        _evidence([
          (_number, 1),
          ('الاسم', .9),
          (reversedRunes('وزارة الداخلية'), .9),
        ]),
        isEmpty,
      );
    });
  });

  group('what the new anchor leaves alone', () {
    test(
      'a printed title still needs one further group and scores as a pair',
      () {
        final evidence = _evidence([('البطاقة الوطنية', .9), (_number, 1)]);
        expect(evidence.single.matchedGroups, ['title', nationalNumberGroupId]);
        expect(evidence.single.score, closeTo(.9, 1e-9));
      },
    );

    test('the number creates no evidence for any other kind', () {
      final evidence = _evidence([
        ('جواز السفر', .9),
        ('رقم الجواز', .9),
        (_number, 1),
      ]);
      expect(evidence.map((e) => e.kind), [DocumentKind.passport]);
    });

    test('next to another kind the result is a conflict, not a choice', () {
      final outcome = _classify([
        ('بطاقة السكن', .95),
        ('اسم رب الأسرة', .9),
        (_number, 1),
        ('الاسم', .85),
        ('وزارة الداخلية', .8),
      ]);
      expect(outcome.candidates, hasLength(2));
      expect(qualifiesForAutomaticPlacement(outcome), isFalse);
    });

    test('error tolerance still cannot match an exact read', () {
      // One edit inside the title: any hit comes from the fuzzy path and
      // carries its discount, so it scores below the exact read.
      final exact = _evidence([
        ('البطاقة الوطنية الموحدة', .9),
        ('الرقم الوطني', .9),
      ]);
      final damaged = _evidence([
        ('البطاقة الرطنية الموحدة', .9),
        ('الرقم الوطني', .9),
      ]);
      expect(exact.single.score, closeTo(.9, 1e-9));
      for (final hit in damaged) {
        expect(hit.score, lessThan(exact.single.score));
      }
    });

    test('a reversed support line is still not an anchor', () {
      expect(
        _evidence([
          (reversedRunes('الرقم الوطني'), .8),
          (reversedRunes('الاسم'), .8),
        ]),
        isEmpty,
      );
    });
  });
}
