import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/application/recognition_worker.dart';
import 'package:scan_id/domain/arrangement.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/page_layout.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_overrides.dart';
import 'package:scan_id/imaging/document_segmenter.dart';
import 'package:scan_id/imaging/large_jpeg_plan.dart';
import 'package:scan_id/persistence/large_jpeg_scaler.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

/// Two ID-1-shaped quads inside a 1000×1000 source: width 0.8, height
/// 0.8 / 1.586 ≈ 0.5045 — so each warped crop classifies by shape alone.
List<Point2> _topQuad() => [
  Point2(.1, .1),
  Point2(.9, .1),
  Point2(.9, .6045),
  Point2(.1, .6045),
];

Future<SegmentationResult> _twoCards(Uint8List bytes) async =>
    SegmentationResult(
      multi: true,
      candidates: [
        SegmentCandidate(
          region: const [.1, .1, .9, .6],
          corners: _topQuad(),
          detectionConfidence: .8,
          reason: 'component-support',
        ),
        SegmentCandidate(
          // Width .6, height .6 / 1.586 ≈ .3783 — the ID-1 shape again.
          region: const [.2, .62, .8, 1],
          corners: [
            Point2(.2, .62),
            Point2(.8, .62),
            Point2(.8, .9983),
            Point2(.2, .9983),
          ],
          detectionConfidence: .75,
          reason: 'component-support',
        ),
      ],
    );

/// Two MEASURED regions, but only the top one resolves into a trustworthy
/// quadrilateral — the reported silent-loss case (AUDIT §G SEGMENT).
///
/// The bottom region carries its measured bounds and no corners: the intake
/// must preserve it, never drop it and never guess a rectangle for it.
Future<SegmentationResult> _cardPlusUnresolved(Uint8List bytes) async =>
    SegmentationResult(
      multi: true,
      candidates: [
        SegmentCandidate(
          region: const [.1, .1, .9, .6],
          corners: _topQuad(),
          detectionConfidence: .8,
          reason: 'component-support',
        ),
        const SegmentCandidate(
          // Width .6, height .38 of a 1000×1000 source → a 600×380 crop.
          region: [.2, .62, .8, 1],
          reason: 'no-trustworthy-quad',
        ),
      ],
    );

/// Two measured regions, neither with a trustworthy quadrilateral. The old
/// multi hint is false because it used to depend on at least one quad — these
/// still have to enter the multi-region preservation path.
Future<SegmentationResult> _twoUnresolved(
  Uint8List bytes,
) async => const SegmentationResult(
  multi: false,
  candidates: [
    SegmentCandidate(region: [.1, .1, .9, .45], reason: 'no-trustworthy-quad'),
    SegmentCandidate(region: [.1, .55, .9, .95], reason: 'no-trustworthy-quad'),
  ],
);

Future<SegmentationResult> _oneRejectedQuad(Uint8List bytes) async =>
    SegmentationResult(
      multi: false,
      candidates: [
        SegmentCandidate(
          region: const [.2, .2, .8, .8],
          corners: [
            Point2(.1, .1),
            Point2(.9, .9),
            Point2(.9, .1),
            Point2(.1, .9),
          ],
          detectionConfidence: .6,
          reason: 'component-support',
        ),
      ],
    );

Future<SegmentationResult> _oneValidCard(Uint8List bytes) async =>
    SegmentationResult(
      multi: false,
      candidates: [
        SegmentCandidate(
          region: const [.1, .1, .9, .6045],
          corners: _topQuad(),
          detectionConfidence: .8,
          reason: 'component-support',
        ),
      ],
    );

Uint8List _smallDistantScene() {
  final image = img.Image(width: 1200, height: 1600);
  img.fill(image, color: img.ColorRgb8(52, 50, 48));
  img.fillRect(
    image,
    x1: 120,
    y1: 200,
    x2: 900,
    y2: 700,
    color: img.ColorRgb8(240, 238, 230),
  );
  img.fillRect(
    image,
    x1: 900,
    y1: 1000,
    x2: 1170,
    y2: 1180,
    color: img.ColorRgb8(232, 230, 222),
  );
  return Uint8List.fromList(img.encodePng(image));
}

Uint8List _photo() {
  final source = img.Image(width: 1000, height: 1000);
  img.fill(source, color: img.ColorRgb8(50, 60, 75));
  img.fillRect(
    source,
    x1: 100,
    y1: 100,
    x2: 900,
    y2: 604,
    color: img.ColorRgb8(240, 238, 232),
  );
  img.fillRect(
    source,
    x1: 200,
    y1: 620,
    x2: 800,
    y2: 998,
    color: img.ColorRgb8(226, 230, 235),
  );
  return Uint8List.fromList(img.encodePng(source));
}

Uint8List _jpegSofOnly(int width, int height) => Uint8List.fromList([
  0xff,
  0xd8,
  0xff,
  0xc0,
  0,
  11,
  8,
  (height >> 8) & 255,
  height & 255,
  (width >> 8) & 255,
  width & 255,
  1,
  1,
  0x11,
  0,
  0xff,
  0xd9,
]);

Uint8List _jpegWithExifOrientation(int width, int height, int orientation) =>
    Uint8List.fromList([
      0xff,
      0xd8,
      0xff,
      0xe1,
      0x00,
      0x22,
      0x45,
      0x78,
      0x69,
      0x66,
      0x00,
      0x00,
      0x49,
      0x49,
      0x2a,
      0x00,
      0x08,
      0x00,
      0x00,
      0x00,
      0x01,
      0x00,
      0x12,
      0x01,
      0x03,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      orientation,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      ..._jpegSofOnly(width, height).skip(2),
    ]);

Uint8List _pngHeaderOnly(int width, int height) {
  final bytes = Uint8List(33);
  bytes.setAll(0, [137, 80, 78, 71, 13, 10, 26, 10]);
  final header = ByteData.sublistView(bytes);
  header.setUint32(8, 13);
  header.setUint32(12, 0x49484452);
  header.setUint32(16, width);
  header.setUint32(20, height);
  return bytes;
}

class _FakeLargeJpegScaler implements LargeJpegScaler {
  _FakeLargeJpegScaler(this.workingPng);
  final Uint8List workingPng;
  LargeJpegPlan? lastPlan;

  @override
  Future<Uint8List> scaleJpeg(Uint8List source, LargeJpegPlan plan) async {
    lastPlan = plan;
    return Uint8List.fromList(workingPng);
  }
}

void main() {
  late Directory root;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan-smart-');
    projects = await LocalProjectRepository.open(root);
    assets = LocalAssetRepository(projects.files);
  });

  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
  });

  ProjectService service({
    Future<SegmentationResult> Function(Uint8List bytes)? segmenter,
    bool smartRecognitionEnabled = true,
    bool multiDocumentSegmentationEnabled = true,
  }) => ProjectService(
    projects,
    assets,
    imageEditor: LocalImageEditor(projects.files),
    smartRecognitionEnabled: smartRecognitionEnabled,
    multiDocumentSegmentationEnabled: multiDocumentSegmentationEnabled,
    segmenter: segmenter,
  );

  test(
    'one photo of two cards takes the independent multi-only path',
    () async {
      final s = service(segmenter: _twoCards, smartRecognitionEnabled: false);
      expect(s.smartRecognitionEnabled, isFalse);
      var project = await s.create('مستندان');
      final bytes = _photo();
      project = (await s.importImages(project, [
        ImportSource('بطاقتان.png', () => Stream.value(bytes)),
      ])).project;
      final sourceId = project.assets.single.id;
      final originalPath = project.assets.single.originalPath;

      final report = await s.arrangeImportedImages(project, [sourceId]);
      final result = report.project;

      expect(report.multiDocumentImages, 1);
      expect(report.cropped, 2);
      expect(report.needsReview, 2);
      expect(recordsNeedingReview(report.project), hasLength(2));
      expect(result.assets, hasLength(3), reason: 'original + two derived');
      expect(result.items, hasLength(2));
      expect(result.documents, hasLength(2));
      // The original image bytes are untouched (ADR-003).
      expect(await (await assets.resolve(originalPath)).readAsBytes(), bytes);
      // No item points at the source photo; each item has its derived asset.
      expect(result.items.every((i) => i.assetId != sourceId), isTrue);
      for (final item in result.items) {
        expect(item.documentKind, DocumentKind.unifiedNationalId);
        expect(item.sizeConfirmed, isTrue);
        expect(item.pageIndex, 0);
        expect([item.width, item.height], [85.6, 53.98]);
      }
      // Derived assets carry readable Arabic names and rectified shapes.
      final derived = result.assets.where((a) => a.id != sourceId).toList();
      expect(derived[0].name, contains('مستند 1'));
      expect(derived[1].name, contains('مستند 2'));
      for (final asset in derived) {
        expect(asset.width / asset.height, closeTo(85.6 / 53.98, .02));
      }
      // Records: recognition truth, provenance back to the source photo.
      for (final record in result.documents) {
        expect(record.provenance.sourceImageId, sourceId);
        expect(record.sides.single.detection!.producer, 'document-segmenter');
        expect(
          record.recognition!.documentKind,
          DocumentKind.unifiedNationalId,
        );
        // Two cards on ONE photo are never two sides of one card.
        expect(record.pairing, PairingState.single);
        expect(record.pairedDocumentId, isNull);
      }
      expect(result.layoutGroups, isEmpty);
      // The result equals what was saved.
      expect((await projects.get(result.id)).toJson(), result.toJson());
    },
  );

  test(
    'a multi-source import batch arranges every new region together',
    () async {
      final s = service(segmenter: _twoCards, smartRecognitionEnabled: false);
      var project = await s.create('أربع مناطق');
      final bytes = _photo();
      project = (await s.importImages(project, [
        ImportSource('الصورة الأولى.png', () => Stream.value(bytes)),
        ImportSource('الصورة الثانية.png', () => Stream.value(bytes)),
      ])).project;

      final report = await s.arrangeImportedImages(
        project,
        project.assets.map((asset) => asset.id),
      );

      expect(report.multiDocumentImages, 2);
      expect(report.cropped, 4);
      expect(report.project.items, hasLength(4));
      expect(report.project.items.every((item) => item.pageIndex == 0), isTrue);
      expect(inspectLayout(report.project), isEmpty);
      expect(recordsNeedingReview(report.project), hasLength(4));
    },
  );

  test('one candidate stays on the legacy single-document path', () async {
    final s = service(segmenter: _oneValidCard, smartRecognitionEnabled: false);
    var project = await s.create('مستند واحد');
    final bytes = _photo();
    project = (await s.importImages(project, [
      ImportSource('بطاقة.png', () => Stream.value(bytes)),
    ])).project;
    final sourceId = project.assets.single.id;

    final report = await s.arrangeImportedImages(project, [sourceId]);

    expect(report.multiDocumentImages, 0);
    expect(report.project.documents, isEmpty);
    expect(report.project.items, hasLength(1));
    expect(report.project.items.single.assetId, sourceId);
    expect(report.project.assets, hasLength(1));
  });

  test('segmentation failure falls back with an explicit warning', () async {
    final s = service(
      segmenter: (_) async =>
          throw StateError('synthetic segmentation failure'),
      smartRecognitionEnabled: false,
    );
    var project = await s.create('رجوع آمن');
    final bytes = img.encodePng(img.Image(width: 400, height: 300));
    project = (await s.importImages(project, [
      ImportSource('single.png', () => Stream.value(bytes)),
    ])).project;
    final sourceId = project.assets.single.id;

    final report = await s.arrangeImportedImages(project, [sourceId]);

    expect(report.project.items, hasLength(1));
    expect(report.project.documents, isEmpty);
    expect(
      report.warnings.any(
        (warning) => warning.contains('تعذر فحص التقسيم متعدد المستمسكات'),
      ),
      isTrue,
    );
  });

  test(
    'disabling the separate policy leaves imports on the legacy path',
    () async {
      var segmented = false;
      final s = service(
        segmenter: (bytes) async {
          segmented = true;
          return _twoCards(bytes);
        },
        smartRecognitionEnabled: false,
        multiDocumentSegmentationEnabled: false,
      );
      var project = await s.create('سياسة التقسيم متوقفة');
      project = (await s.importImages(project, [
        ImportSource('two-cards.png', () => Stream.value(_photo())),
      ])).project;

      final report = await s.arrangeImportedImages(project, [
        project.assets.single.id,
      ]);

      expect(segmented, isFalse);
      expect(report.project.items, hasLength(1));
      expect(report.project.documents, isEmpty);
    },
  );

  test(
    'multi-only import keeps an unresolved region for manual review',
    () async {
      final s = service(
        segmenter: _cardPlusUnresolved,
        smartRecognitionEnabled: false,
      );
      var project = await s.create('مستندان أحدهما بلا حدود');
      final bytes = _photo();
      project = (await s.importImages(project, [
        ImportSource('صورة.png', () => Stream.value(bytes)),
      ])).project;
      final sourceId = project.assets.single.id;
      final originalPath = project.assets.single.originalPath;

      final report = await s.arrangeImportedImages(project, [sourceId]);
      final result = report.project;

      // No document is lost: both measured regions became documents.
      expect(result.items, hasLength(2));
      expect(result.documents, hasLength(2));
      expect(result.assets, hasLength(3), reason: 'original + two derived');

      // The original source image is untouched (ADR-003) and — critically —
      // was NOT cropped to the one quad that was found, which would have made
      // the second region unrecoverable.
      expect(await (await assets.resolve(originalPath)).readAsBytes(), bytes);
      final source = result.assets.firstWhere((a) => a.id == sourceId);
      expect(source.crop, isNull);
      expect(result.items.any((i) => i.assetId == sourceId), isFalse);

      // No duplicate items and no duplicate asset references.
      expect(result.items.map((i) => i.id).toSet(), hasLength(2));
      expect(result.items.map((i) => i.assetId).toSet(), hasLength(2));
      expect(result.documents.map((d) => d.id).toSet(), hasLength(2));

      // The unresolved region is preserved as an un-warped crop of the
      // measured bounds: nothing was invented for it.
      final unresolvedRecord = result.documents.firstWhere(
        (d) => d.sides.single.detection!.polygon == null,
      );
      final unresolvedItem = result.items.firstWhere(
        (i) => i.documentId == unresolvedRecord.id,
      );
      final unresolvedAsset = result.assets.firstWhere(
        (a) => a.id == unresolvedItem.assetId,
      );
      expect(unresolvedAsset.width, closeTo(600, 2));
      expect(unresolvedAsset.height, closeTo(380, 2));
      // An unrectified crop never claims a confirmed catalog size.
      expect(unresolvedItem.sizeConfirmed, isFalse);

      // The resolved region is still a properly rectified document.
      final resolvedRecord = result.documents.firstWhere(
        (d) => d.sides.single.detection!.polygon != null,
      );
      final resolvedItem = result.items.firstWhere(
        (i) => i.documentId == resolvedRecord.id,
      );
      expect(resolvedItem.documentKind, DocumentKind.unifiedNationalId);
      expect(resolvedItem.sizeConfirmed, isTrue);

      // The user is told what happened and how to finish the job.
      expect(
        report.warnings.join('\n'),
        contains('يدوياً'),
        reason: 'an unresolved region must be reported, never silent',
      );
      expect(report.notDetected, 1);

      // Placement remains the deterministic engine's job (ADR-002).
      expect((await projects.get(result.id)).toJson(), result.toJson());
    },
  );

  test(
    'a multi-region photo with no trustworthy quad still keeps every region',
    () async {
      final s = service(segmenter: _twoUnresolved);
      var project = await s.create('بلا حدود');
      final bytes = _photo();
      project = (await s.importImages(project, [
        ImportSource('صورة.png', () => Stream.value(bytes)),
      ])).project;
      final sourceId = project.assets.single.id;
      final originalPath = project.assets.single.originalPath;

      final report = await s.arrangeImportedImages(project, [sourceId]);
      final result = report.project;

      expect(result.items, hasLength(2));
      expect(result.documents, hasLength(2));
      expect(
        result.documents.every(
          (d) => d.sides.single.detection!.polygon == null,
        ),
        isTrue,
        reason: 'no rectangle is fabricated for an unresolved region',
      );
      // Nothing was warped, so nothing is counted as cropped.
      expect(report.cropped, 0);
      expect(report.notDetected, 2);
      expect(report.multiDocumentImages, 1);
      expect(await (await assets.resolve(originalPath)).readAsBytes(), bytes);
      final source = result.assets.firstWhere((a) => a.id == sourceId);
      expect(source.crop, isNull);
      expect((await projects.get(result.id)).toJson(), result.toJson());
    },
  );

  test(
    'a single candidate with rejected corners is kept as a measured manual crop',
    () async {
      final s = service(segmenter: _oneRejectedQuad);
      var project = await s.create('حدود مرفوضة');
      final bytes = _photo();
      project = (await s.importImages(project, [
        ImportSource('منطقة.jpg', () => Stream.value(bytes)),
      ])).project;
      final sourceId = project.assets.single.id;
      final sourcePath = project.assets.single.originalPath;

      final report = await s.arrangeImportedImages(project, [sourceId]);
      final result = report.project;
      final record = result.documents.single;
      final item = result.items.single;
      final derived = result.assets.firstWhere(
        (asset) => asset.id == item.assetId,
      );

      expect(report.multiDocumentImages, 0);
      expect(report.cropped, 0);
      expect(report.notDetected, 1);
      expect(result.documents, hasLength(1));
      expect(derived.derivedFrom, sourceId);
      expect([derived.width, derived.height], [600, 600]);
      expect(record.sourceImageId, sourceId);
      expect(record.sides.single.detection!.polygon, isNull);
      expect(record.sides.single.processedAsset.corners, isNull);
      expect(item.sizeConfirmed, isFalse);
      expect(await (await assets.resolve(sourcePath)).readAsBytes(), bytes);

      // The user can replace the rejected detector geometry with a manual crop.
      // This edit does not re-label the failed machine corners as trustworthy.
      final manuallyCropped = await s.applyManualCrop(
        result,
        derived,
        CropDraft(
          corners: [
            Point2(.1, .1),
            Point2(.9, .1),
            Point2(.9, .9),
            Point2(.1, .9),
          ],
        ).toRecipe(derived.width, derived.height),
      );
      final recovered = manuallyCropped.assets.firstWhere(
        (asset) => asset.id == derived.id,
      );
      expect(recovered.derivedFrom, sourceId);
      expect(recovered.userAuthoredCrop, isTrue);
      expect(recovered.workingPath, isNot(derived.workingPath));
      expect(recovered.crop, isNotNull);
      expect(
        manuallyCropped.documents.single.sides.single.detection!.polygon,
        isNull,
      );
      expect(manuallyCropped.items.single.id, item.id);
      expect(await (await assets.resolve(sourcePath)).readAsBytes(), bytes);
    },
  );

  test(
    'reprocessing preserves a user-authored crop on an unresolved derived region',
    () async {
      final s = service(segmenter: _oneRejectedQuad);
      var project = await s.create('حفظ القص اليدوي عند إعادة المعالجة');
      final bytes = _photo();
      project = (await s.importImages(project, [
        ImportSource('منطقة.jpg', () => Stream.value(bytes)),
      ])).project;
      final sourceId = project.assets.single.id;
      final sourcePath = project.assets.single.originalPath;
      final first = (await s.arrangeImportedImages(project, [
        sourceId,
      ])).project;
      final itemBefore = first.items.single;
      final recordBefore = first.documents.single;
      final derived = first.assets.firstWhere(
        (asset) => asset.id == itemBefore.assetId,
      );
      final manuallyCropped = await s.applyManualCrop(
        first,
        derived,
        CropDraft(
          corners: [
            Point2(.1, .1),
            Point2(.9, .1),
            Point2(.9, .9),
            Point2(.1, .9),
          ],
        ).toRecipe(derived.width, derived.height),
      );
      final edited = manuallyCropped.assets.firstWhere(
        (asset) => asset.id == derived.id,
      );
      final cropBefore = edited.crop!.toJson();
      expect(edited.userAuthoredCrop, isTrue);
      expect(
        Project.fromJson(
          manuallyCropped.toJson(),
        ).assets.firstWhere((asset) => asset.id == edited.id).userAuthoredCrop,
        isTrue,
      );
      final itemAfterCrop = manuallyCropped.items.single;

      final report = await s.reprocessImages(manuallyCropped, [sourceId]);
      final result = report!.project;
      final preserved = result.assets.firstWhere(
        (asset) => asset.id == edited.id,
      );
      final recordAfter = result.documents.single;

      expect(preserved.workingPath, edited.workingPath);
      expect(preserved.crop!.toJson(), cropBefore);
      expect(preserved.derivedFrom, sourceId);
      expect(recordAfter.toJson(), recordBefore.toJson());
      expect(recordAfter.sides.single.detection!.polygon, isNull);
      expect(result.items.single.toJson(), itemAfterCrop.toJson());
      expect(recordsNeedingReview(result), hasLength(1));
      expect(report.warnings.join('\n'), contains('القص اليدوي'));
      expect(await (await assets.resolve(sourcePath)).readAsBytes(), bytes);
    },
  );

  test(
    'automatic recognition replaces the crop and clears stale user authorship',
    () async {
      final s = service(segmenter: _oneValidCard);
      final bytes = _photo();
      var project = await s.create('قص تلقائي بعد تعديل يدوي');
      project = (await s.importImages(project, [
        ImportSource('بطاقة.png', () => Stream.value(bytes)),
      ])).project;
      final sourceId = project.assets.single.id;
      final sourcePath = project.assets.single.originalPath;
      final manuallyCropped = await s.applyManualCrop(
        project,
        project.assets.single,
        CropDraft(
          corners: [
            Point2(.05, .05),
            Point2(.95, .05),
            Point2(.95, .95),
            Point2(.05, .95),
          ],
        ).toRecipe(1000, 1000),
      );
      final manualAsset = manuallyCropped.assets.single;
      expect(manualAsset.userAuthoredCrop, isTrue);

      final report = await s.arrangeImportedImages(manuallyCropped, [sourceId]);
      final result = report.project;
      final updated = result.assets.single;

      expect(report.cropped, 1);
      expect(updated.workingPath, isNot(manualAsset.workingPath));
      expect(updated.crop, isNotNull);
      expect(updated.userAuthoredCrop, isFalse);
      expect(
        result.documents.single.sides.single.detection!.polygon,
        isNotNull,
      );
      expect(await (await assets.resolve(sourcePath)).readAsBytes(), bytes);
    },
  );

  test(
    'large JPEG downscaling preserves multi-region coordinates and source bytes',
    () async {
      final original = _jpegSofOnly(5000, 5000);
      final scaler = _FakeLargeJpegScaler(_photo());
      assets = LocalAssetRepository(projects.files, largeJpegScaler: scaler);
      final s = service(segmenter: _twoCards);
      var project = await s.create('مصدر JPEG كبير');
      final imported = await s.importImages(project, [
        ImportSource('بطاقتان كبيرة.jpg', () => Stream.value(original)),
      ]);
      project = imported.project;
      expect(imported.notices, hasLength(1));
      expect(imported.notices.single.name, 'بطاقتان كبيرة.jpg');
      expect(imported.notices.single.message, contains('حُفظ الأصل كما هو'));
      final source = project.assets.single;
      expect(scaler.lastPlan, isNotNull);
      expect(scaler.lastPlan!.targetPixels, lessThanOrEqualTo(4000000));
      expect([source.width, source.height], [1000, 1000]);
      expect(source.hasScaledLargeSource, isTrue);
      expect(source.transforms.last, contains('large-jpeg:5000x5000'));
      expect(
        await (await assets.resolve(source.originalPath)).readAsBytes(),
        original,
      );

      final report = await s.arrangeImportedImages(project, [source.id]);
      final result = report.project;

      expect(report.multiDocumentImages, 1);
      expect(result.items, hasLength(2));
      expect(result.documents, hasLength(2));
      expect(result.assets, hasLength(3));
      for (final record in result.documents) {
        expect(record.provenance.sourceImageId, source.id);
        final corners = record.sides.single.processedAsset.corners!;
        expect(corners, hasLength(4));
        for (final corner in corners) {
          expect(corner.x, inInclusiveRange(0, 1));
          expect(corner.y, inInclusiveRange(0, 1));
        }
      }
      expect(
        await (await assets.resolve(source.originalPath)).readAsBytes(),
        original,
      );
      expect(Project.fromJson(result.toJson()).toJson(), result.toJson());
    },
  );

  test(
    'a cropped large source reprocesses from its stable sample without moving a locked item',
    () async {
      final original = _jpegSofOnly(5000, 5000);
      final scaler = _FakeLargeJpegScaler(_photo());
      assets = LocalAssetRepository(projects.files, largeJpegScaler: scaler);
      final s = service(segmenter: _oneValidCard);
      var project = await s.create('إعادة معالجة مصدر كبير');
      project = (await s.importImages(project, [
        ImportSource('بطاقة.jpg', () => Stream.value(original)),
      ])).project;
      final initialAsset = project.assets.single;
      final baseRaster = initialAsset.processingInputPath;
      expect(initialAsset.hasScaledLargeSource, isTrue);

      project = (await s.arrangeImportedImages(project, [
        initialAsset.id,
      ])).project;
      final firstPlacement = project.items.single.copyWith(
        x: 31,
        y: 42,
        locked: true,
      );
      project = await projects.save(project.copyWith(items: [firstPlacement]));
      final itemId = project.items.single.id;
      final recordId = project.documents.single.id;
      final firstRevision = project.assets.single.workingPath;
      expect(firstRevision, isNot(baseRaster));
      expect(project.assets.single.processingInputPath, baseRaster);
      expect(await assets.resolve(baseRaster), isNotNull);

      final report = await s.reprocessImages(project, [initialAsset.id]);
      final refreshed = report!.project;
      expect(refreshed.assets, hasLength(1));
      expect(refreshed.items, hasLength(1));
      expect(refreshed.documents, hasLength(1));
      expect(refreshed.items.single.id, itemId);
      expect(refreshed.documents.single.id, recordId);
      expect(refreshed.items.single.toJson(), firstPlacement.toJson());
      expect(refreshed.assets.single.workingPath, isNot(firstRevision));
      expect(refreshed.assets.single.processingInputPath, baseRaster);
      expect(await (await assets.resolve(baseRaster)).exists(), isTrue);
      expect(
        await (await assets.resolve(
          refreshed.assets.single.originalPath,
        )).readAsBytes(),
        original,
      );

      final again = await s.reprocessImages(refreshed, [initialAsset.id]);
      expect(again!.project.items, hasLength(1));
      expect(again.project.documents, hasLength(1));
      expect(again.project.assets, hasLength(1));
      expect(again.project.items.single.toJson(), firstPlacement.toJson());
      expect(again.project.documents.single.id, recordId);
      expect(await (await assets.resolve(baseRaster)).exists(), isTrue);
      expect(
        await (await assets.resolve(
          again.project.assets.single.originalPath,
        )).readAsBytes(),
        original,
      );
    },
  );

  test(
    'synthetic small distant candidate survives the large-JPEG working-raster path',
    () async {
      final original = _jpegSofOnly(4800, 6400);
      final workingPng = _smallDistantScene();
      final scaler = _FakeLargeJpegScaler(workingPng);
      assets = LocalAssetRepository(projects.files, largeJpegScaler: scaler);
      final segment = segmentDocumentBytes(workingPng);
      expect(segment.candidates, hasLength(2));
      expect(segment.rejected, isEmpty);

      final s = service(); // Production segmenter, not an injected result.
      var project = await s.create('مستند بعيد في صورة كبيرة');
      project = (await s.importImages(project, [
        ImportSource('مشهد صناعي.jpg', () => Stream.value(original)),
      ])).project;
      final source = project.assets.single;
      expect(source.hasScaledLargeSource, isTrue);
      expect(source.processingInputPath, isNot(source.originalPath));

      final report = await s.arrangeImportedImages(project, [source.id]);
      final result = report.project;
      final derived = result.assets
          .where((asset) => asset.id != source.id)
          .toList();
      expect(report.multiDocumentImages, 1);
      expect(result.documents, hasLength(2));
      expect(result.items, hasLength(2));
      expect(derived, hasLength(2));
      final areas = derived.map((asset) => asset.width * asset.height).toList()
        ..sort();
      expect(areas.first, greaterThan(0));
      expect(areas.last, greaterThan(areas.first));
      expect(
        await (await assets.resolve(source.originalPath)).readAsBytes(),
        original,
      );
      expect(
        await (await assets.resolve(source.processingInputPath)).readAsBytes(),
        workingPng,
      );
    },
  );

  test(
    'a failed large-image import does not discard neighboring successes',
    () async {
      final originalLarge = _jpegSofOnly(5000, 5000);
      final scaler = _FakeLargeJpegScaler(_photo());
      assets = LocalAssetRepository(projects.files, largeJpegScaler: scaler);
      final s = service();
      final project = await s.create('استيراد مختلط كبير');
      final small = img.encodePng(img.Image(width: 30, height: 20));

      final report = await s.importImages(project, [
        ImportSource('large.jpg', () => Stream.value(originalLarge)),
        ImportSource('corrupt.jpg', () => Stream.value([0xff, 0xd8, 0xff])),
        ImportSource(
          'unsupported-large.png',
          () => Stream.value(_pngHeaderOnly(5000, 4000)),
        ),
        ImportSource('small.png', () => Stream.value(small)),
      ]);

      expect(report.imported, 2);
      expect(report.notices, hasLength(1));
      expect(report.notices.single.name, 'large.jpg');
      expect(report.failures, hasLength(2));
      expect(report.failures.map((failure) => failure.name), [
        'corrupt.jpg',
        'unsupported-large.png',
      ]);
      expect(report.failures.first.message, isNotEmpty);
      expect(report.failures.last.message, contains('PNG'));
      expect(report.project.assets, hasLength(2));
      expect(report.project.assets.first.hasScaledLargeSource, isTrue);
      expect(report.project.assets.last.hasScaledLargeSource, isFalse);
      expect(
        await (await assets.resolve(
          report.project.assets.first.originalPath,
        )).readAsBytes(),
        originalLarge,
      );
      expect((await projects.get(project.id)).assets, hasLength(2));
    },
  );

  test(
    'a mismatched scaled raster fails per-image without losing neighbors',
    () async {
      final scaler = _FakeLargeJpegScaler(_photo());
      assets = LocalAssetRepository(projects.files, largeJpegScaler: scaler);
      final s = service();
      final project = await s.create('تصغير غير مطابق');
      final good = img.encodePng(img.Image(width: 40, height: 30));

      final report = await s.importImages(project, [
        ImportSource(
          'bad-aspect.jpg',
          () => Stream.value(_jpegSofOnly(5000, 4000)),
        ),
        ImportSource('good.png', () => Stream.value(good)),
      ]);

      expect(report.imported, 1);
      expect(report.failures, hasLength(1));
      expect(report.failures.single.name, 'bad-aspect.jpg');
      expect(report.failures.single.message, contains('اتجاهه'));
      expect(report.project.assets, hasLength(1));
      expect(report.project.assets.single.name, 'good.png');
    },
  );

  test(
    'large sampled JPEG import maps EXIF orientation to the working raster',
    () async {
      final original = _jpegWithExifOrientation(5000, 4000, 6);
      final scaler = _FakeLargeJpegScaler(
        Uint8List.fromList(img.encodePng(img.Image(width: 800, height: 1000))),
      );
      assets = LocalAssetRepository(projects.files, largeJpegScaler: scaler);
      final project = await service().create('اتجاه مصدر كبير');

      final report = await service().importImages(project, [
        ImportSource('موجّه.jpg', () => Stream.value(original)),
      ]);

      expect(report.imported, 1);
      expect(scaler.lastPlan!.orientation, 6);
      expect(
        [
          report.project.assets.single.width,
          report.project.assets.single.height,
        ],
        [800, 1000],
      );
      expect(report.project.assets.single.transforms.last, contains('exif6'));
      expect(
        await (await assets.resolve(
          report.project.assets.single.originalPath,
        )).readAsBytes(),
        original,
      );
    },
  );

  test('large-source display previews use a bounded sampled raster', () async {
    final scaler = _FakeLargeJpegScaler(
      Uint8List.fromList(img.encodePng(img.Image(width: 1600, height: 1200))),
    );
    assets = LocalAssetRepository(projects.files, largeJpegScaler: scaler);
    final source = _jpegSofOnly(5000, 3750);

    final preview = await assets.previewImage(source);
    final decoded = img.decodePng(preview)!;

    expect(scaler.lastPlan, isNotNull);
    expect(scaler.lastPlan!.targetPixels, lessThanOrEqualTo(4000000));
    expect(decoded.width, 1200);
    expect(decoded.height, 900);
    expect(source, _jpegSofOnly(5000, 3750));
  });

  test(
    'a native sampled raster below the preview floor fails clearly',
    () async {
      final tooSmall = img.encodePng(img.Image(width: 20, height: 16));
      final scaler = _FakeLargeJpegScaler(tooSmall);
      assets = LocalAssetRepository(projects.files, largeJpegScaler: scaler);
      final s = service();
      final project = await s.create('نتيجة تصغير صغيرة');

      final report = await s.importImages(project, [
        ImportSource(
          'too-small.jpg',
          () => Stream.value(_jpegSofOnly(5000, 4000)),
        ),
      ]);

      expect(report.imported, 0);
      expect(report.failures, hasLength(1));
      expect(
        report.failures.single.message,
        contains('أصغر من حد التحليل الأدنى'),
      );
      expect(report.project.assets, isEmpty);
      expect((await projects.get(project.id)).assets, isEmpty);
    },
  );

  test(
    'a dismissed region stays excluded and identifiable on reprocessing',
    () async {
      final s = service(segmenter: _twoCards);
      var project = await s.create('استبعاد وإعادة معالجة');
      final bytes = _photo();
      project = (await s.importImages(project, [
        ImportSource('بطاقتان.png', () => Stream.value(bytes)),
      ])).project;
      final sourceId = project.assets.single.id;
      final originalPath = project.assets.single.originalPath;
      final first = (await s.arrangeImportedImages(project, [
        sourceId,
      ])).project;
      final targetId = recordsNeedingReview(first).first.id;
      final dismissed = await projects.save(
        dismissRecognition(first, targetId),
      );
      final dismissedRecord = dismissed.documents.firstWhere(
        (record) => record.id == targetId,
      );
      final originalAssetIds = dismissed.assets
          .map((asset) => asset.id)
          .toSet();

      final report = await s.reprocessImages(dismissed, [sourceId]);
      final result = report!.project;
      expect(report.warnings.join('\n'), contains('مستبعد بقرارك'));
      expect(report.warnings.join('\n'), isNot(contains('كما أكّدته')));
      final after = result.documents.firstWhere(
        (record) => record.id == targetId,
      );

      expect(after.overrides.last.dismissed, isTrue);
      expect(after.recognition, same(dismissedRecord.recognition));
      expect(
        result.items.where((item) => item.documentId == targetId),
        isEmpty,
      );
      expect(result.documents, hasLength(2));
      expect(result.items, hasLength(1));
      expect(
        result.assets.map((asset) => asset.id),
        containsAll(originalAssetIds),
      );
      expect(await (await assets.resolve(originalPath)).readAsBytes(), bytes);
      expect(Project.fromJson(result.toJson()).toJson(), result.toJson());
    },
  );

  test('recognized records enter the review queue until confirmed', () async {
    final s = service();
    var project = await s.create('مراجعة');
    final bytes = img.encodePng(img.Image(width: 860, height: 540));
    project = (await s.importImages(project, [
      ImportSource('البطاقة الوطنية الموحدة.png', () => Stream.value(bytes)),
    ])).project;
    final report = await s.arrangeImportedImages(project, [
      project.assets.single.id,
    ]);
    expect(report.project.documents, hasLength(1));
    expect(report.needsReview, 1, reason: 'reviewAll mode queues everything');
    final queue = recordsNeedingReview(report.project);
    expect(queue, hasLength(1));

    final confirmed = confirmRecognition(report.project, queue.single.id);
    expect(recordsNeedingReview(confirmed), isEmpty);
    final saved = await projects.save(confirmed);
    expect(recordsNeedingReview(await projects.get(saved.id)), isEmpty);
  });

  test('two photos of the same kind propose an ambiguous pair', () async {
    final s = service();
    var project = await s.create('وجهان');
    final bytes = img.encodePng(img.Image(width: 860, height: 540));
    project = (await s.importImages(project, [
      ImportSource('البطاقة الوطنية الموحدة.png', () => Stream.value(bytes)),
      ImportSource('البطاقة الوطنية الموحدة 2.png', () => Stream.value(bytes)),
    ])).project;
    final report = await s.arrangeImportedImages(
      project,
      project.assets.map((a) => a.id),
    );
    final docs = report.project.documents;
    expect(docs, hasLength(2));
    for (final record in docs) {
      expect(
        record.pairing,
        PairingState.ambiguous,
        reason: 'no identifier evidence → never auto-paired',
      );
      expect(record.pairingConfidence, isNotNull);
      expect(record.pairingConfidence, lessThan(.9));
    }
    expect(docs[0].pairedDocumentId, docs[1].id);
    expect(docs[1].pairedDocumentId, docs[0].id);
    expect(
      report.project.layoutGroups,
      isEmpty,
      reason: 'grouping only after the user accepts the pair',
    );

    // Accepting the proposal pairs and groups; rejecting dissolves it.
    final accepted = acceptPair(report.project, docs[0].id, docs[1].id);
    expect(accepted.layoutGroups, hasLength(1));
    final saved = await projects.save(accepted);
    final rejected = rejectPair(saved, docs[0].id);
    expect(rejected.layoutGroups, isEmpty);
    expect(
      rejected.documents.every((d) => d.pairing == PairingState.single),
      isTrue,
    );
  });

  test('cancellation before the batch keeps the project unchanged', () async {
    final s = service();
    var project = await s.create('إلغاء');
    final bytes = img.encodePng(img.Image(width: 860, height: 540));
    project = (await s.importImages(project, [
      ImportSource('البطاقة الوطنية الموحدة.png', () => Stream.value(bytes)),
    ])).project;
    final token = CancellationToken()..cancel();
    final report = await s.arrangeImportedImages(project, [
      project.assets.single.id,
    ], cancellation: token);
    expect(report.project.items, isEmpty);
    expect(report.project.documents, isEmpty);
    expect(report.warnings, isNotEmpty);
    expect(
      report.project.revision,
      project.revision,
      reason: 'nothing was saved after the cancel',
    );
  });

  test('progress is reported per analyzed image', () async {
    final s = service();
    var project = await s.create('تقدم');
    final bytes = img.encodePng(img.Image(width: 860, height: 540));
    project = (await s.importImages(project, [
      ImportSource('أ.png', () => Stream.value(bytes)),
      ImportSource('ب.png', () => Stream.value(bytes)),
    ])).project;
    final seen = <int>[];
    await s.arrangeImportedImages(
      project,
      project.assets.map((a) => a.id),
      onProgress: (BatchProgress progress) {
        expect(progress.total, 2);
        seen.add(progress.completed);
      },
    );
    expect(seen, [0, 1, 2]);
  });

  test('already-arranged assets are skipped, keeping items stable', () async {
    final s = service();
    var project = await s.create('ثبات');
    final bytes = img.encodePng(img.Image(width: 860, height: 540));
    project = (await s.importImages(project, [
      ImportSource('البطاقة الوطنية الموحدة.png', () => Stream.value(bytes)),
    ])).project;
    final first = await s.arrangeImportedImages(project, [
      project.assets.single.id,
    ]);
    final second = await s.arrangeImportedImages(first.project, [
      first.project.assets.single.id,
    ]);
    expect(second.project.items, hasLength(1));
    expect(second.cropped, 0);
    expect(second.project.documents, hasLength(1));
  });
}
