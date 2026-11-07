import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/manual_boundary.dart';
import 'package:scan_id/domain/manual_classification.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_overrides.dart' as rec;

import '../fixtures.dart';

final quad = <Point2>[
  Point2(.1, .1),
  Point2(.9, .1),
  Point2(.9, .9),
  Point2(.1, .9),
];

void main() {
  test('a kind with no catalog size is confirmed but never placed on A4', () {
    final asset = assetFixture(id: 'asset1');
    final recipe = CropDraft(corners: quad).toRecipe(asset.width, asset.height);
    final updatedAsset = ImageAsset(
      id: asset.id,
      name: asset.name,
      originalPath: asset.originalPath,
      workingPath: 'projects/project1/assets/asset1/edited-1.png',
      thumbnailPath: 'projects/project1/assets/asset1/edited-1-thumb.jpg',
      width: recipe.geometry.outputWidth,
      height: recipe.geometry.outputHeight,
      crop: recipe.geometry,
    );
    final project = projectFixture(
      assets: [asset],
      items: [
        DocumentItem(
          id: 'item1',
          assetId: asset.id,
          x: 0,
          y: 0,
          width: 60,
          height: 40,
          pageIndex: null,
        ),
      ],
    );
    var sequence = 0;
    String nextId() => 'gen-${++sequence}';

    final classified = classifyItemManually(
      project,
      itemId: 'item1',
      kind: DocumentKind.civilStatusId,
      side: SideKind.front,
      nextId: nextId,
    );
    final confirmed = applyManualConfirmationToProject(
      classified,
      updatedAsset: updatedAsset,
      recipe: recipe,
      documentKind: DocumentKind.civilStatusId,
      sizeMm: null,
      nextId: nextId,
      targetItemId: 'item1',
    );

    final item = confirmed.items.single;
    expect(item.documentKind, DocumentKind.civilStatusId);
    expect(item.userSelectedKind, isTrue);
    expect(item.sizeConfirmed, isFalse);
    expect(item.pageIndex, isNull, reason: 'no invented physical size');
    expect(confirmed.assets.single.crop, isNotNull);

    // Type and BOTH faces remain editable after an unconfirmed placement.
    final edited = classifyItemManually(
      confirmed,
      itemId: 'item1',
      kind: DocumentKind.other,
      side: SideKind.back,
      nextId: nextId,
    );
    final record = edited.documents.single;
    expect(rec.effectiveKind(record), DocumentKind.other);
    expect(rec.effectiveSide(record, record.sides.single), SideKind.back);
    expect(edited.items.single.pageIndex, isNull);
    expect(edited.items.single.sizeConfirmed, isFalse);
  });

  test('a documented catalog size still places the item on A4', () {
    final asset = assetFixture(id: 'asset1');
    final recipe = CropDraft(corners: quad).toRecipe(asset.width, asset.height);
    final updatedAsset = ImageAsset(
      id: asset.id,
      name: asset.name,
      originalPath: asset.originalPath,
      workingPath: 'projects/project1/assets/asset1/edited-2.png',
      thumbnailPath: 'projects/project1/assets/asset1/edited-2-thumb.jpg',
      width: recipe.geometry.outputWidth,
      height: recipe.geometry.outputHeight,
      crop: recipe.geometry,
    );
    final project = projectFixture(
      assets: [asset],
      items: [
        DocumentItem(
          id: 'item1',
          assetId: asset.id,
          x: 0,
          y: 0,
          width: 60,
          height: 40,
          pageIndex: null,
        ),
      ],
    );
    var sequence = 0;
    String nextId() => 'gen-${++sequence}';
    final classified = classifyItemManually(
      project,
      itemId: 'item1',
      kind: DocumentKind.residenceCard,
      side: SideKind.front,
      nextId: nextId,
    );
    final confirmed = applyManualConfirmationToProject(
      classified,
      updatedAsset: updatedAsset,
      recipe: recipe,
      documentKind: DocumentKind.residenceCard,
      sizeMm: const PhysicalSizeMm(92.4, 62.8),
      nextId: nextId,
      targetItemId: 'item1',
    );
    expect(confirmed.items.single.sizeConfirmed, isTrue);
    expect(confirmed.items.single.pageIndex, isNotNull);
    expect(confirmed.items.single.width, closeTo(92.4, 1e-6));
  });
}
