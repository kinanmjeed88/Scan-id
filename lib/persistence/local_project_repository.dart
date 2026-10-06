import 'dart:io';

import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';

import '../application/contracts.dart';
import '../domain/project.dart';
import '../domain/validation.dart';
import 'safe_files.dart';

class LocalProjectRepository implements ProjectRepository {
  LocalProjectRepository._(this._database, this.files);
  final Database _database;
  final SafeFiles files;
  static final _projects = stringMapStoreFactory.store('projects');

  static Future<LocalProjectRepository> open(Directory directory) async {
    await directory.create(recursive: true);
    final root = Directory(await directory.resolveSymbolicLinks());
    final files = SafeFiles(root);
    final path = await files.checkedPath('projects.db');
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
    validId(id);
    final value = await _projects.record(id).get(_database);
    if (value == null) {
      throw const StorageException('المشروع غير موجود.');
    }
    final project = Project.fromJson(value);
    require(project.id == id, 'معرّف سجل المشروع غير متطابق.');
    await _checkAssets(project);
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
    return _database.transaction((txn) async {
      if (await _projects.record(project.id).exists(txn)) {
        throw const RevisionConflict();
      }
      await _projects.record(project.id).put(txn, project.toJson());
      return project;
    });
  }

  @override
  Future<Project> save(Project project) async {
    await _checkAssets(project);
    return _database.transaction((txn) async {
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
      final now = DateTime.now().toUtc();
      final saved = project.copyWith(
        revision: old.revision + 1,
        updatedAt: now.isBefore(old.updatedAt) ? old.updatedAt : now,
      );
      await _projects.record(project.id).put(txn, saved.toJson());
      return saved;
    });
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
    // Intentional metadata-only deletion. Never recursively delete a path
    // derived from a project file; GC and backup retention need a later design.
  }

  @override
  Future<void> close() => _database.close();
}
