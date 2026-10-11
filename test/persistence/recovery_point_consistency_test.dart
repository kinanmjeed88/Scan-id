import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/persistence/recovery_checkpoints.dart';

/// The database commit is the truth; recovery copies are a second durable
/// record. These tests inject the failures that matter and check what is
/// stored, what a restart reports, and what a recovery would rebuild.
///
/// Failing copy writes are simulated with a read-only `checkpoints/` directory,
/// the real partial-failure state: earlier copies stay readable. POSIX only.
void main() {
  late Directory root;
  late LocalProjectRepository projects;
  late ProjectService service;

  String get checkpointsPath => p.join(root.path, 'checkpoints');

  Future<void> reopen() async {
    await projects.close();
    projects = await LocalProjectRepository.open(root);
    service = ProjectService(projects, LocalAssetRepository(projects.files));
  }

  Future<void> setWritable({required bool writable}) async {
    final result = await Process.run('chmod', [
      writable ? '755' : '555',
      checkpointsPath,
    ]);
    expect(result.exitCode, 0, reason: 'chmod failed: ${result.stderr}');
  }

  /// Name held by the live copy of [id], or null when there is none.
  Future<String?> copyName(String id) async {
    for (final copy in await RecoveryCheckpoints(projects.files).read()) {
      if (copy.id == id) {
        return copy.name;
      }
    }
    return null;
  }

  /// Rebuilds a database from a copy of the recovery copies only, the way
  /// [LocalProjectRepository.recover] would after losing the database.
  Future<LocalProjectRepository> recoverFromCopies() async {
    final fresh = await Directory.systemTemp.createTemp('scan-recovered-');
    addTearDown(() => fresh.delete(recursive: true));
    final target = Directory(p.join(fresh.path, 'checkpoints'));
    await target.create(recursive: true);
    await for (final entity in Directory(checkpointsPath).list()) {
      if (entity is File) {
        await entity.copy(p.join(target.path, p.basename(entity.path)));
      }
    }
    return LocalProjectRepository.recover(fresh);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan-consistency-');
    projects = await LocalProjectRepository.open(root);
    service = ProjectService(projects, LocalAssetRepository(projects.files));
  });

  tearDown(() async {
    // Restore write access first, or the temporary tree cannot be removed.
    if (await Directory(checkpointsPath).exists()) {
      await Process.run('chmod', ['755', checkpointsPath]);
    }
    await projects.close();
    await root.delete(recursive: true);
  });

  const posixOnly = 'directory permissions are POSIX-only';

  test(
    'a rejected save changes neither the record nor its recovery copy',
    () async {
      final created = await service.create('أول');
      await service.rename(created, 'ثانٍ');

      // The caller still holds the revision before the rename.
      await expectLater(
        service.rename(created, 'مرفوض'),
        throwsA(isA<RevisionConflict>()),
      );

      expect((await projects.get(created.id)).name, 'ثانٍ');
      expect(await copyName(created.id), 'ثانٍ');
      expect(await projects.staleRecoveryPoints(), isEmpty);
      expect(projects.checkpoints.warning, isNull);
    },
  );

  test(
    'a committed save whose recovery copy fails is reported as saved, stays stale across a restart, and is repaired',
    () async {
      final project = await service.create('قبل');
      await setWritable(writable: false);

      // The commit succeeded, so the save must not be reported as a failure.
      final saved = await service.rename(project, 'بعد');
      expect(saved.name, 'بعد');
      expect((await projects.get(project.id)).name, 'بعد');
      expect(projects.checkpoints.isStale(project.id), isTrue);
      expect(projects.checkpoints.warning, isNotNull);
      expect(await projects.staleRecoveryPoints(), {project.id});
      expect(
        await copyName(project.id),
        'قبل',
        reason: 'the copy still holds the state before the commit',
      );

      // A restart forgets the session's failure, but not the stale copy.
      await reopen();
      expect(projects.checkpoints.isStale(project.id), isFalse);
      expect(await projects.staleRecoveryPoints(), {project.id});

      await setWritable(writable: true);
      await service.refreshRecoveryPoint(project.id);
      expect(await projects.staleRecoveryPoints(), isEmpty);
      expect(await copyName(project.id), 'بعد');

      // After the repair, a recovery returns the committed state.
      final recovered = await recoverFromCopies();
      expect((await recovered.get(project.id)).name, 'بعد');
      await recovered.close();
    },
    skip: Platform.isWindows ? posixOnly : null,
  );

  test(
    'refreshing while the copy still cannot be written fails loudly and stays stale',
    () async {
      final project = await service.create('ص');
      await setWritable(writable: false);
      await service.rename(project, 'ص2');

      await expectLater(
        service.refreshRecoveryPoint(project.id),
        throwsA(isA<StorageException>()),
      );
      expect(await projects.staleRecoveryPoints(), {project.id});
      expect((await projects.get(project.id)).name, 'ص2');
    },
    skip: Platform.isWindows ? posixOnly : null,
  );

  test(
    'a removal whose tombstone cannot be written changes nothing, so the project cannot come back as deleted',
    () async {
      final keep = await service.create('باقٍ');
      final doomed = await service.create('محذوف');
      await setWritable(writable: false);

      await expectLater(
        projects.remove(doomed),
        throwsA(isA<StorageException>()),
      );

      expect((await projects.get(doomed.id)).name, 'محذوف');
      expect(await copyName(doomed.id), 'محذوف');
      expect(await projects.staleRecoveryPoints(), isEmpty);

      await setWritable(writable: true);
      await projects.remove(doomed);
      await reopen();
      expect((await projects.list()).map((e) => e.id), [keep.id]);
      final recovered = await recoverFromCopies();
      expect((await recovered.list()).map((e) => e.id), [keep.id]);
      await recovered.close();
    },
    skip: Platform.isWindows ? posixOnly : null,
  );

  test('a removal with a stale revision is refused before any copy is touched',
      () async {
    final project = await service.create('ق');
    await service.rename(project, 'ق2');

    await expectLater(
      projects.remove(project),
      throwsA(isA<RevisionConflict>()),
    );

    expect((await projects.get(project.id)).name, 'ق2');
    expect(await copyName(project.id), 'ق2');
  });

  test(
    'an unreadable copy counts as stale after a restart and is rebuilt from the database',
    () async {
      final project = await service.create('تالف');
      await File(
        p.join(checkpointsPath, '${project.id}.json'),
      ).writeAsString('{not json');
      await reopen();

      expect(await projects.staleRecoveryPoints(), {project.id});
      await service.refreshRecoveryPoint(project.id);

      expect(await projects.staleRecoveryPoints(), isEmpty);
      expect(await copyName(project.id), 'تالف');
    },
  );
}
