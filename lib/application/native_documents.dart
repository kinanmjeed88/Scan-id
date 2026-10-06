import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'contracts.dart';
import 'project_service.dart';

const _documents = MethodChannel('iq.scanid/local_documents');
Future<bool> saveDocument(File source, String mime) async {
  final name = source.uri.pathSegments.last;
  if (Platform.isAndroid) {
    return await _documents.invokeMethod<bool>('save', {
          'source': source.path,
          'name': name,
          'mime': mime,
        }) ??
        false;
  }
  final location = await getSaveLocation(suggestedName: name);
  if (location == null) return false;
  await XFile(source.path).saveTo(location.path);
  return true;
}

Future<List<ImportSource>> pickAndroidImages() async {
  final records =
      await _documents.invokeListMethod<Object?>('open', {
        'mime': 'image/*',
        'multiple': true,
        'maxBytes': 20 * 1024 * 1024,
      }) ??
      [];
  return records.map((value) {
    final record = Map<String, Object?>.from(value! as Map);
    final error = record['error'] as String?;
    final file = error == null ? File(record['path']! as String) : null;
    return ImportSource(
      record['name']! as String,
      () => file?.openRead() ?? Stream.error(StorageException(error!)),
      cleanup: file == null ? null : () => removePickedFile(file),
    );
  }).toList();
}

Future<File?> pickAndroidBackup() async {
  final records =
      await _documents.invokeListMethod<Object?>('open', {
        'mime': 'application/octet-stream',
        'multiple': false,
        'maxBytes': 64 * 1024 * 1024 * 1024 + 16 * 1024 * 1024 + 64,
      }) ??
      [];
  if (records.isEmpty) {
    return null;
  }
  final record = Map<String, Object?>.from(records.single! as Map);
  if (record['error'] != null) {
    throw StorageException(record['error']! as String);
  }
  return File(record['path']! as String);
}

Future<void> removePickedFile(File file) async {
  // Only callers with an app-created picker cache file use this operation.
  if (await file.exists()) {
    await file.delete();
  }
  if (await file.parent.exists() && await file.parent.list().isEmpty) {
    await file.parent.delete();
  }
}
