import 'dart:io';
import 'package:scan_id/presentation/export_screen.dart';
import 'package:scan_id/presentation/project_screen.dart';
import 'package:scan_id/application/project_backups.dart';
import 'package:scan_id/domain/packing.dart';
import 'package:scan_id/presentation/layout_screen.dart';

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
      for (final size in [const Size(390, 844), const Size(844, 390)]) {
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
    'packing proposal rejection writes nothing and acceptance remains undoable',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _MemoryProjects();
      final p = await repository.create(
        projectFixture(
          assets: [assetFixture()],
          items: [
            DocumentItem(
              id: 'one',
              assetId: 'asset1',
              x: 50,
              y: 50,
              width: 60,
              height: 40,
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        AppShell(
          home: LayoutScreen(
            project: p,
            service: ProjectService(repository, _NoAssets()),
            proposeLayout:
                (
                  project, {
                  required includeLocked,
                  required allowRotation,
                  required pageIndex,
                }) async => proposePacking(
                  project,
                  includeLocked: includeLocked,
                  allowRotation: allowRotation,
                  pageIndex: pageIndex,
                ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final approve in [false, true]) {
        await tester.ensureVisible(find.byKey(const Key('packing-proposal')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('packing-proposal')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('إنشاء الاقتراح'));
        await tester.pumpAndSettle();
        expect(repository.values[p.id]!.revision, 0);
        await tester.tap(
          find.text(approve ? 'اعتماد ومتابعة التحرير' : 'رفض الاقتراح'),
        );
        await tester.pumpAndSettle();
        expect(repository.values[p.id]!.revision, approve ? 1 : 0);
      }
      expect(repository.values[p.id]!.items.single.x, 10);
      await tester.tap(find.byTooltip('تراجع'));
      await tester.pumpAndSettle();
      expect(repository.values[p.id]!.items.single.x, 50);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'A4 drag and resize commit mm, undo restores, workspace mode never moves items',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _MemoryProjects();
      final p = await repository.create(
        projectFixture(
          assets: [assetFixture()],
          items: [
            DocumentItem(
              id: 'one',
              assetId: 'asset1',
              x: 30,
              y: 30,
              width: 60,
              height: 40,
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        AppShell(
          home: LayoutScreen(
            project: p,
            service: ProjectService(repository, _NoAssets()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final item = find.byKey(const Key('page-item-one'));
      await tester.timedDrag(
        item,
        const Offset(70, 45),
        const Duration(milliseconds: 400),
      );
      await tester.pumpAndSettle();
      expect(repository.values[p.id]!.items.single.x, greaterThan(30));
      expect(repository.values[p.id]!.items.single.y, greaterThan(30));
      await tester.tap(find.byTooltip('تراجع'));
      await tester.pumpAndSettle();
      expect(repository.values[p.id]!.items.single.x, 30);
      await tester.timedDrag(
        find.byKey(const Key('resize-one')),
        const Offset(70, 45),
        const Duration(milliseconds: 400),
      );
      await tester.pumpAndSettle();
      expect(repository.values[p.id]!.items.single.width, greaterThan(60));
      expect(
        repository.values[p.id]!.items.single.width /
            repository.values[p.id]!.items.single.height,
        closeTo(1.5, 1e-9),
      );
      final before = repository.values[p.id]!.toJson();
      await tester.tap(find.byKey(const Key('workspace-pan')));
      await tester.pumpAndSettle();
      final start = tester.getCenter(item);
      await tester.timedDragFrom(
        start,
        const Offset(80, 50),
        const Duration(milliseconds: 400),
      );
      await tester.pumpAndSettle();
      expect(repository.values[p.id]!.toJson(), before);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'A4 editor changes physical orientation and persists undo and redo on a phone',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _MemoryProjects();
      final p = await repository.create(projectFixture());
      await tester.pumpWidget(
        AppShell(
          home: LayoutScreen(
            project: p,
            service: ProjectService(repository, _NoAssets()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final dropdown = find.byType(DropdownButton<PaperOrientation>);
      await tester.ensureVisible(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('A4 أفقي').last);
      await tester.pumpAndSettle();
      expect(
        repository.values[p.id]!.paper.orientation,
        PaperOrientation.landscape,
      );
      await tester.tap(find.byTooltip('تراجع'));
      await tester.pumpAndSettle();
      expect(
        repository.values[p.id]!.paper.orientation,
        PaperOrientation.portrait,
      );
      await tester.tap(find.byTooltip('إعادة'));
      await tester.pumpAndSettle();
      expect(
        repository.values[p.id]!.paper.orientation,
        PaperOrientation.landscape,
      );
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
      await tester.ensureVisible(find.text('اقتراح الحدود'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('اقتراح الحدود'));
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
    'arrow keys nudge the selected A4 item, Shift scales the step, Ctrl+Z restores',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1200);
      addTearDown(tester.view.resetPhysicalSize);
      final repository = _MemoryProjects();
      final project = await repository.create(
        projectFixture(
          assets: [assetFixture()],
          items: [itemFixture().copyWith(x: 50, y: 50, locked: false)],
        ),
      );
      final service = ProjectService(repository, _NoAssets());
      await tester.pumpWidget(
        AppShell(
          home: LayoutScreen(project: project, service: service),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(FilterChip).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FilterChip).first);
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(repository.values[project.id]!.items.single.x, 51);
      expect(repository.values[project.id]!.items.single.y, 50);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(repository.values[project.id]!.items.single.y, 60);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(repository.values[project.id]!.items.single.y, 50);
      expect(repository.values[project.id]!.items.single.x, 51);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Delete removes the selected item from the sheet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.resetPhysicalSize);
    final repository = _MemoryProjects();
    final project = await repository.create(
      projectFixture(
        assets: [assetFixture()],
        items: [
          itemFixture().copyWith(x: 20, y: 50, locked: false),
          itemFixture(id: 'item2').copyWith(x: 120, y: 50, locked: false),
        ],
      ),
    );
    final service = ProjectService(repository, _NoAssets());
    await tester.pumpWidget(
      AppShell(
        home: LayoutScreen(project: project, service: service),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(FilterChip).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilterChip).first);
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();

    expect(repository.values[project.id]!.items, hasLength(1));
    expect(repository.values[project.id]!.items.single.id, 'item2');
    expect(tester.takeException(), isNull);
  });

  testWidgets('image library reorder is reachable without a drag gesture', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.resetPhysicalSize);
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
