import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as path;
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_backups.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

void main() {
  late Directory root;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;
  late LocalProjectBackups backups;
  late Project project;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan-backup-test-');
    projects = await LocalProjectRepository.open(root);
    assets = LocalAssetRepository(projects.files);
    backups = LocalProjectBackups(projects, projects.files);
    final service = ProjectService(
      projects,
      assets,
      imageEditor: LocalImageEditor(projects.files),
    );
    project = await service.create('نسخة كاملة');
    project = (await service.importImages(project, [
      ImportSource(
        'original.png',
        () => Stream.value(img.encodePng(img.Image(width: 80, height: 60))),
      ),
    ])).project;
    project = await service.applyCrop(
      project,
      project.assets.single,
      CropDraft.fullImage().toRecipe(80, 60),
    );
    project = await projects.save(
      project.copyWith(
        pageCount: 2,
        items: [
          DocumentItem(
            id: 'item',
            assetId: project.assets.single.id,
            x: 40,
            y: 50,
            width: 60,
            height: 45,
            rotation: 90,
            pageIndex: 1,
          ),
        ],
        exportProfile: ExportProfile(format: ExportFormat.png, dpi: 600),
      ),
    );
  });
  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
  });
  test(
    'complete backup survives removal of source project folder, preserving originals, revisions and mm',
    () async {
      final folder = Directory('${root.path}/projects/${project.id}');
      final expected = <String, List<int>>{};
      await for (final entity in folder.list(recursive: true)) {
        if (entity is File) {
          expected[path.relative(entity.path, from: folder.path)] = await entity
              .readAsBytes();
        }
      }
      expect(expected.length, 5);
      final file = await backups.create(project, root);
      await folder.delete(recursive: true);
      final restored = await backups.restore(file);
      expect(restored.id, isNot(project.id));
      expect(restored.revision, 0);
      expect(restored.items.single.toJson(), project.items.single.toJson());
      expect(restored.exportProfile.toJson(), project.exportProfile.toJson());
      for (final entry in expected.entries) {
        expect(
          await File(
            path.join(root.path, 'projects', restored.id, entry.key),
          ).readAsBytes(),
          entry.value,
        );
      }
      await projects.close();
      projects = await LocalProjectRepository.open(root);
      expect((await projects.get(restored.id)).toJson(), restored.toJson());
    },
  );
  test('restoring twice never overwrites an existing project', () async {
    final file = await backups.create(project, root);
    final a = await backups.restore(file), b = await backups.restore(file);
    expect({project.id, a.id, b.id}, hasLength(3));
    expect((await projects.get(project.id)).toJson(), project.toJson());
  });
  test(
    'truncated, trailing and hash-corrupt payloads never publish metadata or extraction folders',
    () async {
      final good = await backups.create(project, root);
      final bytes = await good.readAsBytes();
      for (final data in [
        bytes.sublist(0, bytes.length - 1),
        [...bytes, 1],
        [...bytes.sublist(0, bytes.length - 1), bytes.last ^ 1],
      ]) {
        final file = await File('${root.path}/bad.scanid').writeAsBytes(data);
        await expectLater(
          backups.restore(file),
          throwsA(isA<ValidationException>()),
        );
        expect(await projects.list(), hasLength(1));
      }
      final staging = Directory('${root.path}/staging');
      expect(await staging.list().toList(), isEmpty);
    },
  );
  test(
    'manifest path traversal, cross-project and duplicate names are rejected before extraction',
    () async {
      final good = await backups.create(project, root);
      final bytes = await good.readAsBytes();
      final prefix = utf8.encode('SCANID-BACKUP-1\n');
      final size = ByteData.sublistView(
        bytes,
        prefix.length,
        prefix.length + 4,
      ).getUint32(0);
      final payload = bytes.sublist(prefix.length + 4 + size);
      for (final attack in [
        '../../outside',
        'projects/other/assets/x/working.png',
        'projects/${project.id}/assets/x/NUL.png',
        'duplicate',
      ]) {
        final manifest =
            jsonDecode(
                  utf8.decode(
                    bytes.sublist(prefix.length + 4, prefix.length + 4 + size),
                  ),
                )
                as Map<String, dynamic>;
        final files = manifest['files'] as List;
        if (attack == 'duplicate') {
          files.add(files.first);
        } else {
          files.first['path'] = attack;
        }
        final encoded = utf8.encode(jsonEncode(manifest));
        final file = await File('${root.path}/attack.scanid').writeAsBytes([
          ...prefix,
          ...(ByteData(4)..setUint32(0, encoded.length)).buffer.asUint8List(),
          ...encoded,
          ...payload,
        ]);
        await expectLater(
          backups.restore(file),
          throwsA(isA<ValidationException>()),
        );
        expect(await projects.list(), hasLength(1));
      }
    },
  );
  test(
    'missing original prevents incomplete backup and leaves project metadata intact',
    () async {
      await (await assets.resolve(project.assets.single.originalPath)).delete();
      await expectLater(backups.create(project, root), throwsException);
      expect((await projects.list()).single.toJson(), project.toJson());
    },
  );
}
