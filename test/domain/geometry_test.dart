import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/validation.dart';

void main() {
  final invalid = throwsA(isA<ValidationException>());
  test('A4 raster rounding at 300 and 600 DPI', () {
    expect(millimetersToPixels(210, 300).round(), 2480);
    expect(millimetersToPixels(297, 300).round(), 3508);
    expect(millimetersToPixels(210, 600).round(), 4961);
    expect(millimetersToPixels(297, 600).round(), 7016);
    expect(millimetersToPoints(25.4), closeTo(72, 1e-9));
    expect(millimetersToPixels(25.4, 300), closeTo(300, 1e-9));
  });
  test('invalid conversion inputs cannot produce NaN or negative output', () {
    expect(() => millimetersToPixels(-1, 300), invalid);
    expect(() => millimetersToPixels(double.infinity, 300), invalid);
    expect(() => millimetersToPixels(100, 0), invalid);
  });
  test('rotated bounds rotate around center, not top-left', () {
    final bounds = RectMm(20, 30, 80, 40).rotatedBounds(90);
    expect(bounds.x, closeTo(40, 1e-9));
    expect(bounds.y, closeTo(10, 1e-9));
    expect(bounds.width, closeTo(40, 1e-9));
    expect(bounds.height, closeTo(80, 1e-9));
  });
  test('edge contact is not overlap', () {
    final first = RectMm(0, 0, 10, 10);
    expect(first.overlaps(RectMm(10, 0, 10, 10)), isFalse);
    expect(first.overlaps(RectMm(9.99, 0, 10, 10)), isTrue);
  });
  test('convex crop geometry round-trips without losing corners', () {
    final crop = CropGeometry(
      corners: [Point2(.1, .2), Point2(.9, .1), Point2(.8, .8), Point2(.2, .9)],
      outputWidth: 800,
      outputHeight: 600,
    );
    expect(CropGeometry.fromJson(crop.toJson()).toJson(), crop.toJson());
    expect(() => crop.corners.clear(), throwsUnsupportedError);
  });
  test(
    'crossing, reversed, collinear, outside and repeated crop points rejected',
    () {
      final tl = Point2(0, 0);
      final tr = Point2(1, 0);
      final br = Point2(1, 1);
      final bl = Point2(0, 1);
      for (final corners in [
        [tl, br, tr, bl],
        [tl, bl, br, tr],
        [tl, tr, tr, bl],
        [tl, Point2(.5, 0), tr, bl],
        [tl, Point2(2, 0), br, bl],
        [tl, tr, br],
      ]) {
        expect(
          () => CropGeometry(
            corners: corners,
            outputWidth: 100,
            outputHeight: 100,
          ),
          invalid,
        );
      }
    },
  );
  test('crop processing size is bounded before allocation', () {
    expect(
      () => CropGeometry(
        corners: [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)],
        outputWidth: 5000,
        outputHeight: 5000,
      ),
      invalid,
    );
  });
}
