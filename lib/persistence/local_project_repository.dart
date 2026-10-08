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

class LocalProjectRepository implements ProjectRepository {
  LocalProjectRepository._(this._database, this.files)
    : checkpoints = RecoveryCheckpoints(files);
  final RecoveryCheckpoints checkpoints;
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
      ]) {
        await files.existingFile(path);
      }
    }
  }

  @override
  Future<Project> create(Project project) async {
    require(project.revision == 0, 'المشروع الجديد يجب أن يبدأ من مراجعة صفر.');
    await _checkAssets(project);
    final saved = await _database.transaction((txn) async {
      if (await _projects.record(project.id).exists(txn)) {
        throw const RevisionConflict();
      }
      await _projects.record(project.id).put(txn, project.toJson());
      return project;
    });
    await checkpoints.save(saved);
    return saved;
  }

  @override
  Future<Project> save(Project project) async {
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
  }

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
    final target = await files.checkedPath('migration-snapshots/$projectId.json');
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

  @override
  Future<void> remove(Project project) async {
    await _database.transaction((txn) async {
      final value = await _projects.record(project.id).get(txn);
      if (value == null ||
          Project.fromJson(value).revision != project.revision) {
        throw const RevisionConflict();
      }
      await _projects.record(project.id).delete(txn);
    });
    await checkpoints.save(project, deleted: true);
    // Intentional metadata-only deletion. Never recursively delete a path
    // derived from a project file; GC and backup retention need a later design.
  }

  /// Explicit recovery only: the previous database is never overwritten/deleted.
  static Future<LocalProjectRepository> recover(Directory directory) async {
    final files = SafeFiles(Directory(await directory.resolveSymbolicLinks()));
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
  }

  @override
  Future<void> close() => _database.close();
}
