import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/application/full_resolution_jpeg_cropper.dart';
import 'package:scan_id/domain/validation.dart';

/// Dart fake-channel contract tests only; they never execute native decoders.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('iq.scanid/large_jpeg');
  const cropper = PlatformFullResolutionJpegCropper(channel: channel);
  final source = Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'Dart fake-channel forwards orientations one through eight unchanged',
    () async {
      final captured = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            captured.add(call);
            return Uint8List.fromList([137, 80, 78, 71]);
          });

      for (var orientation = 1; orientation <= 8; orientation++) {
        final result = await cropper.cropJpegRegion(
          source: source,
          sourceWidth: 5000,
          sourceHeight: 4000,
          orientation: orientation,
          left: .1,
          top: .2,
          right: .8,
          bottom: .9,
        );
        expect(result, [137, 80, 78, 71]);
      }

      expect(captured, hasLength(8));
      for (var index = 0; index < captured.length; index++) {
        final call = captured[index];
        expect(call.method, 'cropJpegRegion');
        final arguments = call.arguments! as Map<Object?, Object?>;
        expect(arguments['bytes'], source);
        expect(arguments['sourceWidth'], 5000);
        expect(arguments['sourceHeight'], 4000);
        expect(arguments['orientation'], index + 1);
        expect(arguments['left'], .1);
        expect(arguments['top'], .2);
        expect(arguments['right'], .8);
        expect(arguments['bottom'], .9);
        expect(arguments['maxPixels'], 16000000);
      }
      expect(source, [0xff, 0xd8, 0xff, 0xd9]);
    },
  );

  test('Dart fake-channel accepts the inclusive source-pixel budget', () async {
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          captured = call;
          return Uint8List.fromList([137, 80, 78, 71]);
        });

    await cropper.cropJpegRegion(
      source: source,
      sourceWidth: 8000,
      sourceHeight: 4000,
      orientation: 1,
      left: 0,
      top: 0,
      right: .5,
      bottom: 1,
    );

    expect(captured, isNotNull);
    final arguments = captured!.arguments! as Map<Object?, Object?>;
    expect(arguments['sourceWidth'], 8000);
    expect(arguments['right'], .5);
    expect(arguments['maxPixels'], 16000000);
  });

  test('Dart fake-channel rejects invalid geometry and source limits locally', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls++;
          return Uint8List.fromList([137, 80, 78, 71]);
        });

    final invalidRequests = <Future<Uint8List> Function()>[
      () => cropper.cropJpegRegion(
        source: source,
        sourceWidth: 5000,
        sourceHeight: 4000,
        orientation: 1,
        left: -.01,
        top: 0,
        right: .5,
        bottom: .5,
      ),
      () => cropper.cropJpegRegion(
        source: source,
        sourceWidth: 5000,
        sourceHeight: 4000,
        orientation: 1,
        left: 0,
        top: 0,
        right: 1.01,
        bottom: .5,
      ),
      () => cropper.cropJpegRegion(
        source: source,
        sourceWidth: 5000,
        sourceHeight: 4000,
        orientation: 1,
        left: .8,
        top: .1,
        right: .2,
        bottom: .9,
      ),
      () => cropper.cropJpegRegion(
        source: source,
        sourceWidth: 5000,
        sourceHeight: 4000,
        orientation: 1,
        left: 0,
        top: 0,
        right: double.nan,
        bottom: .5,
      ),
      () => cropper.cropJpegRegion(
        source: source,
        sourceWidth: 5000,
        sourceHeight: 4000,
        orientation: 0,
        left: 0,
        top: 0,
        right: 1,
        bottom: 1,
      ),
      () => cropper.cropJpegRegion(
        source: source,
        sourceWidth: 5000,
        sourceHeight: 4000,
        orientation: 9,
        left: 0,
        top: 0,
        right: 1,
        bottom: 1,
      ),
      () => cropper.cropJpegRegion(
        source: source,
        sourceWidth: 8001,
        sourceHeight: 4000,
        orientation: 1,
        left: 0,
        top: 0,
        right: 1,
        bottom: 1,
      ),
      () => cropper.cropJpegRegion(
        source: Uint8List(0),
        sourceWidth: 10,
        sourceHeight: 10,
        orientation: 1,
        left: 0,
        top: 0,
        right: 1,
        bottom: 1,
      ),
    ];

    for (final request in invalidRequests) {
      await expectLater(request(), throwsA(isA<ValidationException>()));
    }
    expect(calls, 0, reason: 'invalid requests must not reach the channel');
  });

  test('Dart fake-channel maps native error codes to user-facing failures', () async {
    const mappedErrors = <String, String>{
      'crop_too_large': '16 مليون',
      'out_of_memory': 'ذاكرة',
      'busy': 'مشغول',
      'cancelled': 'أُلغي',
      'crop_failed': 'بأمان',
    };

    for (final entry in mappedErrors.entries) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: entry.key);
          });
      await expectLater(
        cropper.cropJpegRegion(
          source: source,
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
            'message for ${entry.key}',
            contains(entry.value),
          ),
        ),
      );
    }

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw MissingPluginException();
        });
    await expectLater(
      cropper.cropJpegRegion(
        source: source,
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
          'missing-plugin message',
          contains('لا تتوفر معالجة JPEG كاملة الدقة'),
        ),
      ),
    );
  });

  test('Dart fake-channel rejects null and oversized native responses', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    await expectLater(
      cropper.cropJpegRegion(
        source: source,
        sourceWidth: 5000,
        sourceHeight: 4000,
        orientation: 1,
        left: 0,
        top: 0,
        right: 1,
        bottom: 1,
      ),
      throwsA(isA<ValidationException>()),
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => Uint8List(20 * 1024 * 1024 + 1));
    await expectLater(
      cropper.cropJpegRegion(
        source: source,
        sourceWidth: 5000,
        sourceHeight: 4000,
        orientation: 1,
        left: 0,
        top: 0,
        right: 1,
        bottom: 1,
      ),
      throwsA(isA<ValidationException>()),
    );
  });
}
