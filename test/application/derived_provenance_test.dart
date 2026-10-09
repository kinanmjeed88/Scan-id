import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/image_adjustments.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/imaging/document_segmenter.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/persistence/local_storage_maintenance.dart';

/// Source-versus-derived classification, and partial failure.
///
/// The defect: derived assets were classified as derived SOLELY by scanning
/// document records for their processed-image paths, and every asset no record
/// named was treated as an authoritative SOURCE. Combined with a per-region
/// `projects.save` of the asset list — while records and items were merged only
/// at the end of the batch — a failure between the two left a persisted derived
/// crop that nothing explained. On the next reprocess that crop looked exactly
/// like an imported photograph, was re-analysed, and produced a second document
/// for the same physical card.
///
/// These tests pin the invariants that replace it:
///
/// - every derived asset records its own source, so origin is never inferred
///   from dimensions, aspect ratio, filename or appearance;
/// - an image contributes to a batch only if it COMPLETED, so a partial failure
///   commits nothing unexplained;
/// - leftover crop FILES stay discoverable by the existing maintenance tool
///   rather than silently lost (files first, database second — an explicit safe
///   ordering, not a claimed cross-system transaction);
/// - reconciliation backfills only what the records PROVE, and preserves
///   ambiguous assets untouched;
/// - originals stay byte-for-byte immutable throughout.
library;

final _paper = img.ColorRgb8(240, 238, 232);

/// An asset repository that fails one specific `importImage` call, so a failure
/// can be placed exactly between two regions of one photo.
class _FailingAssets implements AssetRepository {
  _FailingAssets(this.inner, {required this.failOnCall});

  final AssetRepository inner;
  final int failOnCall;
  var calls = 0;

  @override
  Future<ImageAsset> importImage(
    String projectId,
    String name,
    Uint8List bytes,
  ) {
    calls++;
    if (calls == failOnCall) {
      return Future.error(const StorageException('تعذر حفظ الملف المشتق'));
    }
    return inner.importImage(projectId, name, bytes);
  }

  @override
  Future<ReplacementFiles> replaceImage(
    String projectId,
    String assetId,
    Uint8List bytes,
  ) => inner.replaceImage(projectId, assetId, bytes);

  @override
  Future<File> resolve(String relativePath) => inner.resolve(relativePath);
}

Uint8List _twoCardPhoto() {
  final source = img.Image(width: 1200, height: 1600);
  img.fill(source, color: img.ColorRgb8(128, 122, 116));
  img.fillRect(source, x1: 150, y1: 180, x2: 800, y2: 590, color: _paper);
  img.fillRect(source, x1: 200, y1: 900, x2: 851, y2: 1311, color: _paper);
  return Uint8List.fromList(img.encodePng(source));
}

/// The two cards drawn above, as normalized quads: 650 × 410 px (ratio 1.5854)
/// and 651 × 411 px (ratio 1.5839), both inside the 4 % tolerance of
/// 85.6 / 53.98 = 1.5858. Regions carry the segmenter's own 8 % margin.
Future<SegmentationResult> _twoCards(Uint8List bytes) async =>
    SegmentationResult(
      multi: true,
      candidates: [
        SegmentCandidate(
          region: const [.08173, .09206, .71059, .38949],
          corners: [
            Point2(.12510, .11257),
            Point2(.66722, .11257),
            Point2(.66722, .36898),
            Point2(.12510, .36898),
          ],
          detectionConfidence: .8,
          reason: 'component-support',
        ),
        SegmentCandidate(
          region: const [.12337, .54229, .75319, .84045],
          corners: [
            Point2(.16681, .56285),
            Point2(.70976, .56285),
            Point2(.70976, .81989),
            Point2(.16681, .81989),
          ],
          detectionConfidence: .8,
          reason: 'component-support',
        ),
      ],
    );

ImageAsset _asset(String id, String projectId, {String? derivedFrom}) {
  final prefix = 'projects/$projectId/assets/$id';
  return ImageAsset(
    id: id,
    name: 'صورة $id.png',
    originalPath: '$prefix/original.png',
    workingPath: '$prefix/working.png',
    thumbnailPath: '$prefix/thumb.jpg',
    width: 400,
    height: 250,
    derivedFrom: derivedFrom,
  );
}

DocumentRecord _record({
  required String id,
  required String sourceImageId,
  required String sideId,
  required String workingPath,
  required String thumbnailPath,
}) => DocumentRecord(
  id: id,
  sourceImageId: sourceImageId,
  sides: [
    DocumentSide(
      id: sideId,
      side: SideKind.front,
      processedAsset: ProcessedAssetRef(
        workingPath: workingPath,
        thumbnailPath: thumbnailPath,
        width: 400,
        height: 250,
      ),
    ),
  ],
  pairing: PairingState.single,
  provenance: Provenance(
    sourceImageId: sourceImageId,
    detectionIds: ['$sourceImageId-d0'],
    processedAssetVersion: 'smart-1',
    pipelineVersion: 'smart-1',
  ),
);

Project _project(List<ImageAsset> assets, List<DocumentRecord> documents) =>
    Project(
      id: 'p1',
      name: 'مشروع',
      createdAt: DateTime.utc(2026, 10, 6),
      updatedAt: DateTime.utc(2026, 10, 6),
      assets: assets,
      documents: documents,
    );

void main() {
  late Directory root;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan-provenance-');
    projects = await LocalProjectRepository.open(root);
    assets = LocalAssetRepository(projects.files);
  });

  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
  });

  ProjectService service({AssetRepository? repository}) => ProjectService(
    projects,
    repository ?? assets,
    imageEditor: LocalImageEditor(projects.files),
    segmenter: _twoCards,
  );

  /// The invariant Problem B violated, stated without inferring anything: an
  /// asset that a document record uses as its PROCESSED image must not be
  /// indistinguishable from an imported original. Either it records its source
  /// directly, or the record that uses it names a source this project holds —
  /// which is exactly the relationship `reconcileDerivedProvenance` backfills
  /// from. An asset in neither state is untraceable, and reprocessing it would
  /// analyse a crop as though it were a photograph.
  ///
  /// [broken] lists assets whose recorded source is deliberately missing.
  void expectTraceable(Project project, {List<String> broken = const []}) {
    final ids = {for (final asset in project.assets) asset.id};
    for (final record in project.documents) {
      expect(
        ids,
        contains(record.sourceImageId),
        reason: '${record.id} names a source the project does not hold',
      );
      for (final side in record.sides) {
        for (final asset in project.assets) {
          final processed =
              asset.workingPath == side.processedAsset.workingPath ||
              asset.thumbnailPath == side.processedAsset.thumbnailPath;
          if (!processed || asset.id == record.sourceImageId) continue;
          expect(
            asset.derivedFrom,
            isNotNull,
            reason:
                '${asset.id} holds a processed image but reads as an original',
          );
        }
      }
    }
    for (final asset in project.assets) {
      final source = asset.derivedFrom;
      if (source == null || broken.contains(asset.id)) continue;
      expect(
        ids,
        contains(source),
        reason: '${asset.id} names a missing source',
      );
      expect(source, isNot(asset.id));
    }
  }

  group('origin is recorded, never inferred', () {
    test(
      'every derived asset names its source; the original names none',
      () async {
        final s = service();
        final bytes = _twoCardPhoto();
        var project = await s.create('أصل ومشتقات');
        project = (await s.importImages(project, [
          ImportSource('صورة.png', () => Stream<List<int>>.value(bytes)),
        ])).project;
        final sourceId = project.assets.single.id;
        expect(project.assets.single.derivedFrom, isNull);

        final report = await s.arrangeImportedImages(project, [sourceId]);
        final result = report.project;

        expect(result.assets, hasLength(3));
        final derived = result.assets.where((a) => a.id != sourceId).toList();
        expect(derived, hasLength(2));
        for (final asset in derived) {
          expect(asset.derivedFrom, sourceId);
        }
        expect(
          result.assets.firstWhere((a) => a.id == sourceId).derivedFrom,
          isNull,
        );
        expectTraceable(result);
        // The original is immutable (ADR-003).
        expect(
          await (await assets.resolve(
            result.assets.firstWhere((a) => a.id == sourceId).originalPath,
          ))
              .readAsBytes(),
          bytes,
        );
      },
    );

    test('a manual revision keeps provenance', () async {
      final s = service();
      final bytes = _twoCardPhoto();
      var project = await s.create('مراجعة يدوية');
      project = (await s.importImages(project, [
        ImportSource('صورة.png', () => Stream<List<int>>.value(bytes)),
      ])).project;
      final sourceId = project.assets.single.id;
      final result = (await s.arrangeImportedImages(project, [sourceId]))
          .project;
      final derived = result.assets.firstWhere((a) => a.id != sourceId);
      expect(derived.derivedFrom, sourceId);

      // `LocalProjectRecovery.rebuildDerived` calls createRevision on EVERY
      // asset, so losing provenance here would silently turn every recovered
      // derived crop back into an apparent original photograph.
      final editor = LocalImageEditor(projects.files);
      final revised = await editor.createRevision(
        derived,
        ImageEditRecipe(
          CropGeometry(
            corners: [
              Point2(0, 0),
              Point2(1, 0),
              Point2(1, 1),
              Point2(0, 1),
            ],
            outputWidth: derived.width,
            outputHeight: derived.height,
          ),
          ImageAdjustments(sharpness: .3),
        ),
      );
      expect(revised.id, derived.id);
      expect(revised.derivedFrom, sourceId);
      // A revision changes pixels, never the original.
      expect(revised.originalPath, derived.originalPath);
      expect(revised.workingPath, isNot(derived.workingPath));
    });
  });

  group('partial failure', () {
    test('a failure between two regions commits nothing unexplained', () async {
      // Call 1 imports the source photo, call 2 crops region 1, call 3 crops
      // region 2 — so failing call 3 lands exactly between the two regions.
      final failing = _FailingAssets(assets, failOnCall: 3);
      final s = service(repository: failing);
      final bytes = _twoCardPhoto();
      var project = await s.create('فشل جزئي');
      project = (await s.importImages(project, [
        ImportSource('صورة.png', () => Stream<List<int>>.value(bytes)),
      ])).project;
      final sourceId = project.assets.single.id;
      expect(failing.calls, 1);

      final report = await s.arrangeImportedImages(project, [sourceId]);
      final result = report.project;
      expect(failing.calls, 3, reason: 'region 1 written, region 2 failed');

      // Nothing partial was committed: no record-less derived asset, no item
      // without a record, no document without an item.
      expect(result.assets, hasLength(1), reason: 'only the source photo');
      expect(result.assets.single.id, sourceId);
      expect(result.documents, isEmpty);
      expect(result.items, isEmpty);
      expectTraceable(result);
      // The failure is reported, not swallowed, and the original survives.
      expect(report.notDetected, greaterThanOrEqualTo(1));
      expect(
        report.warnings.any((w) => w.contains('تعذرت المعالجة الذكية')),
        isTrue,
        reason: '${report.warnings}',
      );
      expect(
        await (await assets.resolve(result.assets.single.originalPath))
            .readAsBytes(),
        bytes,
      );
      // What the report says is what was saved.
      expect((await projects.get(result.id)).toJson(), result.toJson());

      // The crop file region 1 already wrote is unreferenced, and the existing
      // maintenance tool finds it. This is why the ordering is files first and
      // database second: a partial run leaves something RECOVERABLE instead of
      // something untraceable, without claiming a cross-system transaction.
      final maintenance = LocalStorageMaintenance(
        projects.files,
        clock: () => DateTime.now().toUtc().add(const Duration(minutes: 30)),
      );
      final orphans = await maintenance.findOrphans([result]);
      expect(orphans.paths, isNotEmpty);
      expect(
        orphans.paths.every((path) => !path.contains(sourceId)),
        isTrue,
        reason: 'the referenced source photo must not be an orphan',
      );
    });

    test('the same photo recovers completely on a later run', () async {
      final failing = _FailingAssets(assets, failOnCall: 3);
      final bytes = _twoCardPhoto();
      var project = await service(repository: failing).create('تعافٍ');
      project = (await service(repository: failing).importImages(project, [
        ImportSource('صورة.png', () => Stream<List<int>>.value(bytes)),
      ])).project;
      final sourceId = project.assets.single.id;
      final failed = await service(
        repository: failing,
      ).arrangeImportedImages(project, [sourceId]);
      expect(failed.project.documents, isEmpty);

      // A healthy repository, the same source, and no duplicates left behind by
      // the failed run: the recovered documents are the two cards, once.
      final recovered = await service().arrangeImportedImages(
        failed.project,
        [sourceId],
      );
      final result = recovered.project;
      expect(result.documents, hasLength(2));
      expect(result.items, hasLength(2));
      expect(result.assets, hasLength(3));
      for (final asset in result.assets.where((a) => a.id != sourceId)) {
        expect(asset.derivedFrom, sourceId);
      }
      expectTraceable(result);
      expect(
        await (await assets.resolve(
          result.assets.firstWhere((a) => a.id == sourceId).originalPath,
        ))
            .readAsBytes(),
        bytes,
      );
    });
  });

  group('idempotent reprocessing', () {
    test('a second pass duplicates nothing and keeps provenance', () async {
      final s = service();
      final bytes = _twoCardPhoto();
      var project = await s.create('مكرر');
      project = (await s.importImages(project, [
        ImportSource('صورة.png', () => Stream<List<int>>.value(bytes)),
      ])).project;
      final sourceId = project.assets.single.id;
      final first = await s.arrangeImportedImages(project, [sourceId]);

      final assetIds = first.project.assets.map((a) => a.id).toList();
      final itemIds = first.project.items.map((i) => i.id).toList();
      final recordIds = first.project.documents.map((d) => d.id).toList();
      final placed = [
        for (final i in first.project.items)
          (i.pageIndex, i.x, i.y, i.width, i.height, i.rotation, i.locked),
      ];

      final second = await s.reprocessImages(first.project, [sourceId]);
      final result = second!.project;

      expect(result.assets.map((a) => a.id).toList(), assetIds);
      expect(result.items.map((i) => i.id).toList(), itemIds);
      expect(result.documents.map((d) => d.id).toList(), recordIds);
      // Identity, page, position, size, rotation and lock state are preserved
      // without depending on autoFlow: the layout engine stays the only
      // authority for placement.
      expect(
        [
          for (final i in result.items)
            (i.pageIndex, i.x, i.y, i.width, i.height, i.rotation, i.locked),
        ],
        placed,
      );
      expect(result.layoutGroups, first.project.layoutGroups);
      for (final asset in result.assets.where((a) => a.id != sourceId)) {
        expect(asset.derivedFrom, sourceId);
      }
      expectTraceable(result);
      expect(
        await (await assets.resolve(
          result.assets.firstWhere((a) => a.id == sourceId).originalPath,
        ))
            .readAsBytes(),
        bytes,
      );
    });
  });

  group('reconcileDerivedProvenance', () {
    test('backfills only what the records prove', () {
      final source = _asset('src1', 'p1');
      final crop = _asset('crop1', 'p1');
      final ambiguous = _asset('maybe1', 'p1');
      final project = _project([source, crop, ambiguous], [
        _record(
          id: 'doc1',
          sourceImageId: 'src1',
          sideId: 'side1',
          workingPath: crop.workingPath,
          thumbnailPath: crop.thumbnailPath,
        ),
      ]);

      final report = reconcileDerivedProvenance(project);

      expect(report.changed, isTrue);
      expect(report.backfilled, ['crop1']);
      expect(report.brokenChains, isEmpty);
      final byId = {for (final a in report.project.assets) a.id: a};
      // Proven by a record: recorded.
      expect(byId['crop1']!.derivedFrom, 'src1');
      // NOT proven by anything: left a source. An imported photograph that
      // produced no document yet is still a source, and retrying it is the
      // whole point of reprocessing — guessing here would make it unretryable.
      expect(byId['maybe1']!.derivedFrom, isNull);
      expect(byId['src1']!.derivedFrom, isNull);
      // Nothing was deleted and no other field changed.
      expect(report.project.assets, hasLength(3));
      expect(report.project.documents, hasLength(1));
      expect(byId['crop1']!.workingPath, crop.workingPath);
      expect(byId['crop1']!.name, crop.name);
      expect(byId['crop1']!.width, crop.width);
      expectTraceable(report.project);
      // Reconciling twice is a no-op: the relationship is now recorded.
      final again = reconcileDerivedProvenance(report.project);
      expect(again.changed, isFalse);
      expect(again.backfilled, isEmpty);
    });

    test('a recorded relationship is authoritative, never overwritten', () {
      final crop = _asset('crop1', 'p1', derivedFrom: 'src2');
      final project = _project([
        _asset('src1', 'p1'),
        _asset('src2', 'p1'),
        crop,
      ], [
        // The record says src1; the asset says src2. A recorded value is left
        // alone: overwriting it with an inference is how provenance gets lost.
        _record(
          id: 'doc1',
          sourceImageId: 'src1',
          sideId: 'side1',
          workingPath: crop.workingPath,
          thumbnailPath: crop.thumbnailPath,
        ),
      ]);

      final report = reconcileDerivedProvenance(project);
      expect(report.backfilled, isEmpty);
      expect(report.changed, isFalse);
      expect(report.project, same(project));
      expect(
        report.project.assets.firstWhere((a) => a.id == 'crop1').derivedFrom,
        'src2',
      );
    });

    test('a broken chain is reported and preserved, never guessed away', () {
      final project = _project([
        _asset('crop1', 'p1', derivedFrom: 'gone1'),
      ], []);

      final report = reconcileDerivedProvenance(project);

      expect(report.brokenChains, ['crop1']);
      expect(report.backfilled, isEmpty);
      expect(report.changed, isFalse);
      // The asset is still derived and still there: its source is gone, and
      // neither fact is a reason to delete it or to reclassify it as original.
      expect(report.project.assets, hasLength(1));
      expect(report.project.assets.single.derivedFrom, 'gone1');
      expect(report.project, same(project));
    });

    test('a project with nothing to fix is returned untouched', () {
      final project = _project([_asset('src1', 'p1')], []);
      final report = reconcileDerivedProvenance(project);
      expect(report.changed, isFalse);
      expect(report.backfilled, isEmpty);
      expect(report.brokenChains, isEmpty);
      expect(report.project, same(project));
    });

    test('an asset can never be derived from itself', () {
      expect(
        () => _asset('src1', 'p1', derivedFrom: 'src1'),
        throwsA(isA<ValidationException>()),
      );
    });

    test('derivedFrom is optional, so an existing project still opens', () {
      // Assets written before this field existed carry no `derivedFrom` key. A
      // missing key means "no provenance recorded", never "not derived", so the
      // field is purely additive and the schema is NOT bumped.
      final legacy = _asset('src1', 'p1').toJson()..remove('derivedFrom');
      expect(legacy.containsKey('derivedFrom'), isFalse);
      final parsed = ImageAsset.fromJson(legacy);
      expect(parsed.id, 'src1');
      expect(parsed.derivedFrom, isNull);
      expect(parsed.workingPath, 'projects/p1/assets/src1/working.png');
      // An absent key and a null key mean the same thing.
      expect(parsed.toJson()['derivedFrom'], isNull);
      // And a recorded relationship round-trips.
      final derived = _asset('crop1', 'p1', derivedFrom: 'src1').toJson();
      expect(ImageAsset.fromJson(derived).derivedFrom, 'src1');
      expect(Project.schemaVersion, 5);
    });
  });

  group('reprocessing reports broken provenance', () {
    test('the warning names it and the asset survives', () async {
      final s = service();
      final bytes = _twoCardPhoto();
      var project = await s.create('سلسلة مكسورة');
      project = (await s.importImages(project, [
        ImportSource('صورة.png', () => Stream<List<int>>.value(bytes)),
      ])).project;
      final sourceId = project.assets.single.id;
      final first = (await s.arrangeImportedImages(project, [sourceId]))
          .project;

      // The state the old per-region save could leave behind: a derived asset
      // whose recorded source is no longer in the project.
      final derived = first.assets.firstWhere((a) => a.id != sourceId);
      final broken = await projects.save(
        first.copyWith(
          assets: [
            for (final asset in first.assets)
              asset.id == derived.id ? asset.asDerivedOf('gone1') : asset,
          ],
        ),
      );
      expect(
        broken.assets.firstWhere((a) => a.id == derived.id).derivedFrom,
        'gone1',
      );

      final report = await s.reprocessImages(broken, [sourceId]);
      final result = report!.project;

      // Reported, and the asset preserved rather than deleted or relabelled as
      // an original photograph.
      expect(
        report.warnings.any(
          (w) => w.contains('أصل مشتق يشير إلى صورة مصدر لم تعد موجودة'),
        ),
        isTrue,
        reason: '${report.warnings}',
      );
      expect(result.assets.map((a) => a.id), contains(derived.id));
      expect(
        result.assets.firstWhere((a) => a.id == derived.id).derivedFrom,
        isNotNull,
      );
      // Reprocessing still produced no duplicates.
      expect(result.documents, hasLength(2));
      expect(result.items, hasLength(2));
      expectTraceable(result, broken: [derived.id]);
      expect(
        await (await assets.resolve(
          result.assets.firstWhere((a) => a.id == sourceId).originalPath,
        ))
            .readAsBytes(),
        bytes,
      );
    });
  });

  group('recognition never edits the catalog', () {
    test('preset sizes survive a full run unchanged', () async {
      final s = service();
      var project = await s.create('المقاسات');
      project = (await s.importImages(project, [
        ImportSource(
          'صورة.png',
          () => Stream<List<int>>.value(_twoCardPhoto()),
        ),
      ])).project;
      final before = project.catalog;
      final result = (await s.arrangeImportedImages(project, [
        project.assets.single.id,
      ]))
          .project;

      expect(
        result.catalog.natural(DocumentKind.unifiedNationalId),
        before.natural(DocumentKind.unifiedNationalId),
      );
      expect(
        result.catalog.natural(DocumentKind.rationCard),
        DocumentSizeCatalog.defaultRationCard,
      );
      final ration = result.catalog.natural(DocumentKind.rationCard)!;
      expect([ration.width, ration.height], [52, 287]);
      expect(ration.isLandscape, isFalse);
    });
  });
}
