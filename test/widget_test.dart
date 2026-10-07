import 'dart:io';
import 'package:scan_id/application/output_service.dart';
import 'package:scan_id/domain/export_naming.dart';
import 'package:scan_id/export/document_exporter.dart';
import 'package:scan_id/presentation/export_screen.dart';
import 'package:scan_id/presentation/project_screen.dart';
import 'package:scan_id/application/project_backups.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  WidgetController.hitTestWarningShouldBeFatal = true;
  testWidgets(
    'project, home and final export remain usable on short landscape and narrow portrait',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _MemoryProjects();
      final p = await repository.create(
        projectFixture(
          assets: [assetFixture()],
          items: [itemFixture().copyWith(x: 50, y: 50)],
        ),
      );
      final service = ProjectService(
        repository,
        _NoAssets(),
        backups: _UnusedBackups(),
      );
      for (final size in [
        const Size(390, 844),
        const Size(844, 390),
        const Size(320, 640),
      ]) {
        tester.view.physicalSize = size;
        for (final screen in <Widget>[
          ProjectsScreen(service: service, pickImages: () async => []),
          ProjectScreen(
            project: p,
            service: service,
            pickImages: () async => [],
          ),
          ExportScreen(project: p, service: service),
        ]) {
          await tester.pumpWidget(AppShell(home: screen));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      }
    },
  );
  testWidgets(
    'export requires renewed preview approval after settings change',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final p = projectFixture(
        assets: [assetFixture()],
        items: [itemFixture().copyWith(x: 50, y: 50)],
      );
      await tester.pumpWidget(
        AppShell(
          home: ExportScreen(
            project: p,
            service: ProjectService(_MemoryProjects(), _NoAssets()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final export = find.widgetWithText(FilledButton, 'تصدير الملفات');
      expect(tester.widget<FilledButton>(export).onPressed, isNull);
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(export).onPressed, isNotNull);
      final format = find.byType(DropdownButton<ExportFormat>);
      await tester.ensureVisible(format);
      await tester.pumpAndSettle();
      await tester.tap(format);
      await tester.pumpAndSettle();
      await tester.tap(find.text('PNG').last);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(export).onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );
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
      await tester.tap(find.byTooltip('إضافة صور'));
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
      for (var i = 0; i < 4; i++) {
        final corner = find.byKey(Key('crop-corner-$i'));
        final before = tester.getCenter(corner);
        // Send multiple move events beyond pan slop, as a real finger does.
        await tester.timedDrag(
          corner,
          Offset(i == 0 || i == 3 ? 60 : -60, i < 2 ? 40 : -40),
          const Duration(milliseconds: 300),
        );
        await tester.pumpAndSettle();
        expect(
          (tester.getCenter(corner) - before).distance,
          greaterThan(10),
          reason: 'Corner $i must be draggable from its visible centre',
        );
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (w) => w is IconButton && w.tooltip == 'تراجع',
                ),
              )
              .onPressed,
          isNotNull,
        );
        await tester.tap(find.byTooltip('تراجع'));
        await tester.pumpAndSettle();
        expect((tester.getCenter(corner) - before).distance, lessThan(.01));
      }
      await tester.ensureVisible(find.text('اقتراح حدود المستمسك'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('اقتراح حدود المستمسك'));
      await tester.pumpAndSettle();
      // Let the real four-second feedback snackbar expire before tapping
      // controls underneath it. pumpAndSettle does not advance idle timers.
      await tester.pump(const Duration(seconds: 5));
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
      await tester.pumpAndSettle();
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
      await tester.pumpAndSettle();
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
      await tester.pumpAndSettle();
      await tester.tap(find.text('معاينة التصحيح'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('accept-crop')));
      await tester.pumpAndSettle();
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
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
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
      await tester.pumpAndSettle();
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

  testWidgets(
    'the export screen shares the generated files on platforms that can, and reports the result',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final p = projectFixture(
        assets: [assetFixture()],
        items: [itemFixture().copyWith(x: 50, y: 50)],
      ).copyWith(exportProfile: ExportProfile(format: ExportFormat.png));
      final handed = <List<String>>[];
      final output = OutputService(
        // No real file I/O here: widget tests run in a fake-async zone where
        // file futures would never complete, leaving the screen busy forever.
        generate: (plan, directory) async => ExportBundle([
          '${directory.path}/$exportDirectoryName/fake/'
              '${exportNames(plan).pages.first}',
        ]),
        temporary: () async => Directory('/fake-cache'),
        save: (_, _) async => true,
        printPdf: (_, _) async => false,
        shareTarget: ShareTarget.shareSheet,
        share: (paths, mime) async {
          handed.add(paths);
          expect(mime, 'image/png');
          return true;
        },
      );
      await tester.pumpWidget(
        AppShell(
          home: ExportScreen(
            project: p,
            service: ProjectService(_MemoryProjects(), _NoAssets()),
            output: output,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('مستمسكات العائلة'), findsWidgets);
      final share = find.byKey(const Key('export-share'));
      await tester.ensureVisible(share);
      await tester.pumpAndSettle();
      expect(
        tester.widget<OutlinedButton>(share).onPressed,
        isNull,
        reason: 'لا مشاركة قبل مراجعة المستخدم',
      );
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(share).onPressed, isNotNull);
      await tester.ensureVisible(share);
      await tester.pumpAndSettle();
      await tester.tap(share);
      // The export pipeline is real asynchronous work, so it runs in the real
      // zone and its result is applied on the next frame. Waiting only on
      // animations here would hang instead of failing.
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();

      expect(handed, hasLength(1), reason: 'يجب أن تُسلَّم الملفات مرة واحدة');
      expect(handed.single.single, endsWith('مستمسكات العائلة-صفحة-1.png'));
      expect(find.textContaining('تطبيق المشاركة'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('image library reorder is reachable without a drag gesture', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _MemoryProjects();
    final project = await repository.create(
      projectFixture(
        assets: [
          assetFixture(id: 'asset1'),
          assetFixture(id: 'asset2'),
        ],
      ),
    );
    final service = ProjectService(repository, _NoAssets());
    await tester.pumpWidget(
      AppShell(
        home: ProjectScreen(
          project: project,
          service: service,
          pickImages: () async => [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('خيارات الصورة').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('نقل إلى ترتيب لاحق'));
    await tester.pumpAndSettle();

    expect(repository.values[project.id]!.assets.map((a) => a.id), [
      'asset2',
      'asset1',
    ]);
    expect(tester.takeException(), isNull);
  });
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
  Future<ReplacementFiles> replaceImage(
    String projectId,
    String assetId,
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

class _UnusedBackups implements ProjectBackups {
  @override
  Future<File> create(Project project, Directory temporary) => throw StateError(
    'Native transfer is not invoked by the responsive layout test',
  );
  @override
  Future<Project> restore(File source) => throw StateError(
    'Native transfer is not invoked by the responsive layout test',
  );
}
