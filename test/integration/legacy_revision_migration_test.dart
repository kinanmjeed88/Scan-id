import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_project_backups.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/persistence/local_storage_maintenance.dart';

void main() {
  test('explicit migration survives reopen and backup without guessing history', () async {
    final root = await Directory.systemTemp.createTemp('legacy_revision_');
    final output = await Directory.systemTemp.createTemp('legacy_backup_');
    var repository = await LocalProjectRepository.open(root);
    try {
      final assets = LocalAssetRepository(repository.files);
      final service = ProjectService(repository, assets);
      var project = await service.create('قديم');
      project = (await service.importImages(project, [
        ImportSource('sample.png', () => Stream.value(img.encodePng(img.Image(width: 40, height: 30)))),
      ])).project;
      final original = project.assets.single;
      final json = original.toJson()
        ..remove('revisionId')
        ..remove('revisionHistoryComplete');
      final legacy = ImageAsset.fromJson(json);
      project = await repository.save(project.copyWith(assets: [legacy]));
      final originalFile = await assets.resolve(legacy.originalPath);
      final originalBytes = await originalFile.readAsBytes();
      final prefix = 'projects/${project.id}/assets/${legacy.id}';
      final unknown = Directory('${root.path}/$prefix/edits/unknown');
      await unknown.create(recursive: true);
      final unknownFile = File('${unknown.path}/working.png');
      await unknownFile.writeAsBytes([1, 2, 3]);

      final result = await repository.migrateLegacyRevisionIdentities(project.id);
      expect(result.migratedAssetIds, [legacy.id]);
      expect(result.unresolvedAssetIds, [legacy.id]);
      expect(result.project.assets.single.revisionId, isNotNull);
      expect(result.project.assets.single.revisionHistoryComplete, isFalse);
      expect(result.project.assets.single.parentRevisionId, isNull);
      expect(result.project.assets.single.revisionHistory, isEmpty);
      expect(await originalFile.readAsBytes(), originalBytes);
      final revisionId = result.project.assets.single.revisionId;
      final savedRevision = result.project.revision;
      await repository.close();
      repository = await LocalProjectRepository.open(root);
      final reopened = await repository.get(project.id);
      expect(reopened.assets.single.revisionId, revisionId);
      final repeat = await repository.migrateLegacyRevisionIdentities(project.id);
      expect(repeat.migratedAssetIds, isEmpty);
      expect(repeat.unresolvedAssetIds, [legacy.id]);
      expect(repeat.project.revision, savedRevision);
      final maintenance = LocalStorageMaintenance(
        repository.files,
        projects: repository,
        clock: () => DateTime.now().add(const Duration(days: 2)),
      );
      final found = await maintenance.findOrphans(await repository.list());
      expect(found.paths, isNot(contains('$prefix/edits/unknown')));
      expect(found.retained, contains('$prefix/edits/unknown'));
      await expectLater(maintenance.deleteFiles(['$prefix/edits/unknown']), throwsA(isA<ValidationException>()));
      await expectLater(maintenance.deleteFiles([legacy.workingPath]), throwsA(isA<ValidationException>()));
      expect(await unknownFile.readAsBytes(), [1, 2, 3]);
      final backup = LocalProjectBackups(repository, repository.files);
      final restored = await backup.restore(await backup.create(reopened, output));
      expect(restored.assets.single.revisionId, revisionId);
      expect(restored.assets.single.revisionHistoryComplete, isFalse);
      expect(restored.assets.single.originalPath, isNot(legacy.originalPath));
      expect(await File('${root.path}/projects/${restored.id}/assets/${legacy.id}/edits/unknown/working.png').readAsBytes(), [1, 2, 3]);
    } finally {
      await repository.close();
      await root.delete(recursive: true);
      await output.delete(recursive: true);
    }
  });
}
