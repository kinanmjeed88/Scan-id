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
    } on PlatformException catch (error) {
      throw StorageException(
        error.code == 'pending'
            ? 'يوجد التقاط معلق؛ استرده أو احذفه صراحة قبل التقاط صورة جديدة.'
            : 'تعذر فتح الكاميرا. تحقق من توفر تطبيق كاميرا والمساحة، واضبط دقة الالتقاط حتى 16 مليون بكسل.',
      );
    }
  }

  @override
  Future<PendingCapture?> pending() async =>
      _photo(await _channel.invokeMapMethod<Object?, Object?>('pending'));
  @override
  Future<void> discard(String id) async {
    await _channel.invokeMethod<void>('discard', {'id': id});
  }
}
