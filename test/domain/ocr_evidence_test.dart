import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/ocr_decoding.dart';
import 'package:scan_id/domain/ocr_evidence.dart';

void main() {
  test(
    'split and merged titles use disjoint semantic anchors in either line order',
    () {
      for (final texts in [
        ['بطاقة السكن المحلة'],
        ['هوية الأحوال المدنية رقم السجل'],
        ['البطاقة', 'الوطنية الموحدة', 'الرقم الوطني'],
        ['الرقم الوطني', 'البطاقة', 'الوطنية الموحدة'],
        ['National card National number 12345678'],
        [reversedRunes('البطاقة الوطنية الرقم الوطني')],
      ]) {
        final evidence = ocrKeywordEvidence(
          OcrTextResult.available(
            engineVersion: 'layout-regression',
            lines: [
              for (final text in texts) OcrLine(text: text, confidence: .81),
            ],
          ),
        );
        expect(evidence, hasLength(1), reason: texts.join(' | '));
        expect(evidence.single.score, .81);
      }
    },
  );

  test(
    'overlapping issuer/title and arbitrary distant fragments do not invent support',
    () {
      for (final texts in [
        ['مديرية شؤون البطاقة الوطنية'],
        ['البطاقة', 'نص غير مرتبط', 'الوطنية الموحدة', 'الرقم الوطني'],
      ]) {
        expect(
          ocrKeywordEvidence(
            OcrTextResult.available(
              engineVersion: 'negative-layout',
              lines: [
                for (final text in texts) OcrLine(text: text, confidence: .99),
              ],
            ),
          ),
          isEmpty,
        );
      }
    },
  );

  test('unavailable OCR yields no evidence and no confidence', () {
    final result = OcrTextResult.unavailable(
      unavailableReason: 'no-offline-engine-packaged',
      engineVersion: 'ocr-unavailable-1',
    );
    expect(result.isAvailable, isFalse);
    expect(result.confidence, isNull, reason: 'absence, not zero');
    expect(ocrKeywordEvidence(result), isEmpty);
  });

  test('empty available result has null confidence and no evidence', () {
    final result = OcrTextResult.available(
      lines: const [],
      engineVersion: 'test-1',
    );
    expect(result.confidence, isNull);
    expect(ocrKeywordEvidence(result), isEmpty);
  });

  test(
    'each supported type requires and accepts distinct two-line anchors',
    () {
      final cases = [
        (
          kind: DocumentKind.unifiedNationalId,
          title: 'البطاقة الوطنية الموحدة',
          support: 'الرقم الوطني',
        ),
        (
          kind: DocumentKind.civilStatusId,
          title: 'هوية الأحوال المدنية',
          support: 'رقم السجل',
        ),
        (
          kind: DocumentKind.residenceCard,
          title: 'بطاقة السكن',
          support: 'المحلة',
        ),
        (
          kind: DocumentKind.rationCard,
          title: 'البطاقة التموينية',
          support: 'وزارة التجارة',
        ),
        (kind: DocumentKind.passport, title: 'جواز سفر', support: 'رقم الجواز'),
      ];

      for (final entry in cases) {
        final result = OcrTextResult.available(
          lines: [
            OcrLine(text: entry.title, confidence: .82),
            OcrLine(text: entry.support, confidence: .91),
          ],
          engineVersion: 'lexicon-test-1',
        );
        final evidence = ocrKeywordEvidence(result);
        expect(evidence, hasLength(1), reason: entry.kind.name);
        expect(evidence.single.kind, entry.kind);
        expect(evidence.single.matchedAnchorGroups, 2);
        expect(
          evidence.single.score,
          .82,
          reason: 'use the weaker OCR line, not an invented class probability',
        );
      }
    },
  );

  test('single title, issuer, or country name is insufficient', () {
    for (final lines in const [
      ['البطاقة الوطنية الموحدة'],
      ['وزارة الداخلية'],
      ['جمهورية العراق'],
    ]) {
      final result = OcrTextResult.available(
        lines: [for (final text in lines) OcrLine(text: text, confidence: .99)],
        engineVersion: 'lexicon-test-1',
      );
      expect(ocrKeywordEvidence(result), isEmpty, reason: lines.join(' | '));
    }
  });

  test(
    'Arabic diacritics, alef variants, spacing and punctuation normalize',
    () {
      final result = OcrTextResult.available(
        lines: [
          OcrLine(
            text: 'البِطَاقَةُ الوَطَنِيَّةُ المُوَحَّدَةُ',
            confidence: .86,
          ),
          OcrLine(text: 'الرّقمُ الوَطنيّ', confidence: .9),
        ],
        engineVersion: 'test-1',
      );
      final evidence = ocrKeywordEvidence(result);
      expect(evidence.map((e) => e.kind), [DocumentKind.unifiedNationalId]);
      expect(evidence.single.score, .86);
    },
  );

  test(
    'distinct secondary groups are counted without retaining matched text',
    () {
      final result = OcrTextResult.available(
        lines: [
          OcrLine(text: 'البطاقة الوطنية', confidence: .8),
          OcrLine(text: 'الرقم الوطني', confidence: .88),
          OcrLine(text: 'وزارة الداخلية', confidence: .93),
        ],
        engineVersion: 'test-1',
      );
      final evidence = ocrKeywordEvidence(result).single;
      expect(evidence.kind, DocumentKind.unifiedNationalId);
      expect(evidence.matchedAnchorGroups, 3);
      expect(evidence.score, .8);
      expect(evidence.toString(), isNot(contains('البطاقة')));
    },
  );

  test(
    'two full type signatures remain competing evidence, not a forced match',
    () {
      final result = OcrTextResult.available(
        lines: [
          OcrLine(text: 'البطاقة الوطنية الموحدة', confidence: .91),
          OcrLine(text: 'الرقم الوطني', confidence: .9),
          OcrLine(text: 'بطاقة السكن', confidence: .9),
          OcrLine(text: 'المحلة', confidence: .89),
        ],
        engineVersion: 'test-1',
      );
      final evidence = ocrKeywordEvidence(result);
      expect(evidence.map((e) => e.kind), [
        DocumentKind.unifiedNationalId,
        DocumentKind.residenceCard,
      ]);
    },
  );

  test('mean line confidence includes every available line', () {
    final result = OcrTextResult.available(
      lines: [
        OcrLine(text: 'أ', confidence: .5),
        OcrLine(text: 'ب', confidence: .9),
      ],
      engineVersion: 'test-1',
    );
    expect(result.confidence, closeTo(.7, 1e-9));
  });

  test('line and keyword scores and anchor counts are validated', () {
    expect(
      () => OcrLine(text: 'x', confidence: 1.2),
      throwsA(isA<Exception>()),
    );
    expect(
      () => OcrKeywordEvidence(
        kind: DocumentKind.passport,
        score: -0.1,
        matchedAnchorGroups: 2,
      ),
      throwsA(isA<Exception>()),
    );
    expect(
      () => OcrKeywordEvidence(
        kind: DocumentKind.passport,
        score: .9,
        matchedAnchorGroups: 1,
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('unrelated text produces nothing', () {
    final result = OcrTextResult.available(
      lines: [OcrLine(text: 'مرحبا بالعالم', confidence: .99)],
      engineVersion: 'test-1',
    );
    expect(ocrKeywordEvidence(result), isEmpty);
  });

  test('visual-order (right-to-left) recognition still anchors a type', () {
    // The same two anchors, emitted by an export that writes the line in visual
    // order: the text is reversed, the document is the same document.
    final result = OcrTextResult.available(
      lines: [
        OcrLine(text: reversedRunes('البطاقة الوطنية الموحدة'), confidence: .8),
        OcrLine(text: reversedRunes('الرقم الوطني'), confidence: .9),
      ],
      engineVersion: 'rtl-test-1',
    );

    final evidence = ocrKeywordEvidence(result);

    expect(evidence, hasLength(1));
    expect(evidence.single.kind, DocumentKind.unifiedNationalId);
    expect(evidence.single.score, .8);
  });

  test('a two-character phrase can never act as an anchor', () {
    expect(minAnchorLength, greaterThanOrEqualTo(3));
    final result = OcrTextResult.available(
      lines: [
        OcrLine(text: 'اب', confidence: .99),
        OcrLine(text: 'ج د', confidence: .99),
      ],
      engineVersion: 'short-anchor-test',
    );

    expect(ocrKeywordEvidence(result), isEmpty);
  });
}
