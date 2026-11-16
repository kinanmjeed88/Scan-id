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

void main() {
  test(
    'concurrent publication and deletion never leave a committed missing revision',
    () async {
      final root = await Directory.systemTemp.createTemp('revision_race_');
      var repository = await LocalProjectRepository.open(root);
      try {
        final assets = LocalAssetRepository(repository.files);
        final editor = LocalImageEditor(repository.files);
        final service = ProjectService(repository, assets, imageEditor: editor);
        var project = await service.create('اختبار تنسيق التخزين');
        project = (await service.importImages(project, [
          ImportSource(
            'sample.png',
            () => Stream.value(img.encodePng(img.Image(width: 80, height: 60))),
          ),
        ])).project;
        final original = project.assets.single;
        final recipe = CropDraft(
          corners: [
            Point2(.1, .1),
            Point2(.9, .1),
            Point2(.9, .9),
            Point2(.1, .9),
          ],
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
          projects: repository,
        );

        // These operations contend on the storage-root OS lock. Whichever gets
        // it first is safe: deletion first makes the later save fail its fresh
        // file check; publication first makes deletion see the new live ref.
        final results = await Future.wait<Object>([
          _capture(repository.save(project.copyWith(assets: [revision]))),
          _capture(maintenance.deleteFiles([directory])),
        ]);
        final saveResult = results[0];
        final deleteResult = results[1];

        await repository.close();
        repository = await LocalProjectRepository.open(root);
        final stored = await repository.metadata(project.id);
        final savedRevision =
            stored.assets.single.workingPath == revision.workingPath;
        if (saveResult is Project) {
          expect(savedRevision, isTrue);
          expect(
            deleteResult,
            anyOf(isA<ValidationException>(), isA<StorageException>()),
          );
          expect(await working.exists(), isTrue);
          await repository.get(project.id);
        } else {
          expect(saveResult, isA<StorageException>());
          expect(savedRevision, isFalse);
          expect(deleteResult, 1);
          expect(await working.exists(), isFalse);
          await repository.get(project.id);
        }
      } finally {
        await repository.close();
        await root.delete(recursive: true);
      }
    },
  );
}

Future<Object> _capture<T>(Future<T> operation) => operation.then<Object>(
  (value) => value,
  onError: (Object error) => error,
);
