import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_backups.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/persistence/local_storage_maintenance.dart';

void main() {
  test(
    'maintenance waits for restore publication before deleting files',
    () async {
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
          onError: (Object error) => error,
        );
        final unpublished = await gate.published.future;
        final working = File(
          '${root.path}/${unpublished.assets.single.workingPath}',
        );
        final directory = 'projects/${unpublished.id}';
        expect(await working.exists(), isTrue);
        expect(
          (await repository.list()).any(
            (project) => project.id == unpublished.id,
          ),
          isFalse,
        );

        // It is a valid stale-orphan candidate before create. Physical deletion
        // must nevertheless serialize with the restore's publication lease.
        final maintenance = LocalStorageMaintenance(
          repository.files,
          projects: repository,
          clock: () => DateTime.now().toUtc().add(const Duration(hours: 2)),
        );
        final candidates = await maintenance.findOrphans(
          await repository.list(),
        );
        expect(candidates.paths, contains(directory));
        final deletion = maintenance
            .deleteFiles([directory])
            .then<Object>((value) => value, onError: (Object error) => error);

        gate.resume.complete();
        final restored = await outcome;
        expect(restored, isA<Project>());
        final deleteResult = await deletion;
        expect(
          deleteResult,
          anyOf(isA<ValidationException>(), isA<StorageException>()),
          reason: 'fresh live references must refuse the stale candidate',
        );
        expect(await working.exists(), isTrue);

        await repository.close();
        repository = await LocalProjectRepository.open(root);
        final reopened = await repository.get(unpublished.id);
        expect(reopened.toJson(), (restored as Project).toJson());
        await _expectAllAssetFiles(root, reopened);
        final reopenedSource = await repository.get(source.id);
        expect(reopenedSource.toJson(), source.toJson());
        await _expectAllAssetFiles(root, reopenedSource);
      } finally {
        if (!gate.resume.isCompleted) gate.resume.complete();
        if (outcome != null) await outcome;
        await repository.close();
        await root.delete(recursive: true);
      }
    },
  );
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
