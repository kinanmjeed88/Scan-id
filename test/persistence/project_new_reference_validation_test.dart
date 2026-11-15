import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/domain/recognition_routing.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

import '../fixtures.dart';

/// These sequential checks do not test exclusion against concurrent deletion.
void main() {
  late Directory root;
  late LocalProjectRepository repository;

  Future<void> write(String relative) async {
    final file = File('${root.path}/$relative');
    await file.create(recursive: true);
    await file.writeAsBytes([1, 2, 3]);
  }

  Future<ImageAsset> prepareAsset() async {
    final asset = assetFixture();
    for (final path in {
      asset.originalPath,
      asset.workingPath,
      asset.thumbnailPath,
      asset.processingInputPath,
    }) {
      await write(path);
    }
    return asset;
  }

  ImageAsset withHistoricalPath(ImageAsset asset, String working) {
    final history = ImageRevision(
      id: 'old_revision',
      originalPath: asset.originalPath,
      workingPath: working,
      thumbnailPath: asset.thumbnailPath,
      processingInputPath: asset.processingInputPath,
      width: asset.width,
      height: asset.height,
    );
    return ImageAsset.fromJson({
      ...asset.toJson(),
      'revisionHistory': [history.toJson()],
    });
  }

  DocumentRecord dismissedRecord(ImageAsset asset, String working) =>
      DocumentRecord(
        id: 'record1',
        sourceImageId: asset.id,
        sides: [
          DocumentSide(
            id: 'side1',
            side: SideKind.unknown,
            processedAsset: ProcessedAssetRef(
              workingPath: working,
              thumbnailPath: asset.thumbnailPath,
              width: asset.width,
              height: asset.height,
            ),
          ),
        ],
        pairing: PairingState.single,
        provenance: Provenance(
          sourceImageId: asset.id,
          detectionIds: ['detection1'],
          processedAssetVersion: 'v1',
          pipelineVersion: 'v1',
        ),
        overrides: [
          UserOverride(
            dismissed: true,
            fields: const ['dismissed', dismissalTombstoneField],
          ),
        ],
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('new_refs_');
    repository = await LocalProjectRepository.open(root);
  });

  tearDown(() async {
    await repository.close();
    await root.delete(recursive: true);
  });

  test(
    'create rejects a missing historical reference without a record',
    () async {
      final asset = await prepareAsset();
      const missing = 'projects/project1/assets/asset1/edits/old/working.png';
      final invalid = projectFixture(
        assets: [withHistoricalPath(asset, missing)],
      );
      await expectLater(
        repository.create(invalid),
        throwsA(isA<StorageException>()),
      );
      expect(await repository.list(), isEmpty);
      await repository.close();
      repository = await LocalProjectRepository.open(root);
      expect(await repository.list(), isEmpty);
      await write(missing);
      final saved = await repository.create(invalid);
      await repository.close();
      repository = await LocalProjectRepository.open(root);
      final reopened = await repository.get(saved.id);
      expect(reopened.toJson(), saved.toJson());
      expect(await File('${root.path}/$missing').readAsBytes(), [1, 2, 3]);
    },
  );

  test(
    'save rejects newly named missing historical files',
    () async {
      final asset = await prepareAsset();
      final saved = await repository.create(projectFixture(assets: [asset]));
      final checkpoint = File('${root.path}/checkpoints/${saved.id}.json');
      final beforeCheckpoint = await checkpoint.readAsString();
      const historyPath =
          'projects/project1/assets/asset1/edits/old/working.png';
      final history = saved.copyWith(
        assets: [withHistoricalPath(asset, historyPath)],
      );
      await expectLater(
        repository.save(history),
        throwsA(isA<StorageException>()),
      );
      expect((await repository.metadata(saved.id)).toJson(), saved.toJson());
      expect(await checkpoint.readAsString(), beforeCheckpoint);
      const documentPath =
          'projects/project1/assets/asset1/edits/doc/working.png';
      await repository.close();
      repository = await LocalProjectRepository.open(root);
      expect((await repository.get(saved.id)).toJson(), saved.toJson());
      await write(historyPath);
      await write(documentPath);
      final next = await repository.save(
        saved.copyWith(
          assets: [withHistoricalPath(asset, historyPath)],
          documents: [dismissedRecord(asset, documentPath)],
        ),
      );
      await repository.close();
      repository = await LocalProjectRepository.open(root);
      final reopened = await repository.get(next.id);
      expect(reopened.toJson(), next.toJson());
      expect(
        reopened.assets.single.revisionHistory.single.workingPath,
        historyPath,
      );
      expect(
        reopened.documents.single.sides.single.processedAsset.workingPath,
        documentPath,
      );
      for (final path in [
        asset.originalPath,
        asset.workingPath,
        asset.thumbnailPath,
        historyPath,
        documentPath,
      ]) {
        expect(await File('${root.path}/$path').readAsBytes(), [1, 2, 3]);
      }
    },
  );

  test(
    'previously missing historical paths are not newly invented or removed',
    () async {
      final asset = await prepareAsset();
      const historical =
          'projects/project1/assets/asset1/edits/old/working.png';
      await write(historical);
      final saved = await repository.create(
        projectFixture(assets: [withHistoricalPath(asset, historical)]),
      );
      await File('${root.path}/$historical').delete();
      final renamed = await repository.save(saved.copyWith(name: 'renamed'));
      await repository.close();
      repository = await LocalProjectRepository.open(root);
      final reopened = await repository.get(renamed.id);
      expect(
        reopened.assets.single.revisionHistory.single.workingPath,
        historical,
      );
      expect(await File('${root.path}/$historical').exists(), isFalse);
      expect(reopened.name, 'renamed');
    },
  );
}
