import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/application/recognition_pipeline.dart';
import 'package:scan_id/application/recognition_worker.dart';
import 'package:scan_id/domain/crop_draft.dart';
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

Uint8List _idCardPhoto() {
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
    test('D3/D10: a filename label cannot impose a contradicting catalog '
        'aspect on measured corners', () async {
      final pipeline = RecognitionPipeline(
        segment: (_) async => SegmentationResult(
          multi: false,
          candidates: [
            SegmentCandidate(
              corners: _quad(), // measured aspect ~1.6
              region: const [.1, .1, .9, .9],
              reason: 'measured',
            ),
          ],
        ),
        suggestSingle: (_) async => null,
      );
      final result = await pipeline.analyze(
        PipelineImageInput(
          assetId: 'asset1',
          name: 'البطاقة التموينية.png', // filename claims the ration kind
          previewBytes: _bytes,
          sourceWidth: 1600,
          sourceHeight: 1000,
          importIndex: 0,
        ),
      );
      final detection = result.detections.single;
      expect(detection.corners, isNull);
      expect(detection.hasUsableQuad, isFalse);
      expect(detection.boundary, DetectionBoundary.rejected);
      expect(
        result.issues.map((issue) => issue.category),
        contains(RecognitionErrorCategory.geometryFailure),
      );
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
      final bytes = _idCardPhoto();
      project = (await service.importImages(project, [
        ImportSource(name, () => Stream.value(bytes)),
      ])).project;
      return service.arrangeImportedImages(project, [project.assets.single.id]);
    }

    test(
      'a well-formed card is still auto-cropped (behaviour preserved)',
      () async {
        final report = await importNamed('بطاقة.png');
        expect(report.cropped, 1);
        expect(report.project.items, hasLength(1));
        expect(report.project.assets.single.crop, isNotNull);
      },
    );

    test('D1/D10: a filename-imposed aspect that contradicts the detected '
        'boundary blocks the crop and keeps the whole frame', () async {
      final report = await importNamed('البطاقة التموينية.png');
      expect(report.cropped, 0);
      expect(report.notDetected, 1);
      expect(report.project.assets.single.crop, isNull);
      expect(report.warnings.join(' '), contains('لا يطابق مقاس النوع'));
      final item = report.project.items.single;
      expect(item.sizeConfirmed, isFalse);
      expect(
        [item.width, item.height],
        isNot([52, 287]),
        reason:
            'a refused boundary must not be placed at the contradicted size',
      );
    });

    test('production multi path cannot warp a contradicted boundary', () async {
      final gated = ProjectService(
        projects,
        LocalAssetRepository(projects.files),
        imageEditor: LocalImageEditor(projects.files),
        segmenter: (_) async => SegmentationResult(
          multi: true,
          candidates: [
            // Pixel aspect on the 640×480 fixture is the ID-1 shape, so a
            // ration-card filename contradicts it by more than 2.5×.
            SegmentCandidate(
              region: [.05, .08, .45, .416],
              corners: [
                Point2(.05, .08),
                Point2(.45, .08),
                Point2(.45, .416),
                Point2(.05, .416),
              ],
              reason: 'measured',
            ),
            SegmentCandidate(
              region: [.55, .50, .95, .836],
              corners: [
                Point2(.55, .50),
                Point2(.95, .50),
                Point2(.95, .836),
                Point2(.55, .836),
              ],
              reason: 'measured',
            ),
          ],
        ),
      );
      var project = await gated.create('تعدد');
      final bytes = _idCardPhoto();
      project = (await gated.importImages(project, [
        ImportSource('البطاقة التموينية.png', () => Stream.value(bytes)),
      ])).project;
      final sourceId = project.assets.single.id;
      final report = await gated.arrangeImportedImages(project, [sourceId]);
      expect(gated.smartRecognitionEnabled, isFalse);
      expect(gated.multiDocumentSegmentationEnabled, isTrue);
      expect(report.cropped, 0);
      expect(
        report.project.assets.singleWhere((asset) => asset.id == sourceId).crop,
        isNull,
      );
      expect(report.project.items, hasLength(2));
      expect(report.project.items.every((item) => !item.sizeConfirmed), isTrue);
      expect(
        report.project.items.every(
          (item) =>
              item.width / item.height < 4 && item.height / item.width < 4,
        ),
        isTrue,
        reason: 'neither derived crop was stretched to the ration-card ratio',
      );
      final source = report.project.assets.singleWhere(
        (asset) => asset.id == sourceId,
      );
      expect(
        await (await LocalAssetRepository(
          projects.files,
        ).resolve(source.originalPath)).readAsBytes(),
        bytes,
      );
    });

    test('a passport filename cannot stretch an ID-shaped quad', () async {
      final inner = LocalImageEditor(projects.files);
      final gated = ProjectService(
        projects,
        LocalAssetRepository(projects.files),
        imageEditor: _FixedSuggest(inner, _idQuadOnSquare()),
        segmenter: (_) async =>
            const SegmentationResult(multi: false, candidates: []),
      );
      var project = await gated.create('جواز');
      final bytes = _square();
      project = (await gated.importImages(project, [
        ImportSource('جواز السفر.png', () => Stream.value(bytes)),
      ])).project;
      final report = await gated.arrangeImportedImages(project, [
        project.assets.single.id,
      ]);
      final asset = report.project.assets.single;
      final item = report.project.items.single;
      expect(report.cropped, 1);
      expect(item.sizeConfirmed, isFalse);
      expect([item.width, item.height], isNot([125, 88]));
      expect(asset.width / asset.height, closeTo(1.586, .04));
      expect(asset.width / asset.height, isNot(closeTo(125 / 88, .02)));
      expect(report.warnings.join(' '), contains('دون مطّ'));
      expect(
        await (await LocalAssetRepository(
          projects.files,
        ).resolve(asset.originalPath)).readAsBytes(),
        bytes,
      );
    });

    test(
      'production multi path does not stretch ID quads to passport',
      () async {
        final gated = ProjectService(
          projects,
          LocalAssetRepository(projects.files),
          imageEditor: LocalImageEditor(projects.files),
          segmenter: (_) async => SegmentationResult(
            multi: true,
            candidates: [
              SegmentCandidate(
                region: const [.05, .05, .85, .554],
                corners: _idQuadOnSquare(),
                reason: 'measured',
              ),
              SegmentCandidate(
                region: const [.10, .48, .90, .984],
                corners: [
                  Point2(.10, .48),
                  Point2(.90, .48),
                  Point2(.90, .984),
                  Point2(.10, .984),
                ],
                reason: 'measured',
              ),
            ],
          ),
        );
        var project = await gated.create('تعدد جواز');
        final bytes = _square();
        project = (await gated.importImages(project, [
          ImportSource('جواز السفر.png', () => Stream.value(bytes)),
        ])).project;
        final sourceId = project.assets.single.id;
        final report = await gated.arrangeImportedImages(project, [sourceId]);
        expect(report.cropped, 2);
        expect(report.project.items, hasLength(2));
        expect(
          report.project.items.every((item) => !item.sizeConfirmed),
          isTrue,
        );
        expect(
          report.project.items.every(
            (item) => item.width != 125 || item.height != 88,
          ),
          isTrue,
        );
        final derived = report.project.assets.where((a) => a.id != sourceId);
        expect(derived, hasLength(2));
        for (final asset in derived) {
          expect(asset.width / asset.height, closeTo(1.586, .04));
          expect(asset.width / asset.height, isNot(closeTo(125 / 88, .02)));
        }
        expect(report.warnings.join(' '), contains('دون مطّ'));
      },
    );

    test(
      'a catalog match within shapeTolerance does not stretch the saved crop',
      () async {
        final inner = LocalImageEditor(projects.files);
        final gated = ProjectService(
          projects,
          LocalAssetRepository(projects.files),
          imageEditor: _FixedSuggest(inner, _nearIdQuad()),
          segmenter: (_) async =>
              const SegmentationResult(multi: false, candidates: []),
        );
        var project = await gated.create('قرب الهوية');
        final bytes = _square();
        project = (await gated.importImages(project, [
          ImportSource('frame.png', () => Stream.value(bytes)),
        ])).project;
        final report = await gated.arrangeImportedImages(project, [
          project.assets.single.id,
        ]);
        final asset = report.project.assets.single;
        final item = report.project.items.single;
        // 0.80 * 999 + 1 floors to 800; 0.80/1.64 * 999 + 1 floors to 488.
        // The removed catalog stretch would have saved 774×488.
        expect(report.cropped, 1);
        expect(asset.width, 800);
        expect(asset.height, 488);
        expect(asset.crop?.outputWidth, 800);
        expect(asset.crop?.outputHeight, 488);
        expect(asset.width / asset.height, isNot(closeTo(85.6 / 53.98, .01)));
        expect(item.sizeConfirmed, isTrue);
        expect([item.width, item.height], [85.6, 53.98]);
        expect(report.warnings.join(' '), isNot(contains('دون مطّ')));
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
      'production multi path keeps measured pixels when the catalog slot matches',
      () async {
        final quads = _twoNearIdQuads();
        final gated = ProjectService(
          projects,
          LocalAssetRepository(projects.files),
          imageEditor: LocalImageEditor(projects.files),
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
          expect(asset.width / asset.height, isNot(closeTo(85.6 / 53.98, .01)));
        }
        expect(report.project.items, hasLength(2));
        // The classifier floor may refuse to confirm a 3.4 % match. That must
        // not become a license to stretch the pixels, and it must not place
        // the unconfirmed item in the catalog slot.
        for (final item in report.project.items) {
          if (item.sizeConfirmed) {
            expect([item.width, item.height], [85.6, 53.98]);
          } else {
            expect([item.width, item.height], isNot([85.6, 53.98]));
            expect(item.width / item.height, closeTo(400 / 244, .02));
          }
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

/// Aspect 1.64 on a 1000×1000 frame: inside the 4 % ID-1 tolerance, not equal
/// to 85.6/53.98. The unstretched recipe is 800×488, not the old 774×488.
List<Point2> _nearIdQuad() {
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

/// Two non-overlapping copies of the same 1.64 shape. Each is 0.40 of the
/// frame, so the unstretched recipe is 400×244 rather than a catalog stretch.
List<List<Point2>> _twoNearIdQuads() {
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

List<Point2> _idQuadOnSquare() => [
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
  Future<EditorSource> open(ImageAsset asset) => inner.open(asset);

  @override
  Future<List<Point2>?> suggest(Uint8List preview) async => corners;

  @override
  Future<Uint8List> preview(ImageAsset asset, ImageEditRecipe recipe) =>
      inner.preview(asset, recipe);

  @override
  Future<ImageAsset> createRevision(ImageAsset asset, ImageEditRecipe recipe) =>
      inner.createRevision(asset, recipe);
}
