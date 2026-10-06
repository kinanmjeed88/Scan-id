import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/imaging/perspective.dart';
import 'package:scan_id/presentation/crop_screen.dart';
import 'fixtures.dart';
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
      // pageBack() searches for the English tooltip 'Back'; this app is Arabic.
      await tester.tap(find.byType(BackButton));
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
      expect(
        tester.takeException(),
        isNull,
        reason: 'Home header must fit the phone',
      );
      await tester.tap(find.text('صور'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('إضافة صور'));
      await tester.pumpAndSettle();
      expect(repository.values[project.id]!.revision, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'crop proposal can be undone; only a reviewed preview can be committed',
    (tester) async {
      final repository = _MemoryProjects();
      final editor = _TestEditor();
      final project = await repository.create(
        projectFixture(assets: [assetFixture()]),
      );
      final service = ProjectService(
        repository,
        _NoAssets(),
        imageEditor: editor,
      );
      Project? accepted;
      await tester.pumpWidget(
        AppShell(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  accepted = await Navigator.of(context).push<Project>(
                    MaterialPageRoute(
                      builder: (_) => CropScreen(
                        project: project,
                        asset: project.assets.single,
                        service: service,
                      ),
                    ),
                  );
                },
                child: const Text('فتح القص'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('فتح القص'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('crop-corner-0')), findsOneWidget);
      await tester.drag(
        find.byKey(const Key('crop-corner-0')),
        const Offset(20, 10),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<IconButton>(find.byTooltip('تراجع')).onPressed,
        isNotNull,
      );
      await tester.tap(find.byTooltip('تراجع'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('اقتراح الحدود'));
      await tester.tap(find.text('اقتراح الحدود'));
      await tester.pumpAndSettle();
      expect(repository.values[project.id]!.revision, 0);
      await tester.tap(find.byTooltip('تراجع'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('accept-crop')))
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(find.text('معاينة التصحيح'));
      await tester.tap(find.text('معاينة التصحيح'));
      await tester.pumpAndSettle();
      expect(editor.previewCount, 1);
      expect(
        editor.lastRecipe!.geometry.corners.first.x,
        0,
        reason: 'Rejecting proposal restored the original corner',
      );
      expect(repository.values[project.id]!.revision, 0);
      await tester.ensureVisible(find.byKey(const Key('crop-brightness')));
      await tester.drag(
        find.byKey(const Key('crop-brightness')),
        const Offset(35, 0),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('accept-crop')))
            .onPressed,
        isNull,
        reason: 'An old preview cannot approve new parameters',
      );
      await tester.ensureVisible(find.text('معاينة التصحيح'));
      await tester.tap(find.text('معاينة التصحيح'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('accept-crop')));
      await tester.tap(find.byKey(const Key('accept-crop')));
      await tester.pumpAndSettle();
      expect(accepted, isNotNull);
      expect(repository.values[project.id]!.revision, 1);
      expect(accepted!.assets.single.crop, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'crossed handles cannot be processed and cancellation leaves project unchanged',
    (tester) async {
      final repository = _MemoryProjects();
      final editor = _TestEditor();
      final project = await repository.create(
        projectFixture(assets: [assetFixture()]),
      );
      final service = ProjectService(
        repository,
        _NoAssets(),
        imageEditor: editor,
      );
      await tester.pumpWidget(
        AppShell(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => CropScreen(
                      project: project,
                      asset: project.assets.single,
                      service: service,
                    ),
                  ),
                ),
                child: const Text('فتح القص'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('فتح القص'));
      await tester.pumpAndSettle();
      final start = tester.getCenter(find.byKey(const Key('crop-corner-0')));
      final end = tester.getCenter(find.byKey(const Key('crop-corner-2')));
      await tester.dragFrom(start, end - start);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('معاينة التصحيح'));
      await tester.tap(find.text('معاينة التصحيح'));
      await tester.pumpAndSettle();
      expect(editor.previewCount, 0);
      expect(repository.values[project.id]!.revision, 0);
      expect(find.textContaining('زوايا القص'), findsWidgets);
      await tester.tap(find.byTooltip('إلغاء القص'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('إلغاء التعديلات'));
      await tester.pumpAndSettle();
      expect(find.text('فتح القص'), findsOneWidget);
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

class _TestEditor implements ImageEditor {
  final bytes = img.encodePng(img.Image(width: 64, height: 40));
  int previewCount = 0;
  ImageEditRecipe? lastRecipe;
  @override
  Future<EditorSource> open(ImageAsset asset) async =>
      EditorSource(bytes, 64, 40);
  @override
  Future<List<Point2>?> suggest(Uint8List preview) async => [
    Point2(.1, .1),
    Point2(.9, .1),
    Point2(.9, .9),
    Point2(.1, .9),
  ];
  @override
  Future<Uint8List> preview(ImageAsset asset, ImageEditRecipe recipe) async {
    previewCount++;
    lastRecipe = recipe;
    return renderPerspective(bytes, recipe);
  }

  @override
  Future<ImageAsset> createRevision(
    ImageAsset asset,
    ImageEditRecipe recipe,
  ) async => ImageAsset(
    id: asset.id,
    name: asset.name,
    originalPath: asset.originalPath,
    workingPath: 'projects/project1/assets/asset1/edited.png',
    thumbnailPath: 'projects/project1/assets/asset1/edited-thumb.jpg',
    width: recipe.geometry.outputWidth,
    height: recipe.geometry.outputHeight,
    crop: recipe.geometry,
    adjustments: recipe.adjustments,
  );
}
