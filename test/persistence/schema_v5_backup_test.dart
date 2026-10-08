import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/recognition.dart';
import 'package:scan_id/persistence/local_project_backups.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

/// Backup / restore round-trips through the migration layer
/// (docs/MIGRATION_V5.md §5): a v5 backup restores as v5 preserving every
/// record/ref/override/preset snapshot/processed reference/confidence; a legacy
/// backup is restored and migrated; and a missing regenerable processed asset
/// never corrupts the restore.
void main() {
  late Directory root;
  late LocalProjectRepository projects;
  late LocalProjectBackups backups;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan_v5_backup_');
    projects = await LocalProjectRepository.open(root);
    backups = LocalProjectBackups(projects, projects.files);
    const prefix = 'projects/p1/assets/a1';
    final files = {
      '$prefix/original.png': 'original bytes',
      '$prefix/working.png': 'working bytes',
      '$prefix/thumb.jpg': 'thumbnail bytes',
    };
    for (final entry in files.entries) {
      final file = File('${root.path}/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
  });
  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
  });

  ImageAsset asset() => ImageAsset(
    id: 'a1',
    name: 'card.png',
    originalPath: 'projects/p1/assets/a1/original.png',
    workingPath: 'projects/p1/assets/a1/working.png',
    thumbnailPath: 'projects/p1/assets/a1/thumb.jpg',
    width: 400,
    height: 250,
  );

  // A complete v5 project: one recognized record with confidence, a preset
  // snapshot, a user override, and a processed-asset reference.
  Project v5Project({String processedPrefix = 'projects/p1/assets/a1'}) {
    final record = DocumentRecord(
      id: 'rec-card',
      sourceImageId: 'a1',
      pairing: PairingState.single,
      recognition: RecognitionResult(
        documentKind: DocumentKind.passport,
        status: RecognitionStatus.recognized,
        confidences: ConfidenceSet(
          classification: Confidence(value: 0.9, producer: 'p', version: '1'),
          finalConfidence: Confidence(value: 0.9, producer: 'p', version: '1'),
        ),
        preset: const PresetSelection.resolved('builtin-passport'),
        pipelineVersion: 'pipe-1',
        validated: true,
      ),
      provenance: Provenance(
        sourceImageId: 'a1',
        detectionIds: const ['a1'],
        processedAssetVersion: 'proc-1',
        pipelineVersion: 'pipe-1',
        presetVariantId: 'builtin-passport',
        layoutItemIds: const ['card'],
      ),
      overrides: [
        UserOverride(
          documentKind: DocumentKind.residenceCard,
          fields: const ['documentKind'],
        ),
      ],
      sides: [
        DocumentSide(
          id: 'side-card',
          side: SideKind.front,
          processedAsset: ProcessedAssetRef(
            workingPath: '$processedPrefix/working.png',
            thumbnailPath: '$processedPrefix/thumb.jpg',
            width: 400,
            height: 250,
          ),
        ),
      ],
    );
    return Project(
      id: 'p1',
      name: 'v5 backup',
      createdAt: DateTime.utc(2026, 10, 6),
      updatedAt: DateTime.utc(2026, 10, 6),
      assets: [asset()],
      items: [
        DocumentItem(
          id: 'card',
          assetId: 'a1',
          x: 40,
          y: 50,
          width: 125,
          height: 88,
          documentKind: DocumentKind.passport,
          recognitionConfidence: 0.9,
          sizeConfirmed: true,
          documentId: 'rec-card',
          sideId: 'side-card',
          presetSnapshot: PresetSnapshot(
            variantId: 'builtin-passport',
            widthMm: 125,
            heightMm: 88,
            status: PresetStatus.standard,
          ),
        ),
      ],
      documents: [record],
    );
  }

  test('a v5 backup restores as v5 with records and confidence', () async {
    final created = await projects.create(v5Project());
    final file = await backups.create(created, root);
    await Directory('${root.path}/projects/p1').delete(recursive: true);

    final restored = await backups.restore(file);
    expect(restored.id, isNot('p1'));
    expect(restored.revision, 0);
    expect(restored.documents, hasLength(1));
    final record = restored.documents.single;
    expect(record.id, 'rec-card');
    expect(record.recognition!.confidences.classification!.value, 0.9);
    expect(record.recognition!.preset.variantId, 'builtin-passport');
    expect(record.overrides.single.documentKind, DocumentKind.residenceCard);
    // The processed-asset reference is remapped to the new project folder.
    final working = record.sides.single.processedAsset.workingPath;
    expect(working.startsWith('projects/${restored.id}/'), isTrue);
    // The frozen preset snapshot on the item survives verbatim.
    final snapshot = restored.items.single.presetSnapshot!;
    expect(snapshot.variantId, 'builtin-passport');
    expect(snapshot.widthMm, 125);
    // Reopening reads back exactly what was restored.
    expect((await projects.get(restored.id)).toJson(), restored.toJson());
  });

  test('a missing processed asset does not corrupt restore', () async {
    // The processed reference points under processed/ to a file that was never
    // written; the referenced working image (the asset) is what matters.
    final created = await projects.create(
      v5Project(processedPrefix: 'projects/p1/processed/procX'),
    );
    final file = await backups.create(created, root);

    final restored = await backups.restore(file);
    expect(
      restored.documents.single.sides.single.processedAsset.workingPath,
      'projects/${restored.id}/processed/procX/working.png',
    );
    // The project still opens; only pixel operations on the missing cache fail.
    expect((await projects.get(restored.id)).documents, hasLength(1));
    expect(
      await File(
        '${root.path}/projects/${restored.id}/processed/procX/working.png',
      ).exists(),
      isFalse,
    );
  });

  test('a legacy (v4) backup is restored and migrated to v5', () async {
    final legacy = Project(
      id: 'p1',
      name: 'legacy backup',
      createdAt: DateTime.utc(2026, 10, 6),
      updatedAt: DateTime.utc(2026, 10, 6),
      revision: 2,
      assets: [asset()],
      items: [
        DocumentItem(
          id: 'card',
          assetId: 'a1',
          x: 20,
          y: 25,
          width: 85.6,
          height: 53.98,
          documentKind: DocumentKind.unifiedNationalId,
          recognitionConfidence: 0.9,
          sizeConfirmed: true,
        ),
      ],
    ).toJson()
      ..['schemaVersion'] = 4;
    final file = await _craftLegacyBackup(root, legacy);

    final restored = await backups.restore(file);
    expect(restored.id, isNot('p1'));
    expect(restored.revision, 0);
    // Migration ran on restore: the record was synthesized from the scalar.
    expect(restored.documents, hasLength(1));
    expect(restored.documents.single.id, 'rec-card');
    expect(
      restored.documents.single.recognition!.confidences.classification!.value,
      0.9,
    );
    expect(restored.items.single.documentId, 'rec-card');
  });
}

/// Writes a real `.scanid` backup whose manifest carries [projectJson] verbatim
/// (a legacy schema), exactly as an old release would have stored it.
Future<File> _craftLegacyBackup(
  Directory root,
  Map<String, Object?> projectJson,
) async {
  const prefix = 'projects/p1/assets/a1';
  final paths = [
    '$prefix/original.png',
    '$prefix/working.png',
    '$prefix/thumb.jpg',
  ]..sort();
  final records = <Map<String, Object?>>[];
  for (final name in paths) {
    final bytes = await File('${root.path}/$name').readAsBytes();
    records.add({
      'path': name,
      'size': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    });
  }
  final manifest = utf8.encode(
    jsonEncode({'format': 1, 'project': projectJson, 'files': records}),
  );
  final out = File('${root.path}/legacy.scanid');
  final sink = await out.open(mode: FileMode.write);
  try {
    await sink.writeFrom(utf8.encode('SCANID-BACKUP-1\n'));
    await sink.writeFrom(
      (ByteData(4)..setUint32(0, manifest.length)).buffer.asUint8List(),
    );
    await sink.writeFrom(manifest);
    for (final name in paths) {
      await sink.writeFrom(await File('${root.path}/$name').readAsBytes());
    }
  } finally {
    await sink.close();
  }
  return out;
}
