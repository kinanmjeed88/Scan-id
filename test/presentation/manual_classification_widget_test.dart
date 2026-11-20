import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/intake_options.dart';
import 'package:scan_id/presentation/crop_screen.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/manual_classification.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_overrides.dart' as rec;

import '../fixtures.dart';
import 'crop_tap_helpers.dart';
import 'editor_harness.dart';

void main() {
  for (final side in SideKind.values) {
    testWidgets(
      'ambiguous automatic kind never asks again for intake side ${side.name}',
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
        var n = 0;
        final chosen = attachIntakeChoices(
          project,
          project.items,
          IntakeOptions(side: side),
          () => 'choice-${++n}',
        );
        await EditorHarness.pump(
          tester,
          project: chosen,
          imageEditor: FakeImageEditor(),
          autoClassifyItemIds: ['pending'],
        );
        expect(
          find.byKey(const Key('manual-classification-side')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('manual-classification-kind')),
          findsOneWidget,
        );
        expect(chosen.documents.single.sides.single.side, side);
      },
    );
  }
  testWidgets('manual type routes only to the remaining boundary/size review', (
    tester,
  ) async {
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
    var n = 0;
    final chosen = attachIntakeChoices(
      project,
      project.items,
      const IntakeOptions(kind: DocumentKind.passport, side: SideKind.back),
      () => 'choice-${++n}',
    );
    await EditorHarness.pump(
      tester,
      project: chosen,
      imageEditor: FakeImageEditor(),
      autoClassifyItemIds: ['pending'],
    );
    expect(find.byKey(const Key('manual-classification-dialog')), findsNothing);
    expect(
      tester.widget<CropScreen>(find.byType(CropScreen)).documentKind,
      DocumentKind.passport,
    );
  });

  for (final accepted in [true, false]) {
    testWidgets(
      'content type accepted=$accepted routes independently from crop and preserves deferred data',
      (tester) async {
        final template = editorProject(
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
        var sequence = 0;
        final manual = classifyItemManually(
          template,
          itemId: 'pending',
          kind: DocumentKind.residenceCard,
          side: SideKind.unknown,
          nextId: () => 'bootstrap-${++sequence}',
        );
        final record = manual.documents.single.copyWith(
          overrides: [],
          recognition: RecognitionResult(
            documentKind: DocumentKind.residenceCard,
            status: accepted
                ? RecognitionStatus.recognized
                : RecognitionStatus.uncertain,
            confidences: ConfidenceSet(
              classification: Confidence(value: accepted ? .85 : .59),
              finalConfidence: Confidence(value: .2),
            ),
            preset: const PresetSelection.awaiting(),
          ),
        );
        final project = manual.copyWith(
          documents: [record],
          items: [manual.items.single.copyWith(userSelectedKind: false)],
        );
        final harness = await EditorHarness.pump(
          tester,
          project: project,
          imageEditor: FakeImageEditor(),
          autoClassifyItemIds: const ['pending'],
        );
        expect(
          find.byKey(const Key('manual-classification-dialog')),
          accepted ? findsNothing : findsOneWidget,
        );
        if (!accepted) {
          await tapKey(tester, const Key('manual-classification-later'));
        }
        expect(
          harness.saved.assets.first.originalPath,
          project.assets.first.originalPath,
        );
        expect(harness.saved.documents.single.overrides, isEmpty);
        expect(harness.saved.items.single.pageIndex, isNull);
        expect(harness.saved.items.single.sizeConfirmed, isFalse);
      },
    );
  }

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
      expect(
        find.textContaining('مسار مستقل عن درجة التعرف التلقائي'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('manual-classification-confidence')),
        findsNothing,
        reason: 'diagnostic scores are optional, not a blocking banner',
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('manual-classification-continue')),
            )
            .onPressed,
        isNull,
      );

      await tapKey(tester, const Key('manual-classification-diagnostics'));
      expect(
        find.byKey(const Key('manual-classification-confidence')),
        findsOneWidget,
      );
      expect(find.textContaining('غير متاحة'), findsWidgets);
      await tapKey(tester, const Key('manual-classification-diagnostics'));

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
      // The type alone is enough to continue. An unspecified face is an
      // explicit manual value, not fabricated automatic side recognition.
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('manual-classification-continue')),
            )
            .onPressed,
        isNotNull,
      );
      await tapKey(tester, const Key('manual-classification-continue'));
      expect(find.byKey(const Key('crop-source-image')), findsOneWidget);
      expect(harness.saved.items.single.sizeConfirmed, isFalse);
      expect(
        rec.effectiveSide(
          harness.saved.documents.single,
          harness.saved.documents.single.sides.single,
        ),
        SideKind.unknown,
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
        // Handles are visual-only; CornerHitLayer owns the pointer gesture.
        warnIfMissed: false,
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

  testWidgets(
    'a confirmed intake partner is linked without repeating classification or the picker',
    (tester) async {
      const kind = DocumentKind.unifiedNationalId;
      final base = editorProject(
        items: [
          placedDocument('first', 'asset1', kind),
          placedDocument('second', 'asset2', kind),
        ],
      );
      var seq = 0;
      final front = attachIntakeChoices(
        base,
        [base.items.first],
        const IntakeOptions(kind: kind, side: SideKind.front),
        () => 'front-${seq++}',
      );
      final project = attachIntakeChoices(
        front,
        [front.items.last],
        const IntakeOptions(
          kind: kind,
          side: SideKind.back,
          partnerChoice: IntakePartnerChoice('first'),
        ),
        () => 'back-${seq++}',
      );
      final harness = await EditorHarness.pump(
        tester,
        project: project,
        autoClassifyItemIds: ['second'],
      );
      expect(find.text('ربط وجهي المستمسك'), findsNothing);
      expect(
        find.byKey(const Key('manual-classification-dialog')),
        findsNothing,
      );
      expect(
        harness.saved.layoutGroups.single.arrangement,
        GroupArrangement.sideBySide,
      );
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
