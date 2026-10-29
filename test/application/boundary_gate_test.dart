import 'package:scan_id/application/cancellation.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/application/recognition_pipeline.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/imaging/document_segmenter.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

/// Execution-path proof for the boundary decision gate (audits D1, D3, D4,
/// D10) and for what AutomationMode.reviewAll does — and does not — mean.
final _bytes = Uint8List.fromList([1, 2, 3]);

List<Point2> _quad() => [
  Point2(.1, .1),
  Point2(.9, .1),
  Point2(.9, .9),
  Point2(.1, .9),
];

/// Synthetic high-contrast rectangle on a dark background. Geometry fixture only.
Uint8List _contrastScene() {
  final image = img.Image(width: 640, height: 480);
  img.fill(image, color: img.ColorRgb8(40, 48, 60));
  img.fillRect(
    image,
    x1: 90,
    y1: 100,
    x2: 550,
    y2: 390,
    color: img.ColorRgb8(235, 233, 228),
  );
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  group('RecognitionPipeline boundary gate', () {
    test('valid measured geometry is accepted without type evidence', () async {
      final pipeline = RecognitionPipeline(
        segment: (_) async => SegmentationResult(
          multi: false,
          candidates: [
            SegmentCandidate(
              corners: _quad(),
              region: const [.1, .1, .9, .9],
              reason: 'synthetic-measured-geometry',
            ),
          ],
        ),
        suggestSingle: (_) async => null,
      );
      final result = await pipeline.analyze(
        PipelineImageInput(
          assetId: 'asset1',
          previewBytes: _bytes,
          sourceWidth: 1600,
          sourceHeight: 1000,
          importIndex: 0,
        ),
      );
      final detection = result.detections.single;
      expect(detection.corners, isNotNull);
      expect(detection.hasUsableQuad, isTrue);
      expect(detection.boundary, DetectionBoundary.trustworthy);
      expect(detection.classification.kind, DocumentKind.unknown);
      expect(detection.cropAuthorization, isNotNull);
      expect(result.issues, isEmpty);
    });
  });

  group('legacy single-document path (ProjectService)', () {
    late Directory root;
    late LocalProjectRepository projects;
    late ProjectService service;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('scan_boundary_test_');
      projects = await LocalProjectRepository.open(root);
      service = ProjectService(
        projects,
        LocalAssetRepository(projects.files),
        imageEditor: LocalImageEditor(projects.files),
      );
    });
    tearDown(() async {
      await projects.close();
      await root.delete(recursive: true);
    });

    Future<AutomaticLayoutReport> importNamed(String name) async {
      var project = await service.create('مشروع');
      final bytes = _contrastScene();
      project = (await service.importImages(project, [
        ImportSource(name, () => Stream.value(bytes)),
      ])).project;
      return service.arrangeImportedImages(project, [project.assets.single.id]);
    }

    test(
      'filenames do not affect local geometric boundary proposals',
      () async {
        final first = await importNamed('capture-a.png');
        final second = await importNamed('different-name.jpg');
        expect(first.cropped, 0);
        expect(second.cropped, 0);
        expect(first.notDetected, 1);
        expect(second.notDetected, 1);
        expect(first.project.items, hasLength(1));
        expect(second.project.items, hasLength(1));

        final firstAsset = first.project.assets.single;
        final secondAsset = second.project.assets.single;
        expect(firstAsset.crop, isNull);
        expect(secondAsset.crop, isNull);
        expect(firstAsset.suggestedCrop, hasLength(4));
        expect(secondAsset.suggestedCrop, hasLength(4));
        for (var i = 0; i < 4; i++) {
          expect(
            firstAsset.suggestedCrop![i].x,
            closeTo(secondAsset.suggestedCrop![i].x, 1e-9),
          );
          expect(
            firstAsset.suggestedCrop![i].y,
            closeTo(secondAsset.suggestedCrop![i].y, 1e-9),
          );
        }
        expect(
          [firstAsset.width, firstAsset.height],
          [secondAsset.width, secondAsset.height],
        );
        for (final item in [
          first.project.items.single,
          second.project.items.single,
        ]) {
          expect(item.documentKind, DocumentKind.unknown);
          expect(item.sizeConfirmed, isFalse);
          expect(item.pageIndex, isNull);
        }
      },
    );

    test(
      'multi-region crops preserve measured geometry without classifying',
      () async {
        final gated = ProjectService(
          projects,
          LocalAssetRepository(projects.files),
          imageEditor: LocalImageEditor(projects.files),
          multiDocumentSegmentationEnabled: true,
          segmenter: (_) async => SegmentationResult(
            multi: true,
            candidates: [
              SegmentCandidate(
                region: [.05, .08, .45, .416],
                corners: [
                  Point2(.05, .08),
                  Point2(.45, .08),
                  Point2(.45, .416),
                  Point2(.05, .416),
                ],
                reason: 'synthetic-geometry',
              ),
              SegmentCandidate(
                region: [.55, .50, .95, .836],
                corners: [
                  Point2(.55, .50),
                  Point2(.95, .50),
                  Point2(.95, .836),
                  Point2(.55, .836),
                ],
                reason: 'synthetic-geometry',
              ),
            ],
          ),
        );
        var project = await gated.create('synthetic multi-region scene');
        final bytes = _contrastScene();
        project = (await gated.importImages(project, [
          ImportSource('scene.png', () => Stream.value(bytes)),
        ])).project;
        final sourceId = project.assets.single.id;
        final report = await gated.arrangeImportedImages(project, [sourceId]);
        expect(gated.smartRecognitionEnabled, isFalse);
        expect(gated.multiDocumentSegmentationEnabled, isTrue);
        expect(report.cropped, 2);
        expect(
          report.project.assets
              .singleWhere((asset) => asset.id == sourceId)
              .crop,
          isNull,
        );
        expect(report.project.items, hasLength(2));
        expect(
          report.project.items.every(
            (item) =>
                item.documentKind == DocumentKind.unknown &&
                !item.sizeConfirmed &&
                item.pageIndex == null,
          ),
          isTrue,
        );
        final derived = report.project.assets.where(
          (asset) => asset.id != sourceId,
        );
        expect(derived, hasLength(2));
        for (final asset in derived) {
          expect(
            asset.width / asset.height,
            closeTo(.4 * 640 / (.336 * 480), .03),
          );
        }
        final source = report.project.assets.singleWhere(
          (asset) => asset.id == sourceId,
        );
        expect(
          await (await LocalAssetRepository(
            projects.files,
          ).resolve(source.originalPath)).readAsBytes(),
          bytes,
        );
      },
    );

    test('a valid single boundary is cropped but stays unclassified', () async {
      final inner = LocalImageEditor(projects.files);
      final gated = ProjectService(
        projects,
        LocalAssetRepository(projects.files),
        imageEditor: _FixedSuggest(inner, _wideQuadOnSquare()),
        multiDocumentSegmentationEnabled: true,
        segmenter: (_) async =>
            const SegmentationResult(multi: false, candidates: []),
      );
      var project = await gated.create('synthetic single-region scene');
      final bytes = _square();
      project = (await gated.importImages(project, [
        ImportSource('capture.png', () => Stream.value(bytes)),
      ])).project;
      final report = await gated.arrangeImportedImages(project, [
        project.assets.single.id,
      ]);
      final asset = report.project.assets.single;
      final item = report.project.items.single;
      expect(report.cropped, 1);
      expect(item.documentKind, DocumentKind.unknown);
      expect(item.sizeConfirmed, isFalse);
      expect(item.pageIndex, isNull);
      expect(asset.width / asset.height, closeTo(.8 / .504, .03));
      expect(asset.crop?.outputWidth, asset.width);
      expect(asset.crop?.outputHeight, asset.height);
      expect(
        await (await LocalAssetRepository(
          projects.files,
        ).resolve(asset.originalPath)).readAsBytes(),
        bytes,
      );
    });

    test(
      'multi-region boundaries crop measured pixels without inferring size',
      () async {
        final gated = ProjectService(
          projects,
          LocalAssetRepository(projects.files),
          imageEditor: LocalImageEditor(projects.files),
          multiDocumentSegmentationEnabled: true,
          segmenter: (_) async => SegmentationResult(
            multi: true,
            candidates: [
              SegmentCandidate(
                region: const [.05, .05, .85, .554],
                corners: _wideQuadOnSquare(),
                reason: 'synthetic-geometry',
              ),
              SegmentCandidate(
                region: const [.10, .48, .90, .984],
                corners: [
                  Point2(.10, .48),
                  Point2(.90, .48),
                  Point2(.90, .984),
                  Point2(.10, .984),
                ],
                reason: 'synthetic-geometry',
              ),
            ],
          ),
        );
        var project = await gated.create('synthetic multi-region scene');
        final bytes = _square();
        project = (await gated.importImages(project, [
          ImportSource('scene.png', () => Stream.value(bytes)),
        ])).project;
        final sourceId = project.assets.single.id;
        final report = await gated.arrangeImportedImages(project, [sourceId]);
        expect(report.cropped, 2);
        expect(report.project.items, hasLength(2));
        expect(
          report.project.items.every(
            (item) =>
                item.documentKind == DocumentKind.unknown &&
                !item.sizeConfirmed &&
                item.pageIndex == null,
          ),
          isTrue,
        );
        final derived = report.project.assets.where(
          (asset) => asset.id != sourceId,
        );
        expect(derived, hasLength(2));
        for (final asset in derived) {
          expect(asset.width / asset.height, closeTo(.8 / .504, .03));
        }
      },
    );

    test(
      'trusted boundary cropping preserves measured pixels without type or size inference',
      () async {
        final inner = LocalImageEditor(projects.files);
        final gated = ProjectService(
          projects,
          LocalAssetRepository(projects.files),
          imageEditor: _FixedSuggest(inner, _wideQuad()),
          multiDocumentSegmentationEnabled: true,
          segmenter: (_) async =>
              const SegmentationResult(multi: false, candidates: []),
        );
        var project = await gated.create('synthetic geometry');
        final bytes = _square();
        project = (await gated.importImages(project, [
          ImportSource('frame.png', () => Stream.value(bytes)),
        ])).project;
        final report = await gated.arrangeImportedImages(project, [
          project.assets.single.id,
        ]);
        final asset = report.project.assets.single;
        final item = report.project.items.single;
        // The measured .80 × .504 rectangle yields an 800 × 488 pixel crop.
        expect(report.cropped, 1);
        expect(asset.width, 800);
        expect(asset.height, 488);
        expect(asset.crop?.outputWidth, 800);
        expect(asset.crop?.outputHeight, 488);
        expect(item.documentKind, DocumentKind.unknown);
        expect(item.sizeConfirmed, isFalse);
        expect(item.pageIndex, isNull);
        expect(
          item.width / item.height,
          closeTo(asset.width / asset.height, .01),
        );
        expect(
          await (await LocalAssetRepository(
            projects.files,
          ).resolve(asset.originalPath)).readAsBytes(),
          bytes,
        );
        final working = img.decodePng(
          await (await LocalAssetRepository(
            projects.files,
          ).resolve(asset.workingPath)).readAsBytes(),
        )!;
        expect([working.width, working.height], [800, 488]);
      },
    );

    test(
      'multi-region crops retain measured pixel geometry when aspect resembles a catalog size',
      () async {
        final quads = _twoWideQuads();
        final gated = ProjectService(
          projects,
          LocalAssetRepository(projects.files),
          imageEditor: LocalImageEditor(projects.files),
          multiDocumentSegmentationEnabled: true,
          segmenter: (_) async => SegmentationResult(
            multi: true,
            candidates: [
              for (final quad in quads)
                SegmentCandidate(
                  region: [quad[0].x, quad[0].y, quad[2].x, quad[2].y],
                  corners: quad,
                  reason: 'measured',
                ),
            ],
          ),
        );
        var project = await gated.create('قرب الهوية متعدد');
        final bytes = _square();
        project = (await gated.importImages(project, [
          ImportSource('frame.png', () => Stream.value(bytes)),
        ])).project;
        final sourceId = project.assets.single.id;
        final report = await gated.arrangeImportedImages(project, [sourceId]);
        expect(report.cropped, 2);
        expect(report.multiDocumentImages, 1);
        final derived = report.project.assets.where(
          (asset) => asset.id != sourceId,
        );
        expect(derived, hasLength(2));
        for (final asset in derived) {
          expect(asset.width, 400);
          expect(asset.height, 244);
        }
        expect(report.project.items, hasLength(2));
        for (final item in report.project.items) {
          expect(item.documentKind, DocumentKind.unknown);
          expect(item.sizeConfirmed, isFalse);
          expect(item.pageIndex, isNull);
          expect(item.width / item.height, closeTo(400 / 244, .02));
        }
        for (final record in report.project.documents) {
          final processed = record.sides.single.processedAsset;
          expect(processed.outputWidth, 400);
          expect(processed.outputHeight, 244);
        }
        final source = report.project.assets.singleWhere(
          (asset) => asset.id == sourceId,
        );
        expect(source.width, 1000);
        expect(source.height, 1000);
        expect(
          await (await LocalAssetRepository(
            projects.files,
          ).resolve(source.originalPath)).readAsBytes(),
          bytes,
        );
      },
    );
  });
}

/// Synthetic wide quadrilateral on a 1000×1000 frame; its crop is 800×488 px.
List<Point2> _wideQuad() {
  const top = 0.10;
  const left = 0.10;
  const width = 0.80;
  const bottom = top + width / 1.64;
  return [
    Point2(left, top),
    Point2(left + width, top),
    Point2(left + width, bottom),
    Point2(left, bottom),
  ];
}

/// Two non-overlapping synthetic wide quads. Each is .40 of the frame, so
/// the measured crop recipe is approximately 400×244 px.
List<List<Point2>> _twoWideQuads() {
  List<Point2> quad(double left) {
    const top = 0.20;
    const width = 0.40;
    const bottom = top + width / 1.64;
    return [
      Point2(left, top),
      Point2(left + width, top),
      Point2(left + width, bottom),
      Point2(left, bottom),
    ];
  }

  return [quad(0.05), quad(0.55)];
}

List<Point2> _wideQuadOnSquare() => [
  Point2(.05, .05),
  Point2(.85, .05),
  Point2(.85, .554),
  Point2(.05, .554),
];

Uint8List _square() {
  final image = img.Image(width: 1000, height: 1000);
  img.fill(image, color: img.ColorRgb8(30, 40, 50));
  return Uint8List.fromList(img.encodePng(image));
}

class _FixedSuggest implements ImageEditor {
  _FixedSuggest(this.inner, this.corners);
  final ImageEditor inner;
  final List<Point2> corners;

  @override
  Future<EditorSource> open(
    ImageAsset asset, {
    CancellationToken? cancellation,
  }) => inner.open(asset, cancellation: cancellation);

  @override
  Future<List<Point2>?> suggest(Uint8List preview) async => corners;

  @override
  Future<Uint8List> preview(
    ImageAsset asset,
    ImageEditRecipe recipe, {
    CancellationToken? cancellation,
  }) => inner.preview(asset, recipe);

  @override
  Future<ImageAsset> createRevision(ImageAsset asset, ImageEditRecipe recipe) =>
      inner.createRevision(asset, recipe);
}
