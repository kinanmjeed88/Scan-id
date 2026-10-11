import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/domain/image_limits.dart';
import 'package:scan_id/imaging/large_jpeg_plan.dart';
import 'package:scan_id/persistence/large_jpeg_scaler.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

Uint8List _jpegSofOnly(int width, int height) => Uint8List.fromList([
  0xff,
  0xd8,
  0xff,
  0xc0,
  0,
  11,
  8,
  (height >> 8) & 255,
  height & 255,
  (width >> 8) & 255,
  width & 255,
  1,
  1,
  0x11,
  0,
  0,
  0xff,
  0xd9,
]);

class _FakeLargeJpegScaler implements LargeJpegScaler {
  _FakeLargeJpegScaler(this.workingPng);
  final Uint8List workingPng;
  LargeJpegPlan? lastPlan;

  @override
  Future<Uint8List> scaleJpeg(Uint8List source, LargeJpegPlan plan) async {
    lastPlan = plan;
    return Uint8List.fromList(workingPng);
  }
}

void main() {
  late Directory root;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;
  late ProjectService service;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan_import_test_');
    projects = await LocalProjectRepository.open(root);
    assets = LocalAssetRepository(projects.files);
    service = ProjectService(
      projects,
      assets,
      imageEditor: LocalImageEditor(projects.files),
    );
  });
  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
  });

  /// Anything left under staging after an operation, by relative name.
  Future<List<String>> stagingEntries() async {
    final staging = Directory('${root.path}/staging');
    if (!await staging.exists()) {
      return const [];
    }
    final entries = await staging.list().toList();
    return [for (final entity in entries) p.basename(entity.path)];
  }

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
  test(
    'simultaneous imports keep one committed revision and report the conflict',
    () async {
      final project = await service.create('متزامن');
      final bytes = img.encodePng(img.Image(width: 8, height: 8));
      final reports = await Future.wait([
        service.importImages(project, [
          ImportSource('first.png', () => Stream.value(bytes)),
        ]),
        service.importImages(project, [
          ImportSource('second.png', () => Stream.value(bytes)),
        ]),
      ]);
      expect(reports.map((r) => r.imported).reduce((a, b) => a + b), 1);
      expect(reports.expand((r) => r.failures), hasLength(1));
      final saved = await projects.get(project.id);
      expect(saved.revision, 1);
      expect(saved.assets, hasLength(1));
      expect(
        await (await assets.resolve(
          saved.assets.single.originalPath,
        )).readAsBytes(),
        bytes,
      );
    },
  );
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
      await expectLater(
        service.removeAsset(used, asset.id),
        throwsA(isA<ValidationException>()),
      );
      final cleared = await projects.save(used.copyWith(items: []));
      final result = await service.removeAsset(cleared, asset.id);
      expect(result.assets, isEmpty);
      expect(
        await (await assets.resolve(asset.originalPath)).readAsBytes(),
        bytes,
      );
    },
  );

  test(
    'a dismissed record continues to protect its source and derived assets',
    () async {
      final bytes = img.encodePng(img.Image(width: 40, height: 30));
      var project = await service.create('أصول مستبعدة');
      project = (await service.importImages(project, [
        ImportSource('source.png', () => Stream.value(bytes)),
      ])).project;
      final source = project.assets.single;
      final derived = (await assets.importImage(
        project.id,
        'مستند مشتق.png',
        bytes,
      )).asDerivedOf(source.id);
      final historicalPrefix =
          'projects/${project.id}/assets/${derived.id}/edits/old-output';
      for (final path in [
        '$historicalPrefix/working.png',
        '$historicalPrefix/thumb.jpg',
      ]) {
        final file = File('${root.path}/$path');
        await file.parent.create(recursive: true);
        await file.writeAsBytes([1, 2, 3]);
      }
      final record = DocumentRecord(
        id: 'rec-dismissed',
        sourceImageId: source.id,
        sides: [
          DocumentSide(
            id: 'side-dismissed',
            side: SideKind.unknown,
            processedAsset: ProcessedAssetRef(
              workingPath: '$historicalPrefix/working.png',
              thumbnailPath: '$historicalPrefix/thumb.jpg',
              width: derived.width,
              height: derived.height,
            ),
          ),
        ],
        pairing: PairingState.single,
        provenance: Provenance(
          sourceImageId: source.id,
          detectionIds: ['${source.id}-d0'],
          processedAssetVersion: 'smart-1',
          pipelineVersion: 'smart-1',
        ),
        overrides: [
          UserOverride(dismissed: true, fields: const ['dismissed']),
        ],
      );
      project = await projects.save(
        project.copyWith(
          assets: [...project.assets, derived],
          documents: [record],
        ),
      );

      await expectLater(
        service.removeAsset(project, source.id),
        throwsA(isA<ValidationException>()),
      );
      await expectLater(
        service.removeAsset(project, derived.id),
        throwsA(isA<ValidationException>()),
      );
      expect(
        await (await assets.resolve(source.originalPath)).readAsBytes(),
        bytes,
      );
      expect(
        await (await assets.resolve(derived.workingPath)).length(),
        greaterThan(0),
      );
    },
  );

  test(
    'automatic crop clears a stale manual-crop marker without changing the original',
    () async {
      final original = img.encodePng(img.Image(width: 40, height: 30));
      var project = await service.create('مصدر القص');
      project = (await service.importImages(project, [
        ImportSource('photo.png', () => Stream.value(original)),
      ])).project;

      final manuallyCropped = await service.applyManualCrop(
        project,
        project.assets.single,
        CropDraft(
          corners: [
            Point2(.1, .1),
            Point2(.9, .1),
            Point2(.9, .9),
            Point2(.1, .9),
          ],
        ).toRecipe(40, 30),
      );
      final manualAsset = manuallyCropped.assets.single;
      expect(manualAsset.userAuthoredCrop, isTrue);

      final automaticallyCropped = await service.applyCrop(
        manuallyCropped,
        manualAsset,
        CropDraft(
          corners: [
            Point2(.2, .2),
            Point2(.8, .2),
            Point2(.8, .8),
            Point2(.2, .8),
          ],
        ).toRecipe(manualAsset.width, manualAsset.height),
      );

      expect(automaticallyCropped.assets.single.userAuthoredCrop, isFalse);
      expect(
        automaticallyCropped.assets.single.workingPath,
        isNot(manualAsset.workingPath),
      );
      expect(
        await (await assets.resolve(
          project.assets.single.originalPath,
        )).readAsBytes(),
        original,
      );
    },
  );

  test('library reorder is persisted and rejects unknown images', () async {
    final bytes = img.encodePng(img.Image(width: 8, height: 8));
    var project = await service.create('ترتيب');
    project = (await service.importImages(project, [
      ImportSource('first.png', () => Stream.value(bytes)),
      ImportSource('second.png', () => Stream.value(bytes)),
    ])).project;
    final first = project.assets.first.id;
    final second = project.assets.last.id;

    final moved = await service.moveAsset(project, second, 0);

    expect(moved.assets.map((a) => a.id), [second, first]);
    expect((await projects.get(project.id)).assets.first.id, second);
    await expectLater(
      service.moveAsset(moved, 'unknown', 0),
      throwsA(isA<ValidationException>()),
    );
  });

  test(
    'replacing a source keeps the asset id, the old files and its placements',
    () async {
      final first = img.encodePng(img.Image(width: 40, height: 30));
      var project = await service.create('استبدال');
      project = (await service.importImages(project, [
        ImportSource('original.png', () => Stream.value(first)),
      ])).project;
      project = await service.applyCrop(
        project,
        project.assets.single,
        CropDraft.fullImage().toRecipe(40, 30),
      );
      project = await projects.save(
        project.copyWith(
          items: [
            DocumentItem(
              id: 'placed',
              assetId: project.assets.single.id,
              x: 20,
              y: 20,
              width: 40,
              height: 30,
            ),
          ],
        ),
      );
      final before = await (await assets.resolve(
        project.assets.single.originalPath,
      )).readAsBytes();
      final beforeWorking = project.assets.single.workingPath;
      final replacement = img.encodePng(img.Image(width: 30, height: 40));

      final report = await service.replaceImage(
        project,
        project.assets.single,
        ImportSource('new.png', () => Stream.value(replacement)),
      );

      final asset = report.project.assets.single;
      expect(report.aspectChanged, isTrue);
      expect(report.scalingMessage, isNull);
      expect(asset.id, project.assets.single.id);
      expect(asset.name, 'new.png');
      expect(asset.crop, isNull);
      expect(asset.originalPath, isNot(project.assets.single.originalPath));
      expect(
        asset.originalPath,
        startsWith('projects/${project.id}/assets/${asset.id}/replacements/'),
      );
      expect(
        await (await assets.resolve(asset.originalPath)).readAsBytes(),
        replacement,
      );
      expect(
        await (await assets.resolve(beforeWorking)).length(),
        greaterThan(0),
      );
      expect(
        await (await assets.resolve(
          project.assets.single.originalPath,
        )).readAsBytes(),
        before,
      );
      expect(report.project.items.single.assetId, asset.id);
      expect(report.project.revision, project.revision + 1);
    },
  );

  test('a large JPEG replacement reports its bounded working copy', () async {
    final scaler = _FakeLargeJpegScaler(
      Uint8List.fromList(img.encodePng(img.Image(width: 800, height: 640))),
    );
    assets = LocalAssetRepository(projects.files, largeJpegScaler: scaler);
    service = ProjectService(
      projects,
      assets,
      imageEditor: LocalImageEditor(projects.files),
    );
    final originalBytes = img.encodePng(img.Image(width: 40, height: 30));
    var project = await service.create('استبدال بصورة كبيرة');
    project = (await service.importImages(project, [
      ImportSource('original.png', () => Stream.value(originalBytes)),
    ])).project;
    final asset = project.assets.single;
    project = await projects.save(
      project.copyWith(
        items: [
          DocumentItem(
            id: 'placed-large-replacement',
            assetId: asset.id,
            x: 17,
            y: 23,
            width: 40,
            height: 30,
          ),
        ],
      ),
    );
    final beforeItem = project.items.single;
    final replacementBytes = _jpegSofOnly(5000, 4000);

    final report = await service.replaceImage(
      project,
      project.assets.single,
      ImportSource('replacement.jpg', () => Stream.value(replacementBytes)),
    );

    final replaced = report.project.assets.single;
    expect(scaler.lastPlan?.sourceWidth, 5000);
    expect(scaler.lastPlan?.sourceHeight, 4000);
    expect(
      scaler.lastPlan!.targetPixels,
      lessThanOrEqualTo(maxScaledWorkingPixels),
    );
    expect(report.scalingMessage, contains('الأصل كما هو'));
    expect(report.scalingMessage, contains('800×640'));
    expect(replaced.hasScaledLargeSource, isTrue);
    expect(report.project.items.single.toJson(), beforeItem.toJson());
    expect(
      await (await assets.resolve(replaced.originalPath)).readAsBytes(),
      replacementBytes,
    );
    expect(
      await (await assets.resolve(asset.originalPath)).readAsBytes(),
      originalBytes,
    );
  });

  test(
    'a corrupt replacement leaves the project and old files untouched',
    () async {
      final bytes = img.encodePng(img.Image(width: 8, height: 8));
      var project = await service.create('استبدال تالف');
      project = (await service.importImages(project, [
        ImportSource('good.png', () => Stream.value(bytes)),
      ])).project;
      final asset = project.assets.single;

      // The decode runs in an isolate, so the concrete error type may be wrapped;
      // what matters is that the call fails and nothing changed.
      await expectLater(
        service.replaceImage(
          project,
          asset,
          ImportSource('broken.png', () => Stream.value([1, 2, 3])),
        ),
        throwsA(anything),
      );

      final stored = await projects.get(project.id);
      expect(stored.toJson(), project.toJson());
      expect(
        await (await assets.resolve(asset.originalPath)).readAsBytes(),
        bytes,
      );
      expect(await stagingEntries(), isEmpty);
    },
  );

  test('discarding picked sources releases every picker-owned copy', () async {
    var released = 0;
    await service.discardSources([
      ImportSource(
        'a.png',
        () => Stream.value(const []),
        cleanup: () async => released++,
      ),
      ImportSource(
        'b.png',
        () => Stream.value(const []),
        cleanup: () async => released++,
      ),
    ]);
    expect(released, 2);
  });
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
