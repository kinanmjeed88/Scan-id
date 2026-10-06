import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/image_adjustments.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

import '../fixtures.dart';

void main() {
  late Directory root;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;
  late LocalImageEditor editor;
  late ProjectService service;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan_edit_test_');
    projects = await LocalProjectRepository.open(root);
    assets = LocalAssetRepository(projects.files);
    editor = LocalImageEditor(projects.files);
    service = ProjectService(projects, assets, imageEditor: editor);
  });
  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
  });

  test(
    'preview does not persist; acceptance creates new files and survives reopening',
    () async {
      final original = img.encodePng(img.Image(width: 100, height: 80));
      var project = await service.create('قص محفوظ');
      project = (await service.importImages(project, [
        ImportSource('image.png', () => Stream.value(original)),
      ])).project;
      final asset = project.assets.single;
      final oldWork = await (await assets.resolve(
        asset.workingPath,
      )).readAsBytes();
      final source = await editor.open(asset);
      expect([source.width, source.height], [100, 80]);
      final draft = CropDraft(
        corners: [
          Point2(.1, .1),
          Point2(.9, .1),
          Point2(.9, .9),
          Point2(.1, .9),
        ],
        adjustments: ImageAdjustments(
          brightness: .1,
          contrast: 1.2,
          quarterTurns: 1,
        ),
      );
      final recipe = draft.toRecipe(source.width, source.height);
      final preview = await editor.preview(asset, recipe);
      expect(img.decodePng(preview), isNotNull);
      expect((await projects.get(project.id)).toJson(), project.toJson());
      final saved = await service.applyCrop(project, asset, recipe);
      final changed = saved.assets.single;
      expect(changed.id, asset.id);
      expect(changed.originalPath, asset.originalPath);
      expect(changed.workingPath, isNot(asset.workingPath));
      expect(changed.width, recipe.geometry.outputHeight);
      expect(changed.height, recipe.geometry.outputWidth);
      expect(
        await (await assets.resolve(asset.originalPath)).readAsBytes(),
        original,
      );
      expect(
        await (await assets.resolve(asset.workingPath)).readAsBytes(),
        oldWork,
      );
      expect(
        await (await assets.resolve(changed.workingPath)).readAsBytes(),
        preview,
      );
      await projects.close();
      projects = await LocalProjectRepository.open(root);
      final reopened = await projects.get(project.id);
      expect(reopened.toJson(), saved.toJson());
      expect(reopened.assets.single.adjustments.quarterTurns, 1);
      // Re-editing reads the original, not the previously cropped working image.
      final reset = await editor.preview(
        changed,
        CropDraft.fullImage().toRecipe(100, 80),
      );
      expect(
        [img.decodePng(reset)!.width, img.decodePng(reset)!.height],
        [100, 80],
      );
    },
  );
  test(
    'a stale crop acceptance cannot overwrite newer project metadata',
    () async {
      final original = img.encodePng(img.Image(width: 10, height: 8));
      var project = await service.create('تعارض القص');
      project = (await service.importImages(project, [
        ImportSource('image.png', () => Stream.value(original)),
      ])).project;
      await service.rename(project, 'أحدث');
      await expectLater(
        service.applyCrop(
          project,
          project.assets.single,
          CropDraft.fullImage().toRecipe(10, 8),
        ),
        throwsA(isA<RevisionConflict>()),
      );
      expect((await projects.get(project.id)).name, 'أحدث');
      expect(
        (await projects.get(project.id)).assets.single.workingPath,
        project.assets.single.workingPath,
      );
      expect(
        await (await assets.resolve(
          project.assets.single.originalPath,
        )).readAsBytes(),
        original,
      );
    },
  );
  test(
    'schema one migrates in memory with neutral adjustments; next save writes current schema',
    () async {
      final old = projectFixture().toJson()..['schemaVersion'] = 1;
      final migrated = Project.fromJson(old);
      expect(migrated.toJson()['schemaVersion'], Project.schemaVersion);
      final assetJson = assetFixture().toJson()..remove('adjustments');
      expect(ImageAsset.fromJson(assetJson).adjustments.brightness, 0);
      expect(ImageAsset.fromJson(assetJson).adjustments.contrast, 1);
      final created = await projects.create(migrated);
      expect(
        (await projects.get(created.id)).toJson()['schemaVersion'],
        Project.schemaVersion,
      );
      expect(
        old['schemaVersion'],
        1,
        reason: 'Reading old metadata is not destructive',
      );
    },
  );
}
