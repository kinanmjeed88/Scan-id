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

  group('kind classification requires independent evidence', () {
    test(
      'filename, path, extension and token cannot set the document kind',
      () {
        for (final name in const [
          'البطاقة الوطنية الموحدة.jpg',
          'Passport-scan.jpg',
          'بطاقة السكن.png',
          'ration_card.png',
          '/private/جواز السفر/photo.png',
          'IMG_2041.png',
        ]) {
          final suggestion = suggestDocumentType(
            name: name,
            width: 856,
            height: 540,
          );
          expect(suggestion.kind, DocumentKind.unknown, reason: name);
          expect(suggestion.confidence, 0, reason: name);
        }
      },
    );

    test('aspect, full-frame flag and catalog edits cannot infer a kind', () {
      const editedCatalog = DocumentSizeCatalog(
        residenceCard: PhysicalSizeMm(100, 50),
      );
      for (final size in const [
        (856, 540),
        (540, 856),
        (924, 628),
        (1250, 880),
        (104, 574),
        (1000, 1000),
        (2000, 600),
        (4000, 3000),
      ]) {
        for (final fullFrame in [false, true]) {
          final suggestion = suggestDocumentType(
            name: 'neutral-name.png',
            width: size.$1,
            height: size.$2,
            catalog: editedCatalog,
            fullFrame: fullFrame,
          );
          expect(suggestion.kind, DocumentKind.unknown);
          expect(suggestion.confidence, 0);
        }
      }
    });

    test('the catalog shape tolerance remains unchanged', () {
      expect(shapeTolerance, .04);
    });

    test('provisional size keeps proportions for unknown documents', () {
      final estimate = provisionalSize(width: 400, height: 300);
      expect(estimate.width, 80);
      expect(estimate.height, 60);
    });
  });
}
