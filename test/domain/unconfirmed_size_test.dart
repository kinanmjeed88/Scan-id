import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/manual_boundary.dart';

final quad = <Point2>[
  Point2(.1, .1),
  Point2(.9, .1),
  Point2(.9, .9),
  Point2(.1, .9),
];

void main() {
  test('a kind without a catalog size can be confirmed without typing mm', () {
    final result = validateManualBoundary(
      corners: quad,
      sourceWidth: 400,
      sourceHeight: 250,
      documentKind: DocumentKind.civilStatusId,
      allowUnconfirmedSize: true,
    );
    expect(result.isValid, isTrue);
    expect(result.confirmedKind, DocumentKind.civilStatusId);
    expect(result.confirmedSizeMm, isNull);
    expect(result.recipe, isNotNull);
  });

  test('the same call still refuses placement when a size is required', () {
    final result = validateManualBoundary(
      corners: quad,
      sourceWidth: 400,
      sourceHeight: 250,
      documentKind: DocumentKind.civilStatusId,
      requireConfirmedSize: true,
    );
    expect(result.isValid, isFalse);
    expect(result.rejection, ManualBoundaryRejection.unconfirmedDocumentSize);
  });

  test(
    'an estimated default resolved by the caller is a real confirmed size',
    () {
      final result = validateManualBoundary(
        corners: quad,
        sourceWidth: 400,
        sourceHeight: 250,
        documentKind: DocumentKind.residenceCard,
        customSizeMm: const PhysicalSizeMm(92.4, 62.8),
        requireConfirmedSize: true,
      );
      expect(result.isValid, isTrue);
      expect(result.confirmedSizeMm!.width, closeTo(92.4, 1e-9));
      expect(result.confirmedSizeMm!.height, closeTo(62.8, 1e-9));
    },
  );
}
