import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/presentation/crop_screen.dart';

import '../fixtures.dart';
import 'editor_harness.dart';

void main() {
  testWidgets('automatic enhancement renders its result instead of only moving sliders', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = MemoryProjects();
    final asset = assetFixture(id: 'asset-auto-adjust');
    final project = await repository.create(projectFixture(assets: [asset]));
    final editor = FakeImageEditor();
    final service = ProjectService(repository, NoAssets(), imageEditor: editor);
    await tester.pumpWidget(
      MaterialApp(
        home: CropScreen(
          project: project,
          asset: asset,
          service: service,
          suggestedCorners: [
            Point2(.1, .1),
            Point2(.9, .1),
            Point2(.9, .9),
            Point2(.1, .9),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('crop-result')), findsNothing);
    final button = find.byKey(const Key('crop-auto-adjust'));
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
    await tester.tap(button);
    await pumpCropPreviewResult(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('crop-result')), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('accept-crop'))).onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });
}
