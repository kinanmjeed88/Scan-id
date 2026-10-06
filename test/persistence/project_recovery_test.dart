import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/persistence/local_project_recovery.dart';

void main() {
  late Directory root;
  late LocalProjectRepository projects;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan-recovery-');
    projects = await LocalProjectRepository.open(root);
  });
  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
  });
  test(
    'explicit recovery switches to a new database and preserves the corrupt database byte for byte',
    () async {
      final service = ProjectService(
        projects,
        LocalAssetRepository(projects.files),
      );
      final first = await service.create('قبل التلف');
      final saved = await service.rename(first, 'آخر حفظ');
      await projects.close();
      final old = File('${root.path}/projects.db');
      await old.writeAsString('broken database deliberately retained');
      final before = await old.readAsBytes();
      projects = await LocalProjectRepository.recover(root);
      expect((await projects.get(saved.id)).toJson(), saved.toJson());
      expect(await old.readAsBytes(), before);
      await projects.close();
      projects = await LocalProjectRepository.open(root);
      expect((await projects.get(saved.id)).name, 'آخر حفظ');
    },
  );
  test(
    'failed redundant checkpoint never misreports a committed write as failed',
    () async {
      final obstruction = await File(
        '${root.path}/checkpoints',
      ).writeAsString('blocks directory');
      final saved = await ProjectService(
        projects,
        LocalAssetRepository(projects.files),
      ).create('محفوظ');
      expect((await projects.get(saved.id)).name, 'محفوظ');
      expect(projects.checkpoints.warning, isNotNull);
      await obstruction.delete();
      await projects.save(saved.copyWith(name: 'مع نقطة استرداد'));
      expect(projects.checkpoints.warning, isNull);
    },
  );
  test(
    'metadata deletion is a recovery tombstone, not silent project resurrection',
    () async {
      final service = ProjectService(
        projects,
        LocalAssetRepository(projects.files),
      );
      final keep = await service.create('باقٍ');
      final removed = await service.create('محذوف');
      await projects.remove(removed);
      await projects.close();
      projects = await LocalProjectRepository.recover(root);
      expect((await projects.list()).map((p) => p.id), [keep.id]);
    },
  );
  test(
    'missing working copy and corrupt thumbnail rebuild from immutable original with saved crop',
    () async {
      final assets = LocalAssetRepository(projects.files);
      final editor = LocalImageEditor(projects.files);
      final service = ProjectService(projects, assets, imageEditor: editor);
      var p = await service.create('إصلاح');
      final bytes = img.encodePng(img.Image(width: 80, height: 60));
      p = (await service.importImages(p, [
        ImportSource('image.png', () => Stream.value(bytes)),
      ])).project;
      p = await service.applyCrop(
        p,
        p.assets.single,
        CropDraft.fullImage().toRecipe(80, 60),
      );
      final old = p.assets.single;
      await (await assets.resolve(old.workingPath)).delete();
      await (await assets.resolve(old.thumbnailPath)).writeAsString('broken');
      final recovery = LocalProjectRecovery(projects, editor);
      final metadata = await recovery.metadata(p.id);
      final repaired = await recovery.rebuildDerived(metadata);
      final next = repaired.assets.single;
      expect(next.workingPath, isNot(old.workingPath));
      expect(next.crop!.toJson(), old.crop!.toJson());
      expect(
        await (await assets.resolve(next.originalPath)).readAsBytes(),
        bytes,
      );
      expect(
        img.decodePng(
          await (await assets.resolve(next.workingPath)).readAsBytes(),
        ),
        isNotNull,
      );
      expect((await projects.get(p.id)).toJson(), repaired.toJson());
    },
  );
  test(
    'missing original aborts recovery without changing metadata or inventing pixels',
    () async {
      final assets = LocalAssetRepository(projects.files);
      final service = ProjectService(projects, assets);
      var p = await service.create('أصل مفقود');
      p = (await service.importImages(p, [
        ImportSource(
          'a.png',
          () => Stream.value(img.encodePng(img.Image(width: 10, height: 10))),
        ),
      ])).project;
      await (await assets.resolve(p.assets.single.originalPath)).delete();
      await expectLater(
        LocalProjectRecovery(
          projects,
          LocalImageEditor(projects.files),
        ).rebuildDerived(p),
        throwsException,
      );
      expect((await projects.metadata(p.id)).toJson(), p.toJson());
    },
  );
}
