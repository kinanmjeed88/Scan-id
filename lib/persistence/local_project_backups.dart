import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import '../application/contracts.dart';
import '../application/ids.dart';
import '../application/project_backups.dart';
import '../domain/project.dart';
import '../domain/validation.dart';
import 'safe_files.dart';

// Stored (not compressed) payloads: streaming restores cannot be zip bombs.
// The manifest is bounded; hashes detect corruption, not authenticity/encryption.
const _magic = 'SCANID-BACKUP-1\n';
const _maxManifest = 16 * 1024 * 1024;
const _maxFile = 128 * 1024 * 1024;
const _maxTotal = 64 * 1024 * 1024 * 1024;

class LocalProjectBackups implements ProjectBackups {
  const LocalProjectBackups(this.projects, this.files);
  final ProjectRepository projects;
  final SafeFiles files;

  @override
  Future<File> create(Project project, Directory temporary) async {
    final latest = await projects.get(project.id);
    require(
      latest.revision == project.revision,
      'تغير المشروع؛ أعد فتحه قبل النسخ الاحتياطي.',
    );
    final root = files.root.path;
    final folder = await Directory(
      '${temporary.path}/scan-backup-${newId()}',
    ).create(recursive: true);
    try {
      final output = '${folder.path}/project.scanid';
      await Isolate.run(() => _writeBackup(latest, root, output));
      return File(output);
    } catch (_) {
      await folder.delete(recursive: true);
      rethrow;
    }
  }

  @override
  Future<Project> restore(File source) async {
    final root = files.root.path;
    final input = source.path;
    // A new identity and staging directory are chosen locally, never by a backup.
    final id = newId();
    final restored = await Isolate.run(() => _readBackup(input, root, id));
    // Only publish metadata after all bytes, hashes and references are durable.
    // On DB failure, retain the verified new folder for recovery, never delete
    // files that might already have been committed when the OS reported an error.
    return projects.create(restored);
  }
}

Set<String> _references(Project p) => {
  for (final a in p.assets) ...[a.originalPath, a.workingPath, a.thumbnailPath],
};

Future<void> _writeBackup(Project project, String root, String output) async {
  final safe = SafeFiles(Directory(root));
  final base = Directory(await safe.checkedPath('projects/${project.id}'));
  final records = <Map<String, Object?>>[];
  var total = 0;
  if (await base.exists()) {
    await for (final entity in base.list(recursive: true, followLinks: false)) {
      require(entity is! Link, 'لا يمكن نسخ مشروع يحتوي روابط رمزية.');
      if (entity is! File) {
        continue;
      }
      final relative = path
          .relative(entity.path, from: root)
          .split(path.separator)
          .join('/');
      _backupPath(relative, project.id);
      final file = await safe.existingFile(relative);
      final length = await file.length();
      require(
        length > 0 && length <= _maxFile,
        'أحد ملفات النسخة فارغ أو يتجاوز 128 MiB.',
      );
      total += length;
      require(
        total <= _maxTotal && records.length < 10000,
        'النسخة تتجاوز حد 64 GiB أو عشرة آلاف ملف.',
      );
      records.add({
        'path': relative,
        'size': length,
        'sha256': (await sha256.bind(file.openRead()).first).toString(),
      });
    }
  }
  records.sort(
    (a, b) => (a['path']! as String).compareTo(b['path']! as String),
  );
  final names = records.map((r) => r['path']).toSet();
  require(
    records.map((r) => (r['path']! as String).toLowerCase()).toSet().length ==
        records.length,
    'أسماء الملفات تتصادم على Windows.',
  );
  require(
    _references(project).every(names.contains),
    'النسخة غير مكتملة؛ أحد ملفات المشروع مفقود.',
  );
  final manifest = utf8.encode(
    jsonEncode({'format': 1, 'project': project.toJson(), 'files': records}),
  );
  require(manifest.length <= _maxManifest, 'بيانات النسخة كبيرة جداً.');
  final writer = await File(output).open(mode: FileMode.write);
  try {
    await writer.writeFrom(utf8.encode(_magic));
    await writer.writeFrom(
      (ByteData(4)..setUint32(0, manifest.length)).buffer.asUint8List(),
    );
    await writer.writeFrom(manifest);
    for (final record in records) {
      final source = await safe.existingFile(record['path']! as String);
      final digest = _DigestSink();
      final hashing = sha256.startChunkedConversion(digest);
      var written = 0;
      await for (final chunk in source.openRead()) {
        written += chunk.length;
        require(written <= (record['size']! as int), 'تغير ملف أثناء النسخ.');
        hashing.add(chunk);
        await writer.writeFrom(chunk);
      }
      hashing.close();
      require(
        written == record['size'] &&
            digest.value.toString() == record['sha256'],
        'تغير ملف أثناء النسخ؛ أعد المحاولة.',
      );
    }
    await writer.flush();
  } finally {
    await writer.close();
  }
}

Future<Uint8List> _exact(RandomAccessFile file, int length) async {
  final data = await file.read(length);
  require(data.length == length, 'ملف النسخة مبتور.');
  return data;
}

Future<Project> _readBackup(String input, String root, String id) async {
  final reader = await File(input).open();
  final safe = SafeFiles(Directory(root));
  Directory? staging;
  try {
    require(
      await reader.length() <= _maxTotal + _maxManifest + 64,
      'ملف النسخة كبير جداً.',
    );
    require(
      utf8.decode(await _exact(reader, utf8.encode(_magic).length)) == _magic,
      'صيغة النسخة غير مدعومة.',
    );
    final size = ByteData.sublistView(await _exact(reader, 4)).getUint32(0);
    require(size > 0 && size <= _maxManifest, 'حجم بيانات النسخة غير صالح.');
    final manifest = objectMap(
      jsonDecode(utf8.decode(await _exact(reader, size))),
    );
    require(manifest['format'] == 1, 'إصدار النسخة غير مدعوم.');
    final original = Project.fromJson(manifest['project']);
    final records = objectList(manifest['files']).map(objectMap).toList();
    require(records.length <= 10000, 'عدد ملفات النسخة كبير جداً.');
    final names = <String>{};
    final foldedNames = <String>{};
    var total = 0;
    for (final record in records) {
      final name = text(record['path'], 'path');
      _backupPath(name, original.id);
      require(
        (name.startsWith('projects/${original.id}/assets/') ||
                name.startsWith('projects/${original.id}/processed/')) &&
            names.add(name) &&
            foldedNames.add(name.toLowerCase()),
        'مسار مكرر أو خارج ملكية المشروع.',
      );
      final length = integer(record['size'], 'size');
      require(length > 0 && length <= _maxFile, 'حجم صورة النسخة غير صالح.');
      total += length;
      require(total <= _maxTotal, 'حجم محتوى النسخة كبير جداً.');
      require(
        RegExp(r'^[0-9a-f]{64}$').hasMatch(text(record['sha256'], 'sha256')),
        'بصمة النسخة غير صالحة.',
      );
    }
    require(
      _references(original).every(names.contains),
      'النسخة لا تحتوي جميع الصور المشار إليها.',
    );
    require(
      await reader.length() == await reader.position() + total,
      'ملف النسخة مبتور أو يحتوي بيانات إضافية.',
    );
    // Validate the rewritten model before writing any payload.
    final json = original.toJson();
    json['id'] = id;
    json['revision'] = 0;
    json['assets'] = [
      for (final a in original.assets)
        {
          ...a.toJson(),
          'originalPath': _remap(a.originalPath, original.id, id),
          'workingPath': _remap(a.workingPath, original.id, id),
          'thumbnailPath': _remap(a.thumbnailPath, original.id, id),
        },
    ];
    // v5: remap the processed-asset paths inside documents the same way, so a
    // restored project's processed references resolve to the new project folder
    // (a missing processed file still opens; only pixel ops fail safe).
    json['documents'] = [
      for (final d in original.documents)
        {
          ...d.toJson(),
          'sides': [
            for (final s in d.sides)
              {
                ...s.toJson(),
                'processedAsset': {
                  ...s.processedAsset.toJson(),
                  'workingPath': _remap(
                    s.processedAsset.workingPath,
                    original.id,
                    id,
                  ),
                  'thumbnailPath': _remap(
                    s.processedAsset.thumbnailPath,
                    original.id,
                    id,
                  ),
                },
              },
          ],
        },
    ];
    final restored = Project.fromJson(json);
    staging = Directory(await safe.checkedPath('staging/restore-$id'));
    require(!await staging.exists(), 'تعارض في مساحة الاستعادة.');
    await staging.create(recursive: true);
    final stagedFiles = SafeFiles(staging);
    for (final record in records) {
      final name = record['path']! as String;
      final relative = name.substring('projects/${original.id}/'.length);
      final file = File(await stagedFiles.checkedPath(relative));
      await file.parent.create(recursive: true);
      final writer = await file.open(mode: FileMode.write);
      final digest = _DigestSink();
      final hashing = sha256.startChunkedConversion(digest);
      try {
        var remaining = record['size']! as int;
        while (remaining > 0) {
          final bytes = await _exact(
            reader,
            remaining > 65536 ? 65536 : remaining,
          );
          hashing.add(bytes);
          await writer.writeFrom(bytes);
          remaining -= bytes.length;
        }
        hashing.close();
        require(
          digest.value.toString() == record['sha256'],
          'فشل تحقق سلامة صورة داخل النسخة.',
        );
        await writer.flush();
      } finally {
        await writer.close();
      }
    }
    final destination = Directory(await safe.checkedPath('projects/$id'));
    require(!await destination.exists(), 'لا يجوز استبدال مشروع موجود.');
    await destination.parent.create(recursive: true);
    await staging.rename(destination.path);
    return restored;
  } finally {
    await reader.close();
    if (staging != null && await staging.exists()) {
      await staging.delete(recursive: true);
    }
  }
}

void _backupPath(String name, String projectId) {
  validAssetPath(name);
  require(
    name.startsWith('projects/$projectId/assets/') ||
        name.startsWith('projects/$projectId/processed/'),
    'ملف خارج نطاق المشروع.',
  );
  require(
    name
        .split('/')
        .every((part) => !part.endsWith('.') && !isReservedWindowsName(part)),
    'مسار غير محمول أو اسم جهاز Windows محجوز.',
  );
}

String _remap(String value, String oldId, String newId) =>
    'projects/$newId/${value.substring('projects/$oldId/'.length)}';

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
