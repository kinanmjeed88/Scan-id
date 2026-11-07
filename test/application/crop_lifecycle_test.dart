import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/imaging/docquad_model.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/presentation/app.dart';
import 'package:scan_id/presentation/crop_screen.dart';
import '../presentation/crop_tap_helpers.dart';
import '../presentation/editor_harness.dart' show pumpCropPreviewResult;

class _DelayedEditor implements ImageEditor {
  _DelayedEditor(this._inner);
  final LocalImageEditor _inner;
  final openedTokens = <CancellationToken?>[];
  final previewTokens = <CancellationToken?>[];
  Completer<void>? blockPreview;
  // What a Suggest tap returns. Null means no detection result.
  List<Point2>? suggestion;

  @override
  Future<EditorSource> open(
    ImageAsset asset, {
    CancellationToken? cancellation,
  }) {
    openedTokens.add(cancellation);
    return _inner.open(asset, cancellation: cancellation);
  }

  @override
  Future<List<Point2>?> suggest(Uint8List preview) async => suggestion;

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
  Future<ImageAsset> createRevision(ImageAsset asset, ImageEditRecipe recipe) =>
      _inner.createRevision(asset, recipe);
}

// Models/native sessions are owned by the editor on the main isolate and are
// not sendable. Open/preview/save must not capture this object graph.
class _NonSendableProposer implements BoundaryProposalModel {
  final ReceivePort port = ReceivePort();
  @override
  String get modelId => 'non-sendable-test';
  @override
  Future<BoundaryProposal?> suggestProposal(
    Uint8List preview, {
    CancellationToken? cancellation,
  }) async => null;
}

void main() {
  test(
    'read-only isolate cancellation completes and rejects late work',
    () async {
      final token = CancellationToken();
      final started = Completer<void>();
      final future = runCancellableIsolate<int>(() {
        // The parent cancels while this isolate is alive. Killing it must not
        // leave the caller awaiting a result port forever.
        while (true) {}
      }, cancellation: token);
      // Isolate.spawn is asynchronous; give it one event-loop turn to start.
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 20), () {
          started.complete();
          token.cancel();
        }),
      );
      await expectLater(future, throwsA(isA<OperationCancelled>()));
      expect(token.isCancelled, isTrue);
      token.cancel(); // idempotent
    },
  );

  test(
    'async editor wrappers stop waiting when their operation is cancelled',
    () async {
      final token = CancellationToken();
      final source = Completer<int>();
      final waiting = awaitCancellable(source.future, cancellation: token);
      token.cancel();
      await expectLater(waiting, throwsA(isA<OperationCancelled>()));
      source.complete(7); // late work is observed and discarded safely
    },
  );

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
      await tester.pumpWidget(
        AppShell(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<Project?>(
                      builder: (_) => CropScreen(
                        project: project,
                        asset: project.assets.single,
                        service: service,
                        documentKind: DocumentKind.unifiedNationalId,
                        targetItemId: null,
                      ),
                    ),
                  ),
                  child: const Text('open crop'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open crop'));
      await tester.pump();
      // The busy progress indicator animates perpetually; poll the real
      // loading state rather than pumpAndSettle on an indeterminate spinner.
      for (var attempt = 0; attempt < 80; attempt++) {
        await tester.pump(const Duration(milliseconds: 20));
        if (find.byKey(const Key('crop-aspect')).evaluate().isNotEmpty) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      expect(find.byKey(const Key('crop-aspect')), findsOneWidget);
    }

    ButtonStyleButton previewButton(WidgetTester tester) =>
        tester.widget<ButtonStyleButton>(
          find.ancestor(
            of: find.text('معاينة التصحيح'),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
          ),
        );

    ButtonStyleButton acceptButton(WidgetTester tester) =>
        tester.widget<ButtonStyleButton>(find.byKey(const Key('accept-crop')));

    Future<void> tapFourCorners(WidgetTester tester) async {
      await ensureCropTapMode(tester);
      final rect = tester.getRect(find.byKey(const Key('crop-tap-surface')));
      for (final (fx, fy) in const [
        (0.2, 0.2),
        (0.8, 0.2),
        (0.8, 0.8),
        (0.2, 0.8),
      ]) {
        await tester.tapAt(
          Offset(rect.left + rect.width * fx, rect.top + rect.height * fy),
        );
        await tester.pumpAndSettle();
      }
    }

    test(
      'real editor opens, previews and saves with a non-sendable proposer',
      () async {
        final proposer = _NonSendableProposer();
        addTearDown(proposer.port.close);
        final real = LocalImageEditor(
          projects.files,
          boundaryProposer: proposer,
        );
        final asset = project.assets.single;
        final source = await real.open(asset);
        expect(source.width, 120);
        expect(source.height, 80);
        expect(img.decodeImage(source.preview), isNotNull);
        final recipe = CropDraft(
          corners: [
            Point2(.1, .1),
            Point2(.9, .1),
            Point2(.9, .9),
            Point2(.1, .9),
          ],
        ).toRecipe(source.width, source.height);
        final preview = await real.preview(asset, recipe);
        expect(img.decodeImage(preview), isNotNull);
        final revision = await real.createRevision(asset, recipe);
        expect(revision.crop, isNotNull);
        await expectLater(
          (await assets.resolve(asset.originalPath)).readAsBytes(),
          completion(original),
        );
      },
    );

    testWidgets('real source displays and dragged corners preview and persist', (
      tester,
    ) async {
      await pumpScreen(tester);
      final sourceWidget = tester.widget<Image>(
        find.byKey(const Key('crop-source-image')),
      );
      final pixels = img.decodePng((sourceWidget.image as MemoryImage).bytes)!;
      expect((pixels.width, pixels.height), (120, 80));
      final center = pixels.getPixel(60, 40);
      expect(
        (center.r.toInt(), center.g.toInt(), center.b.toInt()),
        (220, 220, 210),
      );
      expect(find.text('تعذر عرض الصورة'), findsNothing);

      await tapFourCorners(tester);
      final corner = find.byKey(const Key('crop-corner-0'));
      final beforeDrag = tester.getCenter(corner);
      await tester.timedDrag(
        corner,
        const Offset(30, 20),
        const Duration(milliseconds: 300),
        // The visual handle is intentionally hit through the surrounding layer.
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect((tester.getCenter(corner) - beforeDrag).distance, greaterThan(5));
      await tester.ensureVisible(find.text('معاينة التصحيح'));
      await tester.tap(find.text('معاينة التصحيح'));
      await pumpCropPreviewResult(tester);
      expect(find.byKey(const Key('crop-result')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('accept-crop')));
      await tester.tap(find.byKey(const Key('accept-crop')));
      // Saving uses real filesystem and isolate work, not Flutter's fake clock.
      for (var attempt = 0; attempt < 150; attempt++) {
        await tester.pump(const Duration(milliseconds: 20));
        if (find.text('open crop').evaluate().isNotEmpty) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      expect(find.text('open crop'), findsOneWidget);
      final saved = (await tester.runAsync(() => projects.get(project.id)))!;
      final asset = saved.assets.single;
      expect(asset.userAuthoredCrop, isTrue);
      expect(asset.crop, isNotNull);
      expect(asset.crop!.corners.first.x, greaterThan(.2));
      final files = (await tester.runAsync(
        () async => (
          await (await assets.resolve(asset.originalPath)).readAsBytes(),
          await (await assets.resolve(asset.workingPath)).readAsBytes(),
        ),
      ))!;
      expect(files.$1, original);
      expect(img.decodeImage(files.$2), isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('known category does not silently reshape a new manual draft', (
      tester,
    ) async {
      await pumpScreen(tester);
      final aspect = tester.widget<DropdownButton<double?>>(
        find.byKey(const Key('crop-aspect')),
      );
      expect(aspect.value, isNull, reason: 'measured corners are the default');
      expect(editor.openedTokens.single, isNotNull);
    });

    // C3: no usable boundary means an unapproved full frame, gated until four
    // valid taps. The gate is the state, not a screen variable.
    testWidgets('no candidate starts gated; four taps lift the gate', (
      tester,
    ) async {
      await pumpScreen(tester);
      // The gate blocks Preview and Accept but does not change the input mode:
      // corners stay draggable, and tap mode opens through its toggle.
      expect(find.byKey(const Key('crop-tap-surface')), findsNothing);
      expect(find.byKey(const Key('crop-corner-0')), findsOneWidget);
      expect(find.textContaining('الكشف التلقائي لم ينجح'), findsWidgets);
      expect(previewButton(tester).onPressed, isNull);
      expect(acceptButton(tester).onPressed, isNull);

      await tapFourCorners(tester);
      expect(find.byKey(const Key('crop-tap-surface')), findsNothing);
      expect(previewButton(tester).onPressed, isNotNull);
      // Accept still needs a current preview of the completed quadrilateral.
      expect(acceptButton(tester).onPressed, isNull);
    });

    testWidgets('an invalid saved suggestion starts gated with its reason', (
      tester,
    ) async {
      final bowTie = [Point2(0, 0), Point2(1, 1), Point2(1, 0), Point2(0, 1)];
      project = project.copyWith(
        assets: [project.assets.single.withSuggestedCrop(bowTie)],
      );
      await pumpScreen(tester);
      expect(find.textContaining('الحدود المحفوظة غير صالحة'), findsWidgets);
      expect(find.byKey(const Key('crop-tap-surface')), findsNothing);
      expect(find.byKey(const Key('crop-corner-0')), findsOneWidget);
      expect(previewButton(tester).onPressed, isNull);
    });

    // C1: undo and redo restore the gate with the frame they restore.
    testWidgets('undo after fallback never restores an ungated full frame', (
      tester,
    ) async {
      await pumpScreen(tester);
      await tapFourCorners(tester);
      expect(previewButton(tester).onPressed, isNotNull);

      await tester.tap(find.byTooltip('تراجع'));
      await tester.pumpAndSettle();
      // Undo returns to the gated frame: corners draggable, tap mode off.
      expect(find.byKey(const Key('crop-tap-surface')), findsNothing);
      expect(find.byKey(const Key('crop-corner-0')), findsOneWidget);
      expect(previewButton(tester).onPressed, isNull);
      expect(acceptButton(tester).onPressed, isNull);
      expect(find.textContaining('الكشف التلقائي لم ينجح'), findsWidgets);

      await tester.tap(find.byTooltip('إعادة'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('crop-tap-surface')), findsNothing);
      expect(previewButton(tester).onPressed, isNotNull);
    });

    // F-K: an adjustment stores the full frame in `crop` without a decision.
    // That is not a saved crop, so the base frame is still gated.
    testWidgets('an adjusted full frame is not a saved crop', (tester) async {
      final asset = project.assets.single;
      final stored = ImageAsset(
        id: asset.id,
        name: asset.name,
        originalPath: asset.originalPath,
        workingPath: asset.workingPath,
        thumbnailPath: asset.thumbnailPath,
        width: asset.width,
        height: asset.height,
        crop: CropGeometry(
          corners: [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)],
          outputWidth: asset.width,
          outputHeight: asset.height,
        ),
      );
      expect(stored.hasApprovedCrop, isFalse);
      project = project.copyWith(assets: [stored]);
      await pumpScreen(tester);
      expect(previewButton(tester).onPressed, isNull);
      expect(acceptButton(tester).onPressed, isNull);
    });

    // C1/F-K: restoring the original full frame is an unapproved state, so it
    // is gated again, as Undo to the starting frame is.
    testWidgets('restoring the full frame re-gates Preview and Accept', (
      tester,
    ) async {
      await pumpScreen(tester);
      await tapFourCorners(tester);
      expect(previewButton(tester).onPressed, isNotNull);

      await tester.ensureVisible(find.text('إعادة ضبط إلى الأصل'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('إعادة ضبط إلى الأصل'));
      await tester.pumpAndSettle();
      expect(previewButton(tester).onPressed, isNull);
      expect(acceptButton(tester).onPressed, isNull);
    });

    // C2: only a valid suggestion lifts the gate.
    testWidgets('a valid suggestion after fallback lifts the gate', (
      tester,
    ) async {
      await pumpScreen(tester);
      editor.suggestion = [
        Point2(.1, .1),
        Point2(.9, .1),
        Point2(.9, .9),
        Point2(.1, .9),
      ];
      await tester.tap(find.text('اقتراح حدود المستمسك'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('crop-tap-surface')), findsNothing);
      expect(previewButton(tester).onPressed, isNotNull);
    });

    testWidgets('a malformed suggestion after fallback keeps the gate', (
      tester,
    ) async {
      await pumpScreen(tester);
      editor.suggestion = [
        Point2(0, 0),
        Point2(1, 1),
        Point2(1, 0),
        Point2(0, 1),
      ];
      await tester.tap(find.text('اقتراح حدود المستمسك'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('crop-tap-surface')), findsOneWidget);
      expect(previewButton(tester).onPressed, isNull);
      expect(acceptButton(tester).onPressed, isNull);
      expect(
        find.textContaining('لا يحتوي على أربع زوايا صالحة'),
        findsWidgets,
      );
    });
  });
}
