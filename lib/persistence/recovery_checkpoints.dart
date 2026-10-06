import 'dart:convert';
import 'dart:io';
import '../application/ids.dart';
import '../domain/project.dart';
import '../domain/validation.dart';
import 'safe_files.dart';

/// A second local copy of committed metadata, not a complete/external backup.
class RecoveryCheckpoints {
  RecoveryCheckpoints(this.files);
  final SafeFiles files;
  Future<void> _tail = Future.value();
  String? warning;
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
        warning = null;
      } finally {
        if (await temporary.exists()) {
          await temporary.delete();
        }
      }
    });
    // Main DB commit is already durable. Never tell a caller that it failed
    // just because the redundant recovery snapshot could not be written.
    _tail = work.catchError((Object error) {
      warning =
          'حُفظ المشروع، لكن تعذر تحديث نقطة الاسترداد المحلية. تحقق من المساحة واحفظ نسخة احتياطية.';
    });
    return _tail;
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
