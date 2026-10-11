import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_overrides.dart';
import 'package:scan_id/domain/recognition_routing.dart';
import 'package:scan_id/domain/page_layout.dart';
import 'package:scan_id/domain/validation.dart';

import '../fixtures.dart';

ImageAsset _asset(String id) {
  final prefix = 'projects/project1/assets/$id';
  return ImageAsset(
    id: id,
    name: '$id.png',
    originalPath: '$prefix/original.png',
    workingPath: '$prefix/working.png',
    thumbnailPath: '$prefix/thumb.jpg',
    width: 856,
    height: 540,
  );
}

DocumentRecord _record(String id, String assetId, {double finalValue = .8}) =>
    DocumentRecord(
      id: 'rec-$id',
      sourceImageId: assetId,
      sides: [
        DocumentSide(
          id: 'side-$id',
          side: SideKind.unknown,
          processedAsset: ProcessedAssetRef(
            workingPath: 'projects/project1/assets/$assetId/working.png',
            thumbnailPath: 'projects/project1/assets/$assetId/thumb.jpg',
            width: 856,
            height: 540,
          ),
        ),
      ],
      recognition: RecognitionResult(
        documentKind: DocumentKind.unifiedNationalId,
        status: RecognitionStatus.recognized,
        confidences: ConfidenceSet(
          finalConfidence: Confidence(value: finalValue),
        ),
        preset: const PresetSelection.resolved('builtin-unifiedNationalId'),
      ),
      pairing: PairingState.single,
      provenance: Provenance(
        sourceImageId: assetId,
        detectionIds: ['$assetId-d0'],
        processedAssetVersion: 'smart-1',
        pipelineVersion: 'smart-1',
      ),
    );

DocumentItem _item(String id, String assetId) => DocumentItem(
  id: id,
  assetId: assetId,
  x: 10,
  y: 10,
  width: 85.6,
  height: 53.98,
  pageIndex: null,
  documentKind: DocumentKind.unifiedNationalId,
  sizeConfirmed: true,
  documentId: 'rec-$id',
  sideId: 'side-$id',
);

Project _project() => Project(
  id: 'project1',
  name: 'مستمسكات العائلة',
  createdAt: DateTime.utc(2026, 10, 6),
  updatedAt: DateTime.utc(2026, 10, 6),
  assets: [_asset('a'), _asset('b')],
  items: [_item('item-a', 'a'), _item('item-b', 'b')],
  documents: [_record('item-a', 'a'), _record('item-b', 'b')],
);

void main() {
  group('effective values', () {
    test('kind: latest override wins over recognition', () {
      var record = _record('item-a', 'a');
      expect(effectiveKind(record), DocumentKind.unifiedNationalId);
      record = record.copyWith(
        overrides: [
          UserOverride(documentKind: DocumentKind.passport),
          UserOverride(documentKind: DocumentKind.rationCard),
        ],
      );
      expect(effectiveKind(record), DocumentKind.rationCard);
    });

    test('side: override wins over the stored side', () {
      final record = _record('item-a', 'a');
      expect(effectiveSide(record, record.sides.single), SideKind.unknown);
      final overridden = record.copyWith(
        overrides: [UserOverride(side: SideKind.back)],
      );
      expect(effectiveSide(overridden, overridden.sides.single), SideKind.back);
    });
  });

  group('setKindWithOverride', () {
    test('changes the item and records the divergence explicitly', () {
      final next = setKindWithOverride(
        _project(),
        'item-a',
        DocumentKind.passport,
      );
      final item = next.items.firstWhere((i) => i.id == 'item-a');
      expect(item.documentKind, DocumentKind.passport);
      expect([item.width, item.height], [125, 88]);
      final record = next.documents.firstWhere((d) => d.id == 'rec-item-a');
      expect(record.overrides, hasLength(1));
      expect(record.overrides.single.documentKind, DocumentKind.passport);
      // The stored recognition evidence is untouched.
      expect(record.recognition!.documentKind, DocumentKind.unifiedNationalId);
    });

    test('re-selecting the effective kind appends nothing', () {
      final next = setKindWithOverride(
        _project(),
        'item-a',
        DocumentKind.unifiedNationalId,
      );
      final record = next.documents.firstWhere((d) => d.id == 'rec-item-a');
      expect(record.overrides, isEmpty);
    });

    test('an item without a record changes layout only', () {
      final base = projectFixture(
        assets: [_asset('a')],
        items: [
          DocumentItem(
            id: 'item-x',
            assetId: 'a',
            x: 10,
            y: 10,
            width: 80,
            height: 50,
            pageIndex: null,
          ),
        ],
      );
      final next = setKindWithOverride(base, 'item-x', DocumentKind.passport);
      expect(next.items.single.documentKind, DocumentKind.passport);
      expect(next.documents, isEmpty);
    });
  });

  group('review confirmation', () {
    test('confirm removes the record from the queue, idempotently', () {
      final before = _project();
      expect(recordsNeedingReview(before), hasLength(2));
      final once = confirmRecognition(before, 'rec-item-a');
      expect(recordsNeedingReview(once), hasLength(1));
      final twice = confirmRecognition(once, 'rec-item-a');
      expect(
        twice.documents.firstWhere((d) => d.id == 'rec-item-a').overrides,
        hasLength(1),
        reason: 'confirming again appends nothing',
      );
    });

    test('missing document throws a user-readable validation error', () {
      expect(
        () => confirmRecognition(_project(), 'rec-nope'),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('dismissal', () {
    test(
      'is a tombstone: removes layout, retains evidence, and is idempotent',
      () {
        final before = _project();
        final target = before.documents.firstWhere((d) => d.id == 'rec-item-a');

        final dismissed = dismissRecognition(before, target.id);

        final record = dismissed.documents.firstWhere((d) => d.id == target.id);
        expect(record.overrides.single.dismissed, isTrue);
        expect(
          record.overrides.single.fields,
          contains(dismissalTombstoneField),
        );
        expect(isDismissalTombstone(record), isTrue);
        expect(record.recognition, same(target.recognition));
        expect(record.provenance.toJson(), target.provenance.toJson());
        expect(dismissed.documents, hasLength(2));
        expect(dismissed.items.map((item) => item.id), ['item-b']);
        expect(
          dismissed.assets.map((asset) => asset.toJson()).toList(),
          before.assets.map((asset) => asset.toJson()).toList(),
        );
        expect(recordsNeedingReview(dismissed), hasLength(1));
        expect(
          Project.fromJson(dismissed.toJson()).toJson(),
          dismissed.toJson(),
        );
        expect(dismissRecognition(dismissed, target.id), same(dismissed));
        expect(dismissRecognition(before, 'missing'), same(before));
      },
    );

    test('legacy schema-v5 dismissals retain linked and paired state', () {
      final paired = acceptPair(_project(), 'rec-item-a', 'rec-item-b');
      final legacy = paired.copyWith(
        documents: [
          for (final record in paired.documents)
            if (record.id == 'rec-item-a')
              record.copyWith(
                overrides: [
                  ...record.overrides,
                  UserOverride(dismissed: true, fields: const ['dismissed']),
                ],
              )
            else
              record,
        ],
      );

      final restored = Project.fromJson(legacy.toJson());
      final target = restored.documents.firstWhere(
        (record) => record.id == 'rec-item-a',
      );

      expect(restored.items, hasLength(2));
      expect(isDismissalTombstone(target), isFalse);
      expect(target.pairing, PairingState.paired);
      expect(target.pairedDocumentId, 'rec-item-b');
      expect(
        Project.fromJson(restored.toJson()).toJson(),
        restored.toJson(),
      );
      expect(
        recordsNeedingReview(restored).map((record) => record.id),
        isNot(contains('rec-item-a')),
      );

      final deleted = PageLayout.remove(restored, {'item-a'});
      expect(deleted.documents.map((record) => record.id), ['rec-item-b']);
      expect(deleted.documents.single.pairing, PairingState.single);
      expect(deleted.documents.single.pairedDocumentId, isNull);
    });

    test(
      'dismissing one side dissolves an unresolved pair and preserves the partner',
      () {
        final before = _project();
        final proposed = before.copyWith(
          items: [
            for (final item in before.items)
              item.id == 'item-b' ? item.copyWith(locked: true) : item,
          ],
          documents: [
            for (final record in before.documents)
              record.copyWith(
                pairing: PairingState.ambiguous,
                pairedDocumentId: record.id == 'rec-item-a'
                    ? 'rec-item-b'
                    : 'rec-item-a',
                pairingConfidence: .8,
              ),
          ],
        );

        final dismissed = dismissRecognition(proposed, 'rec-item-a');

        final target = dismissed.documents.firstWhere(
          (record) => record.id == 'rec-item-a',
        );
        final partner = dismissed.documents.firstWhere(
          (record) => record.id == 'rec-item-b',
        );
        expect(target.overrides.last.dismissed, isTrue);
        expect(target.pairing, PairingState.single);
        expect(target.pairedDocumentId, isNull);
        expect(partner.pairing, PairingState.single);
        expect(partner.pairedDocumentId, isNull);
        expect(partner.overrides.last.pairing, PairingState.single);
        expect(
          recordsNeedingReview(dismissed).map((record) => record.id),
          ['rec-item-b'],
          reason: 'rejecting a pair must not hide the partner’s other reasons',
        );
        expect(dismissed.layoutGroups, isEmpty);
        expect(dismissed.items.single.groupId, isNull);
        expect(dismissed.items.single.documentId, 'rec-item-b');
        expect(dismissed.items.single.locked, isTrue);
        expect(
          dismissed.assets.map((asset) => asset.toJson()).toList(),
          proposed.assets.map((asset) => asset.toJson()).toList(),
        );
      },
    );

    test('a stale dismissal cannot replace an already-confirmed decision', () {
      final confirmed = confirmRecognition(_project(), 'rec-item-a');

      final stale = dismissRecognition(confirmed, 'rec-item-a');

      expect(stale, same(confirmed));
      expect(stale.items, hasLength(2));
      expect(
        stale.documents
            .firstWhere((d) => d.id == 'rec-item-a')
            .overrides
            .single
            .dismissed,
        isNull,
      );
    });

    test('a stale dismissal cannot break a confirmed pair or its group', () {
      final paired = acceptPair(_project(), 'rec-item-a', 'rec-item-b');
      final confirmed = confirmRecognition(
        confirmRecognition(paired, 'rec-item-a'),
        'rec-item-b',
      );

      final stale = dismissRecognition(confirmed, 'rec-item-a');

      expect(stale, same(confirmed));
      expect(stale.items, hasLength(2));
      expect(stale.layoutGroups, hasLength(1));
      expect(
        stale.documents.every(
          (record) => record.pairing == PairingState.paired,
        ),
        isTrue,
      );
    });

    test('locked layout items cannot be dismissed', () {
      final before = _project().copyWith(
        items: [
          for (final item in _project().items)
            item.id == 'item-a' ? item.copyWith(locked: true) : item,
        ],
      );

      expect(
        () => dismissRecognition(before, 'rec-item-a'),
        throwsA(isA<ValidationException>()),
      );
      expect(before.items, hasLength(2));
      expect(before.documents.first.overrides, isEmpty);
    });
  });

  group('ordinary linked-item deletion', () {
    test(
      'deleting the last item cascades its record and unpairs the survivor',
      () {
        final paired = acceptPair(_project(), 'rec-item-a', 'rec-item-b');

        final deleted = PageLayout.remove(paired, {'item-a'});

        expect(deleted.items.map((item) => item.id), ['item-b']);
        expect(deleted.documents.map((record) => record.id), ['rec-item-b']);
        expect(deleted.documents.single.pairing, PairingState.single);
        expect(deleted.documents.single.pairedDocumentId, isNull);
        expect(
          deleted.documents.single.overrides.last.pairing,
          PairingState.single,
        );
        expect(deleted.layoutGroups, isEmpty);
        expect(deleted.items.single.groupId, isNull);
        expect(
          deleted.assets.map((asset) => asset.toJson()).toList(),
          paired.assets.map((asset) => asset.toJson()).toList(),
        );
      },
    );

    test('deleting one duplicate keeps its record and remaining edit link', () {
      final before = _project();
      final copy = PageLayout.copies(
        before.items.first,
        1,
        () => 'item-a-copy',
      ).single;
      final withCopy = before.copyWith(items: [...before.items, copy]);

      final deleted = PageLayout.remove(withCopy, {'item-a'});
      final edited = setKindWithOverride(
        deleted,
        'item-a-copy',
        DocumentKind.passport,
      );

      expect(edited.documents.map((record) => record.id), [
        'rec-item-a',
        'rec-item-b',
      ]);
      expect(edited.items.map((item) => item.id), ['item-b', 'item-a-copy']);
      expect(edited.items.last.documentId, 'rec-item-a');
      expect(edited.items.last.documentKind, DocumentKind.passport);
      expect(
        edited.documents.first.recognition!.documentKind,
        DocumentKind.unifiedNationalId,
      );
    });
  });

  group('pairing overrides', () {
    test('acceptPair links reciprocally and groups the items', () {
      final next = acceptPair(_project(), 'rec-item-a', 'rec-item-b');
      final a = next.documents.firstWhere((d) => d.id == 'rec-item-a');
      final b = next.documents.firstWhere((d) => d.id == 'rec-item-b');
      expect(a.pairing, PairingState.paired);
      expect(b.pairing, PairingState.paired);
      expect(a.pairedDocumentId, 'rec-item-b');
      expect(b.pairedDocumentId, 'rec-item-a');
      final group = next.layoutGroups.single;
      expect(group.id, 'pair-rec-item-a');
      expect(group.itemIds.toSet(), {'item-a', 'item-b'});
      for (final item in next.items) {
        expect(item.groupId, group.id);
      }
    });

    test('rejectPair returns both to single and dissolves the group', () {
      final paired = acceptPair(_project(), 'rec-item-a', 'rec-item-b');
      final next = rejectPair(paired, 'rec-item-b');
      for (final id in ['rec-item-a', 'rec-item-b']) {
        final record = next.documents.firstWhere((d) => d.id == id);
        expect(record.pairing, PairingState.single);
        expect(record.pairedDocumentId, isNull);
      }
      expect(next.layoutGroups, isEmpty);
      for (final item in next.items) {
        expect(item.groupId, isNull);
      }
    });

    test('self-pairing is rejected', () {
      expect(
        () => acceptPair(_project(), 'rec-item-a', 'rec-item-a'),
        throwsA(isA<ValidationException>()),
      );
    });

    test('a record paired elsewhere cannot be paired again', () {
      final withThird = () {
        final base = _project();
        return base.copyWith(
          assets: [...base.assets, _asset('c')],
          items: [...base.items, _item('item-c', 'c')],
          documents: [...base.documents, _record('item-c', 'c')],
        );
      }();
      final paired = acceptPair(withThird, 'rec-item-a', 'rec-item-b');
      expect(
        () => acceptPair(paired, 'rec-item-a', 'rec-item-c'),
        throwsA(isA<ValidationException>()),
      );
    });

    test('override decisions survive a JSON round trip', () {
      final paired = acceptPair(_project(), 'rec-item-a', 'rec-item-b');
      final restored = Project.fromJson(paired.toJson());
      final a = restored.documents.firstWhere((d) => d.id == 'rec-item-a');
      expect(a.pairing, PairingState.paired);
      expect(a.pairedDocumentId, 'rec-item-b');
      expect(a.overrides.single.pairing, PairingState.paired);
      expect(
        recordsNeedingReview(restored).map((record) => record.id),
        ['rec-item-a', 'rec-item-b'],
        reason: 'pairing does not confirm each record’s recognition evidence',
      );
    });
  });
}
