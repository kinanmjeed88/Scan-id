import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/image_limits.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

void main() {
  late Directory root;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;
  late ProjectService service;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan_import_test_');
    projects = await LocalProjectRepository.open(root);
    assets = LocalAssetRepository(projects.files);
    service = ProjectService(projects, assets);
  });
  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
  });

  test(
    'import pipeline commits original, normalized copy and thumbnail then reopens',
    () async {
      final bytes = img.encodePng(img.Image(width: 100, height: 50));
      final sourceFile = File('${root.path}/external-original.png');
      await sourceFile.writeAsBytes(bytes);
      final project = await service.create('مشروع حقيقي');
      final report = await service.importImages(project, [
        ImportSource('صورة.png', () => sourceFile.openRead()),
      ]);
      expect(report.imported, 1);
      expect(report.failures, isEmpty);
      final asset = report.project.assets.single;
      expect(
        await (await assets.resolve(asset.originalPath)).readAsBytes(),
        bytes,
      );
      expect(await sourceFile.readAsBytes(), bytes);
      expect(
        await (await assets.resolve(asset.workingPath)).length(),
        greaterThan(0),
      );
      expect(
        await (await assets.resolve(asset.thumbnailPath)).length(),
        greaterThan(0),
      );
      expect(
        report.project.items,
        isEmpty,
        reason: 'No guessed physical dimensions',
      );
      await projects.close();
      projects = await LocalProjectRepository.open(root);
      expect(
        (await projects.get(project.id)).toJson(),
        report.project.toJson(),
      );
    },
  );
  test(
    'mixed batch reports failures and persists successes independently',
    () async {
      final bytes = img.encodePng(img.Image(width: 8, height: 8));
      final project = await service.create('مختلط');
      final report = await service.importImages(project, [
        ImportSource('good.png', () => Stream.value(bytes)),
        ImportSource('corrupt.jpg', () => Stream.value([255, 216, 255])),
        ImportSource('good-again.png', () => Stream.value(bytes)),
      ]);
      expect(report.imported, 2);
      expect(report.failures.single.name, 'corrupt.jpg');
      expect((await projects.get(project.id)).assets, hasLength(2));
      expect(report.project.revision, 2);
    },
  );
  test(
    'stale import reports all remaining files without another write attempt',
    () async {
      final project = await service.create('قبل التعارض');
      await projects.save(project.copyWith(name: 'حفظ أحدث'));
      final bytes = img.encodePng(img.Image(width: 8, height: 8));
      final report = await service.importImages(project, [
        ImportSource('first.png', () => Stream.value(bytes)),
        ImportSource('second.png', () => Stream.value(bytes)),
      ]);
      expect(report.imported, 0);
      expect(report.failures.map((f) => f.name), ['first.png', 'second.png']);
      expect((await projects.get(project.id)).name, 'حفظ أحدث');
      final originals = await root
          .list(recursive: true)
          .where(
            (entity) => entity is File && entity.path.endsWith('original.png'),
          )
          .toList();
      expect(originals, hasLength(1));
    },
  );
  test(
    'bounded reader cancels oversized input before decoder or persistence',
    () async {
      var requestedThirdChunk = false;
      Stream<List<int>> tooLarge() async* {
        yield Uint8List(maxImportBytes);
        yield [0];
        requestedThirdChunk = true;
        yield [0];
      }

      final project = await service.create('كبير');
      final report = await service.importImages(project, [
        ImportSource('huge.png', tooLarge),
      ]);
      expect(report.imported, 0);
      expect(report.failures.single.message, contains('20 MiB'));
      expect(requestedThirdChunk, isFalse);
      expect((await projects.get(project.id)).assets, isEmpty);
    },
  );
  test('rejected image leaves neither metadata nor new assets', () async {
    final project = await service.create('تالف');
    final report = await service.importImages(project, [
      ImportSource('bad.png', () => Stream.value([1, 2, 3])),
    ]);
    expect(report.project.assets, isEmpty);
    expect(await Directory('${root.path}/projects').exists(), isFalse);
    expect(await Directory('${root.path}/staging').exists(), isFalse);
  });
  test('file-picker cancellation is an empty batch with no save', () async {
    final project = await service.create('إلغاء');
    final report = await service.importImages(project, []);
    expect(report.project.revision, 0);
    expect(report.imported, 0);
    expect(report.failures, isEmpty);
  });
  test(
    'failed database save does not damage original or existing project',
    () async {
      final project = await service.create('قبل الخطأ');
      final failing = ProjectService(_FailingSave(projects), assets);
      final bytes = img.encodePng(img.Image(width: 8, height: 8));
      final report = await failing.importImages(project, [
        ImportSource('good.png', () => Stream.value(bytes)),
      ]);
      expect(report.imported, 0);
      expect(report.failures, hasLength(1));
      expect((await projects.get(project.id)).assets, isEmpty);
      // New files may be orphaned on commit failure, but existing metadata is safe.
      final originals = await root
          .list(recursive: true)
          .where(
            (entity) => entity is File && entity.path.endsWith('original.png'),
          )
          .toList();
      expect(originals, hasLength(1));
      expect(await File(originals.single.path).readAsBytes(), bytes);
    },
  );
  test(
    'removing an asset removes only the reference; used assets are protected',
    () async {
      final bytes = img.encodePng(img.Image(width: 8, height: 8));
      final created = await service.create('إزالة');
      final imported = (await service.importImages(created, [
        ImportSource('good.png', () => Stream.value(bytes)),
      ])).project;
      final asset = imported.assets.single;
      final used = await projects.save(
        imported.copyWith(
          items: [
            DocumentItem(
              id: 'item',
              assetId: asset.id,
              x: 10,
              y: 10,
              width: 50,
              height: 40,
            ),
          ],
        ),
      );
      expect(() => service.removeAsset(used, asset.id), throwsException);
      final cleared = await projects.save(used.copyWith(items: []));
      final result = await service.removeAsset(cleared, asset.id);
      expect(result.assets, isEmpty);
      expect(
        await (await assets.resolve(asset.originalPath)).readAsBytes(),
        bytes,
      );
    },
  );
}

class _FailingSave implements ProjectRepository {
  const _FailingSave(this.delegate);
  final ProjectRepository delegate;
  @override
  Future<Project> save(Project project) =>
      Future.error(const StorageException('فشل حفظ تجريبي'));
  @override
  Future<Project> create(Project project) => delegate.create(project);
  @override
  Future<Project> get(String id) => delegate.get(id);
  @override
  Future<List<Project>> list() => delegate.list();
  @override
  Future<void> remove(Project project) => delegate.remove(project);
  @override
  Future<void> close() => delegate.close();
}
