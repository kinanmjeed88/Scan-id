import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/application/recognition_worker.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_overrides.dart';
import 'package:scan_id/imaging/document_segmenter.dart';
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
    SegmentCandidate(region: [.1, .55, .9, .95], reason: 'region-too-small'),
  ],
);

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
  }) => ProjectService(
    projects,
    assets,
    imageEditor: LocalImageEditor(projects.files),
    segmenter: segmenter,
  );

  test('one photo of two cards becomes two placed documents', () async {
    final s = service(segmenter: _twoCards);
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
      expect(record.recognition!.documentKind, DocumentKind.unifiedNationalId);
      // Two cards on ONE photo are never two sides of one card.
      expect(record.pairing, PairingState.single);
      expect(record.pairedDocumentId, isNull);
    }
    expect(result.layoutGroups, isEmpty);
    // The result equals what was saved (single final save).
    expect((await projects.get(result.id)).toJson(), result.toJson());
  });

  test('a photo with an unresolvable region keeps BOTH documents', () async {
    final s = service(segmenter: _cardPlusUnresolved);
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
  });

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
      expect(await (await assets.resolve(originalPath)).readAsBytes(), bytes);
      final source = result.assets.firstWhere((a) => a.id == sourceId);
      expect(source.crop, isNull);
      expect((await projects.get(result.id)).toJson(), result.toJson());
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
