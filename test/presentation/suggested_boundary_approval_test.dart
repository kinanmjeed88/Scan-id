import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/project.dart';

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
      // The ACTUAL cause is shown; the working dropdowns are untouched.
      expect(
        find.byKey(const Key('manual-classification-reasons')),
        findsOneWidget,
      );
      expect(find.textContaining('سبب عدم الإضافة التلقائية'), findsOneWidget);
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
      await tester.tap(find.text(DocumentKind.residenceCard.label).last);
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('manual-classification-side'));
      await tester.tap(find.text('الوجه الأول (أمامي)').last);
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('manual-classification-continue'));
      await tester.pumpAndSettle();

      // No crop editor, no mandatory size entry, and the estimated catalog
      // default was applied automatically.
      expect(find.byKey(const Key('crop-source-image')), findsNothing);
      expect(find.byKey(const Key('crop-custom-width-mm')), findsNothing);
      final item = harness.saved.items.firstWhere((i) => i.id == 'pending');
      expect(item.documentKind, DocumentKind.residenceCard);
      expect(item.sizeConfirmed, isTrue);
      expect(item.pageIndex, isNotNull);
      expect(item.width, closeTo(92.4, .01));
      expect(item.height, closeTo(62.8, .01));
      final crop = harness.saved.assets.first.crop!;
      expect(
        crop.outputWidth / crop.outputHeight,
        closeTo(item.width / item.height, 1e-9),
        reason: 'direct boundary approval must not create top/bottom bands',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
