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
  test('contain geometry and native DPI ignore empty slot margins', () {
    for (final dimensions in [(1200, 120), (120, 1200), (1200, 1200)]) {
      final fitted = containedDocumentRect(
        itemX: 10,
        itemY: 20,
        itemWidth: 50.8,
        itemHeight: 50.8,
        imageWidth: dimensions.$1,
        imageHeight: dimensions.$2,
      );
      expect(fitted.x + fitted.width / 2, closeTo(35.4, 1e-9));
      expect(fitted.y + fitted.height / 2, closeTo(45.4, 1e-9));
      expect(
        fitted.width / fitted.height,
        closeTo(dimensions.$1 / dimensions.$2, 1e-9),
      );
      expect(
        containedDocumentDpi(
          itemWidth: 50.8,
          itemHeight: 50.8,
          imageWidth: dimensions.$1,
          imageHeight: dimensions.$2,
        ),
        closeTo(600, 1e-9),
      );
    }
  });
  test('contain preserves non-square slot geometry and true low DPI', () {
    final fitted = containedDocumentRect(
      itemX: 7,
      itemY: 9,
      itemWidth: 50.8,
      itemHeight: 25.4,
      imageWidth: 100,
      imageHeight: 50,
    );
    expect(fitted, (x: 7.0, y: 9.0, width: 50.8, height: 25.4));
    expect(
      containedDocumentDpi(
        itemWidth: 50.8,
        itemHeight: 25.4,
        imageWidth: 100,
        imageHeight: 50,
      ),
      closeTo(50, 1e-9),
    );
  });
  test('contained DPI uses the limiting edge without derived-axis drift', () {
    for (final dimensions in [(80, 8), (8, 80)]) {
      final dpi = containedDocumentDpi(
        itemWidth: 50.8,
        itemHeight: 50.8,
        imageWidth: dimensions.$1,
        imageHeight: dimensions.$2,
      );
      expect(dpi, 40.0);
      expect(dpi.floor(), 40);
    }
  });
  test('contain rejects invalid and non-finite geometry', () {
    for (final width in [0.0, -1.0, double.nan, double.infinity]) {
      expect(
        () => containedDocumentDpi(
          itemWidth: width,
          itemHeight: 50,
          imageWidth: 100,
          imageHeight: 50,
        ),
        invalid,
      );
    }
    expect(
      () => containedDocumentRect(
        itemX: double.nan,
        itemY: 0,
        itemWidth: 50,
        itemHeight: 50,
        imageWidth: 100,
        imageHeight: 50,
      ),
      invalid,
    );
    expect(
      () => containedDocumentDpi(
        itemWidth: 50,
        itemHeight: 50,
        imageWidth: 0,
        imageHeight: 50,
      ),
      invalid,
    );
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
