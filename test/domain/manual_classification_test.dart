import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/manual_classification.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_overrides.dart' as rec;
import 'package:scan_id/domain/validation.dart';

import '../fixtures.dart';

ImageAsset approvedAsset(String id) {
  final original = assetFixture(id: id);
  final crop = CropDraft(
    corners: [Point2(.1, .1), Point2(.9, .1), Point2(.9, .9), Point2(.1, .9)],
  ).toRecipe(original.width, original.height).geometry;
  return ImageAsset(
    id: id,
    name: original.name,
    originalPath: original.originalPath,
    workingPath: original.workingPath,
    thumbnailPath: original.thumbnailPath,
    width: original.width,
    height: original.height,
    crop: crop,
  );
}

DocumentItem pending(String id, String assetId) => DocumentItem(
  id: id,
  assetId: assetId,
  x: 0,
  y: 0,
  width: 60,
  height: 40,
  pageIndex: null,
);

void main() {
  var sequence = 0;
  String id() => 'manual-${++sequence}';

  test(
    'manual selection preserves an unapproved source and records kind/side without evidence',
    () {
      final source = assetFixture();
      final original = projectFixture(
        assets: [source],
        items: [pending('item1', source.id)],
      );
      final selected = classifyItemManually(
        original,
        itemId: 'item1',
        kind: DocumentKind.unifiedNationalId,
        side: SideKind.front,
        nextId: id,
      );
      final item = selected.items.single;
      final record = selected.documents.single;
      expect(item.sizeConfirmed, isFalse);
      expect(item.pageIndex, isNull);
      expect(selected.assets.single.originalPath, source.originalPath);
      expect(record.recognition, isNull);
      expect(record.sides.single.detection, isNull);
      expect(rec.effectiveKind(record), DocumentKind.unifiedNationalId);
      expect(rec.effectiveSide(record, record.sides.single), SideKind.front);
      final restored = Project.fromJson(selected.toJson());
      expect(
        rec.effectiveSide(
          restored.documents.single,
          restored.documents.single.sides.single,
        ),
        SideKind.front,
      );
    },
  );

  test(
    'the user explicitly selects the opposite face; both are adjacent without moving a locked item',
    () {
      final front = approvedAsset('front');
      final back = approvedAsset('back');
      final fixedAsset = approvedAsset('fixed');
      final fixed = DocumentItem(
        id: 'fixed-item',
        assetId: fixedAsset.id,
        x: 5,
        y: 160,
        width: 60,
        height: 40,
        pageIndex: 0,
        locked: true,
        documentKind: DocumentKind.other,
        sizeConfirmed: true,
      );
      var project = projectFixture(
        assets: [front, back, fixedAsset],
        items: [
          pending('front-item', front.id),
          pending('back-item', back.id),
          fixed,
        ],
      );
      project = classifyItemManually(
        project,
        itemId: 'front-item',
        kind: DocumentKind.unifiedNationalId,
        side: SideKind.front,
        nextId: id,
      );
      project = classifyItemManually(
        project,
        itemId: 'back-item',
        kind: DocumentKind.unifiedNationalId,
        side: SideKind.back,
        nextId: id,
      );
      expect(
        project.items
            .where((item) => item.id != fixed.id)
            .every((item) => item.sizeConfirmed),
        isTrue,
      );
      expect(
        project.layoutGroups,
        isEmpty,
        reason: 'same type and order must never pair automatically',
      );
      expect(
        matchingManualSidePartners(
          project,
          itemId: 'back-item',
          kind: DocumentKind.unifiedNationalId,
          side: SideKind.back,
        ).map((item) => item.id),
        ['front-item'],
      );
      project = project.copyWith(
        items: [
          for (final item in project.items)
            if (item.id == 'front-item')
              item.copyWith(pageIndex: 0, x: 8, y: 8)
            else
              item,
        ],
      );
      final paired = pairManualSides(project, 'back-item', 'front-item');
      final first = paired.items.firstWhere((item) => item.id == 'front-item');
      final second = paired.items.firstWhere((item) => item.id == 'back-item');
      expect(first.pageIndex, isNotNull);
      expect(first.pageIndex, second.pageIndex);
      expect(first.groupId, second.groupId);
      expect(
        paired.layoutGroups.single.arrangement,
        GroupArrangement.sideBySide,
      );
      expect(first.y, closeTo(second.y, .01));
      expect((first.x - second.x).abs(), greaterThan(50));
      expect(
        paired.items.firstWhere((item) => item.id == fixed.id).toJson(),
        fixed.toJson(),
      );
      expect(
        paired.documents.every((entry) => entry.pairing == PairingState.paired),
        isTrue,
      );
      expect(
        Project.fromJson(paired.toJson()).layoutGroups.single.arrangement,
        GroupArrangement.sideBySide,
      );

      final unchanged = classifyItemManually(
        paired,
        itemId: 'back-item',
        kind: DocumentKind.unifiedNationalId,
        side: SideKind.back,
        nextId: id,
      );
      expect(unchanged.layoutGroups, hasLength(1));
      final revised = classifyItemManually(
        unchanged,
        itemId: 'back-item',
        kind: DocumentKind.unifiedNationalId,
        side: SideKind.front,
        nextId: id,
      );
      expect(revised.layoutGroups, isEmpty);
      expect(
        revised.documents.every(
          (record) => record.pairing == PairingState.single,
        ),
        isTrue,
      );
      expect(
        revised.documents.every((record) => record.pairedDocumentId == null),
        isTrue,
      );
      expect(
        revised.items.firstWhere((item) => item.id == first.id).x,
        first.x,
      );
      expect(
        revised.items.firstWhere((item) => item.id == first.id).y,
        first.y,
      );
      expect(
        revised.items.firstWhere((item) => item.id == fixed.id).toJson(),
        fixed.toJson(),
      );
      final updatedRecord = revised.documents.firstWhere(
        (record) => record.id == second.documentId,
      );
      expect(
        rec.effectiveSide(updatedRecord, updatedRecord.sides.single),
        SideKind.front,
      );
    },
  );

  test('an unconfirmed boundary cannot be paired or silently placed', () {
    final first = assetFixture(id: 'first');
    final second = approvedAsset('second');
    var project = projectFixture(
      assets: [first, second],
      items: [pending('a', first.id), pending('b', second.id)],
    );
    project = classifyItemManually(
      project,
      itemId: 'a',
      kind: DocumentKind.unifiedNationalId,
      side: SideKind.front,
      nextId: id,
    );
    project = classifyItemManually(
      project,
      itemId: 'b',
      kind: DocumentKind.unifiedNationalId,
      side: SideKind.back,
      nextId: id,
    );
    expect(
      () => pairManualSides(project, 'a', 'b'),
      throwsA(isA<ValidationException>()),
    );
    expect(project.items.first.pageIndex, isNull);
  });

  test('an accepted derived warp can use a manually selected catalog kind', () {
    final source = assetFixture(id: 'source');
    final derived = assetFixture(id: 'derived').asDerivedOf(source.id);
    final corners = [
      Point2(.1, .1),
      Point2(.9, .1),
      Point2(.9, .9),
      Point2(.1, .9),
    ];
    final record = DocumentRecord(
      id: 'rec',
      sourceImageId: source.id,
      pairing: PairingState.single,
      sides: [
        DocumentSide(
          id: 'side',
          side: SideKind.unknown,
          processedAsset: ProcessedAssetRef(
            workingPath: derived.workingPath,
            thumbnailPath: derived.thumbnailPath,
            width: derived.width,
            height: derived.height,
            corners: corners,
          ),
          detection: DetectionRef(
            detectionId: 'det',
            producer: 'segmenter',
            version: '1',
            polygon: corners,
          ),
        ),
      ],
      provenance: Provenance(
        sourceImageId: source.id,
        detectionIds: ['det'],
        processedAssetVersion: '1',
        pipelineVersion: '1',
      ),
    );
    final item = pending(
      'derived-item',
      derived.id,
    ).copyWith(documentId: record.id, sideId: 'side');
    final project = classifyItemManually(
      projectFixture(
        assets: [source, derived],
        items: [item],
        documents: [record],
      ),
      itemId: item.id,
      kind: DocumentKind.unifiedNationalId,
      side: SideKind.front,
      nextId: id,
    );
    expect(derived.crop, isNull);
    expect(project.items.single.sizeConfirmed, isTrue);

    final suggestionOnly = record.copyWith(
      sides: [
        DocumentSide(
          id: 'side',
          side: SideKind.unknown,
          processedAsset: record.sides.single.processedAsset,
          detection: DetectionRef(
            detectionId: 'det',
            producer: 'segmenter',
            version: '1',
            suggestedPolygon: corners,
          ),
        ),
      ],
    );
    final pendingReview = classifyItemManually(
      projectFixture(
        assets: [source, derived],
        items: [item],
        documents: [suggestionOnly],
      ),
      itemId: item.id,
      kind: DocumentKind.unifiedNationalId,
      side: SideKind.front,
      nextId: id,
    );
    expect(pendingReview.items.single.sizeConfirmed, isFalse);
    expect(pendingReview.items.single.pageIndex, isNull);
  });
}
