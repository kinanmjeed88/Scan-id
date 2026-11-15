import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/persistence/local_storage_maintenance.dart';

/// A diagnostic of the known defect, NOT an assertion of safe behavior.
/// The skipped test below states the desired invariant and can be enabled once
/// deletion and publication actually share a cross-isolate/process protocol.
void main() {
  test(
    'characterizes stale reference check deleting a committed revision',
    () async {
      final result = await _runRace();
      expect(result.metadataPointsToRevision, isTrue);
      expect(result.removed, 1);
      expect(
        result.fileExists,
        isFalse,
        reason: 'BUG: deletion consumed a snapshot from before the commit',
      );
      expect(result.reopenSucceeded, isFalse);
    },
  );

  test(
    'a revision committed after the scan keeps its file',
    () async {
      final result = await _runRace();
      expect(result.metadataPointsToRevision, isTrue);
      expect(result.removed, isNot(1));
      expect(result.fileExists, isTrue);
      expect(result.reopenSucceeded, isTrue);
    },
    skip: 'Known TOCTOU: enable only after the real storage protocol is fixed.',
  );
}

Future<
  ({
    bool metadataPointsToRevision,
    bool fileExists,
    bool reopenSucceeded,
    int? removed,
  })
>
_runRace() async {
  final root = await Directory.systemTemp.createTemp('revision_race_');
  var repository = await LocalProjectRepository.open(root);
  final gate = _PausedList(repository);
  try {
    final assets = LocalAssetRepository(repository.files);
    final editor = LocalImageEditor(repository.files);
    final service = ProjectService(repository, assets, imageEditor: editor);
    var project = await service.create('اختبار التزامن');
    project = (await service.importImages(project, [
      ImportSource(
        'sample.png',
        () => Stream.value(img.encodePng(img.Image(width: 80, height: 60))),
      ),
    ])).project;
    final original = project.assets.single;
    final recipe = CropDraft(
      corners: [Point2(.1, .1), Point2(.9, .1), Point2(.9, .9), Point2(.1, .9)],
    ).toRecipe(80, 60);
    final revision = await service.createImageRevision(
      project,
      original,
      recipe,
    );
    final working = File('${root.path}/${revision.workingPath}');
    final directory = revision.workingPath.substring(
      0,
      revision.workingPath.lastIndexOf('/'),
    );
    expect(await working.exists(), isTrue);
    final maintenance = LocalStorageMaintenance(
      repository.files,
      projects: gate,
    );

    // GC has read both recovery references and a snapshot of the project list.
    final deletion = maintenance.deleteFiles([directory]);
    await gate.snapshotTaken.future;
    // This save publishes a valid reference to the already written revision.
    project = await repository.save(project.copyWith(assets: [revision]));
    gate.resume.complete();
    int? removed;
    try {
      removed = await deletion;
    } on ValidationException {
      // Refusal is a safe outcome for the desired invariant.
    } on StorageException {
      // Storage may also refuse deletion if a new reference is observed.
    }

    final exists = await working.exists();
    await repository.close();
    repository = await LocalProjectRepository.open(root);
    final stored = await repository.metadata(project.id);
    var reopened = true;
    try {
      await repository.get(project.id);
    } on StorageException {
      reopened = false;
    }
    return (
      metadataPointsToRevision:
          stored.assets.single.workingPath == revision.workingPath,
      fileExists: exists,
      reopenSucceeded: reopened,
      removed: removed,
    );
  } finally {
    if (!gate.resume.isCompleted) gate.resume.complete();
    await repository.close();
    await root.delete(recursive: true);
  }
}

/// Takes a real Sembast snapshot, then deterministically holds the reader while
/// another task commits. No sleeping or fake filesystem is involved.
class _PausedList implements ProjectRepository {
  _PausedList(this.delegate);
  final ProjectRepository delegate;
  final snapshotTaken = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<List<Project>> list() async {
    final snapshot = await delegate.list();
    snapshotTaken.complete();
    await resume.future;
    return snapshot;
  }

  @override
  Future<Project> create(Project project) => delegate.create(project);
  @override
  Future<Project> get(String id) => delegate.get(id);
  @override
  Future<Project> save(Project project) => delegate.save(project);
  @override
  Future<void> remove(Project project) => delegate.remove(project);
  @override
  Future<void> close() => delegate.close();
}
