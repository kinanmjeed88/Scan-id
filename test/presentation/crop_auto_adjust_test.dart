import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/presentation/crop_screen.dart';

import '../fixtures.dart';
import 'editor_harness.dart';

void main() {
  testWidgets(
    'automatic enhancement renders its result instead of only moving sliders',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repository = MemoryProjects();
      final base = assetFixture(id: 'asset-auto-adjust');
      final landscapeCorners = [
        Point2(.1, .1),
        Point2(.9, .1),
        Point2(.9, .9),
        Point2(.1, .9),
      ];
      final asset = ImageAsset(
        id: base.id,
        name: base.name,
        originalPath: base.originalPath,
        workingPath: base.workingPath,
        thumbnailPath: base.thumbnailPath,
        width: base.width,
        height: base.height,
        // Legacy/explicit saved geometry is retained by enhancement alone.
        // A category is not permission to replace it with a catalog ratio.
        crop: CropGeometry(
          corners: landscapeCorners,
          outputWidth: 40,
          outputHeight: 64,
        ),
      );
      final project = await repository.create(projectFixture(assets: [asset]));
      final editor = FakeImageEditor();
      final service = ProjectService(
        repository,
        NoAssets(),
        imageEditor: editor,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: CropScreen(
            project: project,
            asset: asset,
            service: service,
            documentKind: DocumentKind.unifiedNationalId,
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
      final geometry = editor.lastPreview!.geometry;
      expect(geometry.outputWidth, asset.crop!.outputWidth);
      expect(geometry.outputHeight, asset.crop!.outputHeight);
      // Enhancement changes colour/sharpness, not approved geometry. A
      // previously distorted crop needs explicit recropping from the original.

      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('accept-crop')))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
