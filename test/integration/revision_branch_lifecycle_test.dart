import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_backups.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/persistence/local_storage_maintenance.dart';

void main() {
  test('branched revisions retain shared parent and leaf deletion keeps bytes', () async {
    final root = await Directory.systemTemp.createTemp('revision_branch_');
    final output = await Directory.systemTemp.createTemp('revision_branch_backup_');
    var repository = await LocalProjectRepository.open(root);
    try {
      final assets = LocalAssetRepository(repository.files);
      final editor = LocalImageEditor(repository.files);
      var maintenance = LocalStorageMaintenance(repository.files, projects: repository,
          clock: () => DateTime.now().add(const Duration(days: 2)));
      var service = ProjectService(repository, assets, imageEditor: editor, maintenance: maintenance);
      var project = await service.create('فروع');
      project = (await service.importImages(project, [
        ImportSource('sample.png', () => Stream.value(img.encodePng(img.Image(width: 100, height: 80)))),
      ])).project;
      final origin = project.assets.single;
      final recipe = CropDraft(corners: [
        Point2(.1, .1), Point2(.9, .1), Point2(.9, .9), Point2(.1, .9),
      ]).toRecipe(100, 80);
      final left = await service.createImageRevision(project, origin, recipe);
      final right = await service.createImageRevision(project, origin, recipe);
      expect(left.parentRevisionId, origin.revisionId);
      expect(right.parentRevisionId, origin.revisionId);
      expect(left.revisionId, isNot(right.revisionId));
      final branchJson = right.toJson()
        ..['revisionHistory'] = [for (final entry in left.historyWithCurrent) entry.toJson()];
      project = await repository.save(project.copyWith(assets: [ImageAsset.fromJson(branchJson)]));
      expect(project.assets.single.revisionHistory, hasLength(2));
      final originalBytes = await (await assets.resolve(origin.originalPath)).readAsBytes();
      final leftBytes = await (await assets.resolve(left.workingPath)).readAsBytes();
      final backup = LocalProjectBackups(repository, repository.files);
      final restored = await backup.restore(await backup.create(project, output));
      expect(restored.assets.single.revisionHistory.map((r) => r.id),
          [origin.revisionId, left.revisionId]);
      expect(restored.assets.single.parentRevisionId, origin.revisionId);
      await expectLater(service.deleteHistoricalRevision(project, origin.id, origin.revisionId!),
          throwsA(isA<ValidationException>()));
      await expectLater(service.deleteHistoricalRevision(project, origin.id, right.revisionId!),
          throwsA(isA<ValidationException>()));
      final deleted = await service.deleteHistoricalRevision(project, origin.id, left.revisionId!);
      expect(deleted.assets.single.revisionHistory.map((r) => r.id), [origin.revisionId]);
      expect(deleted.assets.single.revisionHistoryComplete, isFalse);
      expect(await (await assets.resolve(left.workingPath)).readAsBytes(), leftBytes);
      expect(await (await assets.resolve(origin.originalPath)).readAsBytes(), originalBytes);
      final found = await maintenance.findOrphans(await repository.list());
      final leftDir = left.workingPath.substring(0, left.workingPath.lastIndexOf('/'));
      expect(found.paths, isNot(contains(leftDir)));
      expect(found.retained, contains(leftDir));
      await expectLater(maintenance.deleteFiles([leftDir]), throwsA(isA<ValidationException>()));
      await repository.close();
      repository = await LocalProjectRepository.open(root);
      expect((await repository.get(project.id)).assets.single.revisionId, right.revisionId);
      maintenance = LocalStorageMaintenance(repository.files, projects: repository);
      service = ProjectService(repository, LocalAssetRepository(repository.files), maintenance: maintenance);
      await expectLater(service.deleteImage(await repository.get(project.id), origin.id),
          throwsA(isA<ValidationException>()));
      final deletion = await service.deleteImage(await repository.get(restored.id), origin.id);
      expect(deletion.project.assets, isEmpty);
      expect((await repository.get(project.id)).assets.single.revisionId, right.revisionId);
    } finally {
      await repository.close();
      await root.delete(recursive: true);
      await output.delete(recursive: true);
    }
  });
}
