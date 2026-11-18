import 'dart:io';
import 'package:flutter/services.dart';
import 'camera_capture.dart';
import 'contracts.dart';

class NativeCamera implements CameraPort {
  static const _channel = MethodChannel('iq.scanid/camera');
  PendingCapture? _photo(Map<Object?, Object?>? data) => data == null
      ? null
      : PendingCapture(
          id: data['id']! as String,
          projectId: data['projectId']! as String,
          file: File(data['path']! as String),
        );
  @override
  Future<PendingCapture?> capture(String projectId) async {
    try {
      return _photo(
        await _channel.invokeMapMethod<Object?, Object?>('capture', {
          'projectId': projectId,
        }),
      );
    } on MissingPluginException {
      // Engine reconfigured while the camera was open. Recover the JPEG only
      // when the camera already wrote it; an empty journal must stay so a
      // still-open camera can finish without Dart deleting the file.
      return _journalIfUsable();
    } on PlatformException catch (error) {
      if (error.code == 'interrupted') {
        return _journalIfUsable();
      }
      throw StorageException(
        error.code == 'pending'
            ? 'يوجد التقاط معلق؛ استرده أو احذفه صراحة قبل التقاط صورة جديدة.'
            : 'تعذر فتح الكاميرا. تحقق من توفر تطبيق كاميرا والمساحة، واضبط دقة JPEG حتى 32 مليون بكسل، وبحد 20 MiB.',
      );
    }
  }

  Future<PendingCapture?> _journalIfUsable() async {
    final photo = await pending();
    if (photo == null || !await isUsableCapture(photo.file)) return null;
    return photo;
  }

  @override
  Future<PendingCapture?> pending() async {
    try {
      return _photo(
        await _channel.invokeMapMethod<Object?, Object?>('pending'),
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> discard(String id) async {
    await _channel.invokeMethod<void>('discard', {'id': id});
  }
}
