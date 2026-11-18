import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/camera_capture.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/presentation/app.dart';
import 'package:scan_id/presentation/project_screen.dart';

import 'editor_harness.dart';

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

Future<void> _allowFileRead(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump();
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
      final repository = MemoryProjects();
      final project = await repository.create(editorProject(items: []));
      final file = await File(
        '${root.path}/shot.jpg',
      ).writeAsBytes(List.filled(40, 0x00));
      final port = _PendingCamera(
        PendingCapture(id: 'pending-1', projectId: project.id, file: file),
      );
      final camera = CameraCapture(repository, NoAssets(), port);

      await tester.pumpWidget(
        AppShell(
          home: ProjectScreen(
            project: project,
            service: ProjectService(repository, NoAssets(), camera: camera),
            pickImages: () async => [],
          ),
        ),
      );
      await _allowFileRead(tester);

      expect(find.text('التقاط غير مؤكد الحفظ'), findsOneWidget);
      await tester.tap(find.text('إلغاء'));
      await tester.pump();
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
      final repository = MemoryProjects();
      final project = await repository.create(editorProject(items: []));
      final port = _PendingCamera(null);
      final camera = CameraCapture(repository, NoAssets(), port);

      await tester.pumpWidget(
        AppShell(
          home: ProjectScreen(
            project: project,
            service: ProjectService(repository, NoAssets(), camera: camera),
            pickImages: () async => [],
          ),
        ),
      );
      await tester.pump();
      expect(find.text('التقاط غير مؤكد الحفظ'), findsNothing);

      port.photo = PendingCapture(
        id: 'pending-resume',
        projectId: project.id,
        file: await File(
          '${root.path}/shot.jpg',
        ).writeAsBytes(List.filled(40, 0x00)),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _allowFileRead(tester);

      expect(find.text('التقاط غير مؤكد الحفظ'), findsOneWidget);
    },
  );
}
