import 'dart:math' as math;

import '../domain/geometry.dart';
import '../domain/image_limits.dart';
import '../domain/validation.dart';

/// Oriented pixel size of a JPEG after EXIF orientation 1–8.
///
/// Dimensions 5–8 swap axes. The manual editor's normalized corners are in
/// this oriented frame, because the sampled preview already baked EXIF.
(int width, int height) orientedPixelSize(
  int width,
  int height,
  int orientation,
) {
  require(
    width > 0 && height > 0 && orientation >= 1 && orientation <= 8,
    'إطار JPEG كامل الدقة غير صالح.',
  );
  if (orientation >= 5) return (height, width);
  return (width, height);
}

/// True when [bounds] is the whole oriented frame, not a document region.
///
/// A sampled large JPEG has no legal full-density result for this rectangle:
/// the source itself is above the 16 MP budget. Crop commands must refuse it.
/// Adjustments of an uncropped asset are a different operation and keep the
/// import sample, which is the stored working representation.
bool coversOrientedFrame(
  ({double left, double top, double right, double bottom}) bounds,
) =>
    bounds.left <= 1e-6 &&
    bounds.top <= 1e-6 &&
    bounds.right >= 1 - 1e-6 &&
    bounds.bottom >= 1 - 1e-6;

/// Axis-aligned bounds of a quadrilateral in normalized oriented coordinates.
///
/// This is the rectangle [cropJpegRegion] must extract. It is not a guessed
/// document and it does not replace the quadrilateral.
({double left, double top, double right, double bottom}) manualCropBounds(
  List<Point2> corners,
) {
  require(corners.length == 4, 'زوايا القص يجب أن تكون أربعًا.');
  var left = corners.first.x;
  var top = corners.first.y;
  var right = left;
  var bottom = top;
  for (final corner in corners) {
    require(
      corner.x.isFinite &&
          corner.y.isFinite &&
          corner.x >= 0 &&
          corner.x <= 1 &&
          corner.y >= 0 &&
          corner.y <= 1,
      'زوايا القص خارج الصورة.',
    );
    if (corner.x < left) left = corner.x;
    if (corner.y < top) top = corner.y;
    if (corner.x > right) right = corner.x;
    if (corner.y > bottom) bottom = corner.y;
  }
  require(left < right && top < bottom, 'منطقة القص فارغة.');
  return (left: left, top: top, right: right, bottom: bottom);
}

/// Pixel span of a normalized interval after the same floor/ceil snap the
/// native JPEG crop uses. A span above [maxImportPixels] must be refused
/// before any silent downsample.
int snappedSpanPixels(double start, double end, int size) {
  require(
    size > 0 && start.isFinite && end.isFinite && start < end,
    'امتداد القص غير صالح.',
  );
  final first = (start * size).floor();
  final last = (end * size).ceil();
  return math.max(0, last - first);
}

/// Refuses a full-density extract that cannot fit the existing 16 MP budget.
///
/// Callers must not continue on the sampled preview after this throws.
void requireFullResolutionCropFits({
  required ({double left, double top, double right, double bottom}) bounds,
  required int orientedWidth,
  required int orientedHeight,
}) {
  final width = snappedSpanPixels(bounds.left, bounds.right, orientedWidth);
  final height = snappedSpanPixels(bounds.top, bounds.bottom, orientedHeight);
  require(
    width > 0 &&
        height > 0 &&
        width <= maxImportPixels &&
        height <= maxImportPixels &&
        width * height <= maxImportPixels,
    'منطقة القص أكبر من حد المعالجة كاملة الدقة (16 مليون بكسل). '
    'لن يُستخدم التصغير الصامت.',
  );
}

/// Rewrites full-frame oriented corners into the extracted rectangle.
///
/// The native crop returns that rectangle already oriented. These local
/// corners describe the same quadrilateral; they are not a new boundary.
List<Point2> remapCornersIntoRegion(
  List<Point2> corners,
  ({double left, double top, double right, double bottom}) bounds,
) {
  final spanX = bounds.right - bounds.left;
  final spanY = bounds.bottom - bounds.top;
  require(spanX > 0 && spanY > 0, 'منطقة القص فارغة.');
  final local = [
    for (final corner in corners)
      Point2(
        (corner.x - bounds.left) / spanX,
        (corner.y - bounds.top) / spanY,
      ),
  ];
  require(
    local.every(
      (corner) =>
          corner.x >= -1e-9 &&
          corner.x <= 1 + 1e-9 &&
          corner.y >= -1e-9 &&
          corner.y <= 1 + 1e-9,
    ),
    'زوايا القص خارج المنطقة المستخرجة.',
  );
  return [
    for (final corner in local)
      Point2(corner.x.clamp(0.0, 1.0), corner.y.clamp(0.0, 1.0)),
  ];
}
