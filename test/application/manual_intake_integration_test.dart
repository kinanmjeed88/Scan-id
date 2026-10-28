import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/application/smart_recognition.dart';
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_routing.dart';
import 'package:scan_id/application/recognition_pipeline.dart';
import 'package:scan_id/imaging/document_segmenter.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/persistence/safe_files.dart';
import 'package:scan_id/presentation/crop_screen.dart';

import '../fixtures.dart';
import '../presentation/editor_harness.dart';

class _UncertainBoundaryEditor implements BoundaryProposalImageEditor {
  _UncertainBoundaryEditor(this._inner, this._proposal);

  final LocalImageEditor _inner;
  final BoundaryProposal _proposal;

  @override
  String? get boundaryModelId => 'synthetic-boundary-review-test';

  @override
  Future<EditorSource> open(ImageAsset asset) => _inner.open(asset);

  @override
  Future<List<Point2>?> suggest(Uint8List preview) async => _proposal.corners;

  @override
  Future<BoundaryProposal?> suggestProposal(Uint8List preview) async =>
      _proposal;

  Future<SegmentationResult> segment(Uint8List preview) async =>
      const SegmentationResult(multi: false, candidates: <SegmentCandidate>[]);

  @override
  Future<Uint8List> preview(ImageAsset asset, ImageEditRecipe recipe) =>
      _inner.preview(asset, recipe);

  @override
  Future<ImageAsset> createRevision(ImageAsset asset, ImageEditRecipe recipe) =>
      _inner.createRevision(asset, recipe);
}

class _TrackingFakeEditor extends FakeImageEditor {
  ImageEditRecipe? lastPreviewRecipe;
  String? lastPreviewAssetId;

  @override
  Future<Uint8List> preview(ImageAsset asset, ImageEditRecipe recipe) async {
    lastPreviewAssetId = asset.id;
    lastPreviewRecipe = recipe;
    return super.preview(asset, recipe);
  }
}

class _RefreshingFakeEditor extends _TrackingFakeEditor
    implements BoundaryProposalImageEditor {
  _RefreshingFakeEditor(this._proposal);

  final BoundaryProposal? _proposal;
  int refreshCount = 0;

  @override
  String? get boundaryModelId => 'synthetic-review-test';

  @override
  Future<BoundaryProposal?> suggestProposal(Uint8List preview) async {
    refreshCount++;
    return _proposal;
  }
}

class _ControlledBoundaryEditor extends _TrackingFakeEditor
    implements BoundaryProposalImageEditor {
  BoundaryProposal? proposal;
  Object? refreshError;
  Completer<BoundaryProposal?>? pendingRefresh;
  int refreshCount = 0;

  @override
  String? get boundaryModelId => 'synthetic-controlled-review-test';

  @override
  Future<BoundaryProposal?> suggestProposal(Uint8List preview) {
    refreshCount++;
    final pending = pendingRefresh;
    if (pending != null) return pending.future;
    final error = refreshError;
    if (error != null) return Future<BoundaryProposal?>.error(error);
    return Future.value(proposal);
  }
}

class _InvalidPreviewEditor extends FakeImageEditor {
  @override
  Future<Uint8List> preview(ImageAsset asset, ImageEditRecipe recipe) async =>
      Uint8List.fromList([0x01, 0x02, 0x03]);
}

void main() {
  test(
    'production import leaves a multi-region image intact for manual review',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'scanid_manual_only_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final files = SafeFiles(tempDir);
      final assets = LocalAssetRepository(files);
      final projects = await LocalProjectRepository.open(tempDir);
      addTearDown(projects.close);
      final editor = LocalImageEditor(files);
      final service = ProjectService(projects, assets, imageEditor: editor);
      final sourceBytes = File(
        'test/fixtures/synthetic_two_cards.png',
      ).readAsBytesSync();

      var project = await service.create('manual-only boundary intake');
      project = (await service.importImages(project, [
        ImportSource('two_regions.png', () => Stream.value(sourceBytes)),
      ])).project;
      final sourceId = project.assets.single.id;
      final report = await service.arrangeImportedImages(project, [sourceId]);
      project = report.project;

      expect(service.smartRecognitionEnabled, isFalse);
      expect(service.multiDocumentSegmentationEnabled, isFalse);
      expect(project.assets, hasLength(1));
      expect(project.assets.single.crop, isNull);
      expect(project.assets.single.suggestedCrop, isNull);
      expect(project.assets.single.derivedFrom, isNull);
      expect(project.items, hasLength(1));
      expect(project.items.single.documentKind, DocumentKind.unknown);
      expect(project.items.single.pageIndex, isNull);
      expect(
        report.warnings.join(' '),
        contains('لا يتوفر كشف تلقائي للحدود'),
      );
      expect(await editor.suggest(Uint8List.fromList(sourceBytes)), isNull);
      expect(
        (await defaultSegment(Uint8List.fromList(sourceBytes))).candidates,
        isEmpty,
      );
      expect(
        await (await assets.resolve(project.assets.single.originalPath))
            .readAsBytes(),
        sourceBytes,
      );
    },
  );

  test(
    'injected boundary proposal remains review-only and persists suggestedCrop on ImageAsset',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('scanid_ai_safe_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final files = SafeFiles(tempDir);
      final assets = LocalAssetRepository(files);
      final projects = await LocalProjectRepository.open(tempDir);
      addTearDown(projects.close);
      final innerEditor = LocalImageEditor(files);
      // Geometrically valid partial-document strip. Keep the fixture synthetic;
      // never add private identity photos to CI.
      final proposedQuad = [
        Point2(0.06, 0.48),
        Point2(0.87, 0.51),
        Point2(0.85, 0.83),
        Point2(0.07, 0.85),
      ];
      final uncertainEditor = _UncertainBoundaryEditor(
        innerEditor,
        BoundaryProposal(
          producer: BoundaryProducer.learnedModel,
          corners: proposedQuad,
          modelConfidence: 0.42, // below minAutoAcceptConfidence -> needsReview
          minAutoAcceptConfidence: 0.55,
          touchesFrameEdge: false,
        ),
      );
      final service = ProjectService(
        projects,
        assets,
        imageEditor: uncertainEditor,
        segmenter: uncertainEditor.segment,
      );

      final goldenBytes = File(
        'test/fixtures/synthetic_card.png',
      ).readAsBytesSync();
      var project = await service.create('حدود غير مؤكدة في المسار الافتراضي');
      project = (await service.importImages(project, [
        ImportSource('uncertain.png', () => Stream.value(goldenBytes)),
      ])).project;

      final arranged = await service.arrangeImportedImages(project, [
        project.assets.single.id,
      ]);
      final reloaded = await projects.get(arranged.project.id);
      final savedAsset = reloaded.assets.single;
      final savedItem = reloaded.items.single;

      expect(savedAsset.crop, isNull, reason: 'must never silently crop');
      expect(savedItem.documentKind, DocumentKind.unknown);
      expect(savedItem.pageIndex, isNull);
      expect(
        savedItem.sizeConfirmed,
        isFalse,
        reason: 'must never silently confirm physical print size',
      );
      expect(savedAsset.suggestedCrop, hasLength(4));
      for (var i = 0; i < 4; i++) {
        expect(
          savedAsset.suggestedCrop![i].x,
          closeTo(proposedQuad[i].x, 1e-9),
        );
        expect(
          savedAsset.suggestedCrop![i].y,
          closeTo(proposedQuad[i].y, 1e-9),
        );
      }
      expect(arranged.warnings, isNotEmpty);

      // SmartIntake path on a fresh unplaced asset also keeps crop null and stores suggestedPolygon on DocumentRecord
      final smartImported = (await service.importImages(reloaded, [
        ImportSource('uncertain_smart.png', () => Stream.value(goldenBytes)),
      ])).project;
      final smartAssetId = smartImported.assets.last.id;
      final intake = SmartIntake(
        projects: projects,
        assets: assets,
        editor: uncertainEditor,
        segment: (_) async => const SegmentationResult(
          multi: false,
          candidates: <SegmentCandidate>[],
        ),
      );
      final report = await intake.run(smartImported, [smartAssetId]);
      final doc = report.project.documents.single;
      final smartAsset = report.project.assets.firstWhere(
        (a) => a.id == smartAssetId,
      );
      expect(smartAsset.crop, isNull);
      expect(hasUnresolvedBoundary(doc), isTrue);
      expect(doc.sides.single.detection?.polygon, isNull);
      expect(doc.sides.single.detection?.suggestedPolygon, hasLength(4));
      for (var i = 0; i < 4; i++) {
        expect(
          doc.sides.single.detection!.suggestedPolygon![i].x,
          closeTo(proposedQuad[i].x, 1e-9),
        );
        expect(
          doc.sides.single.detection!.suggestedPolygon![i].y,
          closeTo(proposedQuad[i].y, 1e-9),
        );
      }
    },
  );

  testWidgets(
    'CropScreen keeps a narrow suggested strip review-only, requires preview, and saves the reviewed geometry',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Geometrically valid partial-document strip. Keep the fixture synthetic;
      // never add private identity photos to CI.
      final proposedQuad = [
        Point2(0.06, 0.48),
        Point2(0.87, 0.51),
        Point2(0.85, 0.83),
        Point2(0.07, 0.85),
      ];
      final repository = MemoryProjects();
      final editor = _TrackingFakeEditor();
      final asset = assetFixture(
        id: 'asset-uncertain',
      ).withSuggestedCrop(proposedQuad);
      final initialProject = await repository.create(
        projectFixture(assets: [asset]),
      );
      final service = ProjectService(
        repository,
        NoAssets(),
        imageEditor: editor,
      );

      Project? accepted;
      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    key: const Key('open-crop'),
                    onPressed: () async {
                      accepted = await Navigator.push<Project>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => CropScreen(
                            project: initialProject,
                            asset: asset,
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
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('open-crop')));
      await tester.pumpAndSettle();

      // Banner confirms the narrow strip is only an unapplied proposal.
      expect(find.byKey(const Key('crop-proposed-banner')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('accept-crop')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('accept-crop')))
            .onPressed,
        isNull,
        reason: 'a proposal cannot be saved before previewing its crop',
      );

      // 1-tap Undo reverts to full image (corners[0] == (0, 0)) and hides review banner
      await tester.tap(find.byTooltip('تراجع'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('crop-proposed-banner')), findsNothing);

      await tester.ensureVisible(find.text('معاينة التصحيح'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('معاينة التصحيح'));
      await pumpCropPreviewResult(tester);
      await tester.pumpAndSettle();
      expect(editor.lastPreviewRecipe!.geometry.corners.first.x, 0);

      // Redo restores proposed quad, then preview and accept manual crop.
      await tester.tap(find.byTooltip('إعادة'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('accept-crop')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('accept-crop')))
            .onPressed,
        isNull,
        reason: 'redo changes the recipe, so the previous preview is stale',
      );
      await tester.ensureVisible(find.text('معاينة التصحيح'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('معاينة التصحيح'));
      await pumpCropPreviewResult(tester);
      await tester.pumpAndSettle();
      expect(
        editor.lastPreviewRecipe!.geometry.corners.first.x,
        closeTo(proposedQuad.first.x, 1e-6),
      );

      await tester.ensureVisible(find.byKey(const Key('accept-crop')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('accept-crop')));
      await tester.pumpAndSettle();

      expect(accepted, isNotNull);
      final savedAsset = accepted!.assets.single;
      expect(savedAsset.crop, isNotNull);
      expect(savedAsset.userAuthoredCrop, isTrue);
      expect(savedAsset.suggestedCrop, isNull);
      for (var i = 0; i < 4; i++) {
        expect(
          savedAsset.crop!.corners[i].x,
          closeTo(editor.lastPreviewRecipe!.geometry.corners[i].x, 1e-9),
        );
        expect(
          savedAsset.crop!.corners[i].y,
          closeTo(editor.lastPreviewRecipe!.geometry.corners[i].y, 1e-9),
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'CropScreen refreshes an unversioned saved suggestion but keeps the fresh proposal review-only',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final staleStrip = [
        Point2(0.06, 0.48),
        Point2(0.87, 0.51),
        Point2(0.85, 0.83),
        Point2(0.07, 0.85),
      ];
      final currentQuad = [
        Point2(0.12, 0.12),
        Point2(0.88, 0.12),
        Point2(0.88, 0.88),
        Point2(0.12, 0.88),
      ];
      final currentProposal = BoundaryProposal(
        producer: BoundaryProducer.learnedModel,
        corners: currentQuad,
        modelConfidence: 0.42,
        minAutoAcceptConfidence: 0.55,
      );
      final repository = MemoryProjects();
      final editor = _RefreshingFakeEditor(currentProposal);
      final asset = assetFixture(
        id: 'asset-refresh-review',
      ).withSuggestedCrop(staleStrip);
      final initialProject = await repository.create(
        projectFixture(assets: [asset]),
      );
      final service = ProjectService(
        repository,
        NoAssets(),
        imageEditor: editor,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    key: const Key('open-crop-refresh'),
                    onPressed: () => Navigator.push<Project>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => CropScreen(
                          project: initialProject,
                          asset: asset,
                          service: service,
                        ),
                      ),
                    ),
                    child: const Text('فتح القص'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('open-crop-refresh')));
      await tester.pumpAndSettle();
      expect(editor.refreshCount, 1);
      expect(find.byKey(const Key('crop-proposed-banner')), findsOneWidget);
      expect(
        verifyBoundary(currentProposal, sourceWidth: 64, sourceHeight: 40).kind,
        BoundaryDecisionKind.needsReview,
      );

      expect(find.byKey(const Key('crop-proposal-status')), findsOneWidget);
      // Refresh replaces only the review outline: Undo exposes the saved
      // suggestion again, and Redo restores the fresh local proposal.
      await tester.tap(find.byTooltip('تراجع'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('معاينة التصحيح'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('معاينة التصحيح'));
      await pumpCropPreviewResult(tester);
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        expect(
          editor.lastPreviewRecipe!.geometry.corners[i].x,
          closeTo(staleStrip[i].x, 1e-9),
        );
      }

      await tester.tap(find.byTooltip('إعادة'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('معاينة التصحيح'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('معاينة التصحيح'));
      await pumpCropPreviewResult(tester);
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        expect(
          editor.lastPreviewRecipe!.geometry.corners[i].x,
          closeTo(currentQuad[i].x, 1e-9),
        );
        expect(
          editor.lastPreviewRecipe!.geometry.corners[i].y,
          closeTo(currentQuad[i].y, 1e-9),
        );
      }

      final unchanged = await repository.get(initialProject.id);
      expect(unchanged.assets.single.crop, isNull);
      expect(unchanged.assets.single.suggestedCrop, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'CropScreen reports failed refresh and keeps the saved review boundary',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final savedQuad = [
        Point2(0.06, 0.48),
        Point2(0.87, 0.51),
        Point2(0.85, 0.83),
        Point2(0.07, 0.85),
      ];
      final repository = MemoryProjects();
      final editor = _ControlledBoundaryEditor()
        ..refreshError = StateError('synthetic offline refresh');
      final asset = assetFixture(
        id: 'asset-refresh-failure',
      ).withSuggestedCrop(savedQuad);
      final project = await repository.create(projectFixture(assets: [asset]));
      final service = ProjectService(
        repository,
        NoAssets(),
        imageEditor: editor,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: CropScreen(project: project, asset: asset, service: service),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(editor.refreshCount, 1);
      expect(find.byKey(const Key('crop-proposed-banner')), findsOneWidget);
      expect(find.byKey(const Key('crop-proposal-status')), findsOneWidget);
      expect(find.textContaining('تعذر تحديث الاقتراح'), findsOneWidget);
      await tester.ensureVisible(find.text('معاينة التصحيح'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('معاينة التصحيح'));
      await pumpCropPreviewResult(tester);
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        expect(
          editor.lastPreviewRecipe!.geometry.corners[i].x,
          closeTo(savedQuad[i].x, 1e-9),
        );
        expect(
          editor.lastPreviewRecipe!.geometry.corners[i].y,
          closeTo(savedQuad[i].y, 1e-9),
        );
      }
      final unchanged = await repository.get(project.id);
      expect(unchanged.assets.single.crop, isNull);
      expect(unchanged.assets.single.suggestedCrop, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'CropScreen rejects empty or malformed suggestions without replacing current corners',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repository = MemoryProjects();
      final editor = _ControlledBoundaryEditor()
        ..proposal = BoundaryProposal(
          producer: BoundaryProducer.learnedModel,
          corners: [Point2(0.1, 0.1), Point2(0.9, 0.1), Point2(0.9, 0.9)],
          modelConfidence: 0.91,
          minAutoAcceptConfidence: 0.55,
        );
      final asset = assetFixture(id: 'asset-invalid-suggestion');
      final project = await repository.create(projectFixture(assets: [asset]));
      final service = ProjectService(
        repository,
        NoAssets(),
        imageEditor: editor,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: CropScreen(project: project, asset: asset, service: service),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('اقتراح حدود المستمسك'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('اقتراح حدود المستمسك'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('لا يحتوي على أربع زوايا صالحة'),
        findsOneWidget,
      );

      await tester.ensureVisible(find.text('معاينة التصحيح'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('معاينة التصحيح'));
      await pumpCropPreviewResult(tester);
      await tester.pumpAndSettle();
      expect(editor.lastPreviewRecipe!.geometry.corners.first.x, 0);

      editor.proposal = null;
      await tester.ensureVisible(find.text('اقتراح حدود المستمسك'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('اقتراح حدود المستمسك'));
      await tester.pumpAndSettle();
      expect(find.textContaining('لم يظهر اقتراح جديد'), findsOneWidget);
      expect(editor.lastPreviewRecipe!.geometry.corners.first.x, 0);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('accept-crop')))
            .onPressed,
        isNotNull,
        reason:
            'the still-current valid preview remains available after an empty refresh',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('CropScreen never enables save for an undecodable crop preview', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = MemoryProjects();
    final editor = _InvalidPreviewEditor();
    final asset = assetFixture(id: 'asset-invalid-preview');
    final project = await repository.create(projectFixture(assets: [asset]));
    final service = ProjectService(repository, NoAssets(), imageEditor: editor);

    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: CropScreen(project: project, asset: asset, service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('معاينة التصحيح'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('معاينة التصحيح'));
    await pumpCropPreviewResult(
      tester,
      expectedErrorContaining: 'معاينة القص غير صالحة',
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('معاينة القص غير صالحة'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('accept-crop')))
          .onPressed,
      isNull,
    );
    expect(editor.revisions, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'CropScreen discards a late AI refresh when the edited asset changes',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final savedQuad = [
        Point2(0.06, 0.48),
        Point2(0.87, 0.51),
        Point2(0.85, 0.83),
        Point2(0.07, 0.85),
      ];
      final firstAsset = assetFixture(
        id: 'asset-switch-first',
      ).withSuggestedCrop(savedQuad);
      final secondAsset = assetFixture(id: 'asset-switch-second');
      final repository = MemoryProjects();
      final editor = _ControlledBoundaryEditor()
        ..pendingRefresh = Completer<BoundaryProposal?>();
      final project = await repository.create(
        projectFixture(assets: [firstAsset, secondAsset]),
      );
      final service = ProjectService(
        repository,
        NoAssets(),
        imageEditor: editor,
      );
      var selectedAsset = firstAsset;
      late StateSetter replaceAsset;

      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: StatefulBuilder(
              builder: (context, setState) {
                replaceAsset = setState;
                return CropScreen(
                  key: const ValueKey('reused-crop-route'),
                  project: project,
                  asset: selectedAsset,
                  service: service,
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(editor.refreshCount, 1);

      replaceAsset(() => selectedAsset = secondAsset);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('crop-proposed-banner')), findsNothing);

      editor.pendingRefresh!.complete(
        BoundaryProposal(
          producer: BoundaryProducer.learnedModel,
          corners: [
            Point2(0.12, 0.12),
            Point2(0.88, 0.12),
            Point2(0.88, 0.88),
            Point2(0.12, 0.88),
          ],
          modelConfidence: 0.48,
          minAutoAcceptConfidence: 0.55,
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('crop-proposed-banner')), findsNothing);

      await tester.ensureVisible(find.text('معاينة التصحيح'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('معاينة التصحيح'));
      await pumpCropPreviewResult(tester);
      await tester.pumpAndSettle();
      expect(editor.lastPreviewAssetId, secondAsset.id);
      expect(editor.lastPreviewRecipe!.geometry.corners.first.x, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'CropScreen can cancel an in-flight AI refresh and ignore its late completion',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final savedQuad = [
        Point2(0.06, 0.48),
        Point2(0.87, 0.51),
        Point2(0.85, 0.83),
        Point2(0.07, 0.85),
      ];
      final repository = MemoryProjects();
      final editor = _ControlledBoundaryEditor()
        ..pendingRefresh = Completer<BoundaryProposal?>();
      final asset = assetFixture(
        id: 'asset-cancel-refresh',
      ).withSuggestedCrop(savedQuad);
      final project = await repository.create(projectFixture(assets: [asset]));
      final service = ProjectService(
        repository,
        NoAssets(),
        imageEditor: editor,
      );
      Project? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    key: const Key('open-cancel-refresh'),
                    onPressed: () async {
                      result = await Navigator.push<Project>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => CropScreen(
                            project: project,
                            asset: asset,
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
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open-cancel-refresh')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(editor.refreshCount, 1);
      expect(find.byTooltip('إلغاء العملية والخروج'), findsOneWidget);

      await tester.tap(find.byTooltip('إلغاء العملية والخروج'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('open-cancel-refresh')), findsOneWidget);
      expect(result, isNull);

      editor.pendingRefresh!.complete(null);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final unchanged = await repository.get(project.id);
      expect(unchanged.assets.single.crop, isNull);
      expect(unchanged.assets.single.suggestedCrop, isNotNull);
    },
  );

  testWidgets(
    'ReviewScreen renders ضبط الحدود for unresolved boundary and opens CropScreen with suggestedPolygon',
    (tester) async {
      final proposedQuad = [
        Point2(0.15, 0.17),
        Point2(0.85, 0.19),
        Point2(0.83, 0.79),
        Point2(0.13, 0.77),
      ];
      final rawAsset = assetFixture(id: 'asset1');
      final provisional = provisionalSize(
        width: rawAsset.width,
        height: rawAsset.height,
      );
      final doc = DocumentRecord(
        id: 'rec-uncertain',
        sourceImageId: rawAsset.id,
        sides: [
          DocumentSide(
            id: 'side-0',
            side: SideKind.unknown,
            detection: DetectionRef(
              detectionId: 'det-0',
              producer: 'scanid_docnet_v1',
              version: '1.0',
              detectionConfidence: Confidence(value: 0.44),
              polygon: null,
              suggestedPolygon: proposedQuad,
              bbox: RectMm(0.12, 0.15, 0.75, 0.66),
            ),
            processedAsset: ProcessedAssetRef(
              workingPath: rawAsset.workingPath,
              thumbnailPath: rawAsset.thumbnailPath,
              width: rawAsset.width,
              height: rawAsset.height,
            ),
          ),
        ],
        recognition: RecognitionResult(
          documentKind: DocumentKind.unknown,
          status: RecognitionStatus.unknown,
          confidences: ConfidenceSet(),
          preset: const PresetSelection.awaiting(),
        ),
        pairing: PairingState.single,
        provenance: Provenance(
          sourceImageId: rawAsset.id,
          detectionIds: const ['det-0'],
          processedAssetVersion: 'smart-1',
          pipelineVersion: 'smart-1',
        ),
      );
      final project = editorProject(
        items: [
          DocumentItem(
            id: 'item-raw',
            assetId: rawAsset.id,
            x: 10,
            y: 10,
            width: provisional.width,
            height: provisional.height,
            sizeConfirmed: false,
            documentId: doc.id,
            sideId: 'side-0',
          ),
        ],
        documents: [doc],
      );

      await EditorHarness.pump(
        tester,
        project: project,
        imageEditor: FakeImageEditor(),
      );
      await tapKey(tester, const Key('rb-review'));
      expect(
        find.byKey(const Key('review-crop-rec-uncertain')),
        findsOneWidget,
      );
      await tapKey(tester, const Key('review-crop-rec-uncertain'));
      expect(find.byKey(const Key('crop-proposed-banner')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
