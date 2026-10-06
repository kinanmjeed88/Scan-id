import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/presentation/app.dart';

void main() {
  testWidgets(
    'empty state, project creation, rename and reopen use repository',
    (tester) async {
      final repository = _MemoryProjects();
      final service = ProjectService(repository, _NoAssets());
      await tester.pumpWidget(
        ScanIdApp(service: service, pickImages: () async => []),
      );
      await tester.pumpAndSettle();
      expect(find.text('مشروعك الأول يبدأ هنا'), findsOneWidget);
      await tester.tap(find.text('مشروع جديد'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'عائلتي');
      await tester.tap(find.text('حفظ'));
      await tester.pumpAndSettle();
      expect(repository.values.values.single.name, 'عائلتي');
      expect(find.text('أضف صور المستمسكات'), findsOneWidget);
      await tester.tap(find.byTooltip('إعادة تسمية المشروع'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'وثائق السفر');
      await tester.tap(find.text('حفظ'));
      await tester.pumpAndSettle();
      expect(repository.values.values.single.name, 'وثائق السفر');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('وثائق السفر'));
      await tester.pumpAndSettle();
      expect(find.text('وثائق السفر'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'blank project is rejected and dialog cancellation writes nothing',
    (tester) async {
      final repository = _MemoryProjects();
      await tester.pumpWidget(
        ScanIdApp(
          service: ProjectService(repository, _NoAssets()),
          pickImages: () async => [],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('مشروع جديد'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('حفظ'));
      await tester.pumpAndSettle();
      expect(find.text('أدخل اسم المشروع'), findsOneWidget);
      expect(repository.values, isEmpty);
      await tester.tap(find.text('إلغاء'));
      await tester.pumpAndSettle();
      expect(repository.values, isEmpty);
    },
  );

  testWidgets(
    'small phone layout and cancelled import have no overflow or write',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _MemoryProjects();
      final service = ProjectService(repository, _NoAssets());
      final project = await service.create('صور');
      await tester.pumpWidget(
        ScanIdApp(service: service, pickImages: () async => []),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('صور'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('إضافة صور'));
      await tester.pumpAndSettle();
      expect(repository.values[project.id]!.revision, 0);
      expect(tester.takeException(), isNull);
    },
  );
}

class _MemoryProjects implements ProjectRepository {
  final values = <String, Project>{};
  @override
  Future<List<Project>> list() async => values.values.toList();
  @override
  Future<Project> get(String id) async => values[id]!;
  @override
  Future<Project> create(Project project) async {
    values[project.id] = project;
    return project;
  }

  @override
  Future<Project> save(Project project) async {
    if (values[project.id]?.revision != project.revision) {
      throw const RevisionConflict();
    }
    final saved = project.copyWith(revision: project.revision + 1);
    values[project.id] = saved;
    return saved;
  }

  @override
  Future<void> remove(Project project) async {
    values.remove(project.id);
  }

  @override
  Future<void> close() async {}
}

class _NoAssets implements AssetRepository {
  @override
  Future<ImageAsset> importImage(
    String projectId,
    String name,
    Uint8List bytes,
  ) => Future.error(
    StateError('No asset operation expected in this widget test'),
  );
  @override
  Future<File> resolve(String relativePath) => Future.error(
    StateError('No asset operation expected in this widget test'),
  );
}
