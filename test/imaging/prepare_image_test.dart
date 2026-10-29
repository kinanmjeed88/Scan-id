import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/imaging/prepare_image.dart';
import 'package:scan_id/domain/image_limits.dart';

void main() {
  final invalid = throwsA(isA<ValidationException>());
  test('PNG processing retains original bytes and correct work dimensions', () {
    final source = img.Image(width: 40, height: 20);
    source.setPixelRgb(10, 10, 123, 80, 45);
    final bytes = img.encodePng(source);
    final before = Uint8List.fromList(bytes);
    final result = prepareImage(bytes);
    expect(bytes, before);
    expect([result.width, result.height], [40, 20]);
    expect(result.extension, 'png');
    final working = img.decodePng(result.working)!;
    expect(working.getPixel(10, 10).r, 123);
    expect(working.getPixel(10, 10).g, 80);
    final thumbnail = img.decodeJpg(result.thumbnail)!;
    expect(thumbnail.width, lessThanOrEqualTo(320));
    expect(thumbnail.width / thumbnail.height, closeTo(2, .02));
  });
  test(
    'EXIF orientation is baked into work while source remains unchanged',
    () {
      final image = img.Image(width: 40, height: 20);
      image.exif.imageIfd.orientation = 6;
      final bytes = img.encodeJpg(image);
      final before = Uint8List.fromList(bytes);
      final prepared = prepareImage(bytes);
      expect([prepared.width, prepared.height], [20, 40]);
      expect(bytes, before);
      // decodeJpg bakes EXIF and deliberately removes the orientation tag.
      // Read the encoded metadata, not the already-normalized decoded image.
      expect(img.decodeJpgExif(bytes)!.imageIfd.orientation, 6);
    },
  );
  test('all EXIF orientations bake exactly once against a pixel oracle', () {
    // Asymmetric 3x2 RGB pattern. Expected transforms are independent of the
    // image package: each cell stores its original coordinate as RGB.
    final raw = img.Image(width: 3, height: 2);
    for (var y = 0; y < 2; y++) {
      for (var x = 0; x < 3; x++) {
        raw.setPixelRgb(x, y, 20 + x * 20, 40 + y * 20, 90);
      }
    }
    List<List<(int, int)>> expected(int orientation) {
      final rows = <List<(int, int)>>[];
      for (var y = 0; y < (orientation >= 5 ? 3 : 2); y++) {
        final row = <(int, int)>[];
        for (var x = 0; x < (orientation >= 5 ? 2 : 3); x++) {
          row.add(switch (orientation) {
            1 => (x, y),
            2 => (2 - x, y),
            3 => (2 - x, 1 - y),
            4 => (x, 1 - y),
            5 => (y, x),
            6 => (y, 2 - x),
            7 => (2 - y, 1 - x),
            _ => (2 - y, x),
          });
        }
        rows.add(row);
      }
      return rows;
    }
    for (var orientation = 1; orientation <= 8; orientation++) {
      final tagged = img.Image.from(raw);
      tagged.exif.imageIfd.orientation = orientation;
      final bytes = img.encodeJpg(tagged, quality: 100);
      final before = Uint8List.fromList(bytes);
      final decoded = decodeForProcessing(bytes);
      final grid = expected(orientation);
      expect(decoded.height, grid.length, reason: 'EXIF $orientation');
      expect(decoded.width, grid.first.length, reason: 'EXIF $orientation');
      for (var y = 0; y < decoded.height; y++) {
        for (var x = 0; x < decoded.width; x++) {
          final source = grid[y][x];
          final pixel = decoded.getPixel(x, y);
          expect(pixel.r, 20 + source.$1 * 20, reason: 'EXIF $orientation at $x,$y');
          expect(pixel.g, 40 + source.$2 * 20, reason: 'EXIF $orientation at $x,$y');
        }
      }
      expect(bytes, before);
      expect(img.decodeJpgExif(bytes)!.imageIfd.orientation, orientation);
      // Re-encoding the working image as PNG cannot rotate it a second time.
      final working = img.encodePng(decoded);
      final again = decodeForProcessing(working);
      expect(again.width, decoded.width);
      expect(again.height, decoded.height);
    }
  });

  test('oversized PNG header is rejected before frame decoding', () {
    final bytes = img.encodePng(img.Image(width: 1, height: 1));
    final data = ByteData.sublistView(bytes);
    data.setUint32(16, 5000);
    data.setUint32(20, 5000);
    var crc = 0xffffffff;
    for (var i = 12; i < 29; i++) {
      crc ^= bytes[i];
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
      }
    }
    data.setUint32(29, crc ^ 0xffffffff);
    expect(
      () => prepareImage(bytes),
      throwsA(
        isA<ValidationException>().having(
          (e) => e.message,
          'pixel limit',
          contains('16'),
        ),
      ),
    );
  });
  test('JPEG is accepted by signature rather than extension', () {
    final bytes = img.encodeJpg(img.Image(width: 30, height: 50));
    final result = prepareImage(bytes);
    expect(result.extension, 'jpg');
    expect([result.width, result.height], [30, 50]);
    expect(img.decodePng(result.working), isNotNull);
  });
  test('unknown, empty, truncated and oversized inputs fail explicitly', () {
    expect(() => prepareImage(Uint8List(0)), invalid);
    expect(() => prepareImage(Uint8List.fromList([1, 2, 3])), invalid);
    expect(() => prepareImage(Uint8List.fromList([255, 216, 255])), invalid);
    expect(() => prepareImage(Uint8List(maxImportBytes + 1)), invalid);
  });
  test('animated PNG input is not flattened silently', () {
    final image = img.Image(width: 4, height: 4);
    image.addFrame(img.Image(width: 4, height: 4));
    expect(() => prepareImage(img.encodePng(image)), invalid);
  });
}
