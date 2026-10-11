import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/image_deletion.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/validation.dart';

import '../fixtures.dart';

void main() {
  DocumentItem placed(String id, String assetId, {bool locked = false}) =>
      DocumentItem(
        id: id,
        assetId: assetId,
        x: 10,
        y: 10,
        width: 50,
        height: 40,
        locked: locked,
        sizeConfirmed: true,
      );

  group('planImageDeletion', () {
    test('an unknown image is refused before anything is planned', () {
      final project = projectFixture(assets: [assetFixture(id: 'a')]);
      expect(
        () => planImageDeletion(project, 'missing'),
        throwsA(isA<ValidationException>()),
      );
    });

    test('counts locked elements without treating them as blockers', () {
      final a = assetFixture(id: 'a');
      final b = assetFixture(id: 'b');
      final project = projectFixture(
        assets: [a, b],
        items: [
          placed('a1', 'a', locked: true),
          placed('a2', 'a'),
          placed('b1', 'b'),
        ],
      );

      final plan = planImageDeletion(project, 'a');

      expect(plan.itemIds, ['a1', 'a2']);
      expect(plan.lockedItemIds, ['a1']);
      expect(plan.assetDirectory, 'projects/project1/assets/a');
      expect(plan.removesSheetElements, isTrue);
    });

    test('an image with no element and no record has an empty plan', () {
      final a = assetFixture(id: 'a');
      final project = projectFixture(assets: [a]);

      final plan = planImageDeletion(project, 'a');

      expect(plan.itemIds, isEmpty);
      expect(plan.documentIds, isEmpty);
      expect(plan.keptDerivedAssetIds, isEmpty);
      expect(plan.removesSheetElements, isFalse);
    });
  });

  group('applyImageDeletion', () {
    test(
      'removes only the image and its own elements; others are identical',
      () {
        final a = assetFixture(id: 'a');
        final b = assetFixture(id: 'b');
        final keep = placed('b1', 'b');
        final project = projectFixture(
          assets: [a, b],
          items: [placed('a1', 'a', locked: true), keep],
        );

        final next = applyImageDeletion(
          project,
          planImageDeletion(project, 'a'),
        );

        expect(next.assets.map((asset) => asset.id), ['b']);
        expect(next.items.single.toJson(), keep.toJson());
      },
    );
  });

  group('detachImageFromSheet', () {
    test('an image that is not placed cannot be detached', () {
      final project = projectFixture(assets: [assetFixture(id: 'a')]);
      expect(
        () => detachImageFromSheet(project, 'a'),
        throwsA(isA<ValidationException>()),
      );
    });

    test('detaching keeps the image in the project', () {
      final a = assetFixture(id: 'a');
      final project = projectFixture(
        assets: [a],
        items: [placed('a1', 'a', locked: true)],
      );

      final next = detachImageFromSheet(project, 'a');

      expect(next.assets.map((asset) => asset.id), ['a']);
      expect(next.items, isEmpty);
    });
  });
}
