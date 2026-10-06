import 'dart:io';

import 'package:path/path.dart' as p;

import '../application/contracts.dart';
import '../domain/validation.dart';

/// The root is canonicalized once by the storage composition root.
/// Relative paths are checked both lexically and for existing symbolic links.
class SafeFiles {
  const SafeFiles(this.root);
  final Directory root;

  Future<String> checkedPath(String relative) async {
    validAssetPath(relative);
    var path = root.path;
    for (final component in relative.split('/')) {
      path = p.join(path, component);
      if (await FileSystemEntity.type(path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const StorageException('تم رفض رابط رمزي داخل مساحة المشروع.');
      }
    }
    if (!p.isWithin(root.path, path)) {
      throw const StorageException('تم رفض مسار خارج مساحة التطبيق.');
    }
    return path;
  }

  Future<File> existingFile(String relative) async {
    final path = await checkedPath(relative);
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const StorageException(
        'أحد ملفات المشروع مفقود. لم يتم تعديل بياناته.',
      );
    }
    return File(path);
  }
}
