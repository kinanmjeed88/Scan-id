import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/validation.dart';

void main() {
  group('catalog sizes', () {
    const catalog = DocumentSizeCatalog();

    test('official and default sizes in natural orientation', () {
      PhysicalSizeMm size(DocumentKind kind) => catalog.natural(kind)!;
      expect(
        [
          size(DocumentKind.unifiedNationalId).width,
          size(DocumentKind.unifiedNationalId).height,
        ],
        [85.6, 53.98],
      );
      expect(
        [
          size(DocumentKind.residenceCard).width,
          size(DocumentKind.residenceCard).height,
        ],
        [92.4, 62.8],
      );
      expect(
        [size(DocumentKind.passport).width, size(DocumentKind.passport).height],
        [125, 88],
      );
      expect(
        [
          size(DocumentKind.rationCard).width,
          size(DocumentKind.rationCard).height,
        ],
        [52, 287],
      );
      expect(catalog.natural(DocumentKind.unknown), isNull);
      expect(catalog.natural(DocumentKind.other), isNull);
    });

    test('sizes turn to the orientation of the cropped image', () {
      final portraitId = catalog.sizeFor(
        DocumentKind.unifiedNationalId,
        landscape: false,
      )!;
      expect([portraitId.width, portraitId.height], [53.98, 85.6]);
      final landscapeRation = catalog.sizeFor(
        DocumentKind.rationCard,
        landscape: true,
      )!;
      expect([landscapeRation.width, landscapeRation.height], [287, 52]);
    });

    test('only standardised sizes are described as official', () {
      expect(DocumentKind.unifiedNationalId.hasOfficialSize, isTrue);
      expect(DocumentKind.passport.hasOfficialSize, isTrue);
      expect(DocumentKind.residenceCard.hasOfficialSize, isFalse);
      expect(DocumentKind.rationCard.hasOfficialSize, isFalse);
      expect(DocumentKind.residenceCard.hasEditableSize, isTrue);
      expect(DocumentKind.rationCard.hasEditableSize, isTrue);
      expect(DocumentKind.passport.hasEditableSize, isFalse);
      expect(
        DocumentKind.residenceCard.sizeNote(catalog),
        allOf(contains('افتراضي'), isNot(contains('رسمي'))),
      );
      expect(
        DocumentKind.rationCard.sizeNote(catalog),
        allOf(contains('افتراضي'), isNot(contains('رسمي'))),
      );
      expect(
        DocumentKind.unifiedNationalId.sizeNote(catalog),
        contains('رسمي'),
      );
    });

    test('editable sizes round-trip and missing entries use defaults', () {
      final edited = catalog.copyWith(
        residenceCard: const PhysicalSizeMm(90, 60),
        rationCard: const PhysicalSizeMm(55, 280),
      );
      final copy = DocumentSizeCatalog.fromJson(edited.toJson());
      expect(copy.residenceCard.sameAs(const PhysicalSizeMm(90, 60)), isTrue);
      expect(copy.rationCard.sameAs(const PhysicalSizeMm(55, 280)), isTrue);
      final defaults = DocumentSizeCatalog.fromJson(null);
      expect(
        defaults.residenceCard.sameAs(DocumentSizeCatalog.defaultResidenceCard),
        isTrue,
      );
      expect(
        () => catalog.copyWith(residenceCard: const PhysicalSizeMm(5, 60)),
        throwsA(isA<ValidationException>()),
      );
    });

    test('sheet order: unified card, residence, passport, ration', () {
      final sorted = [...DocumentKind.values]
        ..sort((a, b) => a.order.compareTo(b.order));
      expect(sorted.take(4), [
        DocumentKind.unifiedNationalId,
        DocumentKind.residenceCard,
        DocumentKind.passport,
        DocumentKind.rationCard,
      ]);
    });
  });

  group('recognition', () {
    test('explicit Arabic and English filenames win', () {
      DocumentKind kind(String name) =>
          suggestDocumentType(name: name, width: 400, height: 300).kind;
      expect(
        kind('البطاقة الوطنية الموحدة.jpg'),
        DocumentKind.unifiedNationalId,
      );
      expect(kind('بطاقة السكن.png'), DocumentKind.residenceCard);
      expect(kind('Passport-scan.jpg'), DocumentKind.passport);
      expect(kind('البطاقة التموينية.jpg'), DocumentKind.rationCard);
      expect(kind('ration_card.png'), DocumentKind.rationCard);
      expect(
        suggestDocumentType(name: 'جواز.png', width: 1, height: 1).confidence,
        greaterThan(.9),
      );
    });

    test('boundary shape recognises each catalog category', () {
      DocumentKind kind(int w, int h) =>
          suggestDocumentType(name: 'scan.jpg', width: w, height: h).kind;
      expect(kind(856, 540), DocumentKind.unifiedNationalId);
      expect(kind(540, 856), DocumentKind.unifiedNationalId);
      expect(kind(924, 628), DocumentKind.residenceCard);
      expect(kind(1250, 880), DocumentKind.passport);
      expect(kind(104, 574), DocumentKind.rationCard);
      expect(kind(1000, 1000), DocumentKind.unknown);
      expect(kind(2000, 600), DocumentKind.unknown);
    });

    test('small perspective errors are tolerated', () {
      final kind = suggestDocumentType(
        name: 'x.png',
        width: 860,
        height: 552, // 1.558, 1.8 % below ID-1
      ).kind;
      expect(kind, DocumentKind.unifiedNationalId);
    });

    test('an uncropped camera frame is not guessed', () {
      for (final size in const [(4000, 3000), (3000, 2000), (1920, 1080)]) {
        expect(
          suggestDocumentType(
            name: 'IMG_0001.jpg',
            width: size.$1,
            height: size.$2,
            fullFrame: true,
          ).kind,
          DocumentKind.unknown,
        );
      }
      // An already-cut scan keeps its document shape.
      expect(
        suggestDocumentType(
          name: 'scan.png',
          width: 856,
          height: 540,
          fullFrame: true,
        ).kind,
        DocumentKind.unifiedNationalId,
      );
    });

    test('edited catalog sizes drive shape recognition', () {
      const catalog = DocumentSizeCatalog(
        residenceCard: PhysicalSizeMm(100, 50),
      );
      expect(
        suggestDocumentType(
          name: 'x.png',
          width: 1000,
          height: 500,
          catalog: catalog,
        ).kind,
        DocumentKind.residenceCard,
      );
    });

    test('provisional size keeps proportions for unknown documents', () {
      final estimate = provisionalSize(width: 400, height: 300);
      expect(estimate.width, 80);
      expect(estimate.height, 60);
    });
  });
}
