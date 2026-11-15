import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_backups.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/persistence/local_storage_maintenance.dart';

/// Diagnostic of a known race, not an assertion that restoration is safe.
void main() {
  test('characterizes cleanup of a published restore before create', () async {
    final root = await Directory.systemTemp.createTemp('restore_race_');
    var repository = await LocalProjectRepository.open(root);
    final gate = _PausedCreate(repository);
    Future<Object>? outcome;
    try {
      final service = ProjectService(
        repository,
        LocalAssetRepository(repository.files),
        imageEditor: LocalImageEditor(repository.files),
      );
      var source = await service.create('نسخة اختبار');
      source = (await service.importImages(source, [
        ImportSource(
          'sample.png',
          () => Stream.value(img.encodePng(img.Image(width: 80, height: 60))),
        ),
      ])).project;
      source = await service.applyCrop(
        source,
        source.assets.single,
        CropDraft.fullImage().toRecipe(80, 60),
      );
      final backup = await LocalProjectBackups(
        repository,
        repository.files,
      ).create(source, root);
      final restore = LocalProjectBackups(
        gate,
        repository.files,
      ).restore(backup);
      outcome = restore.then<Object>(
        (value) => value,
        onError: (Object e) => e,
      );
      final unpublished = await gate.published.future;
      final working = File(
        '${root.path}/${unpublished.assets.single.workingPath}',
      );
      expect(await working.exists(), isTrue);
      expect(
        (await repository.list()).any((p) => p.id == unpublished.id),
        isFalse,
      );

      // Simulate a restore stalled beyond the grace period without a sleep.
      final maintenance = LocalStorageMaintenance(
        repository.files,
        projects: repository,
        clock: () => DateTime.now().toUtc().add(const Duration(hours: 2)),
      );
      final directory = 'projects/${unpublished.id}';
      final candidates = await maintenance.findOrphans(await repository.list());
      expect(candidates.paths, contains(directory));
      expect(await maintenance.deleteFiles([directory]), 1);
      expect(await working.exists(), isFalse);
      gate.resume.complete();
      expect(await outcome, isA<StorageException>());

      // The committed source and its history still reopen. A fresh retry uses
      // the separate backup to restore the deleted unpublished bytes.
      await repository.close();
      repository = await LocalProjectRepository.open(root);
      final reopenedSource = await repository.get(source.id);
      expect(reopenedSource.toJson(), source.toJson());
      await _expectAllAssetFiles(root, reopenedSource);
      final retry = await LocalProjectBackups(
        repository,
        repository.files,
      ).restore(backup);
      expect(retry.id, isNot(unpublished.id));
      await repository.close();
      repository = await LocalProjectRepository.open(root);
      final reopenedRetry = await repository.get(retry.id);
      expect(reopenedRetry.toJson(), retry.toJson());
      expect(
        reopenedRetry.assets.single.revisionHistory.length,
        source.assets.single.revisionHistory.length,
      );
      expect(
        reopenedRetry.assets.single.parentRevisionId,
        source.assets.single.parentRevisionId,
      );
      await _expectAllAssetFiles(root, reopenedRetry);
    } finally {
      if (!gate.resume.isCompleted) gate.resume.complete();
      if (outcome != null) await outcome;
      await repository.close();
      await root.delete(recursive: true);
    }
  });
}

Future<void> _expectAllAssetFiles(Directory root, Project project) async {
  for (final asset in project.assets) {
    final paths = <String>{
      asset.originalPath,
      asset.workingPath,
      asset.thumbnailPath,
      asset.processingInputPath,
      for (final revision in asset.revisionHistory) ...[
        revision.originalPath,
        revision.workingPath,
        revision.thumbnailPath,
        revision.processingInputPath,
      ],
    };
    for (final path in paths) {
      expect(await File('${root.path}/$path').length(), greaterThan(0));
    }
  }
}

class _PausedCreate implements ProjectRepository {
  _PausedCreate(this.delegate);
  final ProjectRepository delegate;
  final published = Completer<Project>();
  final resume = Completer<void>();

  @override
  Future<Project> create(Project project) async {
    published.complete(project);
    await resume.future;
    return delegate.create(project);
  }

  @override
  Future<List<Project>> list() => delegate.list();
  @override
  Future<Project> get(String id) => delegate.get(id);
  @override
  Future<Project> save(Project project) => delegate.save(project);
  @override
  Future<void> remove(Project project) => delegate.remove(project);
  @override
  Future<void> close() => delegate.close();
}
