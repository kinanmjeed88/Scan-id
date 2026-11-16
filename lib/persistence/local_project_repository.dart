import 'dart:io';
import 'dart:convert';

import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';

import '../application/contracts.dart';
import '../application/ids.dart';
import '../domain/project.dart';
import '../domain/validation.dart';
import 'safe_files.dart';
import 'recovery_checkpoints.dart';
import 'storage_coordination.dart';

class LocalProjectRepository
    implements ProjectRepository, LegacyRevisionMigrator {
  LocalProjectRepository._(this._database, this.files)
    : checkpoints = RecoveryCheckpoints(files),
      coordination = StorageCoordination(files);
  final RecoveryCheckpoints checkpoints;
  final StorageCoordination coordination;
  final Database _database;
  final SafeFiles files;
  static final _projects = stringMapStoreFactory.store('projects');

  static Future<LocalProjectRepository> open(Directory directory) async {
    await directory.create(recursive: true);
    final root = Directory(await directory.resolveSymbolicLinks());
    final files = SafeFiles(root);
    var name = 'projects.db';
    final pointer = File(await files.checkedPath('active-store.json'));
    if (await pointer.exists()) {
      require(await pointer.length() < 512, 'مؤشر قاعدة البيانات غير صالح.');
      name = text(
        objectMap(jsonDecode(await pointer.readAsString()))['name'],
        'name',
      );
      require(
        RegExp(r'^recovered-[0-9a-f]{32}\.db$').hasMatch(name),
        'مؤشر قاعدة البيانات غير آمن.',
      );
    }
    final path = await files.checkedPath(name);
    // Never delete/recreate on corruption. Sembast's exception reaches the UI.
    final database = await databaseFactoryIo.openDatabase(path);
    return LocalProjectRepository._(database, files);
  }

  @override
  Future<List<Project>> list() async {
    final records = await _projects.find(_database);
    final projects = records.map((r) {
      final project = Project.fromJson(r.value);
      require(project.id == r.key, 'معرّف سجل المشروع غير متطابق.');
      return project;
    }).toList();
    projects.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return projects;
  }

  @override
  Future<Project> get(String id) async {
    final project = await metadata(id);
    await _checkAssets(project);
    return project;
  }

  Future<Project> metadata(String id) async {
    validId(id);
    final value = await _projects.record(id).get(_database);
    if (value == null) {
      throw const StorageException('المشروع غير موجود.');
    }
    final project = Project.fromJson(value);
    require(project.id == id, 'معرّف سجل المشروع غير متطابق.');
    return project;
  }

  Future<void> _checkAssets(Project project) async {
    for (final asset in project.assets) {
      for (final path in [
        asset.originalPath,
        asset.workingPath,
        asset.thumbnailPath,
        asset.processingInputPath,
      ]) {
        await files.existingFile(path);
      }
    }
  }

  /// Asset and historical file paths that must exist before a new reference is
  /// committed. Processed document sides can name a missing regenerable cache,
  /// including in older backups, and are excluded. Callers that publish project
  /// metadata hold [coordination] across this check and the commit.
  Set<String> _referencedPaths(Project project) => {
    for (final asset in project.assets) ...[
      asset.originalPath,
      asset.workingPath,
      asset.thumbnailPath,
      asset.processingInputPath,
      for (final revision in asset.revisionHistory) ...[
        revision.originalPath,
        revision.workingPath,
        revision.thumbnailPath,
        revision.processingInputPath,
      ],
    ],
  };

  Future<void> _checkNewReferences(Project next, Project? previous) async {
    final paths = _referencedPaths(next);
    if (previous != null) paths.removeAll(_referencedPaths(previous));
    for (final path in paths) {
      await files.existingFile(path);
    }
  }

  @override
  Future<Project> create(Project project) => coordination.runExclusive(() async {
    require(project.revision == 0, 'المشروع الجديد يجب أن يبدأ من مراجعة صفر.');
    await _checkNewReferences(project, null);
    final saved = await _database.transaction((txn) async {
      if (await _projects.record(project.id).exists(txn)) {
        throw const RevisionConflict();
      }
      await _projects.record(project.id).put(txn, project.toJson());
      return project;
    });
    await checkpoints.save(saved);
    return saved;
  });

  /// Explicitly assign a persistent identity to provable CURRENT revisions.
  /// Nothing is rewritten on open. The complete raw pre-migration record is
  /// snapshotted before saving; unknown histories remain marked incomplete and
  /// no parent or historical revision is inferred from a directory name.
  /// If any referenced file cannot be read, no metadata is committed.
  @override
  Future<LegacyRevisionMigrationResult> migrateLegacyRevisionIdentities(
    String projectId,
  ) => coordination.runExclusive(() async {
    final current = await get(projectId);
    final raw = await _projects.record(projectId).get(_database);
    if (raw == null || Project.fromJson(raw).revision != current.revision) {
      throw const RevisionConflict();
    }
    final migrated = <String>[];
    final unresolved = <String>[];
    final updated = <ImageAsset>[];
    for (final asset in current.assets) {
      if (!asset.revisionHistoryComplete) unresolved.add(asset.id);
      if (asset.toJson().containsKey('revisionId')) {
        updated.add(asset);
        continue;
      }
      final alias = asset.revisionId;
      if (alias != null &&
          (asset.parentRevisionId == alias ||
              asset.revisionHistory.any(
                (r) => r.id == alias || r.parentRevisionId == alias,
              ))) {
        // Changing an alias referenced by saved history would sever a link.
        updated.add(asset);
        continue;
      }
      final paths = <String>{
        asset.originalPath,
        asset.workingPath,
        asset.thumbnailPath,
        asset.processingInputPath,
        for (final revision in asset.revisionHistory) ...[
          revision.originalPath,
          revision.workingPath,
          revision.thumbnailPath,
          revision.processingInputPath,
        ],
      };
      for (final path in paths) {
        final file = await files.existingFile(path);
        final size = await file.length();
        var read = 0;
        await for (final bytes in file.openRead()) {
          read += bytes.length;
        }
        if (size == 0 || read != size || await file.length() != size) {
          throw const StorageException(
            'تعذر قراءة ملفات المراجعة بأمان؛ لم يغيّر الترحيل المشروع.',
          );
        }
      }
      final json = asset.toJson();
      var id = newId();
      while (asset.revisionHistory.any(
            (r) => r.id == id || r.parentRevisionId == id,
          ) ||
          asset.parentRevisionId == id) {
        id = newId();
      }
      json['revisionId'] = id;
      updated.add(ImageAsset.fromJson(json));
      migrated.add(asset.id);
    }
    if (migrated.isEmpty) {
      return LegacyRevisionMigrationResult(
        current,
        const [],
        List.unmodifiable(unresolved),
      );
    }
    await _snapshotRevisionMigration(projectId, current.revision, raw);
    final saved = await save(current.copyWith(assets: updated));
    return LegacyRevisionMigrationResult(
      saved,
      List.unmodifiable(migrated),
      List.unmodifiable(unresolved),
    );
  });

  Future<void> _snapshotRevisionMigration(
    String id,
    int revision,
    Map<String, Object?> raw,
  ) async {
    final target = File(
      await files.checkedPath(
        'migration-snapshots/revision-$id-$revision.json',
      ),
    );
    if (await target.exists()) {
      final existing = objectMap(jsonDecode(await target.readAsString()));
      require(
        jsonEncode(existing['project']) == jsonEncode(raw),
        'لقطة الترحيل الموجودة لا تطابق المشروع؛ لم يُعدّل المشروع.',
      );
      return;
    }
    final temporary = File(
      await files.checkedPath(
        'migration-snapshots/revision-$id-${newId()}.tmp',
      ),
    );
    try {
      await temporary.parent.create(recursive: true);
      await temporary.writeAsString(
        jsonEncode({'version': 1, 'project': raw}),
        flush: true,
      );
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  /// Commit order, and what a caller is told when each step fails:
  ///
  /// 1. the file check (read-only; a failure changes nothing);
  /// 2. the database transaction, which is durable on success. A rejected
  ///    revision or a failed pre-upgrade snapshot throws and changes nothing;
  /// 3. the recovery copy, written after the commit. If this write fails, the
  ///    save still succeeds: the data is committed and a retry would only hit
  ///    a revision conflict. The copy stays outdated, which is reported by
  ///    [staleRecoveryPoints] and repaired by [refreshRecoveryPoint].
  @override
  Future<Project> save(Project project) => coordination.runExclusive(() async {
    await _checkAssets(project);
    final saved = await _database.transaction((txn) async {
      final previous = await _projects.record(project.id).get(txn);
      if (previous == null) {
        throw const RevisionConflict();
      }
      final old = Project.fromJson(previous);
      if (old.revision != project.revision) {
        throw const RevisionConflict();
      }
      require(
        old.id == project.id && old.createdAt == project.createdAt,
        'لا يجوز تغيير هوية المشروع أو تاريخ إنشائه.',
      );
      // Existing broken historical references remain readable and repairable;
      // do not add new paths that are already missing at this point. The outer
      // storage-coordination lease serializes this check + commit with physical
      // deletion, including deletion in another isolate or process.
      await _checkNewReferences(project, old);
      // Failure-safe pre-upgrade snapshot: capture the raw legacy bytes before
      // the first v5 rewrite. If this write fails, the transaction aborts and
      // the ≤4 record is left intact (the upgrade never happens without a
      // rollback point). See docs/MIGRATION_V5.md §2 and DESIGN_LOCK.md §4.
      await _snapshotPreUpgrade(project.id, previous);
      final now = DateTime.now().toUtc();
      final saved = project.copyWith(
        revision: old.revision + 1,
        updatedAt: now.isBefore(old.updatedAt) ? old.updatedAt : now,
      );
      await _projects.record(project.id).put(txn, saved.toJson());
      return saved;
    });
    await checkpoints.save(saved);
    return saved;
  });

  /// Writes the raw pre-upgrade record to `migration-snapshots/<id>.json`,
  /// write-if-absent, only when the stored record is legacy (`schemaVersion` <
  /// [Project.schemaVersion]). Atomic via temp + rename; a failure propagates so
  /// the caller's migration write is aborted. Isolated from `checkpoints/`, so
  /// `RecoveryCheckpoints.read()`/`recover()` are unaffected.
  Future<void> _snapshotPreUpgrade(
    String projectId,
    Map<String, Object?> previous,
  ) async {
    final version = previous['schemaVersion'];
    if (version is! int || version >= Project.schemaVersion) {
      return;
    }
    final target = await files.checkedPath(
      'migration-snapshots/$projectId.json',
    );
    if (await File(target).exists()) {
      return;
    }
    final temporary = File(
      await files.checkedPath('migration-snapshots/$projectId-${newId()}.tmp'),
    );
    try {
      await temporary.parent.create(recursive: true);
      await temporary.writeAsString(
        jsonEncode({
          'version': 1,
          'schemaVersion': version,
          'project': previous,
        }),
        flush: true,
      );
      await temporary.rename(target);
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  /// Removal writes the recovery tombstone FIRST and requires it to succeed.
  /// If the tombstone cannot be written, nothing has changed and the removal
  /// fails. Written the other way round, a failed tombstone would leave the
  /// project in the copies, and a later recovery would bring it back after the
  /// user had deleted it. If the record delete itself fails, the live copy is
  /// written again, so the copies never claim a removal that did not happen.
  ///
  /// Intentional metadata-only deletion. Never recursively delete a path
  /// derived from a project file; GC and backup retention need a later design.
  @override
  Future<void> remove(Project project) => coordination.runExclusive(() async {
    final current = await _projects.record(project.id).get(_database);
    if (current == null) {
      throw const RevisionConflict();
    }
    final live = Project.fromJson(current);
    if (live.revision != project.revision) {
      throw const RevisionConflict();
    }
    await checkpoints.saveRequired(project, deleted: true);
    try {
      await _database.transaction((txn) async {
        final value = await _projects.record(project.id).get(txn);
        if (value == null ||
            Project.fromJson(value).revision != project.revision) {
          throw const RevisionConflict();
        }
        await _projects.record(project.id).delete(txn);
      });
    } catch (_) {
      // The record is still there, so the copies must describe it again. If
      // this write fails too, the stale state is reported, not hidden.
      await checkpoints.save(live);
      rethrow;
    }
  });

  /// Projects whose recovery copy does not match the saved data. Durable.
  Future<Set<String>> staleRecoveryPoints() async =>
      checkpoints.staleAgainst(await list());

  /// Rewrites one project's recovery copy from the committed record. Throws
  /// if the copy still cannot be written.
  Future<void> refreshRecoveryPoint(String projectId) =>
      coordination.runExclusive(() async {
        final project = await metadata(projectId);
        await checkpoints.saveRequired(project);
      });

  /// Explicit recovery only: the previous database is never overwritten/deleted.
  static Future<LocalProjectRepository> recover(Directory directory) async {
    final files = SafeFiles(Directory(await directory.resolveSymbolicLinks()));
    return StorageCoordination(files).runExclusive(() async {
      final snapshots = await RecoveryCheckpoints(files).read();
      require(
        snapshots.isNotEmpty,
        'لا توجد نقاط استرداد سليمة. احتفظ بمساحة التطبيق واستعد نسختك الخارجية أو اطلب استرداداً متخصصاً.',
      );
      final name = 'recovered-${newId()}.db';
      final database = await databaseFactoryIo.openDatabase(
        await files.checkedPath(name),
      );
      try {
        await database.transaction((txn) async {
          for (final project in snapshots) {
            await _projects.record(project.id).put(txn, project.toJson());
          }
        });
        final pointer = File(await files.checkedPath('active-${newId()}.tmp'));
        await pointer.writeAsString(jsonEncode({'name': name}), flush: true);
        await pointer.rename(await files.checkedPath('active-store.json'));
        return LocalProjectRepository._(database, files);
      } catch (_) {
        await database.close();
        rethrow;
      }
    });
  }

  @override
  Future<void> close() => _database.close();
}
