import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/persistence/local_storage_maintenance.dart';
import 'package:scan_id/persistence/safe_files.dart';

void main() {
  late Directory root;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;
  late LocalStorageMaintenance maintenance;
  late ProjectService service;

  Future<Project> create(String name, {required int images}) async {
    var project = await service.create(name);
    project = (await service.importImages(project, [
      for (var i = 0; i < images; i++)
        ImportSource(
          'image-$i.png',
          () => Stream.value(img.encodePng(img.Image(width: 40, height: 30))),
        ),
    ])).project;
    return project;
  }

  Future<bool> exists(String relative) async =>
      FileSystemEntity.type('${root.path}/$relative', followLinks: false) !=
      FileSystemEntityType.notFound;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan_maintenance_test_');
    projects = await LocalProjectRepository.open(root);
    assets = LocalAssetRepository(projects.files);
    maintenance = LocalStorageMaintenance(projects.files);
    service = ProjectService(
      projects,
      assets,
      maintenance: maintenance,
    );
  });
  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
  });

  test('deleting a project removes its app-owned files and nothing else', () async {
    final kept = await create('يبقى', images: 1);
    final removed = await create('يُحذف', images: 2);
    final keptDirectory = kept.assets.first.originalPath.split('/assets/').first;
    final removedDirectory =
        removed.assets.first.originalPath.split('/assets/').first;
    expect(removedDirectory, 'projects/${removed.id}');

    final report = await service.deleteProject(removed);

    expect(report.warning, isNull);
    expect(await exists(removedDirectory), isFalse);
    expect(await exists('$keptDirectory/assets'), isTrue);
    expect(await exists('projects/${removed.id}'), isFalse);
    expect(await projects.list(), hasLength(1));
    expect((await projects.list()).single.id, kept.id);
  });

  test('an interrupted delete leaves a detectable orphan, never a stale record', () async {
    final project = await create('يتيم', images: 1);
    final directory = 'projects/${project.id}';
    // Metadata first, files after: simulate the file step being skipped.
    await projects.remove(project);
    expect(await exists(directory), isTrue);

    final orphans = await maintenance.findOrphans(await projects.list());

    expect(orphans.paths, [directory]);
    expect(orphans.bytes, greaterThan(0));
  });

  test('orphan scan separates referenced assets and edits from leftovers', () async {
    final project = await create('مرجعي', images: 2);
    final assetDirectory = project.assets.first.originalPath
        .split('/')
        .take(4)
        .join('/');
    // Unreferenced edit output, an unknown project directory and stale staging
    // are all leftovers; the referenced asset directory is not.
    final old = DateTime.now().toUtc().subtract(const Duration(hours: 2));
    for (final path in [
      '$assetDirectory/edits/legacy',
      'projects/unknownproject/assets/legacy',
      'staging/leftover',
    ]) {
      await Directory('${root.path}/$path').create(recursive: true);
      await File('${root.path}/$path/file.bin').writeAsBytes([1, 2, 3]);
    }
    await File('${root.path}/active-abc123.tmp').writeAsString('{}');
    for (final directory in [
      '$assetDirectory/edits/legacy',
      'projects/unknownproject/assets/legacy',
      'staging/leftover',
      '$assetDirectory',
    ]) {
      await Directory('${root.path}/$directory').setLastModified(old);
    }
    final timestamp = old.add(const Duration(hours: 1));
    await File('${root.path}/active-abc123.tmp').setLastModified(timestamp);

    final orphans = await maintenance.findOrphans(await projects.list());

    expect(
      orphans.paths.toSet(),
      {
        'projects/unknownproject/assets/legacy',
        '$assetDirectory/edits/legacy',
        'active-abc123.tmp',
      },
    );
    expect(orphans.paths, isNot(contains(assetDirectory)));
    expect(orphans.paths, isNot(contains('staging/leftover')));
  });

  test('fresh work is protected from the orphan scan', () async {
    final project = await create('حديث', images: 1);
    await Directory('${root.path}/projects/${project.id}/assets/fresh').create();
    await File(
      '${root.path}/projects/${project.id}/assets/fresh/file.bin',
    ).writeAsBytes([1]);

    final orphans = await maintenance.findOrphans(await projects.list());

    expect(orphans.paths, isEmpty);
  });

  test('orphan deletion removes only reported paths and refuses traversal', () async {
    final project = await create('مشروع', images: 1);
    final orphan = 'projects/${project.id}/assets/orphaned';
    await Directory('${root.path}/$orphan').create(recursive: true);
    await File('${root.path}/$orphan/data.bin').writeAsBytes([1, 2, 3]);
    await Directory('${root.path}/$orphan').setLastModified(
      DateTime.now().toUtc().subtract(const Duration(hours: 1)),
    );
    final outside = await Directory.systemTemp.createTemp('scan_outside_');
    addTearDown(() => outside.delete(recursive: true));
    await File('${outside.path}/precious.txt').writeAsString('user data');

    final removed = await service.deleteOrphans();

    expect(removed, 1);
    expect(await exists(orphan), isFalse);
    expect(await File('${outside.path}/precious.txt').exists(), isTrue);
    expect(await exists('projects/${project.id}/assets'), isTrue);
    await expectLater(
      maintenance.deleteFiles(['../${outside.path.split('/').last}/precious.txt']),
      throwsA(isA<ValidationException>()),
    );
    await expectLater(
      maintenance.deleteFiles([outside.path]),
      throwsA(isA<ValidationException>()),
    );
    expect(await File('${outside.path}/precious.txt').exists(), isTrue);
  });

  test('an empty project list refuses to treat every file as orphaned', () async {
    await Directory('${root.path}/projects/ghost/assets/x').create(recursive: true);
    await File(
      '${root.path}/projects/ghost/assets/x/data.bin',
    ).writeAsBytes([1]);

    await expectLater(
      service.findOrphans(),
      throwsA(predicate((Object e) => userError(e).contains('فارغة'))),
    );
    await expectLater(
      service.deleteOrphans(),
      throwsA(predicate((Object e) => userError(e).contains('فارغة'))),
    );
    expect(await exists('projects/ghost/assets/x/data.bin'), isTrue);
  });

  test('pruning staging keeps in-flight work and removes stale directories', () async {
    await Directory('${root.path}/staging/stale').create(recursive: true);
    await File('${root.path}/staging/stale/part').writeAsBytes([1]);
    await Directory('${root.path}/staging/stale').setLastModified(
      DateTime.now().toUtc().subtract(const Duration(days: 2)),
    );
    await Directory('${root.path}/staging/inflight').create(recursive: true);
    await File('${root.path}/staging/inflight/part').writeAsBytes([1]);

    final removed = await maintenance.pruneStaging();

    expect(removed, 1);
    expect(await exists('staging/stale'), isFalse);
    expect(await exists('staging/inflight'), isTrue);
  });

  test(
    'deletion never follows a symlink out of the application root',
    () async {
      final project = await create('روابط', images: 1);
      final outside = await Directory.systemTemp.createTemp('scan_link_target_');
      addTearDown(() => outside.delete(recursive: true));
      final target = File('${outside.path}/user.txt');
      await target.writeAsString('keep me');
      final link = Link(
        '${root.path}/projects/${project.id}/assets/link',
      );
      await link.create(target.path);

      await maintenance.deleteProjectFiles(project.id);

      expect(await target.readAsString(), 'keep me');
      expect(await exists('projects/${project.id}'), isFalse);
    },
    skip: Platform.isWindows
        ? 'Windows symlinks need additional privileges'
        : null,
  );

  test('checked paths reject symlinked components before any deletion', () async {
    final outside = await Directory.systemTemp.createTemp('scan_component_');
    addTearDown(() => outside.delete(recursive: true));
    await File('${outside.path}/keep.txt').writeAsString('keep');
    final files = SafeFiles(Directory(root.path));
    if (!Platform.isWindows) {
      await Link('${root.path}/escape').create(outside.path);
      await expectLater(
        files.checkedPath('escape/keep.txt'),
        throwsA(isA<StorageException>()),
      );
      expect(await File('${outside.path}/keep.txt').exists(), isTrue);
    }
  });
}
