import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';

void main() {
  const catalog = DocumentSizeCatalog();

  test('every category has a provenance record', () {
    expect(
      documentSizeRecords.keys.toSet(),
      DocumentKind.values.toSet(),
      reason: 'a category without a record would have an unexplained size',
    );
    for (final kind in DocumentKind.values) {
      expect(documentSizeRecordFor(kind).kind, kind);
    }
  });

  test('a documented size names its reference and its check date', () {
    for (final kind in DocumentKind.values) {
      final record = documentSizeRecordFor(kind);
      if (record.provenance != SizeProvenance.documented) continue;
      expect(record.reference, isNotEmpty, reason: kind.name);
      expect(record.standard, isNotEmpty, reason: kind.name);
      expect(
        DateTime.tryParse(record.verifiedOn),
        isNotNull,
        reason: '${kind.name}: verification date must be an ISO-8601 date',
      );
      expect(catalog.natural(kind), isNotNull, reason: kind.name);
      expect(record.mayBeConfirmedAutomatically, isTrue, reason: kind.name);
    }
  });

  test('an estimated size is offered but never confirmable automatically', () {
    for (final kind in DocumentKind.values) {
      final record = documentSizeRecordFor(kind);
      if (record.provenance != SizeProvenance.estimated) continue;
      expect(catalog.natural(kind), isNotNull, reason: kind.name);
      expect(record.reference, isEmpty, reason: '${kind.name}: no citation');
      expect(record.verifiedOn, isEmpty, reason: kind.name);
      expect(record.note, isNotEmpty, reason: kind.name);
      expect(record.mayBeConfirmedAutomatically, isFalse, reason: kind.name);
    }
  });

  test('a missing size has no number and no automatic confirmation', () {
    for (final kind in DocumentKind.values) {
      final record = documentSizeRecordFor(kind);
      if (record.provenance != SizeProvenance.missing) continue;
      expect(catalog.natural(kind), isNull, reason: kind.name);
      expect(record.mayBeConfirmedAutomatically, isFalse, reason: kind.name);
      expect(record.note, isNotEmpty, reason: kind.name);
    }
  });

  test('preset status is derived from provenance, not asserted separately', () {
    expect(
      presetStatusFor(DocumentKind.unifiedNationalId),
      PresetStatus.standard,
    );
    expect(presetStatusFor(DocumentKind.passport), PresetStatus.standard);
    expect(presetStatusFor(DocumentKind.residenceCard), PresetStatus.estimated);
    expect(presetStatusFor(DocumentKind.rationCard), PresetStatus.estimated);
    expect(presetStatusFor(DocumentKind.civilStatusId), PresetStatus.unknown);
    expect(presetStatusFor(DocumentKind.unknown), PresetStatus.unknown);
    expect(presetStatusFor(DocumentKind.other), PresetStatus.unknown);
  });

  test('the civil-status identity still has no invented size', () {
    final record = documentSizeRecordFor(DocumentKind.civilStatusId);

    expect(catalog.natural(DocumentKind.civilStatusId), isNull);
    expect(record.provenance, SizeProvenance.missing);
    expect(record.reference, isEmpty);
    expect(record.verifiedOn, isEmpty);
    expect(record.note, isNotEmpty);
  });

  test('the two target card sizes that are estimates say so', () {
    for (final kind in [
      DocumentKind.residenceCard,
      DocumentKind.rationCard,
    ]) {
      expect(
        documentSizeRecordFor(kind).provenance,
        SizeProvenance.estimated,
        reason:
            '${kind.name} has no published source; calling it documented '
            'would be a fabricated citation',
      );
    }
  });
}
