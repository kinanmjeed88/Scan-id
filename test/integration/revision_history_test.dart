import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_backups.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/persistence/local_storage_maintenance.dart';

void main() {
  test(
    'revision files survive reopen, orphan scan and backup restore',
    () async {
      final root = await Directory.systemTemp.createTemp('revision_store_');
      final output = await Directory.systemTemp.createTemp('revision_backup_');
      var projects = await LocalProjectRepository.open(root);
      try {
        var assets = LocalAssetRepository(projects.files);
        final service = ProjectService(
          projects,
          assets,
          imageEditor: LocalImageEditor(projects.files),
        );
        var project = await service.create('تاريخ');
        final bytes = Uint8List.fromList(
          img.encodePng(img.Image(width: 120, height: 80)),
        );
        project = (await service.importImages(project, [
          ImportSource('sample.png', () => Stream.value(bytes)),
        ])).project;
        final initial = project.assets.single;
        final recipe = CropDraft(
          corners: [
            Point2(.1, .1),
            Point2(.9, .1),
            Point2(.9, .9),
            Point2(.1, .9),
          ],
        ).toRecipe(120, 80);
        project = await service.applyCrop(project, initial, recipe);
        final first = project.assets.single;
        project = await service.applyCrop(project, first, recipe);
        final second = project.assets.single;
        expect(second.revisionHistory.map((r) => r.id), [
          initial.revisionId,
          first.revisionId,
        ]);
        expect(second.parentRevisionId, first.revisionId);
        expect(
          second.revisionHistory.last.parentRevisionId,
          initial.revisionId,
        );
        final priorPath = first.workingPath;
        final originalBytes = await (await assets.resolve(
          initial.originalPath,
        )).readAsBytes();
        await projects.close();
        projects = await LocalProjectRepository.open(root);
        assets = LocalAssetRepository(projects.files);
        project = await projects.get(project.id);
        expect(project.assets.single.revisionHistory, hasLength(2));
        final maintenance = LocalStorageMaintenance(
          projects.files,
          projects: projects,
          clock: () => DateTime.now().add(const Duration(days: 2)),
        );
        final orphans = await maintenance.findOrphans([project]);
        expect(
          orphans.paths.any((path) => priorPath.startsWith('$path/')),
          isFalse,
        );
        await maintenance.deleteFiles(orphans.paths);
        expect(await (await assets.resolve(priorPath)).exists(), isTrue);
        final backups = LocalProjectBackups(projects, projects.files);
        final restored = await backups.restore(
          await backups.create(project, output),
        );
        final historical = restored.assets.single.revisionHistory;
        expect(historical.map((r) => r.id), [
          initial.revisionId,
          first.revisionId,
        ]);
        expect(historical.last.workingPath, isNot(priorPath));
        expect(
          await (await assets.resolve(historical.last.workingPath)).exists(),
          isTrue,
        );
        expect(
          await (await assets.resolve(
            historical.first.originalPath,
          )).readAsBytes(),
          originalBytes,
        );
      } finally {
        await projects.close();
        await root.delete(recursive: true);
        await output.delete(recursive: true);
      }
    },
  );
}
