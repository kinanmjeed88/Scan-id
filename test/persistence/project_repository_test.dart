import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

import '../fixtures.dart';

void main() {
  late Directory directory;
  late LocalProjectRepository repository;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('scan_id_test_');
    repository = await LocalProjectRepository.open(directory);
  });
  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });

  test(
    'create, rename, close and reopen preserve the committed state',
    () async {
      var project = await repository.create(projectFixture());
      project = await repository.save(project.copyWith(name: 'مشروع محفوظ'));
      expect(project.revision, 1);
      await repository.close();
      repository = await LocalProjectRepository.open(directory);
      expect((await repository.get(project.id)).toJson(), project.toJson());
      expect((await repository.list()).single.name, 'مشروع محفوظ');
    },
  );
  test(
    'duplicate creation and stale writes cannot overwrite latest project',
    () async {
      final first = await repository.create(projectFixture());
      await expectLater(
        repository.create(first),
        throwsA(isA<RevisionConflict>()),
      );
      await repository.save(first.copyWith(name: 'آخر حفظ'));
      await expectLater(
        repository.save(first.copyWith(name: 'حالة قديمة')),
        throwsA(isA<RevisionConflict>()),
      );
      expect((await repository.get(first.id)).name, 'آخر حفظ');
    },
  );
  test('two competing writes commit exactly one revision', () async {
    final first = await repository.create(projectFixture());
    Future<bool> attempt(String name) async {
      try {
        await repository.save(first.copyWith(name: name));
        return true;
      } on RevisionConflict {
        return false;
      }
    }

    final outcomes = await Future.wait([attempt('one'), attempt('two')]);
    expect(outcomes.where((success) => success), hasLength(1));
    expect((await repository.get(first.id)).revision, 1);
  });
  test('asset existence checked before database commit', () async {
    final first = await repository.create(projectFixture());
    await expectLater(
      repository.save(first.copyWith(assets: [assetFixture()])),
      throwsA(isA<StorageException>()),
    );
    expect((await repository.get(first.id)).assets, isEmpty);
    expect((await repository.get(first.id)).revision, 0);
  });
  test(
    'missing file during reopen raises an error without destroying metadata',
    () async {
      final asset = assetFixture();
      for (final relative in [
        asset.originalPath,
        asset.workingPath,
        asset.thumbnailPath,
      ]) {
        final file = File('${directory.path}/$relative');
        await file.parent.create(recursive: true);
        await file.writeAsString('file fixture');
      }
      await repository.create(
        projectFixture(assets: [asset], items: [itemFixture()]),
      );
      await File('${directory.path}/${asset.workingPath}').delete();
      await expectLater(
        repository.get('project1'),
        throwsA(isA<StorageException>()),
      );
      expect((await repository.list()).single.items.single.width, 85.6);
    },
  );
  test(
    'deleting metadata leaves source and app-owned files untouched',
    () async {
      final asset = assetFixture();
      for (final relative in [
        asset.originalPath,
        asset.workingPath,
        asset.thumbnailPath,
      ]) {
        final file = File('${directory.path}/$relative');
        await file.parent.create(recursive: true);
        await file.writeAsString('immutable');
      }
      final project = await repository.create(projectFixture(assets: [asset]));
      await repository.remove(project);
      expect(await repository.list(), isEmpty);
      expect(
        await File('${directory.path}/${asset.originalPath}').readAsString(),
        'immutable',
      );
    },
  );
  test(
    'future schema blocks read and overwrite, preserving raw data',
    () async {
      final project = projectFixture();
      await repository.close();
      var db = await databaseFactoryIo.openDatabase(
        '${directory.path}/projects.db',
      );
      final store = stringMapStoreFactory.store('projects');
      final future = project.toJson()
        ..['schemaVersion'] = Project.schemaVersion + 1;
      await store.record(project.id).put(db, future);
      await db.close();
      repository = await LocalProjectRepository.open(directory);
      await expectLater(
        repository.get(project.id),
        throwsA(isA<ValidationException>()),
      );
      await expectLater(
        repository.save(project),
        throwsA(isA<ValidationException>()),
      );
      await repository.close();
      db = await databaseFactoryIo.openDatabase(
        '${directory.path}/projects.db',
      );
      expect(
        (await store.record(project.id).get(db))!['schemaVersion'],
        Project.schemaVersion + 1,
      );
      await db.close();
      repository = await LocalProjectRepository.open(directory);
    },
  );
  test(
    'symlink cannot redirect asset reads outside the app root',
    () async {
      final outside = await Directory.systemTemp.createTemp('scan_outside_');
      try {
        await File('${outside.path}/image.png').writeAsString('private');
        await Link('${directory.path}/escape').create(outside.path);
        await expectLater(
          repository.files.existingFile('escape/image.png'),
          throwsA(isA<StorageException>()),
        );
        await Link('${directory.path}/escape').delete();
      } finally {
        await outside.delete(recursive: true);
      }
    },
    skip: Platform.isWindows
        ? 'Windows symlinks need additional privileges'
        : false,
  );
}
