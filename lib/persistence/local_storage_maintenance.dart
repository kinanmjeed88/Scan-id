import 'dart:io';

import 'package:path/path.dart' as p;

import '../application/contracts.dart';
import '../domain/project.dart';
import '../domain/validation.dart';
import 'safe_files.dart';

/// File maintenance inside the application-owned root.
///
/// Every deletion goes through [SafeFiles.checkedPath], which rejects traversal
/// and any symbolic-link component. Directory walks never follow links, so a
/// link planted inside the root can only ever delete the link itself.
class LocalStorageMaintenance implements StorageMaintenance {
  const LocalStorageMaintenance(this.files, {this.clock = DateTime.now});
  final SafeFiles files;
  final DateTime Function() clock;
  static const _projects = 'projects';
  static const _staging = 'staging';
  static const _minimumAge = Duration(hours: 24);
  static const _grace = Duration(minutes: 10);

  @override
  Future<void> deleteProjectFiles(String projectId) async {
    validId(projectId);
    await _deleteTree(await files.checkedPath('$_projects/$projectId'));
  }

  @override
  Future<OrphanFiles> findOrphans(List<Project> projects) async {
    final referenced = <String>{
      for (final project in projects)
        for (final asset in project.assets) ...[
          asset.originalPath,
          asset.workingPath,
          asset.thumbnailPath,
        ],
    };
    final knownProjects = {for (final project in projects) project.id};
    // Files being written right now are not orphans. An asset directory exists
    // briefly before its project record is committed.
    final cutoff = clock().toUtc().subtract(_grace);
    final orphans = <String>[];
    var bytes = 0;
    final projectsPath = await files.checkedPath(_projects);
    // Known project directories are always inspected: a stale orphan inside a
    // recently touched project must not be hidden by the grace window.
    await for (final project in _directories(projectsPath)) {
      final id = p.basename(project.path);
      if (!knownProjects.contains(id)) {
        if ((await _modified(project.path)).isAfter(cutoff)) {
          continue;
        }
        orphans.add('$_projects/$id');
        bytes += await _size(project.path);
        continue;
      }
      await for (final asset in _directories(
        p.join(project.path, 'assets'),
        cutoff,
      )) {
        final relative = '$_projects/$id/assets/${p.basename(asset.path)}';
        if (!_referenced(relative, referenced)) {
          orphans.add(relative);
          bytes += await _size(asset.path);
          continue;
        }
        // Revisions live one level below the asset: edits/<id> for crops and
        // replacements/<id> for substituted sources.
        await for (final group in _directories(asset.path)) {
          final groupRelative = '$relative/${p.basename(group.path)}';
          await for (final revision in _directories(group.path, cutoff)) {
            final revisionRelative =
                '$groupRelative/${p.basename(revision.path)}';
            if (!_referenced(revisionRelative, referenced)) {
              orphans.add(revisionRelative);
              bytes += await _size(revision.path);
            }
          }
        }
      }
    }
    // A crash while publishing the recovery pointer can leave this temporary
    // file; it is never read, only renamed away.
    final root = Directory(files.root.path);
    await for (final entity in root.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is! File ||
          !name.startsWith('active-') ||
          !name.endsWith('.tmp') ||
          (await entity.stat()).modified.toUtc().isAfter(cutoff)) {
        continue;
      }
      orphans.add(name);
      bytes += await entity.length();
    }
    return OrphanFiles(orphans, bytes);
  }

  @override
  Future<int> deleteFiles(Iterable<String> relativePaths) async {
    var removed = 0;
    for (final relative in relativePaths) {
      final path = await files.checkedPath(relative);
      if (await _deleteTree(path)) {
        removed++;
      }
    }
    return removed;
  }

  @override
  Future<int> pruneStaging({Duration olderThan = _minimumAge}) async {
    final path = await files.checkedPath(_staging);
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return 0;
    }
    final cutoff = clock().toUtc().subtract(olderThan);
    var removed = 0;
    await for (final entity in Directory(path).list(followLinks: false)) {
      if ((await _modified(entity.path)).isAfter(cutoff)) {
        continue;
      }
      if (await _deleteTree(entity.path)) {
        removed++;
      }
    }
    return removed;
  }

  bool _referenced(String directory, Set<String> paths) {
    final prefix = '$directory/';
    return paths.any((path) => path.startsWith(prefix));
  }

  Stream<Directory> _directories(String path, [DateTime? cutoff]) async* {
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return;
    }
    await for (final entity in Directory(path).list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      if (cutoff == null || !(await _modified(entity.path)).isAfter(cutoff)) {
        yield entity;
      }
    }
  }

  /// Newest modification time of the tree rooted at [path].
  ///
  /// A directory's own timestamp only changes when an entry is added or
  /// removed, so a rewrite in place would make live files look stale. Deciding
  /// staleness by the newest entry keeps such work out of the cleanup paths.
  /// Links are reported as epoch: they are unlinked, never followed.
  Future<DateTime> _modified(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound ||
        type == FileSystemEntityType.link) {
      return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
    var newest = (await FileStat.stat(path)).modified.toUtc();
    if (type != FileSystemEntityType.directory) {
      return newest;
    }
    await for (final entity in Directory(path).list(followLinks: false)) {
      final child = await _modified(entity.path);
      if (child.isAfter(newest)) {
        newest = child;
      }
    }
    return newest;
  }

  Future<int> _size(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.file) {
      return File(path).length();
    }
    if (type != FileSystemEntityType.directory) {
      return 0;
    }
    var total = 0;
    await for (final entity in Directory(path).list(followLinks: false)) {
      total += await _size(entity.path);
    }
    return total;
  }

  /// Returns whether anything existed at [path]. Links are unlinked, never
  /// followed; directories are emptied entry by entry and then removed.
  Future<bool> _deleteTree(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return false;
    }
    if (type == FileSystemEntityType.link) {
      await Link(path).delete();
    } else if (type == FileSystemEntityType.file) {
      await File(path).delete();
    } else if (type == FileSystemEntityType.directory) {
      await for (final entity in Directory(path).list(followLinks: false)) {
        await _deleteTree(entity.path);
      }
      await Directory(path).delete();
    } else {
      return false;
    }
    return true;
  }
}
