import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/imaging/ocr_region.dart';

Uint8List _source() {
  final image = img.Image(width: 100, height: 100);
  img.fill(image, color: img.ColorRgb8(10, 10, 10));
  img.fillRect(
    image,
    x1: 25,
    y1: 25,
    x2: 74,
    y2: 74,
    color: img.ColorRgb8(220, 40, 30),
  );
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  test('measured region crop excludes surrounding pixels', () {
    final bytes = prepareOcrRegion(
      _source(),
      region: const [.25, .25, .75, .75],
    );
    final crop = img.decodeImage(bytes)!;
    expect(crop.width, 50);
    expect(crop.height, 50);
    final center = crop.getPixel(25, 25);
    expect(center.rNormalized, greaterThan(.7));
    expect(center.gNormalized, lessThan(.3));
  });

  test('a valid quadrilateral uses the perspective crop path', () {
    final bytes = prepareOcrRegion(
      _source(),
      corners: [
        Point2(.25, .25),
        Point2(.75, .25),
        Point2(.75, .75),
        Point2(.25, .75),
      ],
    );
    final crop = img.decodeImage(bytes)!;
    expect(crop.width, 50);
    expect(crop.height, 50);
    expect(crop.getPixel(25, 25).rNormalized, greaterThan(.7));
  });

  test('whole preview is passed through only when no region was measured', () {
    final source = _source();
    expect(prepareOcrRegion(source), same(source));
  });

  test('invalid measured regions fail closed', () {
    for (final region in const [
      <double>[.2, .2, .1, .9],
      <double>[.2, .2, 1.2, .9],
      <double>[.2, .2, .9],
    ]) {
      expect(
        () => prepareOcrRegion(_source(), region: region),
        throwsA(isA<ValidationException>()),
      );
    }
  });
}
