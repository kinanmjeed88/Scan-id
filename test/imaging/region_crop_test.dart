import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/imaging/region_crop.dart';

/// 100×80 source with a light rectangle at x 20..59, y 10..49.
img.Image _source() {
  final image = img.Image(width: 100, height: 80);
  img.fill(image, color: img.ColorRgb8(10, 20, 30));
  img.fillRect(
    image,
    x1: 20,
    y1: 10,
    x2: 59,
    y2: 49,
    color: img.ColorRgb8(200, 200, 200),
  );
  return image;
}

void main() {
  test('a measured region is cropped without guessing or warping', () {
    final bytes = Uint8List.fromList(img.encodePng(_source()));
    final cropped = cropRegionBytes(bytes, const [.2, .125, .6, .625]);
    final decoded = img.decodePng(cropped)!;
    // Region spans x 20..59, y 10..49 of the 100×80 source.
    expect(decoded.width, 40);
    expect(decoded.height, 40);
    // The pixels are the region's own pixels: nothing was invented.
    final center = decoded.getPixel(decoded.width ~/ 2, decoded.height ~/ 2);
    expect(center.rNormalized, greaterThan(.5));
  });

  test('the whole frame is a valid region', () {
    final bytes = Uint8List.fromList(img.encodePng(_source()));
    final decoded = img.decodePng(cropRegionBytes(bytes, fullFrameRegion))!;
    expect(decoded.width, 100);
    expect(decoded.height, 80);
  });

  test(
    'hostile, inverted or missing bounds are clamped, never out of range',
    () {
      final bytes = Uint8List.fromList(img.encodePng(_source()));
      for (final region in <List<double>>[
        const [9.0, -4.0, -1.0, 12.0],
        const [.8, .8, .2, .2],
        const [double.nan, 0.0, 1.0, 1.0],
        const [0.0, 0.0],
      ]) {
        final decoded = img.decodePng(cropRegionBytes(bytes, region))!;
        expect(decoded.width, greaterThan(0), reason: '$region');
        expect(decoded.height, greaterThan(0), reason: '$region');
        expect(decoded.width, lessThanOrEqualTo(100), reason: '$region');
        expect(decoded.height, lessThanOrEqualTo(80), reason: '$region');
      }
    },
  );
}
