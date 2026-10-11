import 'dart:io';

import 'package:path/path.dart' as p;

import '../application/contracts.dart';
import '../domain/project.dart';
import '../domain/validation.dart';
import 'recovery_checkpoints.dart';
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
    final relative = '$_projects/$projectId';
    require(
      !_under(relative, await _recoveryReferences()),
      _keptByRecovery,
    );
    await _deleteTree(await files.checkedPath(relative));
  }

  @override
  Future<OrphanFiles> findOrphans(List<Project> projects) async {
    final referenced = _referencesOf(projects);
    // Copies that are not live but can still be restored or rolled back. A
    // folder named here is historical, not garbage.
    final recovery = await _recoveryReferences();
    final knownProjects = {for (final project in projects) project.id};
    // Files being written right now are not orphans. An asset directory exists
    // briefly before its project record is committed.
    final cutoff = clock().toUtc().subtract(_grace);
    final orphans = <String>[];
    final retained = <String>[];
    var bytes = 0;
    final projectsPath = await files.checkedPath(_projects);
    // Known project directories are always inspected: a stale orphan inside a
    // recently touched project must not be hidden by the grace window.
    await for (final project in _directories(projectsPath)) {
      final id = p.basename(project.path);
      final projectRelative = '$_projects/$id';
      if (!knownProjects.contains(id)) {
        if ((await _modified(project.path)).isAfter(cutoff)) {
          continue;
        }
        switch (_useOf(projectRelative, referenced, recovery)) {
          case _Use.live:
            // A folder of a project the list does not know but a live record
            // names cannot be classified safely; leave it alone.
            break;
          case _Use.recovery:
            retained.add(projectRelative);
            break;
          case _Use.unused:
            orphans.add(projectRelative);
            bytes += await _size(project.path);
        }
        continue;
      }
      await for (final asset in _directories(
        p.join(project.path, 'assets'),
        cutoff,
      )) {
        final relative = '$projectRelative/assets/${p.basename(asset.path)}';
        switch (_useOf(relative, referenced, recovery)) {
          case _Use.recovery:
            retained.add(relative);
            continue;
          case _Use.unused:
            orphans.add(relative);
            bytes += await _size(asset.path);
            continue;
          case _Use.live:
            break;
        }
        // Revisions live one level below the asset: edits/<id> for crops and
        // replacements/<id> for substituted sources.
        await for (final group in _directories(asset.path)) {
          final groupRelative = '$relative/${p.basename(group.path)}';
          await for (final revision in _directories(group.path, cutoff)) {
            final revisionRelative =
                '$groupRelative/${p.basename(revision.path)}';
            switch (_useOf(revisionRelative, referenced, recovery)) {
              case _Use.recovery:
                retained.add(revisionRelative);
                break;
              case _Use.unused:
                orphans.add(revisionRelative);
                bytes += await _size(revision.path);
              case _Use.live:
                break;
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
    return OrphanFiles(orphans, bytes, retained: retained);
  }

  /// Removes exactly the given paths. A path that a recovery copy or snapshot
  /// still names is refused, not deleted: the caller reports why, and the path
  /// is removed once that copy has been rewritten.
  @override
  Future<int> deleteFiles(Iterable<String> relativePaths) async {
    final recovery = await _recoveryReferences();
    var removed = 0;
    for (final relative in relativePaths) {
      require(!_under(relative, recovery), _keptByRecovery);
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

  static const _keptByRecovery =
      'نقطة استرداد أو نسخة ترقية ما زالت تشير إلى هذه الملفات، فتُحفظ حتى تُحدَّث.';

  /// Every path a saved project names, including the older revisions that
  /// recognition records still refer to.
  Set<String> _referencesOf(Iterable<Project> projects) => {
    for (final project in projects) ...[
      for (final asset in project.assets) ...[
        asset.originalPath,
        asset.workingPath,
        asset.thumbnailPath,
        asset.processingInputPath,
      ],
      // Recognition references may name an older revision after a later
      // crop/replacement. Keep that file alive while any document record,
      // including a dismissed tombstone, still refers to it.
      for (final record in project.documents)
        for (final side in record.sides) ...[
          side.processedAsset.workingPath,
          side.processedAsset.thumbnailPath,
        ],
    ],
  };

  /// Paths named by the recovery copies of live projects and by the pre-upgrade
  /// snapshots. Deleted-project checkpoints are not read by [read] and so name
  /// nothing. The scan is deliberately broad: any `projects/` string in a
  /// snapshot protects that path, so an unknown field can only keep data.
  Future<Set<String>> _recoveryReferences() async {
    final copies = await RecoveryCheckpoints(files).read();
    final paths = _referencesOf(copies);
    final snapshots = Directory(
      await files.checkedPath('migration-snapshots'),
    );
    if (await snapshots.exists()) {
      final pattern = RegExp(r'projects/[^"\\\s]+');
      await for (final entity in snapshots.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.json')) {
          continue;
        }
        for (final match in pattern.allMatches(await entity.readAsString())) {
          paths.add(match.group(0)!);
        }
      }
    }
    return paths;
  }

  /// Whether [relative] is named by a path in [paths]: as itself or as a
  /// directory that contains the named path.
  bool _under(String relative, Set<String> paths) {
    final prefix = '$relative/';
    return paths.any((path) => path == relative || path.startsWith(prefix));
  }

  _Use _useOf(String relative, Set<String> live, Set<String> recovery) {
    if (_under(relative, live)) {
      return _Use.live;
    }
    if (_under(relative, recovery)) {
      return _Use.recovery;
    }
    return _Use.unused;
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

  /// Modification time that decides whether [path] counts as stale.
  ///
  /// A directory timestamp only changes when an entry is created or removed, so
  /// rewriting a file in place would make live work look untouched. The newest
  /// file in the tree decides instead; a tree without files falls back to its
  /// own timestamp, so an empty directory is never treated as ancient. Links
  /// are never followed.
  Future<DateTime> _modified(String path) async {
    final newest = await _newestFile(path);
    if (newest != null) {
      return newest;
    }
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
    return (await FileStat.stat(path)).modified.toUtc();
  }

  Future<DateTime?> _newestFile(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.file) {
      return (await FileStat.stat(path)).modified.toUtc();
    }
    if (type != FileSystemEntityType.directory) {
      return null;
    }
    DateTime? newest;
    await for (final entity in Directory(path).list(followLinks: false)) {
      final child = await _newestFile(entity.path);
      if (child != null && (newest == null || child.isAfter(newest))) {
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

/// How a folder or file relates to the saved state.
enum _Use {
  /// Named by a saved project: current data, never touched.
  live,

  /// Not in any saved project, but named by a recovery copy or snapshot.
  recovery,

  /// Named by nothing: safe to remove after the grace window.
  unused,
}
