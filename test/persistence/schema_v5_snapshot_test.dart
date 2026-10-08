import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';
import 'package:scan_id/application/contracts.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

/// Failure-safe pre-upgrade snapshot + recoverability (docs/MIGRATION_V5.md §2,
/// DESIGN_LOCK.md §4). The destructive v4→v5 rewrite only happens on save, and
/// only after a write-if-absent snapshot of the raw legacy bytes; a failure
/// anywhere leaves the original recoverable.
void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('scan_v5_snap_');
    const prefix = 'projects/p1/assets/a1';
    final files = {
      '$prefix/original.png': 'original bytes',
      '$prefix/working.png': 'working bytes',
      '$prefix/thumb.jpg': 'thumbnail bytes',
    };
    for (final entry in files.entries) {
      final file = File('${directory.path}/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  Map<String, Object?> legacyV4() {
    final json = Project(
      id: 'p1',
      name: 'legacy',
      createdAt: DateTime.utc(2026, 10, 6),
      updatedAt: DateTime.utc(2026, 10, 6),
      revision: 3,
      assets: [
        ImageAsset(
          id: 'a1',
          name: 'card.png',
          originalPath: 'projects/p1/assets/a1/original.png',
          workingPath: 'projects/p1/assets/a1/working.png',
          thumbnailPath: 'projects/p1/assets/a1/thumb.jpg',
          width: 400,
          height: 250,
        ),
      ],
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
    ).toJson();
    json['schemaVersion'] = 4;
    json.remove('documents');
    json.remove('layoutGroups');
    return json;
  }

  File snapshotFile() {
    return File('${directory.path}/migration-snapshots/p1.json');
  }

  test('first save writes a pre-upgrade snapshot', () async {
    final raw = legacyV4();
    await _putRaw(directory, raw);
    final repository = await LocalProjectRepository.open(directory);
    final opened = await repository.get('p1');
    await repository.save(opened.copyWith(name: 'محفوظ'));
    await repository.close();

    // The stored record is now v5 with the synthesized record.
    final upgraded = (await _getRaw(directory))!;
    expect(upgraded['schemaVersion'], Project.schemaVersion);
    expect(upgraded['documents'], isA<List<Object?>>());

    // The snapshot captured the exact original v4 bytes and schema number.
    final decoded = await _snapshotJson(snapshotFile());
    expect(decoded['version'], 1);
    expect(decoded['schemaVersion'], 4);
    expect(decoded['project'], raw);
  });

  test('an existing snapshot is never overwritten (write-if-absent)', () async {
    final raw = legacyV4();
    await _putRaw(directory, raw);
    final file = snapshotFile();
    await file.parent.create(recursive: true);
    await file.writeAsString('{"sentinel":true}');

    final repository = await LocalProjectRepository.open(directory);
    final opened = await repository.get('p1');
    await repository.save(opened.copyWith(name: 'x'));
    await repository.close();

    expect(await file.readAsString(), '{"sentinel":true}');
  });

  test('interrupted migration recovers from the snapshot', () async {
    final raw = legacyV4();
    await _putRaw(directory, raw);
    // Simulate a crash AFTER the snapshot but BEFORE the destructive write.
    final file = snapshotFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({'version': 1, 'schemaVersion': 4, 'project': raw}),
    );

    // The database was never rewritten: it still holds the legacy record.
    final stillLegacy = (await _getRaw(directory))!;
    expect(stillLegacy['schemaVersion'], 4);

    // The snapshot is a valid rollback point: exact original + original schema.
    final decoded = await _snapshotJson(file);
    expect(decoded['schemaVersion'], 4);
    expect(decoded['project'], raw);

    // Completing the migration upgrades the DB but leaves the snapshot intact.
    final repository = await LocalProjectRepository.open(directory);
    final opened = await repository.get('p1');
    await repository.save(opened.copyWith(name: 'x'));
    await repository.close();
    expect((await _getRaw(directory))!['schemaVersion'], Project.schemaVersion);
    final after = await _snapshotJson(file);
    expect(after['project'], raw);
  });

  test('a failed save leaves the original record recoverable', () async {
    final raw = legacyV4();
    await _putRaw(directory, raw);
    final repository = await LocalProjectRepository.open(directory);
    final opened = await repository.get('p1');
    // Break a referenced asset so the pre-commit asset check fails.
    await File('${directory.path}/projects/p1/assets/a1/working.png').delete();
    await expectLater(
      repository.save(opened.copyWith(name: 'x')),
      throwsA(isA<StorageException>()),
    );
    await repository.close();
    // Nothing was committed: the raw legacy record is untouched.
    expect(await _getRaw(directory), raw);
  });
}

final _store = stringMapStoreFactory.store('projects');

Future<void> _putRaw(Directory directory, Map<String, Object?> json) async {
  final db = await databaseFactoryIo.openDatabase(
    '${directory.path}/projects.db',
  );
  await _store.record('p1').put(db, json);
  await db.close();
}

Future<Map<String, Object?>?> _getRaw(Directory directory) async {
  final db = await databaseFactoryIo.openDatabase(
    '${directory.path}/projects.db',
  );
  final value = await _store.record('p1').get(db);
  await db.close();
  return value == null ? null : Map<String, Object?>.of(value);
}

Future<Map<String, dynamic>> _snapshotJson(File file) async {
  final text = await file.readAsString();
  return jsonDecode(text) as Map<String, dynamic>;
}
