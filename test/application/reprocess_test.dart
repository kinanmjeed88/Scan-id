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

/// Region 0: an ID-1 shaped card (width .8, height .8 / 1.586 ≈ .5045).
List<Point2> _topQuad() => [
  Point2(.1, .1),
  Point2(.9, .1),
  Point2(.9, .6045),
  Point2(.1, .6045),
];

/// Region 1: the ID-1 shape again, lower down.
List<Point2> _bottomQuad() => [
  Point2(.2, .62),
  Point2(.8, .62),
  Point2(.8, .9983),
  Point2(.2, .9983),
];

/// Region 2: a third card, only present when the analysis improves.
List<Point2> _thirdQuad() => [
  Point2(.05, .05),
  Point2(.45, .05),
  Point2(.45, .3335),
  Point2(.05, .3335),
];

/// Two regions: the top one resolves, the bottom one does not.
Future<SegmentationResult> _oneUnresolved(Uint8List bytes) async =>
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
          region: [.2, .62, .8, 1],
          reason: 'no-trustworthy-quad',
        ),
      ],
    );

/// The same two regions, both resolved.
Future<SegmentationResult> _bothResolved(Uint8List bytes) async =>
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
          region: const [.2, .62, .8, 1],
          corners: _bottomQuad(),
          detectionConfidence: .75,
          reason: 'component-support',
        ),
      ],
    );

/// Three regions: the first two unchanged, plus a newly detected one.
Future<SegmentationResult> _threeResolved(Uint8List bytes) async =>
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
          region: const [.2, .62, .8, 1],
          corners: _bottomQuad(),
          detectionConfidence: .75,
          reason: 'component-support',
        ),
        SegmentCandidate(
          region: const [.05, .05, .45, .34],
          corners: _thirdQuad(),
          detectionConfidence: .7,
          reason: 'component-support',
        ),
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
    root = await Directory.systemTemp.createTemp('scan-reprocess-');
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

  test('reprocessing refreshes documents without duplicating them', () async {
    final bytes = _photo();
    final s = service(segmenter: _bothResolved);
    var project = await s.create('تحديث');
    project = (await s.importImages(project, [
      ImportSource('صورة.png', () => Stream<List<int>>.value(bytes)),
    ])).project;
    final sourceId = project.assets.single.id;
    final first = (await s.arrangeImportedImages(project, [sourceId])).project;

    final itemIds = first.items.map((i) => i.id).toList();
    final recordIds = first.documents.map((d) => d.id).toList();
    final workingPaths = [
      for (final d in first.documents) d.sides.single.processedAsset.workingPath,
    ];

    final report = await s.reprocessImages(first, [sourceId]);
    final result = report!.project;

    // No duplicate items, no duplicate records, no new assets.
    expect(result.items, hasLength(2));
    expect(result.documents, hasLength(2));
    expect(result.assets, hasLength(3));
    expect(result.items.map((i) => i.id).toList(), itemIds);
    expect(result.documents.map((d) => d.id).toList(), recordIds);

    // The derived images were regenerated in place (new revision files, same
    // asset ids) and the source photo was never rewritten.
    final refreshed = [
      for (final d in result.documents) d.sides.single.processedAsset.workingPath,
    ];
    expect(refreshed, isNot(workingPaths));
    expect(result.assets.map((a) => a.id).toList(),
        first.assets.map((a) => a.id).toList());
    final source = result.assets.firstWhere((a) => a.id == sourceId);
    expect(
      await (await assets.resolve(source.originalPath)).readAsBytes(),
      bytes,
    );
    // Placement is still the deterministic engine's job.
    expect((await projects.get(result.id)).toJson(), result.toJson());
  });

  test('reprocessing resolves a previously unresolved region in place', () async {
    final bytes = _photo();
    var project = await service(segmenter: _oneUnresolved).create('منطقة بلا حدود');
    project = (await service().importImages(project, [
      ImportSource('صورة.png', () => Stream<List<int>>.value(bytes)),
    ])).project;
    final sourceId = project.assets.single.id;
    final first = (await service(segmenter: _oneUnresolved)
            .arrangeImportedImages(project, [sourceId]))
        .project;
    expect(first.documents, hasLength(2));

    final unresolvedRecord = first.documents.firstWhere(
      (d) => d.sides.single.detection!.polygon == null,
    );
    final unresolvedItem = first.items.firstWhere(
      (i) => i.documentId == unresolvedRecord.id,
    );
    expect(unresolvedItem.sizeConfirmed, isFalse);

    // A better analysis now finds the boundary it missed.
    final result = (await service(segmenter: _bothResolved).reprocessImages(
      first,
      [sourceId],
    ))!.project;

    // The SAME document was updated — a new one was not created beside it.
    expect(result.documents, hasLength(2));
    expect(result.items, hasLength(2));
    expect(result.assets, hasLength(3));
    expect(result.documents.map((d) => d.id), contains(unresolvedRecord.id));
    final fixed = result.documents.firstWhere(
      (d) => d.id == unresolvedRecord.id,
    );
    expect(fixed.sides.single.detection!.polygon, isNotNull);
    final fixedItem = result.items.firstWhere(
      (i) => i.documentId == fixed.id,
    );
    expect(fixedItem.sizeConfirmed, isTrue);
    expect(fixedItem.id, unresolvedItem.id);
    expect((await projects.get(result.id)).toJson(), result.toJson());
  });

  test('a region with no existing document is added, never merged', () async {
    final bytes = _photo();
    final s = service(segmenter: _bothResolved);
    var project = await s.create('منطقة جديدة');
    project = (await s.importImages(project, [
      ImportSource('صورة.png', () => Stream<List<int>>.value(bytes)),
    ])).project;
    final sourceId = project.assets.single.id;
    final first = (await s.arrangeImportedImages(project, [sourceId])).project;
    expect(first.documents, hasLength(2));

    final result = (await service(segmenter: _threeResolved).reprocessImages(
      first,
      [sourceId],
    ))!.project;

    // The two known documents were refreshed and the new one was appended.
    expect(result.documents, hasLength(3));
    expect(result.items, hasLength(3));
    expect(result.assets, hasLength(4));
    expect(
      result.documents
          .map((d) => d.id)
          .toSet()
          .intersection(first.documents.map((d) => d.id).toSet()),
      hasLength(2),
      reason: 'existing documents keep their identity',
    );
    expect((await projects.get(result.id)).toJson(), result.toJson());
  });

  test('a user-confirmed document is left exactly as the user left it', () async {
    final bytes = _photo();
    final s = service(segmenter: _bothResolved);
    var project = await s.create('تأكيد المستخدم');
    project = (await s.importImages(project, [
      ImportSource('صورة.png', () => Stream<List<int>>.value(bytes)),
    ])).project;
    final sourceId = project.assets.single.id;
    final first = (await s.arrangeImportedImages(project, [sourceId])).project;

    // The user confirms one document and overrides the other's kind.
    final confirmed = first.documents.first;
    final lastRecord = first.documents.last;
    final lastItem = first.items.firstWhere(
      (i) => i.documentId == lastRecord.id,
    );
    final withOverride = setKindWithOverride(
      confirmRecognition(first, confirmed.id),
      lastItem.id,
      DocumentKind.passport,
    );
    final committed = await projects.save(withOverride);

    final report = await s.reprocessImages(committed, [sourceId]);
    final result = report!.project;

    // Both records still carry the user's decisions (ADR-004).
    final keptConfirmed = result.documents.firstWhere((d) => d.id == confirmed.id);
    final keptOverride = result.documents.firstWhere(
      (d) => d.id == lastRecord.id,
    );
    expect(keptConfirmed.overrides, isNotEmpty);
    expect(keptOverride.overrides, isNotEmpty);
    expect(keptOverride.recognition!.documentKind, DocumentKind.unifiedNationalId);
    expect(
      report.warnings.join('\n'),
      contains('تُرِك'),
      reason: 'the user is told why a document was skipped',
    );
    expect((await projects.get(result.id)).toJson(), result.toJson());
  });

  test('a missing original is reported and never corrupts the project', () async {
    final bytes = _photo();
    final s = service(segmenter: _bothResolved);
    var project = await s.create('أصل مفقود');
    project = (await s.importImages(project, [
      ImportSource('صورة.png', () => Stream<List<int>>.value(bytes)),
    ])).project;
    final sourceId = project.assets.single.id;
    final first = (await s.arrangeImportedImages(project, [sourceId])).project;

    await (await assets.resolve(
      first.assets.singleWhere((a) => a.id == sourceId).originalPath,
    )).delete();

    final report = await s.reprocessImages(first, [sourceId]);
    // The failure is actionable and isolated: the project is untouched.
    expect(report!.warnings, isNotEmpty);
    expect(report.notDetected, 1);
    expect((await projects.get(first.id)).toJson(), first.toJson());
  });

  test('reprocess reports real per-image progress', () async {
    final bytes = _photo();
    final s = service(segmenter: _bothResolved);
    var project = await s.create('تقدم');
    project = (await s.importImages(project, [
      ImportSource('صورة.png', () => Stream<List<int>>.value(bytes)),
    ])).project;
    final sourceId = project.assets.single.id;
    final first = (await s.arrangeImportedImages(project, [sourceId])).project;

    final seen = <int>[];
    final report = await s.reprocessImages(
      first,
      [sourceId],
      onProgress: (BatchProgress progress) {
        expect(progress.total, 1);
        seen.add(progress.completed);
      },
    );
    expect(seen, [0, 1]);
    expect(report!.project.documents, hasLength(2));
  });

  test('a cancelled reprocess leaves the project exactly as it was', () async {
    final bytes = _photo();
    final s = service(segmenter: _bothResolved);
    var project = await s.create('إلغاء');
    project = (await s.importImages(project, [
      ImportSource('صورة.png', () => Stream<List<int>>.value(bytes)),
    ])).project;
    final sourceId = project.assets.single.id;
    final first = (await s.arrangeImportedImages(project, [sourceId])).project;

    final token = CancellationToken()..cancel();
    final report = await s.reprocessImages(
      first,
      [sourceId],
      cancellation: token,
    );
    expect(report!.project.revision, first.revision);
    expect(report.project.documents.map((d) => d.id).toList(),
        first.documents.map((d) => d.id).toList());
    expect(report.warnings.join('\n'), contains('أُلغيت'));
    expect((await projects.get(first.id)).toJson(), first.toJson());
  });

  test('reprocessing an empty selection changes nothing', () async {
    final bytes = _photo();
    final s = service(segmenter: _bothResolved);
    var project = await s.create('فارغ');
    project = (await s.importImages(project, [
      ImportSource('صورة.png', () => Stream<List<int>>.value(bytes)),
    ])).project;
    final report = await s.reprocessImages(project, const []);
    expect(report!.project.revision, project.revision);
    expect(report.project.documents, isEmpty);
  });
}
