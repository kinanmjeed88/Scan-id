import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/imaging/image_header.dart';

void main() {
  test('oversized JPEG SOF rejected without entering a codec', () {
    final bytes = Uint8List.fromList([
      0xff,
      0xd8,
      0xff,
      0xc0,
      0,
      11,
      8,
      0x27,
      0x10,
      0x27,
      0x10,
      1,
      1,
      0x11,
      0,
      0xff,
      0xd9,
    ]);
    expect(
      () => inspectImageHeader(bytes),
      throwsA(
        isA<ValidationException>().having(
          (e) => e.message,
          'pixel guard',
          contains('16'),
        ),
      ),
    );
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
