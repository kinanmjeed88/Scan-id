import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/export_plan.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_routing.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/export/document_exporter.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_backups.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/persistence/local_storage_maintenance.dart';

/// Image deletion on real storage: sembast records and project files on disk.
/// Every scenario checks the stored state (records, folders, files, orphans),
/// not only what the service returned.
void main() {
  late Directory root;
  late Directory workspace;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;
  late ProjectRepository repository;
  late _FailingDeletes store;
  late ProjectService service;

  void wire() {
    assets = LocalAssetRepository(projects.files);
    store = _FailingDeletes(
      projects.files,
      clock: () => DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
    repository = projects;
    service = ProjectService(
      repository,
      assets,
      imageEditor: LocalImageEditor(projects.files),
      backups: LocalProjectBackups(projects, projects.files),
      maintenance: store,
    );
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan_delete_store_');
    workspace = await Directory.systemTemp.createTemp('scan_delete_out_');
    projects = await LocalProjectRepository.open(root);
    wire();
  });
  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
    await workspace.delete(recursive: true);
  });

  Uint8List png(int width, int height) => Uint8List.fromList(
    img.encodePng(img.Image(width: width, height: height)),
  );

  Future<bool> exists(String relative) async =>
      await File(p.join(root.path, relative)).exists() ||
      await Directory(p.join(root.path, relative)).exists();

  Future<Project> stored(String id) => projects.get(id);

  /// A project with one image per name. Images are imported through the real
  /// pipeline, so every file is written exactly as the app writes it.
  Future<Project> projectWith(List<String> names) async {
    var project = await service.create('مستمسكات');
    final report = await service.importImages(project, [
      for (final name in names)
        ImportSource(name, () => Stream.value(png(40, 30))),
    ]);
    project = report.project;
    expect(project.assets, hasLength(names.length));
    return project;
  }

  DocumentItem placed(
    String id,
    String assetId, {
    double x = 10,
    bool locked = false,
    String? documentId,
    String? sideId,
  }) => DocumentItem(
    id: id,
    assetId: assetId,
    x: x,
    y: 10,
    width: 50,
    height: 40,
    pageIndex: 0,
    locked: locked,
    sizeConfirmed: true,
    documentId: documentId,
    sideId: sideId,
  );

  /// A non-tombstone recognition record: its single side is processed into
  /// [processedAssetId]'s folder, and the item that represents it is placed.
  DocumentRecord recordFor(
    String id,
    ImageAsset source, {
    required ImageAsset processed,
    required String sideId,
  }) => DocumentRecord(
    id: id,
    sourceImageId: source.id,
    sides: [
      DocumentSide(
        id: sideId,
        side: SideKind.unknown,
        processedAsset: ProcessedAssetRef(
          workingPath: processed.workingPath,
          thumbnailPath: processed.thumbnailPath,
          width: processed.width,
          height: processed.height,
        ),
      ),
    ],
    pairing: PairingState.single,
    provenance: Provenance(
      sourceImageId: source.id,
      detectionIds: ['$id-d0'],
      processedAssetVersion: 'smart-1',
      pipelineVersion: 'smart-1',
    ),
  );

  /// A dismissal tombstone: the user rejected a region of [source]. It has no
  /// layout element and remembers the rejection only.
  DocumentRecord tombstoneFor(String id, ImageAsset source) => DocumentRecord(
    id: id,
    sourceImageId: source.id,
    sides: [
      DocumentSide(
        id: '$id-side',
        side: SideKind.unknown,
        processedAsset: ProcessedAssetRef(
          workingPath: source.workingPath,
          thumbnailPath: source.thumbnailPath,
          width: source.width,
          height: source.height,
        ),
      ),
    ],
    pairing: PairingState.single,
    provenance: Provenance(
      sourceImageId: source.id,
      detectionIds: ['$id-d0'],
      processedAssetVersion: 'smart-1',
      pipelineVersion: 'smart-1',
    ),
    overrides: [
      UserOverride(
        dismissed: true,
        fields: ['dismissed', dismissalTombstoneField],
      ),
    ],
  );

  /// Every invariant a user could be harmed by: no element, record, or pair
  /// points at a missing image; every image still in the project has its files;
  /// and no app-owned folder is left unreferenced.
  Future<void> expectConsistent() async {
    for (final project in await projects.list()) {
      final ids = {for (final asset in project.assets) asset.id};
      for (final item in project.items) {
        expect(
          ids,
          contains(item.assetId),
          reason: 'element ${item.id} points at a missing image',
        );
      }
      for (final record in project.documents) {
        expect(
          ids,
          contains(record.sourceImageId),
          reason: 'record ${record.id} points at a missing source',
        );
      }
      for (final asset in project.assets) {
        expect(
          await exists(asset.originalPath),
          isTrue,
          reason: '${asset.id} lost its original',
        );
        expect(
          await exists(asset.workingPath),
          isTrue,
          reason: '${asset.id} lost its working copy',
        );
      }
    }
    final orphans = await service.findOrphans();
    expect(orphans.paths, isEmpty, reason: 'unreferenced app files remain');
  }

  Future<void> deleteSucceeded(ImageDeletion deletion) async {
    expect(deletion.warning, isNull);
  }

  group('deleting an image directly from image management', () {
    test(
      '1. an image that is not on the sheet is deleted with its folder',
      () async {
        final project = await projectWith(['أ.png', 'ب.png']);
        final target = project.assets.first;
        final kept = project.assets.last;
        final folder = 'projects/${project.id}/assets/${target.id}';
        expect(await exists(folder), isTrue);

        final deletion = await service.deleteImage(project, target.id);
        await deleteSucceeded(deletion);

        expect(deletion.plan.itemIds, isEmpty);
        final after = await stored(project.id);
        expect(after.assets.map((a) => a.id), [kept.id]);
        expect(await exists(folder), isFalse);
        expect(await exists(kept.originalPath), isTrue);
        await expectConsistent();
      },
    );

    test(
      '2. an image used by one element: only its element leaves the sheet',
      () async {
        var project = await projectWith(['أ.png', 'ب.png']);
        final target = project.assets.first;
        final other = project.assets.last;
        project = await projects.save(
          project.copyWith(
            items: [placed('a1', target.id), placed('b1', other.id, x: 80)],
          ),
        );
        final otherBefore = project.items.firstWhere((i) => i.id == 'b1');

        final deletion = await service.deleteImage(project, target.id);
        await deleteSucceeded(deletion);

        expect(deletion.plan.itemIds, ['a1']);
        final after = await stored(project.id);
        expect(after.items.map((i) => i.id), ['b1']);
        final otherAfter = after.items.single;
        expect(otherAfter.toJson(), otherBefore.toJson());
        expect(await exists(target.originalPath), isFalse);
        await expectConsistent();
      },
    );

    test(
      '3. an image used by several elements, a locked one and a recognition record: all leave together',
      () async {
        var project = await projectWith(['أ.png', 'ب.png']);
        final target = project.assets.first;
        final other = project.assets.last;
        final record = recordFor(
          'rec-target',
          target,
          processed: target,
          sideId: 'side-target',
        );
        project = await projects.save(
          project.copyWith(
            documents: [record],
            items: [
              placed('t1', target.id),
              placed('t2', target.id, x: 30, locked: true),
              placed(
                't3',
                target.id,
                x: 60,
                documentId: record.id,
                sideId: 'side-target',
              ),
              placed('o1', other.id, x: 90),
            ],
          ),
        );

        final deletion = await service.deleteImage(project, target.id);
        await deleteSucceeded(deletion);

        // The lock is named in the plan and removed without unlocking first.
        expect(deletion.plan.itemIds.toSet(), {'t1', 't2', 't3'});
        expect(deletion.plan.lockedItemIds, ['t2']);
        expect(deletion.plan.documentIds, ['rec-target']);
        final after = await stored(project.id);
        expect(after.items.map((i) => i.id), ['o1']);
        expect(after.documents, isEmpty);
        expect(await exists(target.originalPath), isFalse);
        await expectConsistent();
      },
    );

    test(
      '4. a derived crop of the image is kept with its files, and reported as a broken chain',
      () async {
        var project = await projectWith(['أصل.png']);
        final source = project.assets.single;
        final derived = (await assets.importImage(
          project.id,
          'قصّ.png',
          png(20, 20),
        )).asDerivedOf(source.id);
        project = await projects.save(
          project.copyWith(
            assets: [...project.assets, derived],
            items: [placed('d1', derived.id)],
          ),
        );

        final deletion = await service.deleteImage(project, source.id);
        await deleteSucceeded(deletion);

        expect(deletion.plan.keptDerivedAssetIds, [derived.id]);
        final after = await stored(project.id);
        expect(after.assets.map((a) => a.id), [derived.id]);
        expect(after.items.map((i) => i.id), ['d1']);
        expect(await exists(derived.workingPath), isTrue);
        expect(await exists(derived.originalPath), isTrue);
        // The derived image keeps its lineage. The app already reports a
        // lineage whose source is gone; it is never silently re-classified as
        // an original photo, which would make it eligible for reprocessing.
        final report = reconcileDerivedProvenance(after);
        expect(report.brokenChains, [derived.id]);
        expect(report.project.assets.single.derivedFrom, source.id);
      },
    );

    test(
      '5. backups made before the delete keep the image; other elements are unchanged',
      () async {
        var project = await projectWith(['أ.png', 'ب.png']);
        final target = project.assets.first;
        final other = project.assets.last;
        project = await projects.save(
          project.copyWith(
            items: [
              placed('a1', target.id),
              placed('b1', other.id, x: 80, locked: true),
            ],
          ),
        );
        final backupFile = await service.backups!.create(project, workspace);
        final otherBefore = project.items.firstWhere((i) => i.id == 'b1');
        final targetOriginal = await File(
          p.join(root.path, target.originalPath),
        ).readAsBytes();

        await deleteSucceeded(await service.deleteImage(project, target.id));

        final after = await stored(project.id);
        expect(after.items.single.toJson(), otherBefore.toJson());
        // The backup still restores the deleted image byte-for-byte.
        final restored = await service.backups!.restore(backupFile);
        expect(restored.assets, hasLength(2));
        final copy = restored.assets.firstWhere((a) => a.name == target.name);
        expect(
          await File(p.join(root.path, copy.originalPath)).readAsBytes(),
          targetOriginal,
        );
        await expectConsistent();
      },
    );

    test(
      '6. file deletion failure: the image leaves the project, the folder is kept and reported, nothing references it',
      () async {
        var project = await projectWith(['أ.png', 'ب.png']);
        final target = project.assets.first;
        project = await projects.save(
          project.copyWith(items: [placed('a1', target.id)]),
        );
        final folder = 'projects/${project.id}/assets/${target.id}';
        store.failDeletes = true;

        final deletion = await service.deleteImage(project, target.id);

        expect(deletion.warning, isNotNull);
        final after = await stored(project.id);
        expect(after.assets.map((a) => a.id), isNot(contains(target.id)));
        expect(after.items, isEmpty);
        expect(await exists(folder), isTrue, reason: 'folder must remain');
        final orphans = await service.findOrphans();
        expect(orphans.paths, contains(folder));
      },
    );

    test(
      '7. database update failure: nothing changes on disk or in the stored project',
      () async {
        var project = await projectWith(['أ.png']);
        final target = project.assets.single;
        project = await projects.save(
          project.copyWith(items: [placed('a1', target.id)]),
        );
        final before = (await stored(project.id)).toJson();
        final folder = 'projects/${project.id}/assets/${target.id}';
        final failing = _FailingSaves(projects);
        service = ProjectService(
          failing,
          assets,
          imageEditor: LocalImageEditor(projects.files),
          maintenance: store,
        );
        failing.failSave = true;

        await expectLater(
          service.deleteImage(project, target.id),
          throwsA(isA<_InjectedFailure>()),
        );

        expect((await stored(project.id)).toJson(), before);
        expect(await exists(folder), isTrue);
        expect(await exists(target.originalPath), isTrue);
      },
    );

    test(
      '8. partial-failure recovery: a later maintenance run removes the folder that the failed delete left behind',
      () async {
        var project = await projectWith(['أ.png', 'ب.png']);
        final target = project.assets.first;
        final folder = 'projects/${project.id}/assets/${target.id}';
        store.failDeletes = true;
        final failed = await service.deleteImage(project, target.id);
        expect(failed.warning, isNotNull);
        expect(await exists(folder), isTrue);

        store.failDeletes = false;
        final removed = await service.deleteOrphans();

        expect(removed, 1);
        expect(await exists(folder), isFalse);
        await expectConsistent();
      },
    );

    test(
      '9. repeated taps on a stale project delete once; the second attempt is refused',
      () async {
        final project = await projectWith(['أ.png', 'ب.png']);
        final target = project.assets.first;
        final folder = 'projects/${project.id}/assets/${target.id}';

        Future<Object> attempt() => service
            .deleteImage(project, target.id)
            .then<Object>((result) => result, onError: (Object error) => error);
        final outcomes = await Future.wait([attempt(), attempt()]);

        expect(outcomes.whereType<ImageDeletion>(), hasLength(1));
        final failure = outcomes.singleWhere((o) => o is! ImageDeletion);
        expect(failure, isA<Exception>());
        expect(await exists(folder), isFalse);

        // A later tap, on the refreshed project, is a clean refusal.
        final latest = await stored(project.id);
        await expectLater(
          service.deleteImage(latest, target.id),
          throwsA(isA<ValidationException>()),
        );
        await expectConsistent();
      },
    );

    test(
      '10. reopening the store after a delete shows the same state',
      () async {
        var project = await projectWith(['أ.png', 'ب.png']);
        final target = project.assets.first;
        final other = project.assets.last;
        project = await projects.save(
          project.copyWith(
            items: [placed('a1', target.id), placed('b1', other.id, x: 80)],
          ),
        );
        await deleteSucceeded(await service.deleteImage(project, target.id));

        await projects.close();
        projects = await LocalProjectRepository.open(root);
        wire();

        final reopened = await stored(project.id);
        expect(reopened.assets.map((a) => a.id), [other.id]);
        expect(reopened.items.map((i) => i.id), ['b1']);
        expect(
          await exists('projects/${project.id}/assets/${target.id}'),
          isFalse,
        );
        await expectConsistent();
      },
    );

    test(
      '11. export after the delete succeeds and contains the remaining image only',
      () async {
        var project = await projectWith(['أ.png', 'ب.png']);
        final target = project.assets.first;
        final other = project.assets.last;
        project = await projects.save(
          project.copyWith(
            items: [placed('a1', target.id), placed('b1', other.id, x: 80)],
          ),
        );
        await deleteSucceeded(await service.deleteImage(project, target.id));

        final latest = await stored(project.id);
        final bundle = await DocumentExporter(assets).generate(
          ExportPlan(latest, ExportProfile(format: ExportFormat.pdf, dpi: 300)),
          workspace,
        );

        expect(bundle.files, hasLength(1));
        expect(await File(bundle.files.single).length(), greaterThan(0));
        await expectConsistent();
      },
    );

    test(
      '12. restoring a backup taken after the delete does not bring the image back',
      () async {
        var project = await projectWith(['أ.png', 'ب.png']);
        final target = project.assets.first;
        await deleteSucceeded(await service.deleteImage(project, target.id));

        final latest = await stored(project.id);
        final file = await service.backups!.create(latest, workspace);
        final restored = await service.backups!.restore(file);

        expect(restored.assets.map((a) => a.id), isNot(contains(target.id)));
        expect(restored.assets, hasLength(1));
        await expectConsistent();
      },
    );

    test(
      '13. deleting the project afterwards leaves no folder and does not touch the other project',
      () async {
        var project = await projectWith(['أ.png', 'ب.png']);
        final target = project.assets.first;
        final other = await projectWith(['ج.png']);
        await deleteSucceeded(await service.deleteImage(project, target.id));
        project = await stored(project.id);

        final report = await service.deleteProject(project);

        expect(report.warning, isNull);
        expect(await exists('projects/${project.id}'), isFalse);
        expect(await exists(other.assets.single.originalPath), isTrue);
        await expectConsistent();
      },
    );

    test(
      '14. after several deletes across projects there are no broken references and no orphans',
      () async {
        var first = await projectWith(['أ.png', 'ب.png', 'ج.png']);
        final second = await projectWith(['د.png']);
        final a = first.assets[0];
        final b = first.assets[1];
        first = await projects.save(
          first.copyWith(
            items: [
              placed('x1', a.id),
              placed('x2', b.id, x: 70, documentId: 'r-b', sideId: 's-b'),
            ],
            documents: [recordFor('r-b', b, processed: b, sideId: 's-b')],
          ),
        );
        await deleteSucceeded(await service.deleteImage(first, a.id));
        first = await stored(first.id);
        await deleteSucceeded(
          await service.deleteImage(first, first.assets.first.id),
        );
        await deleteSucceeded(
          await service.deleteImage(
            await stored(second.id),
            second.assets.single.id,
          ),
        );

        await expectConsistent();
        expect(await stored(first.id), isNotNull);
      },
    );

    test(
      '15. a dismissed region on the image is removed and counted in the plan',
      () async {
        var project = await projectWith(['أ.png', 'ب.png']);
        final target = project.assets.first;
        final other = project.assets.last;
        final tombstone = tombstoneFor('rec-dismissed', target);
        project = await projects.save(
          project.copyWith(
            documents: [tombstone],
            items: [placed('o1', other.id)],
          ),
        );

        final deletion = await service.deleteImage(project, target.id);

        await deleteSucceeded(deletion);
        expect(deletion.plan.dismissedDocumentIds, ['rec-dismissed']);
        final after = await stored(project.id);
        expect(after.documents, isEmpty);
        expect(after.items.map((i) => i.id), ['o1']);
        await expectConsistent();
      },
    );

    test(
      '16. removing an image from the sheet keeps the image and its files',
      () async {
        var project = await projectWith(['أ.png', 'ب.png']);
        final target = project.assets.first;
        final other = project.assets.last;
        project = await projects.save(
          project.copyWith(
            items: [
              placed('a1', target.id),
              placed('a2', target.id, x: 30, locked: true),
              placed('b1', other.id, x: 80),
            ],
          ),
        );

        final detached = await service.removeImageFromSheet(project, target.id);

        expect(
          detached.assets.map((a) => a.id),
          containsAll([target.id, other.id]),
        );
        expect(detached.items.map((i) => i.id), ['b1']);
        expect(await exists(target.originalPath), isTrue);
        expect(await exists(target.workingPath), isTrue);
        await expectConsistent();

        // The image is still a normal, deletable project image.
        final deletion = await service.deleteImage(
          await stored(project.id),
          target.id,
        );
        await deleteSucceeded(deletion);
        expect(deletion.plan.itemIds, isEmpty);
        await expectConsistent();
      },
    );

    test('deleting a middle image keeps the order of the others', () async {
      final project = await projectWith(['أ.png', 'ب.png', 'ج.png']);
      final first = project.assets[0];
      final middle = project.assets[1];
      final last = project.assets[2];

      final deletion = await service.deleteImage(project, middle.id);

      await deleteSucceeded(deletion);
      expect((await stored(project.id)).assets.map((a) => a.id), [
        first.id,
        last.id,
      ]);
      await expectConsistent();
    });
  });

  group('recovery copies and maintenance', () {
    // Recovery copies live in checkpoints/. Making that directory read-only
    // makes the copy write fail while every earlier copy stays readable, which
    // is the real partial-failure state. POSIX permissions only.
    Future<void> setWritable(Directory directory, {required bool writable}) async {
      final result = await Process.run('chmod', [
        writable ? '755' : '555',
        directory.path,
      ]);
      expect(result.exitCode, 0, reason: 'chmod failed: ${result.stderr}');
    }

    test(
      'a folder named by an unwritten recovery copy is kept, then released once the copy is rewritten',
      () async {
        final project = await projectWith(['أ.png', 'ب.png']);
        final target = project.assets.first;
        final folder = 'projects/${project.id}/assets/${target.id}';
        final checkpoints = Directory(p.join(root.path, 'checkpoints'));
        try {
          await setWritable(checkpoints, writable: false);
          expect(
            () => File(
              p.join(checkpoints.path, 'probe.tmp'),
            ).writeAsStringSync('x'),
            throwsA(isA<FileSystemException>()),
            reason: 'the scenario needs a checkpoint directory that refuses writes',
          );

          final deletion = await service.deleteImage(project, target.id);

          // The metadata is committed; the files wait for a fresh copy.
          expect(deletion.warning, isNotNull);
          expect(
            (await stored(project.id)).assets.map((a) => a.id),
            isNot(contains(target.id)),
          );
          expect(await exists(folder), isTrue);
          expect(projects.checkpoints.isStale(project.id), isTrue);
          expect(projects.checkpoints.warning, isNotNull);
          // The stale copy still names the folder, so it must not be removed.
          await expectLater(
            store.deleteFiles([folder]),
            throwsA(isA<ValidationException>()),
          );
          final held = await service.findOrphans();
          expect(held.paths, isNot(contains(folder)));
          expect(held.retained, contains(folder));
        } finally {
          await setWritable(checkpoints, writable: true);
        }

        // The next successful save of this project rewrites its copy.
        await projects.save(await stored(project.id));
        expect(projects.checkpoints.isStale(project.id), isFalse);
        expect(projects.checkpoints.warning, isNull);

        final released = await service.findOrphans();
        expect(released.paths, contains(folder));
        expect(released.retained, isEmpty);
        expect(await service.deleteOrphans(), greaterThan(0));
        expect(await exists(folder), isFalse);
        await expectConsistent();
      },
      skip: Platform.isWindows ? 'directory permissions are POSIX-only' : false,
    );

    test(
      'a stale recovery copy of one project is not hidden by saving another',
      () async {
        final stale = await projectWith(['أ.png']);
        final other = await service.create('ملف آخر');
        // Occupy this project's copy path with a directory: the rename of the
        // new copy over it fails, while the other project's copy still works.
        final blocked = Directory(p.join(root.path, 'checkpoints', '${stale.id}.json'));
        await blocked.create(recursive: true);
        try {
          await projects.save(stale.copyWith(name: 'مستمسكات بعد التعديل'));
          expect(projects.checkpoints.isStale(stale.id), isTrue);

          await projects.save(other.copyWith(name: 'ملف آخر محدّث'));
          expect(projects.checkpoints.isStale(other.id), isFalse);
          expect(
            projects.checkpoints.warning,
            isNotNull,
            reason: 'saving another project must not clear this warning',
          );
        } finally {
          await blocked.delete(recursive: true);
        }

        await projects.save(await stored(stale.id));
        expect(projects.checkpoints.warning, isNull);
      },
      skip: Platform.isWindows ? 'rename over a directory behaves differently' : false,
    );

    test(
      'maintenance removes unnamed folders, keeps folders named by a pre-upgrade snapshot, and never lists live images',
      () async {
        final project = await projectWith(['أ.png', 'ب.png']);
        final id = project.id;
        Future<void> plant(String relative) async {
          final file = File(p.join(root.path, relative, 'original.png'));
          await file.create(recursive: true);
          await file.writeAsBytes(png(4, 4));
        }

        await plant('projects/$id/assets/unnamed');
        await plant('projects/$id/assets/archived');
        final snapshots = Directory(p.join(root.path, 'migration-snapshots'));
        await snapshots.create(recursive: true);
        await File(p.join(snapshots.path, '$id.json')).writeAsString(
          jsonEncode({
            'version': 1,
            'schemaVersion': 4,
            'project': {
              'assets': [
                {'originalPath': 'projects/$id/assets/archived/original.png'},
              ],
            },
          }),
        );

        final found = await service.findOrphans();
        expect(found.paths, ['projects/$id/assets/unnamed']);
        expect(found.retained, ['projects/$id/assets/archived']);
        for (final asset in project.assets) {
          expect(
            [...found.paths, ...found.retained].where((path) => path.contains(asset.id)),
            isEmpty,
            reason: 'a live image must never be reported as garbage',
          );
        }

        expect(await service.deleteOrphans(), 1);
        expect(await exists('projects/$id/assets/unnamed'), isFalse);
        expect(await exists('projects/$id/assets/archived'), isTrue);
        for (final asset in project.assets) {
          expect(await exists(asset.originalPath), isTrue);
        }
      },
    );
  });
}

class _InjectedFailure implements Exception {
  const _InjectedFailure();
}

/// Storage whose file deletion can be made to fail, to test the path where the
/// metadata is saved but the folder remains.
class _FailingDeletes extends LocalStorageMaintenance {
  _FailingDeletes(super.files, {super.clock});
  bool failDeletes = false;

  @override
  Future<int> deleteFiles(Iterable<String> relativePaths) async {
    if (failDeletes) {
      throw const FileSystemException('تعذر الحذف (اختبار)');
    }
    return super.deleteFiles(relativePaths);
  }
}

/// Repository whose saves can be made to fail, to test that a failed metadata
/// update leaves files and records exactly as they were.
class _FailingSaves implements ProjectRepository {
  _FailingSaves(this._inner);
  final LocalProjectRepository _inner;
  bool failSave = false;

  @override
  Future<List<Project>> list() => _inner.list();

  @override
  Future<Project> get(String id) => _inner.get(id);

  @override
  Future<Project> create(Project project) => _inner.create(project);

  @override
  Future<Project> save(Project project) async {
    if (failSave) {
      throw const _InjectedFailure();
    }
    return _inner.save(project);
  }

  @override
  Future<void> remove(Project project) => _inner.remove(project);

  @override
  Future<void> close() => _inner.close();
}
