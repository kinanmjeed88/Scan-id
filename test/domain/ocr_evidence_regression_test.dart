/// Regression tests for the keyword-driven Iraqi-document classifier.
///
/// Every fixture below is built ONLY from printed headings and field labels
/// (plus synthetic MRZ lines with placeholder characters). No personal name,
/// document number, birth date or other extracted value appears in any test,
/// and no test image is shipped with the repository.
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/ocr_decoding.dart';
import 'package:scan_id/domain/ocr_evidence.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_classifier.dart';

OcrTextResult _ocr(List<String> texts, {double confidence = .9}) =>
    OcrTextResult.available(
      engineVersion: 'regression-test',
      lines: [
        for (final text in texts) OcrLine(text: text, confidence: confidence),
      ],
    );

List<DocumentKind> _kinds(List<String> texts, {double confidence = .9}) =>
    ocrKeywordEvidence(_ocr(texts, confidence: confidence))
        .map((entry) => entry.kind)
        .toList();

OcrKeywordEvidence _single(List<String> texts, {double confidence = .9}) {
  final evidence = ocrKeywordEvidence(_ocr(texts, confidence: confidence));
  expect(evidence, hasLength(1), reason: texts.join(' | '));
  return evidence.single;
}

void main() {
  group('national ID', () {
    test('front: printed title plus distinctive fields', () {
      final evidence = _single([
        'البطاقة الوطنية',
        'جمهورية العراق',
        'وزارة الداخلية',
        'مديرية الأحوال المدنية والجوازات والإقامة',
        'الاسم',
        'الأب',
        'الجد',
        'اللقب',
        'الأم',
        'الجنس',
        'فصيلة الدم',
        'الرقم الوطني',
      ]);
      expect(evidence.kind, DocumentKind.unifiedNationalId);
      expect(evidence.matchedGroups, [
        'title',
        'identifier',
        'fields',
        'issuer',
      ]);
    });

    test('back: MRZ structure plus printed fields, without the title', () {
      final evidence = _single([
        'جهة الإصدار',
        'تاريخ الإصدار',
        'تاريخ الانتهاء',
        'محل الولادة',
        'تاريخ الولادة',
        'الرقم العائلي',
        'IDIRQ A00000000 0000000000000<<<',
      ]);
      expect(evidence.kind, DocumentKind.unifiedNationalId);
      expect(evidence.matchedGroups, ['mrz', 'fields']);
    });

    test('title plus issuer alone evidences (two independent groups)', () {
      final evidence = _single([
        'البطاقة الوطنية',
        'وزارة الداخلية',
      ]);
      expect(evidence.kind, DocumentKind.unifiedNationalId);
      expect(evidence.matchedAnchorGroups, 2);
    });

    test('title plus a distinctive field evidences', () {
      expect(
        _kinds(['البطاقة الوطنية', 'فصيلة الدم']),
        [DocumentKind.unifiedNationalId],
      );
    });

    test('personal fields without a title or MRZ never evidence', () {
      expect(
        _kinds(['الاسم', 'الجنس', 'فصيلة الدم']),
        isEmpty,
      );
      expect(
        _kinds(['الاسم', 'الأم', 'تاريخ الولادة']),
        isEmpty,
      );
    });

    test('a partial word inside a longer word is not a field hit', () {
      // «الاسماء» must not count as the «الاسم» field.
      expect(
        _kinds(['البطاقة الوطنية', 'الاسماء']),
        isEmpty,
      );
    });

    test('MRZ with an OCR-confused prefix letter still evidences', () {
      final evidence = _single([
        'IDIR0 A00000000 0000000000000<<<',
        'تاريخ الولادة',
      ]);
      expect(evidence.kind, DocumentKind.unifiedNationalId);
      expect(evidence.matchedGroups, contains('mrz'));
    });
  });

  group('residence information card', () {
    test('office heading plus household fields', () {
      final evidence = _single([
        'جمهورية العراق',
        'وزارة الداخلية',
        'مديرية الأحوال المدنية والجوازات والإقامة',
        'مديرية مكتب المعلومات المركزي',
        'مكتب معلومات',
        'اسم رب الأسرة',
        'عنوان السكن',
        'رقم الاستمارة',
      ]);
      expect(evidence.kind, DocumentKind.residenceCard);
      expect(evidence.matchedGroups, ['title', 'household']);
    });

    test('office heading plus the form number evidences', () {
      expect(
        _kinds([
          'مديرية مكتب المعلومات المركزي',
          'رقم الاستمارة',
        ]),
        [DocumentKind.residenceCard],
      );
    });

    test('office heading split across adjacent lines evidences', () {
      expect(
        _kinds([
          'مكتب',
          'المعلومات المركزي',
          'اسم رب الأسرة',
        ]),
        [DocumentKind.residenceCard],
      );
    });

    test('the supporting form never evidences on its own', () {
      // The استمارة carries the office stamp and form fields only; it lacks
      // every household field, so it must stay manual.
      expect(
        _kinds([
          'الرمز',
          'التسلسل',
          'مديرية مكتب المعلومات المركزي',
          'تاريخ تنظيم الاستمارة',
          'اسم ورتبة منظم الاستمارة',
          'التوقيع',
        ]),
        isEmpty,
      );
    });

    test('office heading plus a signature alone never evidences', () {
      expect(_kinds(['مكتب معلومات', 'التوقيع']), isEmpty);
    });

    test('form fields without the office heading never evidence', () {
      expect(
        _kinds([
          'تاريخ تنظيم الاستمارة',
          'اسم ورتبة منظم الاستمارة',
          'التوقيع',
        ]),
        isEmpty,
      );
    });
  });

  group('passport', () {
    test('full data page: title, fields and MRZ', () {
      final evidence = _single([
        'REPUBLIC OF IRAQ',
        'Passport',
        'جواز سفر',
        'Type',
        'P',
        'Country',
        'IRQ',
        'Passport No',
        'Full Name',
        'Surname',
        'Sex',
        'Nationality',
        'Date of Birth',
        'Mother Name',
        'Date of Expiry',
        'Date of Issue',
        'Issuing Authority',
        'P<IRQTEST<<NAME<<<<<<<<<<<<',
      ]);
      expect(evidence.kind, DocumentKind.passport);
      expect(evidence.matchedGroups, [
        'title',
        'mrz',
        'documentNumber',
        'personalDataLabels',
      ]);
    });

    test('MRZ plus fields evidences without the printed title', () {
      final evidence = _single([
        'Full Name',
        'Date of Birth',
        'P<IRQTEST<<NAME<<<<<<<<<<<<',
      ]);
      expect(evidence.kind, DocumentKind.passport);
      expect(evidence.matchedGroups, ['mrz', 'personalDataLabels']);
    });

    test('title plus a passport field evidences', () {
      expect(
        _kinds(['Passport', 'Date of Birth']),
        [DocumentKind.passport],
      );
    });

    test('mixed Arabic and English labels evidence', () {
      expect(
        _kinds(['جواز سفر', 'Passport No', 'Date of Birth']),
        [DocumentKind.passport],
      );
    });

    test('visual-order (reversed) passport labels evidence', () {
      expect(
        _kinds([
          reversedRunes('جواز سفر'),
          reversedRunes('رقم الجواز'),
        ]),
        [DocumentKind.passport],
      );
    });

    test('passport MRZ never evidences as a national ID', () {
      expect(
        _kinds(['P<IRQTEST<<NAME<<<<<<<<<<<<', 'Full Name']),
        [DocumentKind.passport],
      );
    });

    test('national-ID MRZ never evidences as a passport', () {
      expect(
        _kinds([
          'IDIRQ A00000000 0000000000000<<<',
          'تاريخ الولادة',
        ]),
        [DocumentKind.unifiedNationalId],
      );
    });

    test('a stray IRQ inside a line is not an MRZ', () {
      expect(_kinds(['Full Name', 'A123IRQ456']), isEmpty);
    });

    test('MRZ with an OCR-confused prefix letter still evidences', () {
      final evidence = _single([
        'P<IROTEST<<NAME<<<<<<<<<<<<',
        'Full Name',
      ]);
      expect(evidence.kind, DocumentKind.passport);
      expect(evidence.matchedGroups, contains('mrz'));
    });
  });

  group('generic and negative cases', () {
    test('shared government words alone never evidence', () {
      expect(
        _kinds(['جمهورية العراق', 'وزارة الداخلية']),
        isEmpty,
      );
      expect(_kinds(['Republic of Iraq']), isEmpty);
      expect(_kinds(['وزارة الداخلية']), isEmpty);
    });

    test('numbers only never evidence', () {
      expect(_kinds(['12345', '67890']), isEmpty);
      expect(_kinds(['١٢٣٤٥٦']), isEmpty);
    });

    test('unrelated text never evidences', () {
      expect(_kinds(['نص غير مرتبط تماما']), isEmpty);
    });

    test('title plus unrelated text never evidences', () {
      expect(
        _kinds(['البطاقة الوطنية', 'نص غير مرتبط تماما']),
        isEmpty,
      );
    });
  });

  group('layout and repetition', () {
    test('title and support on the same line evidence', () {
      expect(
        _kinds(['البطاقة الوطنية الرقم الوطني']),
        [DocumentKind.unifiedNationalId],
      );
    });

    test('title split across adjacent lines evidences', () {
      expect(
        _kinds([
          'البطاقة',
          'الوطنية الموحدة',
          'الرقم الوطني',
        ]),
        [DocumentKind.unifiedNationalId],
      );
    });

    test('title fragments on distant lines never evidence', () {
      expect(
        _kinds([
          'البطاقة',
          'نص غير مرتبط',
          'الوطنية الموحدة',
          'الرقم الوطني',
        ]),
        isEmpty,
      );
    });

    test('repeated phrases never inflate the group count', () {
      final evidence = _single([
        'البطاقة الوطنية',
        'البطاقة الوطنية',
        'الرقم الوطني',
        'الرقم الوطني',
      ]);
      expect(evidence.matchedAnchorGroups, 2);
      expect(evidence.matchedGroups, ['title', 'identifier']);
    });

    test('evidence distributed across many lines evidences', () {
      expect(
        _kinds([
          'البطاقة الوطنية',
          'سطر غير مرتبط',
          'سطر آخر غير مرتبط',
          'الرقم الوطني',
        ]),
        [DocumentKind.unifiedNationalId],
      );
    });
  });

  group('limited OCR-error tolerance', () {
    test('a one-character spelling error still evidences, discounted', () {
      final evidence = _single([
        'البطاقة الوطنية',
        'الرقم الوطن',
      ]);
      expect(evidence.kind, DocumentKind.unifiedNationalId);
      // Exact title confidence 0.9, fuzzy support discounted to 0.9 * 0.85.
      expect(evidence.score, closeTo(.765, 1e-9));
      expect(evidence.matchedAnchorGroups, 2);
    });

    test('a different word is not a spelling error', () {
      // «الرقم العائلي» is a real field of its own, not a misread of
      // «الرقم الوطني»; with no title it must not evidence either.
      expect(_kinds(['الرقم العائلي']), isEmpty);
    });
  });

  group('conflicts and confidence floor', () {
    test('two full signatures stay competing evidence', () {
      final evidence = ocrKeywordEvidence(
        _ocr([
          'البطاقة الوطنية',
          'الرقم الوطني',
          'مكتب معلومات',
          'اسم رب الأسرة',
        ]),
      );
      expect(evidence.map((entry) => entry.kind), [
        DocumentKind.unifiedNationalId,
        DocumentKind.residenceCard,
      ]);
    });

    test('conflicting signatures classify as uncertain (manual)', () {
      final outcome = classifyDocument(
        ClassificationInput(
          ocrKeywords: ocrKeywordEvidence(
            _ocr([
              'البطاقة الوطنية',
              'الرقم الوطني',
              'مكتب معلومات',
              'اسم رب الأسرة',
            ]),
          ),
          ocrConfidence: .9,
        ),
      );
      expect(outcome.status, RecognitionStatus.uncertain);
      expect(outcome.candidates, hasLength(2));
    });

    test('weak OCR confidence stays below the classification floor', () {
      final evidence = ocrKeywordEvidence(
        _ocr(
          ['البطاقة الوطنية', 'الرقم الوطني'],
          confidence: .55,
        ),
      );
      expect(evidence, hasLength(1));
      expect(evidence.single.score, closeTo(.55, 1e-9));
      final outcome = classifyDocument(
        ClassificationInput(ocrKeywords: evidence, ocrConfidence: .55),
      );
      expect(outcome.kind, DocumentKind.unknown);
      expect(outcome.status, RecognitionStatus.unknown);
    });

    test('strong residence evidence classifies as recognized', () {
      final outcome = classifyDocument(
        ClassificationInput(
          ocrKeywords: ocrKeywordEvidence(
            _ocr([
              'مديرية مكتب المعلومات المركزي',
              'اسم رب الأسرة',
              'عنوان السكن',
            ]),
          ),
          ocrConfidence: .9,
        ),
      );
      expect(outcome.kind, DocumentKind.residenceCard);
      expect(outcome.status, RecognitionStatus.recognized);
    });

    test('the supporting form classifies as unknown (manual)', () {
      final outcome = classifyDocument(
        ClassificationInput(
          ocrKeywords: ocrKeywordEvidence(
            _ocr([
              'الرمز',
              'التسلسل',
              'مديرية مكتب المعلومات المركزي',
              'تاريخ تنظيم الاستمارة',
              'اسم ورتبة منظم الاستمارة',
              'التوقيع',
            ]),
          ),
          ocrConfidence: .9,
        ),
      );
      expect(outcome.kind, DocumentKind.unknown);
      expect(outcome.status, RecognitionStatus.unknown);
      expect(outcome.evidence, isEmpty);
    });
  });
}
