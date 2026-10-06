import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

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
