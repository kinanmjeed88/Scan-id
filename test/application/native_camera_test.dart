import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/native_camera.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('iq.scanid/camera');
  late Directory root;

  void answer(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('native-camera-');
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });

  List<int> jpegBytes() => List<int>.filled(40, 0xFF);

  test('an interrupted capture recovers the journalled photo', () async {
    final file = await File('${root.path}/shot.jpg').writeAsBytes(jpegBytes());
    answer((call) async {
      if (call.method == 'capture') {
        throw PlatformException(code: 'interrupted', message: 'engine');
      }
      expect(call.method, 'pending');
      return {
        'id': 'capture-1',
        'projectId': 'project-1',
        'path': file.path,
      };
    });

    final photo = await NativeCamera().capture('project-1');
    expect(photo, isNotNull);
    expect(photo!.id, 'capture-1');
    expect(photo.file.path, file.path);
  });

  test(
    'a missing plugin after engine reset reads pending instead of hanging',
    () async {
      final file = await File(
        '${root.path}/shot.jpg',
      ).writeAsBytes(jpegBytes());
      var pendingCalls = 0;
      answer((call) async {
        if (call.method == 'capture') {
          throw MissingPluginException('iq.scanid/camera');
        }
        pendingCalls++;
        return {
          'id': 'capture-2',
          'projectId': 'project-1',
          'path': file.path,
        };
      });

      final photo = await NativeCamera().capture('project-1');
      expect(pendingCalls, 1);
      expect(photo?.id, 'capture-2');
    },
  );

  test(
    'an interrupted empty journal is kept so the camera can still write',
    () async {
      final file = await File('${root.path}/empty.jpg').create();
      var discarded = 0;
      answer((call) async {
        if (call.method == 'capture') {
          throw PlatformException(code: 'interrupted', message: 'engine');
        }
        if (call.method == 'discard') {
          discarded++;
          return null;
        }
        return {
          'id': 'capture-empty',
          'projectId': 'project-1',
          'path': file.path,
        };
      });

      expect(await NativeCamera().capture('project-1'), isNull);
      expect(discarded, 0);
      expect(await file.exists(), isTrue);
    },
  );
}
