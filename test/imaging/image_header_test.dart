import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/imaging/image_header.dart';
import 'package:scan_id/imaging/prepare_image.dart';

Uint8List _jpegHeader(int width, int height) => Uint8List.fromList([
  0xff,
  0xd8,
  0xff,
  0xc0,
  0,
  11,
  8,
  (height >> 8) & 255,
  height & 255,
  (width >> 8) & 255,
  width & 255,
  1,
  1,
  0x11,
  0,
  0xff,
  0xd9,
]);

void main() {
  test('direct Dart decoding rejects an oversized JPEG before a codec runs', () {
    final bytes = _jpegHeader(4001, 4000);
    expect(
      () => decodeForProcessing(bytes),
      throwsA(
        isA<ValidationException>().having(
          (e) => e.message,
          'pixel guard',
          contains('16'),
        ),
      ),
    );
  });
  test(
    'a source above the processing limit is admitted for bounded scaling',
    () {
      const width = 4001, height = 4000;
      final header = inspectImageHeader(_jpegHeader(width, height));
      expect(header.width, width);
      expect(header.height, height);
      expect(header.width * header.height, greaterThan(16000000));
    },
  );

  test('JPEGs above the bounded source ceiling are rejected in the header', () {
    expect(
      () => inspectImageHeader(_jpegHeader(7000, 5000)),
      throwsA(isA<ValidationException>().having(
        (error) => error.message,
        'source pixel guard',
        contains('32'),
      )),
    );
  });

  test('EXIF orientation is read without decoding the JPEG frame', () {
    final bytes = Uint8List.fromList([
      0xff, 0xd8,
      0xff, 0xe1, 0x00, 0x22,
      0x45, 0x78, 0x69, 0x66, 0x00, 0x00,
      0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00,
      0x01, 0x00,
      0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00,
      0x06, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00,
      ..._jpegHeader(4000, 5000).skip(2),
    ]);
    expect(inspectImageHeader(bytes).orientation, 6);
  });

  test('EXIF after SOF is still read before the JPEG scan starts', () {
    final frame = _jpegHeader(4000, 5000);
    final bytes = Uint8List.fromList([
      ...frame.take(frame.length - 2),
      0xff, 0xe1, 0x00, 0x22,
      0x45, 0x78, 0x69, 0x66, 0x00, 0x00,
      0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00,
      0x01, 0x00,
      0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00,
      0x06, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00,
      0xff, 0xd9,
    ]);

    final header = inspectImageHeader(bytes);
    expect([header.width, header.height], [4000, 5000]);
    expect(header.orientation, 6);
  });

  test('JPEG segment lengths cannot overflow the input', () {
    expect(
      () => inspectImageHeader(
        Uint8List.fromList([0xff, 0xd8, 0xff, 0xe1, 0xff, 0xff]),
      ),
      throwsA(isA<ValidationException>()),
    );
  });
  test(
    '32-bit PNG dimensions cannot bypass budget through integer overflow',
    () {
      final bytes = Uint8List(33);
      bytes.setAll(0, [137, 80, 78, 71, 13, 10, 26, 10]);
      final data = ByteData.sublistView(bytes);
      data.setUint32(8, 13);
      data.setUint32(12, 0x49484452);
      data.setUint32(16, 0xffffffff);
      data.setUint32(20, 0xffffffff);
      expect(
        () => inspectImageHeader(bytes),
        throwsA(isA<ValidationException>()),
      );
    },
  );
  test('zero-size PNG header cannot enter a codec', () {
    final bytes = Uint8List(33);
    bytes.setAll(0, [137, 80, 78, 71, 13, 10, 26, 10]);
    final data = ByteData.sublistView(bytes);
    data.setUint32(8, 13);
    data.setUint32(12, 0x49484452);
    data.setUint32(20, 100);
    expect(
      () => inspectImageHeader(bytes),
      throwsA(isA<ValidationException>()),
    );
  });
}
