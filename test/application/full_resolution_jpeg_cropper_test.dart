import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/full_resolution_jpeg_cropper.dart';
import 'package:scan_id/domain/validation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('iq.scanid/large_jpeg');
  const cropper = PlatformFullResolutionJpegCropper(channel: channel);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('sends bounded normalized full-resolution crop request unchanged', () async {
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          captured = call;
          return Uint8List.fromList([137, 80, 78, 71]);
        });

    final result = await cropper.cropJpegRegion(
      source: Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]),
      sourceWidth: 5000,
      sourceHeight: 4000,
      orientation: 6,
      left: .1,
      top: .2,
      right: .8,
      bottom: .9,
    );

    expect(result, [137, 80, 78, 71]);
    expect(captured!.method, 'cropJpegRegion');
    final arguments = captured!.arguments! as Map<Object?, Object?>;
    expect(arguments['bytes'], [0xff, 0xd8, 0xff, 0xd9]);
    expect(arguments['sourceWidth'], 5000);
    expect(arguments['sourceHeight'], 4000);
    expect(arguments['orientation'], 6);
    expect(arguments['left'], .1);
    expect(arguments['top'], .2);
    expect(arguments['right'], .8);
    expect(arguments['bottom'], .9);
    expect(arguments['maxPixels'], 16000000);
  });

  test('rejects malformed bounds before invoking native code', () async {
    var called = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          called = true;
          return Uint8List(1);
        });

    await expectLater(
      cropper.cropJpegRegion(
        source: Uint8List.fromList([1]),
        sourceWidth: 5000,
        sourceHeight: 4000,
        orientation: 1,
        left: .8,
        top: .1,
        right: .2,
        bottom: .9,
      ),
      throwsA(isA<ValidationException>()),
    );
    expect(called, isFalse);
  });

  test('makes native crop budget rejection actionable', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'crop_too_large');
        });

    await expectLater(
      cropper.cropJpegRegion(
        source: Uint8List.fromList([1]),
        sourceWidth: 5000,
        sourceHeight: 4000,
        orientation: 1,
        left: 0,
        top: 0,
        right: 1,
        bottom: 1,
      ),
      throwsA(
        isA<ValidationException>().having(
          (error) => error.message,
          'message',
          contains('16 مليون'),
        ),
      ),
    );
  });
}
