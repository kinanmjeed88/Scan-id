import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/ocr_decoding.dart';
import 'package:scan_id/domain/ocr_evidence.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_classifier.dart';

// Audit of the structural anchors: the printed national number and the MRZ.
//
// The questions are the ones a reviewer asks before trusting an anchor that
// matches a FORMAT: are the groups that corroborate it really independent, can
// another supported document that happens to carry such a number be relabelled,
// does the digit script or the order of the lines change the answer, and what
// happens when the anchor is absent.
//
// It also covers a fault measured on the back of the unified card: the app's
// own OCR read the first MRZ line at confidence 1.00 and a printed field label
// exactly, yet the card evidenced nothing. The engine emits Arabic in visual
// order, so the label was legible only in the reversed view, while the MRZ
// anchor was offered in the as-emitted view alone, and the two views are never
// paired. A correctly read anchor and its support simply never met.
//
// Every string is a dictionary phrase, a synthetic number or a placeholder MRZ
// line. No document's number, name or text appears.

/// Twelve digits opening with a plausible year: the FORMAT of a national
/// number, deliberately nobody's.
const _number = '199000000000';

/// Placeholder machine-readable lines in the two supported layouts.
const _cardMrz = 'IDIRQA0000000000000000000<<<';
const _passportMrz = 'P<IRQTEST<<NAME<<<<<<<<<<<<';

OcrTextResult _ocr(List<(String, double)> lines) => OcrTextResult.available(
  engineVersion: 'anchor-audit',
  lines: [
    for (final (text, confidence) in lines)
      OcrLine(text: text, confidence: confidence),
  ],
);

List<OcrKeywordEvidence> _evidence(List<(String, double)> lines) =>
    ocrKeywordEvidence(_ocr(lines));

List<OcrKeywordEvidence> _plain(List<String> lines) =>
    _evidence([for (final line in lines) (line, .9)]);

List<DocumentKind> _kinds(List<String> lines) =>
    _plain(lines).map((entry) => entry.kind).toList();

ClassificationOutcome _classify(List<String> lines) => classifyDocument(
  ClassificationInput(ocrKeywords: _plain(lines), ocrConfidence: .9),
);

/// Every ordering of [items].
List<List<T>> _permutations<T>(List<T> items) {
  if (items.length <= 1) return [items];
  final all = <List<T>>[];
  for (var i = 0; i < items.length; i++) {
    final rest = [...items]..removeAt(i);
    for (final tail in _permutations(rest)) {
      all.add([items[i], ...tail]);
    }
  }
  return all;
}

void main() {
  group('the groups that corroborate the number are independent', () {
    test('one label repeated on many lines is still one group', () {
      expect(_plain([_number, 'الاسم', 'الاسم', 'الاسم']), isEmpty);
    });

    test('several labels of the same group are still one group', () {
      expect(
        _plain([_number, 'الاسم', 'اللقب', 'تاريخ الولادة', 'فصيلة الدم']),
        isEmpty,
      );
    });

    test('several issuer lines are still one group', () {
      expect(
        _plain([
          _number,
          'وزارة الداخلية',
          'مديرية الأحوال المدنية والجوازات والإقامة',
        ]),
        isEmpty,
      );
    });

    test('the issuer line cannot double as a field label', () {
      // «الجنس» is a field label and sits inside «الجنسية»; a hit must start
      // and end on word boundaries, so this issuer line is one group only.
      expect(_plain([_number, 'مديرية الجنسية والمعلومات المدنية']), isEmpty);
    });

    test('two numbers do not corroborate each other', () {
      expect(_plain([_number, '200100000000', 'الاسم']), isEmpty);
    });

    test('two numbers with both groups are one piece of evidence of three', () {
      final evidence = _plain([
        _number,
        '200100000000',
        'الاسم',
        'وزارة الداخلية',
      ]);
      expect(evidence.single.kind, DocumentKind.unifiedNationalId);
      expect(evidence.single.matchedGroups, [
        nationalNumberGroupId,
        'fields',
        'issuer',
      ]);
      expect(evidence.single.matchedAnchorGroups, 3);
    });

    test('the score is the weakest line the anchor needed, never a sum', () {
      final evidence = _evidence([
        (_number, 1),
        ('الاسم', .7),
        ('اللقب', .95),
        ('وزارة الداخلية', .8),
      ]);
      // Each group counts once, by its best line: fields .95, issuer .8.
      expect(evidence.single.score, closeTo(.8, 1e-9));
    });

    test('a perfectly read number never lifts a weak title pair', () {
      final pair = _evidence([('البطاقة الوطنية', .65), ('الاسم', .7)]);
      final withNumber = _evidence([
        ('البطاقة الوطنية', .65),
        ('الاسم', .7),
        (_number, 1),
      ]);
      expect(pair.single.score, closeTo(.65, 1e-9));
      expect(withNumber.single.score, closeTo(.65, 1e-9));
    });

    test('a perfectly read number adds nothing to a weak support', () {
      final outcome = classifyDocument(
        ClassificationInput(
          ocrKeywords: _evidence([
            (_number, 1),
            ('الاسم', .5),
            ('وزارة الداخلية', .5),
          ]),
        ),
      );
      expect(outcome.kind, DocumentKind.unknown);
      expect(outcome.status, RecognitionStatus.unknown);
    });
  });

  group('the format of the number', () {
    const groups = ['الاسم', 'وزارة الداخلية'];

    test('Arabic-Indic, extended and Latin digits are the same number', () {
      for (final number in [
        '199000000000',
        '١٩٩٠٠٠٠٠٠٠٠٠',
        '۱۹۹۰۰۰۰۰۰۰۰۰',
        '1990٠٠٠٠۰۰۰۰',
        '1990 0000 0000',
        '\u00A0199000000000\t',
      ]) {
        expect(_kinds([number, ...groups]), [
          DocumentKind.unifiedNationalId,
        ], reason: 'number written as "$number"');
      }
    });

    test('anything else on the line means it is not the number', () {
      for (final line in [
        '19900000000', // eleven digits
        '1990000000000', // thirteen digits
        '189900000000', // not a plausible year
        '210000000000',
        '077012345678', // a telephone number
        '964770123456',
        '1990-0000-0000',
        '1990.0000.0000',
        '1990/0000/0000',
        ':199000000000',
        'الرقم الوطني 199000000000',
        'No 199000000000',
        '\u200F199000000000', // right-to-left mark
        '\u200E199000000000', // left-to-right mark
        '\u202B199000000000\u202C', // embedding and pop
        '\u2067199000000000\u2069', // isolate and pop
        '１９９０００００００００', // full-width digits
      ]) {
        expect(
          _kinds([line, ...groups]),
          isEmpty,
          reason: 'line "$line" must not anchor',
        );
      }
    });

    test('the number is format-identical to a year-led serial or timestamp, '
        'which is why it never evidences without two further groups', () {
      const timestamp = '202407301255';
      expect(_plain([timestamp]), isEmpty);
      expect(_plain([timestamp, 'الاسم']), isEmpty);
      expect(_plain([timestamp, 'وزارة الداخلية']), isEmpty);
    });
  });

  group('the order of the lines does not change the answer', () {
    test('every ordering of number, label and issuer evidences alike', () {
      final lines = [(_number, 1.0), ('اللقب', .85), ('وزارة الداخلية', .8)];
      for (final order in _permutations(lines)) {
        final evidence = _evidence(order);
        expect(evidence.single.kind, DocumentKind.unifiedNationalId);
        expect(evidence.single.matchedGroups, [
          nationalNumberGroupId,
          'fields',
          'issuer',
        ]);
        expect(evidence.single.score, closeTo(.8, 1e-9));
      }
    });

    test('unrelated lines between them change nothing', () {
      final evidence = _plain([
        'وزارة الداخلية',
        'نص غير ذي صلة',
        _number,
        'سطر آخر',
        'سطر ثالث',
        'الجنس',
      ]);
      expect(evidence.single.kind, DocumentKind.unifiedNationalId);
    });
  });

  group('without a structural anchor or a title', () {
    test('field labels and the issuer evidence nothing', () {
      expect(
        _plain([
          'الاسم',
          'اللقب',
          'تاريخ الولادة',
          'فصيلة الدم',
          'وزارة الداخلية',
          'مديرية الأحوال المدنية والجوازات والإقامة',
          'الرقم الوطني',
        ]),
        isEmpty,
      );
    });

    test('digits that are not the number do not help them', () {
      expect(
        _plain(['الاسم', 'وزارة الداخلية', '12345678', '2024', '07701234567']),
        isEmpty,
      );
    });
  });

  group('a document that names itself is never relabelled by the number', () {
    // The number is a format, and it belongs to a person: the same twelve
    // digits may be printed on that person's other papers, next to the same
    // ministry and the same generic labels. Each case below prints all three
    // facts the number anchor asks for, beside the document's own evidence.
    const withNumber = [_number, 'الاسم', 'اللقب', 'وزارة الداخلية'];

    final others = <DocumentKind, List<String>>{
      DocumentKind.residenceCard: [
        'مديرية مكتب المعلومات المركزي',
        'اسم رب الأسرة',
        'عنوان السكن',
        'رقم الاستمارة',
      ],
      DocumentKind.passport: [
        'جواز السفر',
        'رقم الجواز',
        'تاريخ الولادة',
        'محل الولادة',
        'جهة الإصدار',
      ],
      DocumentKind.rationCard: [
        'وزارة التجارة',
        'البطاقة التموينية',
        'المركز التمويني',
      ],
      DocumentKind.civilStatusId: [
        'هوية الأحوال المدنية',
        'سجل النفوس',
        'رقم السجل',
        'رقم الصحيفة',
      ],
    };

    for (final MapEntry(key: kind, value: own) in others.entries) {
      test('${kind.name}: classified exactly as it is without the number', () {
        final without = _plain(own);
        final beside = _plain([...own, ...withNumber]);

        expect(without.single.kind, kind);
        expect(beside.map((entry) => entry.kind), [kind]);
        expect(beside.single.matchedGroups, without.single.matchedGroups);
        expect(beside.single.score, without.single.score);

        final outcome = _classify([...own, ...withNumber]);
        expect(outcome.kind, kind);
        expect(outcome.status, RecognitionStatus.recognized);
        expect(outcome.candidates, [kind]);
        expect(qualifiesForAutomaticPlacement(outcome), isTrue);
      });
    }

    test('a passport named by its MRZ alone is unaffected too', () {
      final evidence = _plain([_passportMrz, 'رقم الجواز', ...withNumber]);
      expect(evidence.map((entry) => entry.kind), [DocumentKind.passport]);
    });

    test('every ordering of the lines gives the same answer', () {
      final lines = [
        'مديرية مكتب المعلومات المركزي',
        'اسم رب الأسرة',
        _number,
        'الاسم',
        'وزارة الداخلية',
      ];
      for (final order in _permutations(lines)) {
        expect(_kinds(order), [DocumentKind.residenceCard]);
      }
    });

    test('the number does not fill in for evidence too weak to accept', () {
      // The document names itself, weakly. A perfectly read number, label and
      // ministry beside it do not turn it into a unified card.
      final outcome = classifyDocument(
        ClassificationInput(
          ocrKeywords: _evidence([
            ('بطاقة السكن', .5),
            ('اسم رب الأسرة', .5),
            (_number, 1),
            ('الاسم', 1),
            ('وزارة الداخلية', 1),
          ]),
        ),
      );
      expect(outcome.candidates, [DocumentKind.residenceCard]);
      expect(outcome.kind, isNot(DocumentKind.unifiedNationalId));
      expect(outcome.status, isNot(RecognitionStatus.recognized));
    });

    test('a unified card that prints its own title is not withdrawn: two '
        'named kinds stay a manual choice, as they always were', () {
      final outcome = _classify([
        'البطاقة الوطنية',
        _number,
        'الاسم',
        'وزارة الداخلية',
        'هوية الأحوال المدنية',
        'سجل النفوس',
      ]);
      expect(outcome.candidates, [
        DocumentKind.unifiedNationalId,
        DocumentKind.civilStatusId,
      ]);
      expect(outcome.status, isNot(RecognitionStatus.recognized));
      expect(qualifiesForAutomaticPlacement(outcome), isFalse);
    });

    test('a unified card named by its MRZ is not withdrawn either', () {
      final evidence = _plain([
        _cardMrz,
        _number,
        'تاريخ الإصدار',
        'جواز السفر',
        'رقم الجواز',
      ]);
      expect(evidence.map((entry) => entry.kind), [
        DocumentKind.unifiedNationalId,
        DocumentKind.passport,
      ]);
    });

    test('with no other kind named, the number anchors the card as before', () {
      final outcome = _classify(withNumber);
      expect(outcome.kind, DocumentKind.unifiedNationalId);
      expect(outcome.status, RecognitionStatus.recognized);
      expect(outcome.candidates, [DocumentKind.unifiedNationalId]);
    });

    test('labels of another kind that do not name it change nothing', () {
      // Household and registry labels without their title evidence nothing,
      // so there is no other kind for the number to yield to.
      expect(_kinds([...withNumber, 'اسم رب الأسرة', 'سجل النفوس']), [
        DocumentKind.unifiedNationalId,
      ]);
    });
  });

  group('the unified card itself', () {
    test('front without a readable title: number, labels and issuer', () {
      final outcome = _classify([
        'وزارة الداخلية',
        _number,
        'الاسم',
        'الأب',
        'الجد',
        'اللقب',
        'الأم',
        'الجنس',
        'فصيلة الدم',
      ]);
      expect(outcome.kind, DocumentKind.unifiedNationalId);
      expect(outcome.status, RecognitionStatus.recognized);
    });

    test('front with the title: the title pairs as it always did', () {
      final evidence = _plain(['البطاقة الوطنية', 'الاسم']);
      expect(evidence.single.matchedGroups, ['title', 'fields']);
    });
  });

  group('an MRZ line meets its labels in either reading order', () {
    test('card back as the engine emits it: MRZ and a visual-order label', () {
      final evidence = _evidence([
        (reversedRunes('محل الولادة'), .83),
        (_cardMrz, 1),
      ]);
      expect(evidence.single.kind, DocumentKind.unifiedNationalId);
      expect(evidence.single.matchedGroups, ['mrz', 'fields']);
      expect(evidence.single.score, closeTo(.83, 1e-9));
    });

    test('card back in logical order: unchanged', () {
      final evidence = _evidence([('تاريخ الإصدار', .9), (_cardMrz, 1)]);
      expect(evidence.single.matchedGroups, ['mrz', 'fields']);
      expect(evidence.single.score, closeTo(.9, 1e-9));
    });

    test('a label merged with a value in visual order still matches on word '
        'boundaries only', () {
      // The label is the last word group of the as-emitted line; reversed, it
      // opens the line and is followed by other words.
      final evidence = _evidence([
        (reversedRunes('محل الولادة كلمة أخرى'), .8),
        (_cardMrz, .95),
      ]);
      expect(evidence.single.matchedGroups, ['mrz', 'fields']);
      expect(evidence.single.score, closeTo(.8, 1e-9));
    });

    test('passport: MRZ and a visual-order Arabic label', () {
      final evidence = _evidence([
        (reversedRunes('نوع الجواز'), .8),
        (_passportMrz, 1),
      ]);
      expect(evidence.single.kind, DocumentKind.passport);
      expect(evidence.single.matchedGroups, ['mrz', 'personalDataLabels']);
    });

    test('recognized as a single kind above the acceptance score', () {
      final outcome = classifyDocument(
        ClassificationInput(
          ocrKeywords: _evidence([
            (reversedRunes('جهة الإصدار'), .85),
            (reversedRunes('تاريخ النفاذ'), .8),
            (_cardMrz, 1),
          ]),
        ),
      );
      expect(outcome.kind, DocumentKind.unifiedNationalId);
      expect(outcome.status, RecognitionStatus.recognized);
      expect(outcome.candidates, [DocumentKind.unifiedNationalId]);
    });

    test('an MRZ line alone evidences nothing in either view', () {
      expect(_plain([_cardMrz]), isEmpty);
      expect(_plain([_passportMrz]), isEmpty);
      expect(_plain([_cardMrz, reversedRunes('نص غير ذي صلة')]), isEmpty);
    });

    test('the line is validated as emitted: a reversed MRZ is not one', () {
      expect(_plain([reversedRunes(_cardMrz), 'تاريخ الإصدار']), isEmpty);
      expect(_plain([reversedRunes(_passportMrz), 'رقم الجواز']), isEmpty);
    });

    test('the two layouts still never evidence each other', () {
      // A label only the passport lexicon knows beside the card's MRZ, and
      // the reverse, in the visual order the engine emits.
      expect(_plain([_cardMrz, reversedRunes('رقم الجواز')]), isEmpty);
      expect(_plain([_passportMrz, reversedRunes('فصيلة الدم')]), isEmpty);
    });

    test(
      'labels in one view and a title in the other are still not paired',
      () {
        // The number and the MRZ are structural and are offered in both views;
        // a printed title is text and belongs to the view it is legible in.
        expect(
          _plain(['البطاقة الوطنية', reversedRunes('تاريخ الإصدار')]),
          isEmpty,
        );
      },
    );

    test('the evidence still carries group ids only, never the line', () {
      final evidence = _evidence([
        (reversedRunes('محل الولادة'), .83),
        (_cardMrz, 1),
      ]);
      final outcome = classifyDocument(
        ClassificationInput(ocrKeywords: evidence),
      );
      expect(outcome.evidence, isNotEmpty);
      for (final entry in outcome.evidence) {
        final reason = entry.reason ?? '';
        expect(reason, isNot(contains('IDIRQ')));
        expect(reason, isNot(contains('<')));
        expect(RegExp(r'\d{4,}').hasMatch(reason), isFalse);
      }
    });
  });
}
