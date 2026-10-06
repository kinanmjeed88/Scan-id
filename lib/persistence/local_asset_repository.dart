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

  @override
  Future<ReplacementFiles> replaceImage(
    String projectId,
    String assetId,
    Uint8List bytes,
  ) {
    validId(projectId);
    validId(assetId);
    final root = files.root.path;
    return Isolate.run(() => _replace(root, projectId, assetId, bytes));
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
  final staging = Directory(await _stagingDirectory(files, id));
  try {
    await _writePrepared(staging.path, bytes, prepared);
    await _publish(files, staging, relative);
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

/// Replacements live under the asset prefix the project already owns, so the
/// previous files stay byte-identical and the layout keeps its asset id.
Future<ReplacementFiles> _replace(
  String root,
  String projectId,
  String assetId,
  Uint8List bytes,
) async {
  final prepared = prepareImage(bytes);
  final id = newId();
  final files = SafeFiles(Directory(root));
  final relative = 'projects/$projectId/assets/$assetId/replacements/$id';
  final staging = Directory(await _stagingDirectory(files, id));
  try {
    await _writePrepared(staging.path, bytes, prepared);
    await _publish(files, staging, relative);
    return ReplacementFiles(
      revision: id,
      originalPath: '$relative/original.${prepared.extension}',
      workingPath: '$relative/working.png',
      thumbnailPath: '$relative/thumb.jpg',
      width: prepared.width,
      height: prepared.height,
    );
  } finally {
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }
  }
}

Future<String> _stagingDirectory(SafeFiles files, String id) async {
  final path = await files.checkedPath('staging/$id');
  final staging = Directory(path);
  require(!await staging.exists(), 'تعارض في مجلد الاستيراد.');
  await staging.create(recursive: true);
  return path;
}

Future<void> _writePrepared(
  String stagingPath,
  Uint8List original,
  PreparedImage prepared,
) async {
  // EXIF remains in the original, as promised. No destructive sanitization.
  await File(
    '$stagingPath/original.${prepared.extension}',
  ).writeAsBytes(original, flush: true);
  await File(
    '$stagingPath/working.png',
  ).writeAsBytes(prepared.working, flush: true);
  await File(
    '$stagingPath/thumb.jpg',
  ).writeAsBytes(prepared.thumbnail, flush: true);
}

Future<void> _publish(
  SafeFiles files,
  Directory staging,
  String relative,
) async {
  final destination = await files.checkedPath(relative);
  require(!await Directory(destination).exists(), 'تعارض في معرّف الصورة.');
  await Directory(destination).parent.create(recursive: true);
  await staging.rename(destination);
}
