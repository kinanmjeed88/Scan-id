import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/presentation/app.dart';
import 'package:scan_id/presentation/crop_screen.dart';

import '../presentation/editor_harness.dart';

class _DelayedEditor implements ImageEditor {
  _DelayedEditor(this._inner);
  final LocalImageEditor _inner;
  final openedTokens = <CancellationToken?>[];
  final previewTokens = <CancellationToken?>[];
  Completer<void>? blockPreview;

  @override
  Future<EditorSource> open(
    ImageAsset asset, {
    CancellationToken? cancellation,
  }) {
    openedTokens.add(cancellation);
    return _inner.open(asset, cancellation: cancellation);
  }

  @override
  Future<List<Point2>?> suggest(Uint8List preview) async => null;

  @override
  Future<Uint8List> preview(
    ImageAsset asset,
    ImageEditRecipe recipe, {
    CancellationToken? cancellation,
  }) async {
    previewTokens.add(cancellation);
    final block = blockPreview;
    if (block != null) await block.future;
    return _inner.preview(asset, recipe, cancellation: cancellation);
  }

  @override
  Future<ImageAsset> createRevision(
    ImageAsset asset,
    ImageEditRecipe recipe,
  ) => _inner.createRevision(asset, recipe);
}

void main() {
  test('read-only isolate cancellation completes and rejects late work', () async {
    final token = CancellationToken();
    final started = Completer<void>();
    final future = runCancellableIsolate<int>(() {
      // The parent cancels while this isolate is alive. Killing it must not
      // leave the caller awaiting a result port forever.
      while (true) {}
    }, cancellation: token);
    // Isolate.spawn is asynchronous; give it one event-loop turn to start.
    unawaited(Future<void>.delayed(const Duration(milliseconds: 20), () {
      started.complete();
      token.cancel();
    }));
    await expectLater(future, throwsA(isA<OperationCancelled>()));
    expect(token.isCancelled, isTrue);
    token.cancel(); // idempotent
  });

  test('pre-cancelled editor work never opens the source', () async {
    final root = await Directory.systemTemp.createTemp('scan-cancel-');
    addTearDown(() => root.delete(recursive: true));
    final projects = await LocalProjectRepository.open(root);
    addTearDown(projects.close);
    final editor = LocalImageEditor(projects.files);
    final asset = ImageAsset(
      id: 'missing',
      name: 'missing.png',
      originalPath: 'projects/p/assets/missing/original.png',
      workingPath: 'projects/p/assets/missing/working.png',
      thumbnailPath: 'projects/p/assets/missing/thumb.jpg',
      width: 10,
      height: 10,
    );
    final token = CancellationToken()..cancel();
    await expectLater(
      editor.open(asset, cancellation: token),
      throwsA(isA<OperationCancelled>()),
    );
  });

  group('real CropScreen with local persistence', () {
    late Directory root;
    late LocalProjectRepository projects;
    late LocalAssetRepository assets;
    late _DelayedEditor editor;
    late ProjectService service;
    late Project project;
    late Uint8List original;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('scan-crop-ui-');
      projects = await LocalProjectRepository.open(root);
      assets = LocalAssetRepository(projects.files);
      editor = _DelayedEditor(LocalImageEditor(projects.files));
      service = ProjectService(projects, assets, imageEditor: editor);
      project = await service.create('دورة القص');
      final image = img.Image(width: 120, height: 80);
      img.fill(image, color: img.ColorRgb8(220, 220, 210));
      original = Uint8List.fromList(img.encodePng(image));
      project = (await service.importImages(project, [
        ImportSource('photo.png', () => Stream.value(original)),
      ])).project;
    });
    tearDown(() async {
      await projects.close();
      await root.delete(recursive: true);
    });

    Future<void> pumpScreen(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(AppShell(
        home: CropScreen(
          project: project,
          asset: project.assets.single,
          service: service,
          documentKind: DocumentKind.unifiedNationalId,
          targetItemId: project.items.single.id,
        ),
      ));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pumpAndSettle();
    }

    testWidgets('known category does not silently reshape a new manual draft', (tester) async {
      await pumpScreen(tester);
      final aspect = tester.widget<DropdownButton<double?>>(
        find.byKey(const Key('crop-aspect')),
      );
      expect(aspect.value, isNull, reason: 'measured corners are the default');
      expect(editor.openedTokens.single, isNotNull);
    });

    testWidgets('leaving the screen cancels an in-flight preview', (tester) async {
      await pumpScreen(tester);
      editor.blockPreview = Completer<void>();
      await tester.ensureVisible(find.text('معاينة التصحيح'));
      await tester.tap(find.text('معاينة التصحيح'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      expect(editor.previewTokens, hasLength(1));
      final token = editor.previewTokens.single!;
      await tester.pageBack();
      await tester.pump();
      // Dirty preview operation: cancel operation and leave via close button.
      await tester.tap(find.byTooltip('إلغاء العملية والخروج'));
      await tester.pumpAndSettle();
      expect(token.isCancelled, isTrue);
      expect(find.byType(CropScreen), findsNothing);
      final stored = await projects.get(project.id);
      expect(stored.assets.single.workingPath, project.assets.single.workingPath);
      expect(await (await assets.resolve(stored.assets.single.originalPath)).readAsBytes(), original);
    });

    testWidgets('failed metadata save keeps the draft and last accepted files', (tester) async {
      await pumpScreen(tester);
      await tester.ensureVisible(find.text('معاينة التصحيح'));
      await tester.tap(find.text('معاينة التصحيح'));
      await pumpCropPreviewResult(tester);
      // A competing metadata write makes the crop's revision stale.
      final newer = await service.rename(project, 'نسخة أحدث');
      await tester.ensureVisible(find.byKey(const Key('accept-crop')));
      await tester.tap(find.byKey(const Key('accept-crop')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pumpAndSettle();
      expect(find.byType(CropScreen), findsOneWidget);
      expect(find.byKey(const Key('crop-error')), findsOneWidget);
      final stored = await projects.get(project.id);
      expect(stored.name, newer.name);
      expect(stored.assets.single.workingPath, project.assets.single.workingPath);
      expect(await (await assets.resolve(stored.assets.single.originalPath)).readAsBytes(), original);
      // The user can return to editing and cancel without corrupting state.
      await tester.tap(find.byTooltip('إلغاء القص'));
      await tester.pumpAndSettle();
      expect(find.text('إلغاء تعديلات القص؟'), findsOneWidget);
      await tester.tap(find.text('إلغاء التعديلات'));
      await tester.pumpAndSettle();
      expect(find.byType(CropScreen), findsNothing);
    });
  });
}
