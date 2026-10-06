import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../application/contracts.dart';
import '../application/ids.dart';
import '../domain/project.dart';
import '../domain/validation.dart';
import '../imaging/prepare_image.dart';
import 'safe_files.dart';

class LocalAssetRepository implements AssetRepository {
  const LocalAssetRepository(this.files);
  final SafeFiles files;

  @override
  Future<File> resolve(String relativePath) => files.existingFile(relativePath);

  @override
  Future<ImageAsset> importImage(
    String projectId,
    String name,
    Uint8List bytes,
  ) {
    validId(projectId);
    validName(name);
    final root = files.root.path;
    // Decode, thumbnail, encoding and file writes are all off the UI isolate.
    return Isolate.run(() => _import(root, projectId, name, bytes));
  }
}

Future<ImageAsset> _import(
  String root,
  String projectId,
  String name,
  Uint8List bytes,
) async {
  final prepared = prepareImage(bytes);
  final id = newId();
  final files = SafeFiles(Directory(root));
  final relative = 'projects/$projectId/assets/$id';
  final stagingPath = await files.checkedPath('staging/$id');
  final staging = Directory(stagingPath);
  require(!await staging.exists(), 'تعارض في مجلد الاستيراد.');
  await staging.create(recursive: true);
  try {
    // EXIF remains in the original, as promised. No destructive sanitization.
    await File(
      '$stagingPath/original.${prepared.extension}',
    ).writeAsBytes(bytes, flush: true);
    await File(
      '$stagingPath/working.png',
    ).writeAsBytes(prepared.working, flush: true);
    await File(
      '$stagingPath/thumb.jpg',
    ).writeAsBytes(prepared.thumbnail, flush: true);
    final destination = await files.checkedPath(relative);
    require(!await Directory(destination).exists(), 'تعارض في معرّف الصورة.');
    await Directory(destination).parent.create(recursive: true);
    await staging.rename(destination);
    return ImageAsset(
      id: id,
      name: name,
      originalPath: '$relative/original.${prepared.extension}',
      workingPath: '$relative/working.png',
      thumbnailPath: '$relative/thumb.jpg',
      width: prepared.width,
      height: prepared.height,
      transforms: const ['exif-orientation'],
    );
  } finally {
    // Clean only the unique staging directory created by this operation.
    // Never remove a committed asset on a database save failure.
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }
  }
}
