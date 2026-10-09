/// False-positive documents: the reported defect, tested through the
/// PRODUCTION pipeline.
///
/// A segmenter-only test cannot prove the defect is fixed. The extra editor
/// items were not a segmentation artifact that stopped at the segmenter — the
/// segmenter emitted a region, `RecognitionPipeline` routed it, `SmartIntake`
/// created a derived file, a `DocumentRecord` and a `DocumentItem` for it, and
/// `OffSheetTray` rendered it. These tests therefore run the real segmenter,
/// the real corner detector, the real classifier, the real repository and the
/// real layout engine, and assert on the project the user ends up with.
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

/// Two ID-1 cards (651x411 and 652x412, ratio 1.584 and 1.583, both inside the
/// 4 % shape tolerance of 85.6 / 53.98 = 1.586) on a mid-tone desk.
img.Image _twoCards() {
  final image = _canvas(1200, 1600, img.ColorRgb8(128, 122, 116));
  _rect(image, 150, 180, 800, 590, _paper);
  _rect(image, 200, 900, 851, 1311, _paper2);
  return image;
}

/// The reported defect class, reconstructed synthetically.
///
/// No screenshot was ever attached to the report, so this is built from the
/// described symptoms rather than from a real photograph: several identity
/// documents in one photo, plus background furniture that used to come back as
/// extra editor items. Three documents are present — two held landscape and one
/// held PORTRAIT — so the assertions below cannot silently assume an
/// orientation.
///
/// Measured through the segmenter's own arithmetic on the editor's 900x1200
/// preview of this photo (background estimate (128, 122, 116), Otsu 168.7):
///
///   top frame band  reaches 3 frame edges  -> frameArtifact
///   dark strip      aspect 16.08           -> implausibleAspect
///   card 1 631x397  aspect 1.58, crop 546x345            -> accepted
///   card 2 321x505  aspect 1.58, crop 278x439 (portrait) -> accepted
///   card 3 721x453  aspect 1.59, crop 626x392            -> accepted
///
/// The furniture is therefore refused BY THE GATES with a wide margin (16.08
/// against a bound of 8.0; 3 frame edges against a bound of 2), not by luck: a
/// variant of this photo whose border median happened to land on the frame
/// colour was also tried, and the furniture simply fell below the Otsu
/// threshold instead — reaching the same three documents by a route that
/// proves nothing, which is why this geometry is the one asserted.
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
    segmenter: realSegmenter,
  );

  test(
    'a narrow dark strip beside two cards creates no third document',
    () async {
      final photo = _twoCards();
      // A solid dark strip, 57 px wide and 721 px tall (measured aspect 12.46 at
      // working scale against a bound of 8.0, 68 px short side in the preview).
      _rect(photo, 40, 700, 96, 1420, _dark);
      final s = service();
      final bytes = _png(photo);
      var project = await s.create('بطاقتان وشريط');
      project = (await s.importImages(project, [
        ImportSource('صورة.png', () => Stream<List<int>>.value(bytes)),
      ])).project;
      final sourceId = project.assets.single.id;
      final originalPath = project.assets.single.originalPath;

      final report = await s.arrangeImportedImages(project, [sourceId]);
      final result = report.project;

      // The defect: this used to be 3 documents / 3 items / 4 assets, the extra
      // one a strip of background with no confirmed size, sitting outside the
      // sheet. The two real cards are unaffected.
      expect(result.documents, hasLength(2));
      expect(result.items, hasLength(2));
      expect(result.assets, hasLength(3), reason: 'original + two derived');
      expect(report.multiDocumentImages, 1);
      expect(report.cropped, 2);
      expect(report.rejectedRegions, 1);

      // Both survivors are real, confirmed, placed documents — not off-sheet
      // fragments.
      for (final item in result.items) {
        expect(item.documentKind, DocumentKind.unifiedNationalId);
        expect(item.sizeConfirmed, isTrue);
        expect(item.pageIndex, 0);
        expect([item.width, item.height], [85.6, 53.98]);
      }
      // No item was sized from the strip's proportions.
      expect(
        result.items.where((i) => i.height > i.width * 2),
        isEmpty,
        reason: 'no ration-card-shaped fragment',
      );

      // The refusal is reported to the user in Arabic, aggregated, and the
      // original photo is byte-for-byte untouched (ADR-003).
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

      // Every derived asset traces back to the source photo.
      for (final asset in result.assets.where((a) => a.id != sourceId)) {
        expect(asset.derivedFrom, sourceId);
      }
    },
  );

  test('the reported photo yields exactly its three documents', () async {
    final s = service();
    final bytes = _png(_reportedCase());
    var project = await s.create('الحالة المبلّغة');
    project = (await s.importImages(project, [
      ImportSource('ثلاثة.png', () => Stream<List<int>>.value(bytes)),
    ])).project;
    final sourceId = project.assets.single.id;

    final report = await s.arrangeImportedImages(project, [sourceId]);
    final result = report.project;

    expect(result.documents, hasLength(3));
    expect(result.items, hasLength(3));
    expect(result.assets, hasLength(4), reason: 'original + three derived');
    // Both pieces of furniture were measured and refused WITH A REASON, and
    // the three real documents were placed. Nothing was silently dropped and
    // nothing extra entered the project.
    expect(report.rejectedRegions, 2);
    expect(report.multiDocumentImages, 1);
    expect(report.cropped, 3);
    // No item carries a fragment's proportions. Two cards are photographed
    // landscape and one portrait, so the assertion is on the PAIR of edges:
    // the catalog ID-1 size in whichever orientation the crop is held.
    for (final item in result.items) {
      expect(item.documentKind, DocumentKind.unifiedNationalId);
      expect(item.sizeConfirmed, isTrue);
      expect(math.max(item.width, item.height), 85.6);
      expect(math.min(item.width, item.height), 53.98);
    }
    // Orientation follows the MEASURED crop, never a fixed assumption: card 2
    // is held portrait, so exactly one item is taller than it is wide.
    expect(result.items.where((i) => i.height > i.width), hasLength(1));
    // The derived crops are all card-shaped in whichever orientation they are
    // held, so nothing off-sheet was made.
    for (final asset in result.assets.where((a) => a.id != sourceId)) {
      final long = math.max(asset.width, asset.height).toDouble();
      final short = math.min(asset.width, asset.height).toDouble();
      expect(long / short, greaterThan(1.4));
      expect(long / short, lessThan(1.8));
    }
  });

  test('a region too small to crop creates no document', () async {
    final image = _canvas(200, 200, img.ColorRgb8(128, 122, 116));
    _rect(image, 20, 20, 170, 110, _paper);
    _rect(image, 60, 150, 94, 184, _dark);
    final s = service();
    final bytes = _png(image);
    var project = await s.create('صغيرة');
    project = (await s.importImages(project, [
      ImportSource('صغيرة.png', () => Stream<List<int>>.value(bytes)),
    ])).project;
    final sourceId = project.assets.single.id;

    final report = await s.arrangeImportedImages(project, [sourceId]);
    final result = report.project;

    // One plausible region is left, so the precise single-document detector
    // handles the photo: exactly one document, and the fragment is refused.
    expect(result.documents, hasLength(1));
    expect(result.items, hasLength(1));
    expect(result.assets, hasLength(2));
    expect(report.rejectedRegions, 1);
    expect(report.multiDocumentImages, 0);
  });

  test(
    'an ambiguous blank region is preserved for review, never confirmed',
    () async {
      final image = _canvas(1200, 1600, img.ColorRgb8(88, 90, 96));
      _rect(image, 120, 120, 640, 450, _paper);
      // A blank sheet of paper that is not a document. Its shape matches no
      // catalogued size (1021x281, ratio 3.63 — measured 3.61 at working scale,
      // well inside the aspect bound of 8.0 and reaching no frame edge), so
      // nothing about it can be confirmed — but it is not provably invalid
      // either, so it is KEPT for review instead of being refused. This is the
      // deliberate Case-4 boundary.
      _rect(image, 100, 1300, 1120, 1580, img.ColorRgb8(246, 245, 242));
      final s = service();
      final bytes = _png(image);
      var project = await s.create('غامضة');
      project = (await s.importImages(project, [
        ImportSource('غامضة.png', () => Stream<List<int>>.value(bytes)),
      ])).project;
      final sourceId = project.assets.single.id;

      final report = await s.arrangeImportedImages(project, [sourceId]);
      final result = report.project;

      expect(result.documents, hasLength(2));
      expect(report.rejectedRegions, 0, reason: 'ambiguity is not invalidity');

      final confirmed = result.items.where((i) => i.sizeConfirmed).toList();
      final pending = result.items.where((i) => !i.sizeConfirmed).toList();
      expect(confirmed, hasLength(1));
      expect(confirmed.single.documentKind, DocumentKind.unifiedNationalId);
      expect(pending, hasLength(1));
      expect(pending.single.documentKind, DocumentKind.unknown);

      // The ambiguous one is recoverable: it stays in the review queue with an
      // explicit reason and is never presented as a confirmed document.
      final pendingRecord = result.documents.firstWhere(
        (d) => d.id == pending.single.documentId,
      );
      expect(pendingRecord.recognition!.preset.awaitingSize, isTrue);
      expect(reviewReasons(pendingRecord), contains('بانتظار تحديد المقاس'));
      expect(recordNeedsReview(pendingRecord), isTrue);
      // Its source photo is preserved, so the region can be re-examined.
      expect(pendingRecord.provenance.sourceImageId, sourceId);
      expect(
        result.assets.firstWhere((a) => a.id == sourceId).originalPath,
        isNotEmpty,
      );
    },
  );

  test(
    'reprocessing a photo with artifacts does not duplicate anything',
    () async {
      final photo = _twoCards();
      _rect(photo, 40, 700, 96, 1420, _dark);
      final s = service();
      final bytes = _png(photo);
      var project = await s.create('إعادة');
      project = (await s.importImages(project, [
        ImportSource('صورة.png', () => Stream<List<int>>.value(bytes)),
      ])).project;
      final sourceId = project.assets.single.id;
      final first = await s.arrangeImportedImages(project, [sourceId]);

      final itemIds = first.project.items.map((i) => i.id).toList();
      final recordIds = first.project.documents.map((d) => d.id).toList();
      final assetIds = first.project.assets.map((a) => a.id).toList();

      final second = await s.reprocessImages(first.project, [sourceId]);
      final result = second!.project;

      // The strip is refused again — it is never re-analysed as a photo and
      // never comes back as a duplicate document.
      expect(result.documents, hasLength(2));
      expect(result.items, hasLength(2));
      expect(result.assets, hasLength(3));
      expect(result.documents.map((d) => d.id).toList(), recordIds);
      expect(result.items.map((i) => i.id).toList(), itemIds);
      expect(result.assets.map((a) => a.id).toList(), assetIds);
      expect(second.rejectedRegions, 1);
      // Placement is still the deterministic engine's decision.
      expect((await projects.get(result.id)).toJson(), result.toJson());
    },
  );

  test('the real isolate seam carries rejections through', () async {
    // defaultSegment runs the segmenter off the UI isolate; the rejections
    // must survive that boundary so the report is not isolate-dependent.
    final direct = await defaultSegment(_png(_twoCards()));
    expect(direct.rejected, isEmpty);
    expect(direct.candidates, hasLength(2));

    final photo = _twoCards();
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
