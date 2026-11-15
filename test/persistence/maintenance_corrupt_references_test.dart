import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/persistence/local_storage_maintenance.dart';

void main() {
  test(
    'unreadable migration snapshots never authorize file deletion',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'maintenance_snapshot_',
      );
      var projects = await LocalProjectRepository.open(root);
      try {
        final service = ProjectService(
          projects,
          LocalAssetRepository(projects.files),
        );
        var project = await service.create('مشروع');
        project = (await service.importImages(project, [
          ImportSource(
            'image.png',
            () => Stream.value(img.encodePng(img.Image(width: 40, height: 30))),
          ),
        ])).project;
        final relative = 'projects/${project.id}/assets/unresolved';
        final file = File('${root.path}/$relative/original.png');
        await file.create(recursive: true);
        await file.writeAsBytes([1, 2, 3]);
        final snapshot = File('${root.path}/migration-snapshots/snapshot.json');
        await snapshot.parent.create(recursive: true);
        final maintenance = LocalStorageMaintenance(
          projects.files,
          projects: projects,
        );
        final malformed = [
          '{"version":1,"project":',
          jsonEncode({'version': 1, 'project': <String, Object?>{}}),
          jsonEncode({'version': 2, 'project': project.toJson()}),
        ];
        for (final raw in malformed) {
          await snapshot.writeAsString(raw);
          await expectLater(
            maintenance.findOrphans(await projects.list()),
            throwsA(anyOf(isA<FormatException>(), isA<ValidationException>())),
          );
          await expectLater(
            maintenance.deleteFiles([relative]),
            throwsA(anyOf(isA<FormatException>(), isA<ValidationException>())),
          );
          expect(await file.readAsBytes(), [1, 2, 3]);
          expect(await snapshot.readAsString(), raw);
        }
        await projects.close();
        projects = await LocalProjectRepository.open(root);
        expect(
          (await projects.get(project.id)).assets.single.id,
          project.assets.single.id,
        );
        expect(await file.readAsBytes(), [1, 2, 3]);
      } finally {
        await projects.close();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'corrupt recovery checkpoint refuses cleanup without losing project',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'maintenance_checkpoint_',
      );
      var projects = await LocalProjectRepository.open(root);
      try {
        final service = ProjectService(
          projects,
          LocalAssetRepository(projects.files),
        );
        var project = await service.create('مشروع');
        project = (await service.importImages(project, [
          ImportSource(
            'image.png',
            () => Stream.value(img.encodePng(img.Image(width: 40, height: 30))),
          ),
        ])).project;
        final orphan = 'projects/${project.id}/assets/unknown';
        final file = File('${root.path}/$orphan/file.png');
        await file.create(recursive: true);
        await file.writeAsBytes([1, 2, 3]);
        final checkpoint = File('${root.path}/checkpoints/${project.id}.json');
        await checkpoint.writeAsString('{"version":1');
        final maintenance = LocalStorageMaintenance(
          projects.files,
          projects: projects,
        );
        await expectLater(
          maintenance.deleteFiles([orphan]),
          throwsA(isA<FormatException>()),
        );
        expect(await file.readAsBytes(), [1, 2, 3]);
        await projects.close();
        projects = await LocalProjectRepository.open(root);
        expect(
          (await projects.get(project.id)).assets.single.id,
          project.assets.single.id,
        );
        expect(await file.exists(), isTrue);
      } finally {
        await projects.close();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'unreadable reference entries fail closed',
    () async {
      final root = await Directory.systemTemp.createTemp('maintenance_link_');
      final projects = await LocalProjectRepository.open(root);
      try {
        final service = ProjectService(
          projects,
          LocalAssetRepository(projects.files),
        );
        final project = await service.create('مشروع');
        final orphan = 'projects/${project.id}/assets/unknown';
        final file = File('${root.path}/$orphan/file.png');
        await file.create(recursive: true);
        await file.writeAsBytes([1, 2, 3]);
        final linkedTarget = File('${root.path}/outside.json');
        await linkedTarget.writeAsString('{}');
        final snapshots = Directory('${root.path}/migration-snapshots');
        await snapshots.create();
        final snapshotLink = Link('${snapshots.path}/unknown.json');
        await snapshotLink.create(linkedTarget.path);
        final maintenance = LocalStorageMaintenance(
          projects.files,
          projects: projects,
        );
        await expectLater(
          maintenance.deleteFiles([orphan]),
          throwsA(isA<ValidationException>()),
        );
        await snapshotLink.delete();
        final checkpointLink = Link('${root.path}/checkpoints/unknown.json');
        await checkpointLink.create(linkedTarget.path);
        await expectLater(
          maintenance.deleteFiles([orphan]),
          throwsA(isA<ValidationException>()),
        );
        expect(await file.readAsBytes(), [1, 2, 3]);
        expect(await linkedTarget.readAsString(), '{}');
        expect((await projects.get(project.id)).id, project.id);
      } finally {
        await projects.close();
        await root.delete(recursive: true);
      }
    },
    skip: Platform.isWindows
        ? 'Windows symlinks need additional privileges'
        : null,
  );
}
