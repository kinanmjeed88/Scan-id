import 'dart:convert';
import 'dart:io';
import '../application/contracts.dart';
import '../application/ids.dart';
import '../domain/project.dart';
import '../domain/validation.dart';
import 'safe_files.dart';

/// A second local copy of committed metadata, not a complete/external backup.
///
/// Role: the database commit is the source of truth. After each commit a copy
/// is written, and [LocalProjectRepository.recover] rebuilds from these copies
/// only when the database itself is lost. A failed copy write never turns the
/// commit it follows into a failure, because the new data is already durable.
/// The failure is kept, reported, and repaired explicitly with [saveRequired].
class RecoveryCheckpoints {
  RecoveryCheckpoints(this.files);
  final SafeFiles files;
  Future<void> _tail = Future.value();

  /// Copy writes that failed and have not been followed by a successful write
  /// of the same project. Session-only; the durable view is [staleAgainst].
  final _failed = <String, Object>{};

  /// Non-null while at least one copy written this session is outdated.
  String? get warning => _failed.isEmpty
      ? null
      : 'حُفظت البيانات، لكن تعذر تحديث نقطة الاسترداد المحلية. تحقق من المساحة والصلاحيات، ثم حدّث نقطة الاسترداد.';

  /// Whether a copy write of [projectId] failed in this session and has not
  /// been retried successfully since.
  bool isStale(String projectId) => _failed.containsKey(projectId);

  Future<void> save(Project project, {bool deleted = false}) {
    final work = _tail.then((_) async {
      final temporary = File(
        await files.checkedPath('checkpoints/${project.id}-${newId()}.tmp'),
      );
      try {
        await temporary.parent.create(recursive: true);
        await temporary.writeAsString(
          jsonEncode({
            'version': 1,
            'deleted': deleted,
            'project': project.toJson(),
          }),
          flush: true,
        );
        await temporary.rename(
          await files.checkedPath('checkpoints/${project.id}.json'),
        );
        _failed.remove(project.id);
      } finally {
        if (await temporary.exists()) {
          await temporary.delete();
        }
      }
    });
    // The failure is recorded with its cause, not dropped. It is reported
    // through [warning] and [isStale]; the caller's commit is not undone.
    _tail = work.catchError((Object error) {
      _failed[project.id] = error;
    });
    return _tail;
  }

  /// Like [save], but a copy that could not be written is an error for the
  /// caller. Used where the copy is the only thing being changed (repair), and
  /// where a removal must not be reported as done while the copy still holds
  /// the project.
  Future<void> saveRequired(Project project, {bool deleted = false}) async {
    await save(project, deleted: deleted);
    final failure = _failed[project.id];
    if (failure != null) {
      throw StorageException(
        'تعذر تحديث نقطة الاسترداد لهذا المشروع. تحقق من الصلاحيات والمساحة المتاحة ثم أعد المحاولة. (${failure.runtimeType})',
      );
    }
  }

  /// Projects whose copy is missing, unreadable, marked deleted, or older than
  /// the saved revision. Read from the copies themselves, so the answer
  /// survives a restart; [isStale] does not.
  Future<Set<String>> staleAgainst(Iterable<Project> live) async {
    final stale = <String>{};
    for (final project in live) {
      final revision = await _copyRevision(project.id);
      if (revision == null ||
          revision.deleted ||
          revision.revision != project.revision) {
        stale.add(project.id);
      }
    }
    return stale;
  }

  /// Revision and deleted-flag of one copy, or null when the copy is missing
  /// or cannot be read. An unreadable copy counts as outdated: repairing it
  /// from the database is always safe, since the database is the truth.
  Future<({int revision, bool deleted})?> _copyRevision(String projectId) async {
    final path = await files.checkedPath('checkpoints/$projectId.json');
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    try {
      final record = objectMap(jsonDecode(await File(path).readAsString()));
      final project = Project.fromJson(record['project']);
      return (
        revision: project.revision,
        deleted: boolean(record['deleted'], 'deleted'),
      );
    } on FormatException {
      return null;
    } on ValidationException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  Future<List<Project>> read() async {
    final directory = Directory(await files.checkedPath('checkpoints'));
    if (!await directory.exists()) {
      return [];
    }
    final result = <Project>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) {
        continue;
      }
      require(
        await entity.length() <= 16 * 1024 * 1024,
        'نقطة الاسترداد كبيرة جداً.',
      );
      final record = objectMap(jsonDecode(await entity.readAsString()));
      require(record['version'] == 1, 'إصدار نقطة الاسترداد غير مدعوم.');
      final deleted = boolean(record['deleted'], 'deleted');
      final project = Project.fromJson(record['project']);
      require(
        entity.uri.pathSegments.last == '${project.id}.json',
        'هوية نقطة الاسترداد غير متطابقة.',
      );
      if (!deleted) {
        result.add(project);
      }
    }
    return result;
  }
}
