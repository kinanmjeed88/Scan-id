import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/presentation/crop_screen.dart';

import '../fixtures.dart';
import 'editor_harness.dart';

// Regression: an editable ESTIMATE is still a real catalog size. Showing blank
// boxes and refusing to save until a number was typed forced the user to enter
// a measurement that already had a default. The fields are now prefilled and
// leaving them untouched is an explicit acceptance of that default.
Future<void> _pumpCrop(WidgetTester tester, {required String assetId}) async {
  tester.view.physicalSize = const Size(1100, 820);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repository = MemoryProjects();
  final asset = assetFixture(id: assetId);
  final project = await repository.create(projectFixture(assets: [asset]));
  final service = ProjectService(
    repository,
    NoAssets(),
    imageEditor: FakeImageEditor(),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: CropScreen(project: project, asset: asset, service: service),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _chooseKind(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const Key('crop-document-kind')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'a documented kind supplies its size without duplicate controls',
    (tester) async {
      await _pumpCrop(tester, assetId: 'asset-documented-size');
      await _chooseKind(tester, DocumentKind.unifiedNationalId.label);

      expect(find.byKey(const Key('crop-custom-width-mm')), findsNothing);
      expect(find.byKey(const Key('crop-custom-height-mm')), findsNothing);
      expect(find.byKey(const Key('crop-aspect')), findsNothing);
    },
  );

  for (final kind in [DocumentKind.residenceCard, DocumentKind.rationCard]) {
    testWidgets('${kind.name} prefills its estimated default; no entry needed', (
      tester,
    ) async {
      await _pumpCrop(tester, assetId: 'asset-estimated');
      await _chooseKind(tester, kind.label);

      final width = find.byKey(const Key('crop-custom-width-mm'));
      final height = find.byKey(const Key('crop-custom-height-mm'));
      expect(width, findsOneWidget);
      expect(height, findsOneWidget);
      final w = tester.widget<TextField>(width).controller!.text;
      final h = tester.widget<TextField>(height).controller!.text;
      expect(w, isNotEmpty);
      expect(h, isNotEmpty);

      // The asset is 400x250 (landscape), so the catalog size is oriented too.
      final expected = const DocumentSizeCatalog().sizeFor(
        kind,
        landscape: true,
      )!;
      expect(double.parse(w), closeTo(expected.width, .05));
      expect(double.parse(h), closeTo(expected.height, .05));
      expect(find.textContaining('مقاس افتراضي قابل للتعديل'), findsOneWidget);
      expect(find.byKey(const Key('crop-size-error')), findsNothing);
    });
  }

  testWidgets('civil-status crop has no invented size and is not blocked', (
    tester,
  ) async {
    await _pumpCrop(tester, assetId: 'asset-civil-status');
    await _chooseKind(tester, 'هوية الأحوال المدنية');

    final width = find.byKey(const Key('crop-custom-width-mm'));
    final height = find.byKey(const Key('crop-custom-height-mm'));
    expect(width, findsOneWidget);
    expect(height, findsOneWidget);
    // No documented size means empty fields, NOT "0.0" and NOT a required
    // measurement: the service keeps the confirmed crop off A4 instead.
    expect(tester.widget<TextField>(width).controller!.text, isEmpty);
    expect(tester.widget<TextField>(height).controller!.text, isEmpty);
    expect(find.textContaining('لا يوجد مقاس موثق'), findsOneWidget);
    expect(DocumentKind.civilStatusId.hasOfficialSize, isFalse);
  });

  testWidgets('leaving the prefilled fields untouched shows no size error', (
    tester,
  ) async {
    await _pumpCrop(tester, assetId: 'asset-untouched');
    await _chooseKind(tester, DocumentKind.residenceCard.label);
    expect(find.byKey(const Key('crop-custom-width-mm')), findsOneWidget);
    expect(find.byKey(const Key('crop-size-error')), findsNothing);
    expect(find.textContaining('أدخل العرض والارتفاع'), findsNothing);
  });
}
