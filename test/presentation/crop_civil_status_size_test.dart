import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/presentation/crop_screen.dart';

import '../fixtures.dart';
import 'editor_harness.dart';

void main() {
  testWidgets('civil-status crop requires a manually entered physical size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = MemoryProjects();
    final asset = assetFixture(id: 'asset-civil-status');
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

    await tester.tap(find.byKey(const Key('crop-document-kind')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('هوية الأحوال المدنية').last);
    await tester.pumpAndSettle();

    final width = find.byKey(const Key('crop-custom-width-mm'));
    final height = find.byKey(const Key('crop-custom-height-mm'));
    expect(width, findsOneWidget);
    expect(height, findsOneWidget);
    expect(tester.widget<TextField>(width).controller!.text, isEmpty);
    expect(tester.widget<TextField>(height).controller!.text, isEmpty);
    expect(find.textContaining('لا يوجد مقاس موثق'), findsOneWidget);
    expect(DocumentKind.civilStatusId.hasOfficialSize, isFalse);
  });
}
