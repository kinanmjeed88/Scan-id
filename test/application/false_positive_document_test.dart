/// Synthetic regression coverage for reported false-positive regions, through
/// the production intake pipeline.
///
/// No source photo or human annotation is available here. The geometry-only
/// scenes can exercise region rejection, crop retention, and project wiring;
/// they cannot establish that a region is a real document or measure accuracy.
/// These tests run the real segmenter, corner detector, classifier, repository
/// and layout engine, and assert that accepted regions remain unclassified.
///
/// Only the isolate hop is replaced ([segmentDocumentBytes] instead of
/// [defaultSegment]) so the tests stay deterministic; one test below exercises
/// the real isolate seam too.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/application/recognition_pipeline.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/recognition_routing.dart';
import 'package:scan_id/imaging/document_segmenter.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

final _paper = img.ColorRgb8(240, 238, 230);
final _paper2 = img.ColorRgb8(232, 230, 222);
final _dark = img.ColorRgb8(14, 14, 16);

img.Image _canvas(int width, int height, img.ColorRgb8 background) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: background);
  return image;
}

void _rect(
  img.Image image,
  int x1,
  int y1,
  int x2,
  int y2,
  img.ColorRgb8 color,
) => img.fillRect(image, x1: x1, y1: y1, x2: x2, y2: y2, color: color);

Uint8List _png(img.Image image) => Uint8List.fromList(img.encodePng(image));

/// Two synthetic landscape rectangles on a mid-tone background. Their
/// proportions describe fixture geometry only, not document categories.
img.Image _twoRectangles() {
  final image = _canvas(1200, 1600, img.ColorRgb8(128, 122, 116));
  _rect(image, 150, 180, 800, 590, _paper);
  _rect(image, 200, 900, 851, 1311, _paper2);
  return image;
}

/// Synthetic reproduction of the described scene; it is not a photograph or
/// a labeled sample. Three candidate rectangles and two background artifacts
/// let the test exercise the segmenter's geometric gates.
///
/// Measured through the segmenter's arithmetic on its 900x1200 preview
/// (background estimate (128, 122, 116), Otsu 168.7):
///
///   top frame band  reaches 3 frame edges  -> frameArtifact
///   dark strip      aspect 16.08           -> implausibleAspect
///   region 1 631x397  aspect 1.58, crop 546x345            -> accepted
///   region 2 321x505  aspect 1.58, crop 278x439 (portrait) -> accepted
///   region 3 721x453  aspect 1.59, crop 626x392            -> accepted
///
/// The two background shapes are refused by the configured gates in this
/// synthetic scene; this says nothing about the validity of any real photo.
img.Image _reportedCase() {
  final image = _canvas(1200, 1600, img.ColorRgb8(128, 122, 116));
  _rect(image, 150, 160, 780, 556, _paper);
  _rect(image, 830, 200, 1150, 704, _paper2);
  _rect(image, 200, 1000, 920, 1452, img.ColorRgb8(242, 240, 232));
  _rect(image, 0, 0, 1200, 70, img.ColorRgb8(16, 15, 15));
  _rect(image, 60, 700, 116, 1560, _dark);
  return image;
}

void main() {
  late Directory root;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan-false-positive-');
    projects = await LocalProjectRepository.open(root);
    assets = LocalAssetRepository(projects.files);
  });

  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
  });

  /// The real segmenter, minus the isolate hop.
  Future<SegmentationResult> realSegmenter(Uint8List bytes) async =>
      segmentDocumentBytes(bytes);

  ProjectService service() => ProjectService(
    projects,
    assets,
    imageEditor: LocalImageEditor(projects.files),
    smartRecognitionEnabled: true,
    segmenter: realSegmenter,
  );

  test(
    'a narrow dark strip beside two synthetic rectangles creates no extra item',
    () async {
      final photo = _twoRectangles();
      // A solid dark strip, 57 px wide and 721 px tall (measured aspect
      // 12.46 at working scale against a bound of 8.0, 68 px short side in
      // the preview).
      _rect(photo, 40, 700, 96, 1420, _dark);
      final s = service();
      final bytes = _png(photo);
      var project = await s.create('synthetic geometry');
      project = (await s.importImages(project, [
        ImportSource('scene.png', () => Stream<List<int>>.value(bytes)),
      ])).project;
      final sourceId = project.assets.single.id;
      final originalPath = project.assets.single.originalPath;

      final report = await s.arrangeImportedImages(project, [sourceId]);
      final result = report.project;

      // The vertical background strip is rejected; the two synthetic
      // rectangles remain as separate review items.
      expect(result.documents, hasLength(2));
      expect(result.items, hasLength(2));
      expect(result.assets, hasLength(3), reason: 'original + two derived');
      expect(report.multiDocumentImages, 1);
      expect(report.cropped, 2);
      expect(report.rejectedRegions, 1);

      for (final item in result.items) {
        expect(item.documentKind, DocumentKind.unknown);
        expect(item.sizeConfirmed, isFalse);
        expect(item.pageIndex, isNull);
        expect(
          math.max(item.width, item.height) / math.min(item.width, item.height),
          lessThan(2),
        );
      }

      expect(
        report.warnings.any((w) => w.contains('تجاهل التقسيم')),
        isTrue,
        reason: '${report.warnings}',
      );
      expect(
        report.warnings.any(
          (w) => w.contains(
            regionRejectionLabel(RegionRejection.implausibleAspect),
          ),
        ),
        isTrue,
        reason: '${report.warnings}',
      );
      expect(await (await assets.resolve(originalPath)).readAsBytes(), bytes);

      for (final asset in result.assets.where((a) => a.id != sourceId)) {
        expect(asset.derivedFrom, sourceId);
      }
    },
  );

  test(
    'the synthetic scene retains its three accepted regions as unclassified',
    () async {
      final s = service();
      final bytes = _png(_reportedCase());
      var project = await s.create('synthetic scene');
      project = (await s.importImages(project, [
        ImportSource('scene.png', () => Stream<List<int>>.value(bytes)),
      ])).project;
      final sourceId = project.assets.single.id;

      final report = await s.arrangeImportedImages(project, [sourceId]);
      final result = report.project;

      expect(result.documents, hasLength(3));
      expect(result.items, hasLength(3));
      expect(result.assets, hasLength(4), reason: 'source + three derived');
      expect(report.rejectedRegions, 2);
      expect(report.multiDocumentImages, 1);
      expect(report.cropped, 3);
      for (final item in result.items) {
        expect(item.documentKind, DocumentKind.unknown);
        expect(item.sizeConfirmed, isFalse);
        expect(item.pageIndex, isNull);
      }
      // One synthetic region is portrait; the assertion concerns measured
      // orientation only and does not imply a document category.
      expect(result.items.where((i) => i.height > i.width), hasLength(1));
      for (final asset in result.assets.where((a) => a.id != sourceId)) {
        final long = math.max(asset.width, asset.height).toDouble();
        final short = math.min(asset.width, asset.height).toDouble();
        expect(long / short, greaterThan(1.4));
        expect(long / short, lessThan(1.8));
      }
    },
  );

  test('a rejected small region creates no extra review item', () async {
    final image = _canvas(200, 200, img.ColorRgb8(128, 122, 116));
    _rect(image, 20, 20, 170, 110, _paper);
    _rect(image, 60, 150, 94, 184, _dark);
    final s = service();
    final bytes = _png(image);
    var project = await s.create('synthetic small region');
    project = (await s.importImages(project, [
      ImportSource('scene.png', () => Stream<List<int>>.value(bytes)),
    ])).project;
    final sourceId = project.assets.single.id;

    final report = await s.arrangeImportedImages(project, [sourceId]);
    final result = report.project;

    // The larger rectangle survives the single-image path; the small square
    // is refused and does not become another review item.
    expect(result.documents, hasLength(1));
    expect(result.items, hasLength(1));
    expect(result.items.single.documentKind, DocumentKind.unknown);
    expect(result.items.single.sizeConfirmed, isFalse);
    expect(result.items.single.pageIndex, isNull);
    // The single-image path revises the source asset in place, while keeping
    // the original file untouched (ADR-003).
    expect(result.assets, hasLength(1));
    expect(result.assets.single.id, sourceId);
    expect(result.assets.single.derivedFrom, isNull);
    expect(report.rejectedRegions, 1);
    expect(report.multiDocumentImages, 0);
  });

  test(
    'synthetic regions remain unclassified review items regardless of shape',
    () async {
      final image = _canvas(1200, 1600, img.ColorRgb8(88, 90, 96));
      _rect(image, 120, 120, 640, 450, _paper);
      // A second, much wider rectangle is kept as a plausible geometric
      // candidate. Neither fixture has a human category label; measured shape
      // must not confirm a kind or printed size.
      _rect(image, 100, 1300, 1120, 1580, img.ColorRgb8(246, 245, 242));
      final s = service();
      final bytes = _png(image);
      var project = await s.create('synthetic review geometry');
      project = (await s.importImages(project, [
        ImportSource('scene.png', () => Stream<List<int>>.value(bytes)),
      ])).project;
      final sourceId = project.assets.single.id;

      final report = await s.arrangeImportedImages(project, [sourceId]);
      final result = report.project;

      expect(result.documents, hasLength(2));
      expect(result.items, hasLength(2));
      expect(report.rejectedRegions, 0);
      for (final item in result.items) {
        expect(item.documentKind, DocumentKind.unknown);
        expect(item.sizeConfirmed, isFalse);
        expect(item.pageIndex, isNull);
        final record = result.documents.firstWhere(
          (document) => document.id == item.documentId,
        );
        expect(record.recognition!.documentKind, DocumentKind.unknown);
        expect(record.recognition!.preset.awaitingSize, isTrue);
        expect(reviewReasons(record), contains('نوع غير معروف'));
        expect(reviewReasons(record), contains('بانتظار تحديد المقاس'));
        expect(recordNeedsReview(record), isTrue);
        expect(record.provenance.sourceImageId, sourceId);
      }
      expect(
        result.assets.firstWhere((asset) => asset.id == sourceId).originalPath,
        isNotEmpty,
      );
    },
  );

  test(
    'reprocessing the synthetic scene does not duplicate review items',
    () async {
      final photo = _twoRectangles();
      _rect(photo, 40, 700, 96, 1420, _dark);
      final s = service();
      final bytes = _png(photo);
      var project = await s.create('synthetic reprocessing');
      project = (await s.importImages(project, [
        ImportSource('scene.png', () => Stream<List<int>>.value(bytes)),
      ])).project;
      final sourceId = project.assets.single.id;
      final first = await s.arrangeImportedImages(project, [sourceId]);

      final itemIds = first.project.items.map((i) => i.id).toList();
      final recordIds = first.project.documents.map((d) => d.id).toList();
      final assetIds = first.project.assets.map((a) => a.id).toList();

      final second = await s.reprocessImages(first.project, [sourceId]);
      final result = second!.project;

      // The rejected strip stays absent, and no new review item is created.
      expect(result.documents, hasLength(2));
      expect(result.items, hasLength(2));
      expect(result.assets, hasLength(3));
      expect(result.documents.map((d) => d.id).toList(), recordIds);
      expect(result.items.map((i) => i.id).toList(), itemIds);
      expect(result.assets.map((a) => a.id).toList(), assetIds);
      expect(
        result.items.every(
          (item) =>
              item.documentKind == DocumentKind.unknown &&
              !item.sizeConfirmed &&
              item.pageIndex == null,
        ),
        isTrue,
      );
      expect(second.rejectedRegions, 1);
      expect((await projects.get(result.id)).toJson(), result.toJson());
    },
  );

  test('the isolate seam carries region rejections through', () async {
    // defaultSegment runs the segmenter off the UI isolate; the rejections
    // must survive that boundary so the report is not isolate-dependent.
    final direct = await defaultSegment(_png(_twoRectangles()));
    expect(direct.rejected, isEmpty);
    expect(direct.candidates, hasLength(2));

    final photo = _twoRectangles();
    _rect(photo, 40, 700, 96, 1420, _dark);
    final isolated = await defaultSegment(_png(photo));
    expect(isolated.rejected, hasLength(1));
    expect(
      isolated.rejected.single.rejection,
      RegionRejection.implausibleAspect,
    );
    expect(isolated.candidates, hasLength(2));
  });
}
