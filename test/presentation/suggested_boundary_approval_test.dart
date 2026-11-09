import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_overrides.dart' as rec;

import '../fixtures.dart';
import 'editor_harness.dart';

// Regression for the screenshots: an image with a saved 46% boundary score was
// still sent to the crop editor AFTER the user had chosen its type. Choosing a
// type must now approve the saved, geometrically valid boundary in one action.
final suggested = <Point2>[
  Point2(.1, .1),
  Point2(.9, .1),
  Point2(.9, .9),
  Point2(.1, .9),
];

void main() {
  testWidgets(
    'choosing a type applies the saved boundary without reopening the crop editor',
    (tester) async {
      final base = editorProject(
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
      final asset = assetFixture(id: 'asset1').withSuggestedCrop(suggested);
      final project = base.copyWith(assets: [asset, ...base.assets.skip(1)]);
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
      // The ACTUAL cause remains available on demand without blocking the
      // primary manual action.
      await tapKey(tester, const Key('manual-classification-diagnostics'));
      expect(
        find.byKey(const Key('manual-classification-reasons')),
        findsOneWidget,
      );
      expect(find.textContaining('سبب عدم الإضافة التلقائية'), findsOneWidget);
      expect(find.textContaining('حد الحدود المتعلمة 55٪'), findsOneWidget);
      expect(find.textContaining('حد التصنيف النصي 60٪'), findsOneWidget);
      expect(find.textContaining('٧٠٪'), findsNothing);
      expect(find.textContaining('(لا تُستخدم للقبول)'), findsOneWidget);
      expect(
        find.byKey(const Key('manual-classification-apply-boundary')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('manual-classification-kind')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('manual-classification-side')),
        findsOneWidget,
      );

      await tapKey(tester, const Key('manual-classification-kind'));
      await tester.tap(find.text(DocumentKind.unifiedNationalId.label).last);
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('manual-classification-continue'));
      await tester.pumpAndSettle();

      // No crop editor, no mandatory size entry, and the documented catalog
      // default was applied automatically.
      expect(find.byKey(const Key('crop-source-image')), findsNothing);
      expect(find.byKey(const Key('crop-custom-width-mm')), findsNothing);
      final item = harness.saved.items.firstWhere((i) => i.id == 'pending');
      expect(item.documentKind, DocumentKind.unifiedNationalId);
      expect(item.sizeConfirmed, isTrue);
      expect(item.pageIndex, isNotNull);
      expect(item.width, closeTo(85.6, .01));
      expect(item.height, closeTo(53.98, .01));
      final crop = harness.saved.assets.first.crop!;
      final source = await FakeImageEditor().open(asset);
      final measured = CropDraft(
        corners: suggested,
      ).toRecipe(source.width, source.height).geometry;
      expect(crop.outputWidth, measured.outputWidth);
      expect(crop.outputHeight, measured.outputHeight);
      expect(
        crop.outputWidth / crop.outputHeight,
        isNot(closeTo(item.width / item.height, .001)),
        reason: 'catalog millimetres must not reshape the approved boundary',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unknown-size kinds stay off A4 while type and both sides stay editable',
    (tester) async {
      final base = editorProject(
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
      final asset = assetFixture(id: 'asset1').withSuggestedCrop(suggested);
      final project = base.copyWith(assets: [asset, ...base.assets.skip(1)]);
      final harness = await EditorHarness.pump(
        tester,
        project: project,
        imageEditor: FakeImageEditor(),
        autoClassifyItemIds: const ['pending'],
      );

      await tapKey(tester, const Key('manual-classification-kind'));
      await tester.tap(find.text(DocumentKind.civilStatusId.label).last);
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('manual-classification-side'));
      await tester.tap(find.text('الوجه الأول (أمامي)').last);
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('manual-classification-continue'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('crop-source-image')), findsOneWidget);
      await tester.tap(find.byTooltip('إلغاء القص'));
      await tester.pumpAndSettle();
      final item = harness.saved.items.firstWhere((i) => i.id == 'pending');
      expect(item.documentKind, DocumentKind.civilStatusId);
      expect(item.sizeConfirmed, isFalse);
      expect(item.pageIndex, isNull);
      expect(harness.saved.assets.first.hasApprovedCrop, isTrue);
      final firstRecord = harness.saved.documents.single;
      expect(
        rec.effectiveSide(firstRecord, firstRecord.sides.single),
        SideKind.front,
      );

      await tapKey(tester, const Key('offsheet-pending'));
      await tapKey(tester, const Key('ribbon-tab-document'));
      await tapKey(tester, const Key('rb-doc-classify'));
      expect(find.text('تعديل تصنيف المستمسك'), findsOneWidget);
      await tapKey(tester, const Key('manual-classification-kind'));
      await tester.tap(find.text(DocumentKind.other.label).last);
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('manual-classification-side'));
      await tester.tap(find.text('الوجه الثاني (خلفي)').last);
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('manual-classification-continue'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('crop-source-image')), findsNothing);
      final updatedItem = harness.saved.items.firstWhere(
        (i) => i.id == 'pending',
      );
      expect(updatedItem.documentKind, DocumentKind.other);
      expect(updatedItem.sizeConfirmed, isFalse);
      expect(updatedItem.pageIndex, isNull);
      final updatedRecord = harness.saved.documents.single;
      expect(rec.effectiveKind(updatedRecord), DocumentKind.other);
      expect(
        rec.effectiveSide(updatedRecord, updatedRecord.sides.single),
        SideKind.back,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
