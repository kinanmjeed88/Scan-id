import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/application/recognition_pipeline.dart';
import 'package:scan_id/application/recognition_worker.dart';
import 'package:scan_id/domain/geometry.dart';
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
  });
}
