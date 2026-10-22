import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/application/smart_recognition.dart';
import 'package:scan_id/domain/boundary_decision.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/export_plan.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_routing.dart';
import 'package:scan_id/export/document_exporter.dart';
import 'package:scan_id/imaging/ai_document_detector.dart';
import 'package:scan_id/main.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/persistence/safe_files.dart';
import 'package:scan_id/presentation/crop_screen.dart';

import '../fixtures.dart';
import '../presentation/editor_harness.dart';

AiModelBundle _loadBundleFromRepo() {
  final manifestJson = File(
    'assets/models/MODEL_MANIFEST.json',
  ).readAsStringSync();
  final s1 = File('assets/models/scanid_stage1_det_v1.onnx').readAsBytesSync();
  final s2 = File(
    'assets/models/scanid_stage2_corners_v1.onnx',
  ).readAsBytesSync();
  return AiModelBundle.verified(
    manifestJson: manifestJson,
    stage1Bytes: s1,
    stage2Bytes: s2,
  );
}

class _UncertainAiEditor implements ImageEditor {
  _UncertainAiEditor(this._inner, this._proposal);

  final LocalImageEditor _inner;
  final BoundaryProposal _proposal;

  @override
  Future<EditorSource> open(ImageAsset asset) => _inner.open(asset);

  @override
  Future<List<Point2>?> suggest(Uint8List preview) async => _proposal.corners;

  @override
  Future<BoundaryProposal?> suggestProposal(Uint8List preview) async =>
      _proposal;

  @override
  Future<SegmentationResult> segment(Uint8List preview) async =>
      const SegmentationResult(multi: false, candidates: []);

  @override
  Future<Uint8List> preview(ImageAsset asset, ImageEditRecipe recipe) =>
      _inner.preview(asset, recipe);

  @override
  Future<ImageAsset> createRevision(ImageAsset asset, ImageEditRecipe recipe) =>
      _inner.createRevision(asset, recipe);
}

class _TrackingFakeEditor extends FakeImageEditor {
  ImageEditRecipe? lastPreviewRecipe;

  @override
  Future<Uint8List> preview(ImageAsset asset, ImageEditRecipe recipe) async {
    lastPreviewRecipe = recipe;
    return super.preview(asset, recipe);
  }
}

Uint8List _exifRotatedCardJpeg(Uint8List goldenCardPng) {
  final upright = img.decodePng(goldenCardPng)!;
  // Rotate pixels 270 deg CW so EXIF Orientation 6 (90 deg CW display) restores upright
  final stored = img.copyRotate(upright, angle: 270);
  stored.exif.imageIfd.orientation = 6;
  return Uint8List.fromList(img.encodeJpg(stored, quality: 96));
}

void main() {
  test(
    'loadVerifiedAiBundle loads real ONNX assets from Flutter rootBundle and verifies SHA-256',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final bundle = await loadVerifiedAiBundle();
      expect(bundle, isNotNull);
      expect(bundle!.bundleId, 'scanid-docnet-v1');
      expect(bundle.stage1Bytes.length, 498075);
      expect(bundle.stage2Bytes.length, 608568);
    },
  );

  test(
    'production single-card lifecycle: import + EXIF orientation + AI crop + original preservation + A4 PDF/PNG/JPEG export + full-frame revert',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('scanid_ai_sgl_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final files = SafeFiles(tempDir);
      final assets = LocalAssetRepository(files);
      final projects = LocalProjectRepository(files);
      final bundle = _loadBundleFromRepo();
      final editor = LocalImageEditor(assets, aiBundle: bundle);
      // Production defaults: smartRecognitionEnabled = false, multiDocumentSegmentationEnabled = true
      final service = ProjectService(projects, assets, imageEditor: editor);

      final goldenBytes = File(
        'test/fixtures/ai_golden_card.png',
      ).readAsBytesSync();
      final exifJpegBytes = _exifRotatedCardJpeg(goldenBytes);

      var project = await service.create('فحص دورة بطاقة مفردة');
      final imported = await service.importImages(project, [
        ImportSource('card.png', () => Stream.value(goldenBytes)),
        ImportSource('card_exif6.jpg', () => Stream.value(exifJpegBytes)),
      ]);
      project = imported.project;
      expect(project.assets, hasLength(2));

      final arranged = await service.arrangeImportedImages(project, [
        for (final a in project.assets) a.id,
      ]);
      project = arranged.project;

      // Both upright PNG and EXIF-6 rotated JPEG must be auto-cropped cleanly
      for (final asset in project.assets) {
        expect(asset.crop, isNotNull, reason: '${asset.name} auto-cropped');
        expect(asset.workingPath, isNot(asset.originalPath));
        expect(
          asset.width,
          greaterThan(asset.height),
          reason: 'landscape card',
        );
      }

      // Original PNG bytes on disk must remain 100% bit-for-bit identical
      final origPngOnDisk = await (await assets.resolve(
        project.assets.first.originalPath,
      )).readAsBytes();
      expect(origPngOnDisk, goldenBytes);

      // Both cards must be placed on A4 page 0
      final placed = project.items.where((i) => i.pageIndex != null).toList();
      expect(placed, hasLength(2));
      for (final item in placed) {
        expect(item.pageIndex, 0);
      }

      // Export A4 to PDF, PNG, and JPEG and verify real outputs
      final exportDir = await Directory.systemTemp.createTemp('scanid_ai_exp_');
      addTearDown(() async {
        if (await exportDir.exists()) {
          await exportDir.delete(recursive: true);
        }
      });
      final exporter = DocumentExporter(assets);

      final pdfOut = await exporter.generate(
        ExportPlan(project, ExportProfile(format: ExportFormat.pdf)),
        exportDir,
      );
      final pdfBytes = await File(pdfOut.files.single).readAsBytes();
      expect(String.fromCharCodes(pdfBytes.take(5)), '%PDF-');

      final pngOut = await exporter.generate(
        ExportPlan(project, ExportProfile(format: ExportFormat.png)),
        exportDir,
      );
      final pngImg = img.decodePng(
        await File(pngOut.files.single).readAsBytes(),
      )!;
      expect([pngImg.width, pngImg.height], [2480, 3508]);

      final jpgOut = await exporter.generate(
        ExportPlan(project, ExportProfile(format: ExportFormat.jpg)),
        exportDir,
      );
      final jpgImg = img.decodeJpg(
        await File(jpgOut.files.single).readAsBytes(),
      )!;
      expect([jpgImg.width, jpgImg.height], [2480, 3508]);

      // Revert crop back to full image via applyManualCrop and verify original stays untouched
      final firstAsset = project.assets.first;
      project = await service.applyManualCrop(
        project,
        firstAsset,
        CropDraft.fullImage().toRecipe(320, 240),
      );
      final revertedAsset = project.assets.firstWhere(
        (a) => a.id == firstAsset.id,
      );
      expect([revertedAsset.width, revertedAsset.height], [320, 240]);
      final origAfterRevert = await (await assets.resolve(
        revertedAsset.originalPath,
      )).readAsBytes();
      expect(origAfterRevert, goldenBytes);
    },
  );

  test(
    'production multi-card lifecycle: two tilted cards in one frame -> 2 independent crops -> A4 layout -> PDF/PNG/JPEG export',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('scanid_ai_mul_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final files = SafeFiles(tempDir);
      final assets = LocalAssetRepository(files);
      final projects = LocalProjectRepository(files);
      final bundle = _loadBundleFromRepo();
      final editor = LocalImageEditor(assets, aiBundle: bundle);
      final service = ProjectService(projects, assets, imageEditor: editor);

      final twoCardBytes = File(
        'test/fixtures/ai_golden_two_cards.png',
      ).readAsBytesSync();

      var project = await service.create('فحص بطاقتين في صورة واحدة');
      project = (await service.importImages(project, [
        ImportSource('two_cards.png', () => Stream.value(twoCardBytes)),
      ])).project;
      final sourceId = project.assets.single.id;

      final arranged = await service.arrangeImportedImages(project, [sourceId]);
      project = arranged.project;

      // Source image must be preserved untouched while 2 independent derived card assets are created
      final sourceAsset = project.assets.firstWhere((a) => a.id == sourceId);
      expect(
        await (await assets.resolve(sourceAsset.originalPath)).readAsBytes(),
        twoCardBytes,
      );
      final derived = project.assets
          .where((a) => a.derivedFrom == sourceId)
          .toList();
      expect(derived, hasLength(2));
      for (final cardAsset in derived) {
        expect(cardAsset.crop, isNotNull);
        expect(cardAsset.width, greaterThan(cardAsset.height));
      }

      // Both segmented cards must be automatically arranged on A4 page 0 without overlapping
      final placed = project.items.where((i) => i.pageIndex == 0).toList();
      expect(placed, hasLength(2));
      final a = placed[0];
      final b = placed[1];
      final separated =
          a.x + a.width <= b.x + 1e-6 ||
          b.x + b.width <= a.x + 1e-6 ||
          a.y + a.height <= b.y + 1e-6 ||
          b.y + b.height <= a.y + 1e-6;
      expect(separated, isTrue, reason: 'A4 placed items must not overlap');

      final exportDir = await Directory.systemTemp.createTemp(
        'scanid_ai_mexp_',
      );
      addTearDown(() async {
        if (await exportDir.exists()) {
          await exportDir.delete(recursive: true);
        }
      });
      final exporter = DocumentExporter(assets);
      final pdfOut = await exporter.generate(
        ExportPlan(project, ExportProfile(format: ExportFormat.pdf)),
        exportDir,
      );
      expect(await File(pdfOut.files.single).length(), greaterThan(1000));
    },
  );

  test(
    'production safety: uncertain learned-model proposal never auto-crops, never confirms size, and persists suggestedCrop on ImageAsset',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('scanid_ai_safe_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final files = SafeFiles(tempDir);
      final assets = LocalAssetRepository(files);
      final projects = LocalProjectRepository(files);
      final innerEditor = LocalImageEditor(assets);
      final proposedQuad = [
        Point2(0.16, 0.18),
        Point2(0.84, 0.22),
        Point2(0.82, 0.78),
        Point2(0.14, 0.76),
      ];
      final uncertainEditor = _UncertainAiEditor(
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
      );

      final goldenBytes = File(
        'test/fixtures/ai_golden_card.png',
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

      // SmartIntake path also keeps crop null and stores suggestedPolygon on DocumentRecord
      final intake = SmartIntake(
        projects: projects,
        assets: assets,
        editor: uncertainEditor,
        segment: (_) async =>
            const SegmentationResult(multi: false, candidates: []),
      );
      final report = await intake.run(reloaded, [savedAsset.id]);
      final doc = report.project.documents.single;
      expect(report.project.assets.single.crop, isNull);
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
    'CropScreen preloads ImageAsset.suggestedCrop in production mode, supports 1-tap Undo to full image, and clears suggestedCrop on manual save',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final proposedQuad = [
        Point2(0.16, 0.18),
        Point2(0.84, 0.22),
        Point2(0.82, 0.78),
        Point2(0.14, 0.76),
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

      // Banner confirms unapplied editable proposal was loaded from asset.suggestedCrop
      expect(find.byKey(const Key('crop-proposed-banner')), findsOneWidget);

      // 1-tap Undo reverts to full image (corners[0] == (0, 0)) and hides review banner
      await tester.tap(find.byTooltip('تراجع'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('crop-proposed-banner')), findsNothing);

      await tester.ensureVisible(find.text('معاينة التصحيح'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('معاينة التصحيح'));
      await tester.pumpAndSettle();
      expect(editor.lastPreviewRecipe!.geometry.corners.first.x, 0);

      // Redo restores proposed quad, then preview and accept manual crop
      await tester.tap(find.byTooltip('إعادة'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('معاينة التصحيح'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('معاينة التصحيح'));
      await tester.pumpAndSettle();
      expect(
        editor.lastPreviewRecipe!.geometry.corners.first.x,
        closeTo(0.16, 1e-6),
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
      expect(tester.takeException(), isNull);
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
      final rawAsset = assetFixture(id: 'asset-raw');
      final doc = DocumentRecord(
        id: 'rec-uncertain',
        sourceImageId: rawAsset.id,
        sides: [
          DocumentSide(
            id: 'side-0',
            side: SideKind.front,
            detection: DetectionRef(
              detectionId: 'det-0',
              producer: 'scanid_docnet_v1',
              version: '1.0',
              detectionConfidence: Confidence(value: 0.44),
              polygon: null,
              suggestedPolygon: proposedQuad,
              bbox: const [0.12, 0.15, 0.87, 0.81],
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
          documentKind: DocumentKind.unifiedNationalId,
          status: RecognitionStatus.needsReview,
          confidences: ConfidenceSet(finalConfidence: Confidence(value: 0.44)),
          preset: const PresetSelection.unresolved(),
        ),
        provenance: Provenance(
          sourceImageId: 'asset-raw',
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
            width: 85.6,
            height: 53.98,
            sizeConfirmed: false,
            documentId: doc.id,
            sideId: 'side-0',
          ),
        ],
        documents: [doc],
      ).copyWith(assets: [rawAsset]);

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
