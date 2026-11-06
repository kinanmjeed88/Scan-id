import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/manual_classification.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_overrides.dart' as rec;

import '../fixtures.dart';
import 'crop_tap_helpers.dart';
import 'editor_harness.dart';

void main() {
  testWidgets(
    'failed import immediately offers classification; defer can be resumed and crop confirms placement',
    (tester) async {
      final project = editorProject(
        items: [
          DocumentItem(
            id: 'pending',
            assetId: 'asset1',
            x: 0,
            y: 0,
            width: 60,
            height: 40,
            pageIndex: null,
          ),
        ],
      );
      final harness = await EditorHarness.pump(
        tester,
        project: project,
        imageEditor: FakeImageEditor(),
        autoClassifyItemIds: const ['pending'],
      );
      expect(
        find.byKey(const Key('manual-classification-dialog')),
        findsOneWidget,
      );
      expect(find.text('اختر تصنيف المستمسك'), findsOneWidget);
      expect(find.textContaining('غير متاحة'), findsWidgets);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('manual-classification-continue')),
            )
            .onPressed,
        isNull,
      );

      await tapKey(tester, const Key('manual-classification-later'));
      expect(
        harness.saved.assets.first.originalPath,
        project.assets.first.originalPath,
      );
      expect(harness.saved.items.single.pageIndex, isNull);
      expect(
        find.descendant(
          of: find.byKey(const Key('pending-classification-section')),
          matching: find.byKey(const Key('offsheet-pending')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('off-sheet-section')),
          matching: find.byKey(const Key('offsheet-pending')),
        ),
        findsNothing,
      );

      await tapKey(tester, const Key('choose-document-classification'));
      await tapKey(tester, const Key('manual-classification-kind'));
      await tester.tap(find.text(DocumentKind.unifiedNationalId.label).last);
      await tester.pumpAndSettle();
      // Kind alone is insufficient: the user must also explicitly choose a side.
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('manual-classification-continue')),
            )
            .onPressed,
        isNull,
      );
      await tapKey(tester, const Key('manual-classification-side'));
      await tester.tap(find.text('الوجه الأول (أمامي)').last);
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('manual-classification-continue'));
      expect(find.byKey(const Key('crop-source-image')), findsOneWidget);
      expect(harness.saved.items.single.sizeConfirmed, isFalse);
      expect(
        rec.effectiveSide(
          harness.saved.documents.single,
          harness.saved.documents.single.sides.single,
        ),
        SideKind.front,
      );

      await ensureCropTapMode(tester);
      final rect = tester.getRect(find.byKey(const Key('crop-tap-surface')));
      for (final (x, y) in const [(.2, .2), (.8, .2), (.8, .8), (.2, .8)]) {
        await tester.tapAt(
          Offset(rect.left + rect.width * x, rect.top + rect.height * y),
        );
        await tester.pumpAndSettle();
      }
      // The four taps produce adjustable handles; drag one before previewing.
      final corner = find.byKey(const Key('crop-corner-0'));
      await tester.ensureVisible(corner);
      await tester.pumpAndSettle();
      final beforeDrag = tester.getCenter(corner);
      await tester.timedDrag(
        corner,
        const Offset(35, 25),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      expect((tester.getCenter(corner) - beforeDrag).distance, greaterThan(5));
      await tester.ensureVisible(find.text('معاينة التصحيح'));
      await tester.tap(find.text('معاينة التصحيح'));
      await pumpCropPreviewResult(tester);
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('accept-crop'));
      expect(harness.saved.items.single.sizeConfirmed, isTrue);
      expect(harness.saved.items.single.pageIndex, isNotNull);
      expect(harness.saved.assets.first.crop, isNotNull);
      expect(harness.saved.assets.first.crop!.corners.first.x, greaterThan(.2));
      expect(
        find.byKey(const Key('choose-document-classification')),
        findsNothing,
      );

      // Classification remains editable after the image is on the sheet.
      await tapKey(tester, const Key('ribbon-tab-document'));
      await tapKey(tester, const Key('rb-doc-classify'));
      expect(find.text('تعديل تصنيف المستمسك'), findsOneWidget);
      await tapKey(tester, const Key('manual-classification-side'));
      await tester.tap(find.text('الوجه الثاني (خلفي)').last);
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('manual-classification-continue'));
      final revised = harness.saved.documents.single;
      expect(rec.effectiveSide(revised, revised.sides.single), SideKind.back);
      expect(harness.saved.items.single.pageIndex, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('explicitly chosen matching faces are paired side by side', (
    tester,
  ) async {
    ImageAsset reviewedAsset(String id) {
      final asset = assetFixture(id: id);
      final crop = CropDraft(
        corners: [
          Point2(.1, .1),
          Point2(.9, .1),
          Point2(.9, .9),
          Point2(.1, .9),
        ],
      ).toRecipe(asset.width, asset.height).geometry;
      return ImageAsset(
        id: asset.id,
        name: asset.name,
        originalPath: asset.originalPath,
        workingPath: asset.workingPath,
        thumbnailPath: asset.thumbnailPath,
        width: asset.width,
        height: asset.height,
        crop: crop,
      );
    }

    final template = editorProject(
      items: [
        placedDocument('first', 'asset1', DocumentKind.unifiedNationalId),
        DocumentItem(
          id: 'second',
          assetId: 'asset2',
          x: 0,
          y: 0,
          width: 60,
          height: 40,
          pageIndex: null,
        ),
      ],
    );
    var sequence = 0;
    final project = classifyItemManually(
      template.copyWith(
        assets: [
          reviewedAsset('asset1'),
          reviewedAsset('asset2'),
          ...template.assets.skip(2),
        ],
      ),
      itemId: 'first',
      kind: DocumentKind.unifiedNationalId,
      side: SideKind.front,
      nextId: () => 'existing-${++sequence}',
    );
    final harness = await EditorHarness.pump(
      tester,
      project: project,
      autoClassifyItemIds: const ['second'],
    );
    await tapKey(tester, const Key('manual-classification-kind'));
    await tester.tap(find.text(DocumentKind.unifiedNationalId.label).last);
    await tester.pumpAndSettle();
    await tapKey(tester, const Key('manual-classification-side'));
    await tester.tap(find.text('الوجه الثاني (خلفي)').last);
    await tester.pumpAndSettle();
    await tapKey(tester, const Key('manual-classification-partner'));
    await tester.tap(
      find
          .byWidgetPredicate(
            (widget) =>
                widget is DropdownMenuItem<String> && widget.value == 'first',
          )
          .last,
    );
    await tester.pumpAndSettle();
    await tapKey(tester, const Key('manual-classification-continue'));

    final first = harness.saved.items.firstWhere((item) => item.id == 'first');
    final second = harness.saved.items.firstWhere(
      (item) => item.id == 'second',
    );
    expect(first.pageIndex, isNotNull);
    expect(first.pageIndex, second.pageIndex);
    expect(first.groupId, second.groupId);
    expect(
      harness.saved.layoutGroups.single.arrangement,
      GroupArrangement.sideBySide,
    );
    expect(first.y, closeTo(second.y, .01));
    expect((first.x - second.x).abs(), greaterThan(50));
    expect(
      harness.saved.assets.first.originalPath,
      project.assets.first.originalPath,
    );
    expect(tester.takeException(), isNull);
  });
}
