import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

void main() {
  test('legacy path fallback becomes a stored identity, not a path identity', () async {
    final root = await Directory.systemTemp.createTemp('legacy_path_revision_');
    var repository = await LocalProjectRepository.open(root);
    try {
      final assets = LocalAssetRepository(repository.files);
      final service = ProjectService(repository, assets, imageEditor: LocalImageEditor(repository.files));
      var project = await service.create('مراجعة قديمة');
      project = (await service.importImages(project, [
        ImportSource('sample.png', () => Stream.value(img.encodePng(img.Image(width: 80, height: 60)))),
      ])).project;
      final recipe = CropDraft(corners: [
        Point2(.1, .1), Point2(.9, .1), Point2(.9, .9), Point2(.1, .9),
      ]).toRecipe(80, 60);
      project = await service.applyCrop(project, project.assets.single, recipe);
      final old = project.assets.single.toJson()
        ..remove('revisionId')
        ..remove('parentRevisionId')
        ..remove('revisionHistory')
        ..remove('revisionHistoryComplete')
        ..remove('originalWidth')
        ..remove('originalHeight');
      final legacy = ImageAsset.fromJson(old);
      expect(legacy.revisionId, isNotNull);
      final alias = legacy.revisionId;
      project = await repository.save(project.copyWith(assets: [legacy]));
      final result = await repository.migrateLegacyRevisionIdentities(project.id);
      final migrated = result.project.assets.single;
      expect(migrated.revisionId, isNotNull);
      expect(migrated.revisionId, isNot(alias));
      expect(migrated.workingPath, legacy.workingPath);
      expect(migrated.parentRevisionId, isNull);
      expect(migrated.originalWidth, isNull);
      expect(migrated.originalHeight, isNull);
      expect(migrated.revisionHistoryComplete, isFalse);
      final savedId = migrated.revisionId;
      await repository.close();
      repository = await LocalProjectRepository.open(root);
      expect((await repository.get(project.id)).assets.single.revisionId, savedId);
    } finally {
      await repository.close();
      await root.delete(recursive: true);
    }
  });
}
