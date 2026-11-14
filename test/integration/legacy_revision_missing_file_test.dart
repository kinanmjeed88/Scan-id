import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

void main() {
  test('missing referenced file refuses migration without rewriting metadata', () async {
    final root = await Directory.systemTemp.createTemp('legacy_missing_');
    final repository = await LocalProjectRepository.open(root);
    try {
      final assets = LocalAssetRepository(repository.files);
      final service = ProjectService(repository, assets);
      var project = await service.create('قديم');
      project = (await service.importImages(project, [
        ImportSource('sample.png', () => Stream.value(img.encodePng(img.Image(width: 40, height: 30)))),
      ])).project;
      final json = project.assets.single.toJson()
        ..remove('revisionId')
        ..remove('revisionHistoryComplete');
      project = await repository.save(project.copyWith(assets: [ImageAsset.fromJson(json)]));
      final before = project.toJson();
      await File('${root.path}/${project.assets.single.workingPath}').delete();
      await expectLater(repository.migrateLegacyRevisionIdentities(project.id), throwsA(isA<Object>()));
      expect((await repository.metadata(project.id)).toJson(), before);
    } finally {
      await repository.close();
      await root.delete(recursive: true);
    }
  });
}
