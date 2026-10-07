import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';

void main() {
  test('version-scoped published size references follow image orientation', () {
    final idLandscape = DocumentKind.unifiedNationalId.publishedReferenceSize(
      landscape: true,
    );
    final idPortrait = DocumentKind.unifiedNationalId.publishedReferenceSize(
      landscape: false,
    );
    final passport = DocumentKind.passport.publishedReferenceSize(
      landscape: false,
    );

    expect([idLandscape!.width, idLandscape.height], [86, 54]);
    expect([idPortrait!.width, idPortrait.height], [54, 86]);
    expect([passport!.width, passport.height], [88, 125]);
    expect(
      DocumentKind.residenceCard.publishedReferenceSize(landscape: true),
      isNull,
    );
    expect(DocumentKind.unifiedNationalId.measurementHint, contains('لا يثبت'));
    expect(DocumentKind.passport.measurementHint, contains('2009'));
  });

  test('explicit Arabic and English filenames classify with high confidence', () {
    expect(
      suggestDocumentType(
        name: 'البطاقة الوطنية الموحدة.png',
        width: 600,
        height: 380,
      ),
      isA<DocumentTypeSuggestion>()
          .having((value) => value.kind, 'kind', DocumentKind.unifiedNationalId)
          .having((value) => value.confidence, 'confidence', .98),
    );
    expect(
      suggestDocumentType(
        name: 'بطاقة السكن.jpg',
        width: 900,
        height: 600,
      ).kind,
      DocumentKind.residenceCard,
    );
    expect(
      suggestDocumentType(
        name: 'passport-front.png',
        width: 300,
        height: 420,
      ).kind,
      DocumentKind.passport,
    );
  });

  test('ratio recognition stays a low-confidence suggestion and variable sizes remain unverified', () {
    final id = suggestDocumentType(name: 'IMG_1.png', width: 860, height: 540);
    final unknown = suggestDocumentType(name: 'IMG_2.png', width: 400, height: 300);
    final estimate = provisionalSize(width: 400, height: 300);

    expect(id.kind, DocumentKind.unifiedNationalId);
    expect(id.confidence, lessThan(.85));
    expect(unknown.kind, DocumentKind.unknown);
    expect(estimate.width / estimate.height, closeTo(4 / 3, 1e-9));
    expect(DocumentKind.residenceCard.hasPublishedSizeReference, isFalse);
  });
}
