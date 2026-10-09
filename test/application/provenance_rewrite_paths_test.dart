/// Provenance across every path that REWRITES an asset.
///
/// `ImageAsset` has no `copyWith`: every rewrite constructs a new asset field
/// by field, so each of them is a place `derivedFrom` can be silently dropped
/// — and a dropped relationship is exactly what turns a derived crop back into
/// an apparent original photograph, which the next reprocess then analyses as
/// a photo of a document and appends a duplicate record for.
///
/// `test/application/derived_provenance_test` covers recording, reconciliation,
/// partial failure and idempotent reprocessing. This file covers the rewrite
/// paths that were audited but not yet pinned by a test:
///
/// - `ProjectService.replaceImage` (replacing a crop's pixels);
/// - `LocalProjectRecovery.rebuildDerived` (the "recreate processed copies"
///   repair action, which revises EVERY asset of the project);
/// - backup and restore, where paths are remapped to a new project folder but
///   asset IDS are stable, so a `derivedFrom` written as an id stays valid;
/// - and the classification consequence: an asset whose `derivedFrom` is
///   recorded but whose document record is GONE must still never be reprocessed
///   as an independent source.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/imaging/document_segmenter.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_backups.dart';
import 'package:scan_id/persistence/local_project_recovery.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

final _paper = img.ColorRgb8(240, 238, 230);
final _paper2 = img.ColorRgb8(232, 230, 222);

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

/// Two ID cards on a mid-tone desk: the segmenter returns two regions, so the
/// multi-document intake creates two DERIVED assets and leaves the photo alone.
Uint8List get _twoCardPhoto {
  final image = _canvas(1200, 1600, img.ColorRgb8(128, 122, 116));
  _rect(image, 150, 180, 800, 590, _paper);
  _rect(image, 200, 900, 851, 1311, _paper2);
  return Uint8List.fromList(img.encodePng(image));
}

Uint8List _smallPng(int width, int height) => Uint8List.fromList(
  img.encodePng(_canvas(width, height, img.ColorRgb8(200, 198, 190))),
);

void main() {
  late Directory root;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;
  late LocalImageEditor editor;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan-provenance-paths-');
    projects = await LocalProjectRepository.open(root);
    assets = LocalAssetRepository(projects.files);
    editor = LocalImageEditor(projects.files);
  });

  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
  });

  /// Imports one two-card photo and arranges it, so the project holds a source
  /// plus two derived crops with recorded provenance.
  Future<(ProjectService, Project, String)> arranged() async {
    final s = ProjectService(
      projects,
      assets,
      imageEditor: editor,
      segmenter: (bytes) async => segmentDocumentBytes(bytes),
    );
    final bytes = _twoCardPhoto;
    var project = await s.create('أصل ومشتقات');
    project = (await s.importImages(project, [
      ImportSource('صورة.png', () => Stream<List<int>>.value(bytes)),
    ])).project;
    final sourceId = project.assets.single.id;
    final report = await s.arrangeImportedImages(project, [sourceId]);
    expect(report.project.assets, hasLength(3), reason: 'original + two crops');
    return (s, report.project, sourceId);
  }

  List<ImageAsset> derivedOf(Project project, String sourceId) => [
    for (final asset in project.assets)
      if (asset.id != sourceId) asset,
  ];

  group('every rewrite path keeps the recorded origin', () {
    test('replacing a crop\'s pixels keeps what it was derived from', () async {
      final (s, project, sourceId) = await arranged();
      final derived = derivedOf(project, sourceId).first;
      expect(derived.derivedFrom, sourceId);

      final replaced = await s.replaceImage(
        project,
        derived,
        ImportSource(
          'بديل.png',
          () => Stream<List<int>>.value(_smallPng(400, 250)),
        ),
      );

      final updated = replaced.project.assets.firstWhere(
        (a) => a.id == derived.id,
      );
      expect(
        updated.derivedFrom,
        sourceId,
        reason: 'new pixels do not change what an asset was derived from',
      );
      // The replacement really happened, so this is not a no-op passing by
      // accident: the paths moved and a revision was logged.
      expect(updated.workingPath, isNot(derived.workingPath));
      expect(updated.transforms.last, startsWith('replaced:'));
      // The source is still an original and still byte-identical.
      expect(
        replaced.project.assets
            .firstWhere((a) => a.id == sourceId)
            .derivedFrom,
        isNull,
      );
    });

    test('rebuilding every processed copy keeps provenance', () async {
      final (_, project, sourceId) = await arranged();
      final before = derivedOf(project, sourceId);

      final recovery = LocalProjectRecovery(projects, editor);
      final rebuilt = await recovery.rebuildDerived(project);

      expect(rebuilt.assets, hasLength(project.assets.length));
      for (final asset in derivedOf(rebuilt, sourceId)) {
        expect(
          asset.derivedFrom,
          sourceId,
          reason:
              'rebuildDerived revises EVERY asset, so losing the relationship '
              'here would turn each recovered crop into an apparent original',
        );
      }
      expect(
        rebuilt.assets.firstWhere((a) => a.id == sourceId).derivedFrom,
        isNull,
        reason: 'the original must never become derived',
      );
      // It really rebuilt: new working files, same identities.
      expect(
        rebuilt.assets.map((a) => a.id).toList(),
        project.assets.map((a) => a.id).toList(),
      );
      expect(
        rebuilt.assets.firstWhere((a) => a.id == before.first.id).workingPath,
        isNot(before.first.workingPath),
      );
    });

    test('a backup and its restore carry the relationship across', () async {
      final (_, project, sourceId) = await arranged();
      final backups = LocalProjectBackups(projects, projects.files);
      final temporary = await Directory.systemTemp.createTemp('scan-backup-');
      addTearDown(() => temporary.delete(recursive: true));

      final file = await backups.create(project, temporary);
      final restored = await backups.restore(file);

      // Restore remaps PATHS into the new project folder but keeps asset IDS,
      // which is why an id-based relationship survives it and a path-based one
      // would not.
      expect(restored.id, isNot(project.id));
      expect(
        restored.assets.map((a) => a.id).toSet(),
        project.assets.map((a) => a.id).toSet(),
      );
      final ids = {for (final asset in restored.assets) asset.id};
      for (final asset in restored.assets) {
        if (asset.id == sourceId) {
          expect(asset.derivedFrom, isNull);
          continue;
        }
        expect(
          asset.derivedFrom,
          sourceId,
          reason: '${asset.name} lost its origin across backup/restore',
        );
        expect(ids, contains(asset.derivedFrom), reason: 'chain must resolve');
      }
      expect(restored.documents, hasLength(project.documents.length));
      expect(restored.items, hasLength(project.items.length));
    });
  });

  group('classification without a document record', () {
    test('a recorded origin alone keeps a crop out of the sources', () async {
      // The failure this guards: a partial run left a derived crop whose
      // document record never got committed. Classification must not then read
      // it as an imported photograph and analyse it as one.
      final source = ImageAsset(
        id: 'src1',
        name: 'الأصل.png',
        originalPath: 'projects/project1/assets/src1/original.png',
        workingPath: 'projects/project1/assets/src1/working.png',
        thumbnailPath: 'projects/project1/assets/src1/thumb.jpg',
        width: 1200,
        height: 1600,
      );
      final crop = ImageAsset(
        id: 'crop1',
        name: 'قصاصة.png',
        originalPath: 'projects/project1/assets/crop1/original.png',
        workingPath: 'projects/project1/assets/crop1/working.png',
        thumbnailPath: 'projects/project1/assets/crop1/thumb.jpg',
        width: 600,
        height: 400,
      ).asDerivedOf(source.id);
      final project = await projects.create(
        Project(
          id: 'project1',
          name: 'بلا سجلات',
          createdAt: DateTime.utc(2026, 10, 9),
          updatedAt: DateTime.utc(2026, 10, 9),
          assets: [source, crop],
          items: [
            DocumentItem(
              id: 'item1',
              assetId: crop.id,
              x: 5,
              y: 5,
              width: 85.6,
              height: 53.98,
              pageIndex: null,
            ),
          ],
        ),
      );
      expect(project.documents, isEmpty, reason: 'no record explains the crop');

      final s = ProjectService(
        projects,
        assets,
        imageEditor: editor,
        segmenter: (bytes) async => segmentDocumentBytes(bytes),
      );
      final report = await s.reprocessImages(project, [crop.id]);

      expect(report, isNotNull);
      final after = report!.project;
      // The crop was NOT analysed as a source: nothing new was created for it,
      // and the ambiguous asset was preserved rather than deleted or guessed
      // away.
      expect(after.assets.map((a) => a.id).toList(), ['src1', 'crop1']);
      expect(after.documents, isEmpty);
      expect(after.items.map((i) => i.id).toList(), ['item1']);
      expect(
        after.assets.firstWhere((a) => a.id == crop.id).derivedFrom,
        source.id,
      );
      // The layout item the crop backs is untouched: refusing to reprocess a
      // derived asset must not cost the user its place on the sheet.
      expect(after.items.single.pageIndex, isNull);
      expect(after.items.single.width, 85.6);
    });

    test('an ambiguous asset with no relationship stays a source', () async {
      // The other direction must not be over-corrected: an imported photo that
      // produced no document yet is a source, and retrying it is the point of
      // reprocessing. Nothing may mark it derived on a guess.
      final photo = ImageAsset(
        id: 'photo1',
        name: 'صورة.png',
        originalPath: 'projects/project2/assets/photo1/original.png',
        workingPath: 'projects/project2/assets/photo1/working.png',
        thumbnailPath: 'projects/project2/assets/photo1/thumb.jpg',
        width: 1200,
        height: 1600,
      );
      final project = await projects.create(
        Project(
          id: 'project2',
          name: 'صورة وحيدة',
          createdAt: DateTime.utc(2026, 10, 9),
          updatedAt: DateTime.utc(2026, 10, 9),
          assets: [photo],
          items: [
            DocumentItem(
              id: 'item1',
              assetId: photo.id,
              x: 5,
              y: 5,
              width: 85.6,
              height: 53.98,
              pageIndex: null,
            ),
          ],
        ),
      );
      final reconciled = reconcileDerivedProvenance(project);
      expect(reconciled.backfilled, isEmpty);
      expect(reconciled.brokenChains, isEmpty);
      expect(reconciled.changed, isFalse);
      expect(reconciled.project.assets.single.derivedFrom, isNull);
    });
  });
}
