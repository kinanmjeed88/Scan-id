import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/camera_capture.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/presentation/app.dart';
import 'package:scan_id/presentation/project_screen.dart';

class _PendingCamera implements CameraPort {
  _PendingCamera(this.photo);
  PendingCapture? photo;

  @override
  Future<PendingCapture?> capture(String projectId) async => photo;

  @override
  Future<PendingCapture?> pending() async => photo;

  @override
  Future<void> discard(String id) async {
    if (photo?.id == id) photo = null;
  }
}

void main() {
  testWidgets(
    'opening a project offers a journalled camera capture instead of dropping it',
    (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final root = await Directory.systemTemp.createTemp('pending-capture-ui-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final repository = await LocalProjectRepository.open(root);
      addTearDown(repository.close);
      final assets = LocalAssetRepository(repository.files);
      final project = await ProjectService(repository, assets).create('كاميرا');
      final file = await File(
        '${root.path}/shot.jpg',
      ).writeAsBytes(img.encodeJpg(img.Image(width: 80, height: 60)));
      final port = _PendingCamera(
        PendingCapture(id: 'pending-1', projectId: project.id, file: file),
      );
      final camera = CameraCapture(repository, assets, port);

      await tester.pumpWidget(
        AppShell(
          home: ProjectScreen(
            project: project,
            service: ProjectService(repository, assets, camera: camera),
            pickImages: () async => [],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('التقاط غير مؤكد الحفظ'), findsOneWidget);
      await tester.tap(find.text('إلغاء'));
      await tester.pumpAndSettle();
      expect(await port.pending(), isNotNull);
    },
  );

  testWidgets(
    'returning from the camera offers a JPEG written after interruption',
    (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final root = await Directory.systemTemp.createTemp('pending-resume-ui-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final repository = await LocalProjectRepository.open(root);
      addTearDown(repository.close);
      final assets = LocalAssetRepository(repository.files);
      final project = await ProjectService(repository, assets).create('كاميرا');
      final port = _PendingCamera(null);
      final camera = CameraCapture(repository, assets, port);

      await tester.pumpWidget(
        AppShell(
          home: ProjectScreen(
            project: project,
            service: ProjectService(repository, assets, camera: camera),
            pickImages: () async => [],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('التقاط غير مؤكد الحفظ'), findsNothing);

      final file = await File(
        '${root.path}/shot.jpg',
      ).writeAsBytes(img.encodeJpg(img.Image(width: 80, height: 60)));
      port.photo = PendingCapture(
        id: 'pending-resume',
        projectId: project.id,
        file: file,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.text('التقاط غير مؤكد الحفظ'), findsOneWidget);
    },
  );
}
