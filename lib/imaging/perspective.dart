import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../domain/crop_draft.dart';
import '../domain/geometry.dart';
import '../domain/validation.dart';
import 'prepare_image.dart';

/// Projective unit-square -> source quadrilateral mapping. Not a bilinear
/// corner blend: straight source lines remain straight after correction.
class PerspectiveMap {
  PerspectiveMap(CropGeometry geometry) {
    final p = geometry.corners;
    final dx1 = p[1].x - p[2].x;
    final dx2 = p[3].x - p[2].x;
    final dx3 = p[0].x - p[1].x + p[2].x - p[3].x;
    final dy1 = p[1].y - p[2].y;
    final dy2 = p[3].y - p[2].y;
    final dy3 = p[0].y - p[1].y + p[2].y - p[3].y;
    if (dx3.abs() + dy3.abs() < 1e-12) {
      g = 0;
      h = 0;
    } else {
      final determinant = dx1 * dy2 - dx2 * dy1;
      require(determinant.abs() > 1e-12, 'تعذر تصحيح المنظور لهذه الزوايا.');
      g = (dx3 * dy2 - dx2 * dy3) / determinant;
      h = (dx1 * dy3 - dx3 * dy1) / determinant;
    }
    a = p[1].x - p[0].x + g * p[1].x;
    b = p[3].x - p[0].x + h * p[3].x;
    c = p[0].x;
    d = p[1].y - p[0].y + g * p[1].y;
    e = p[3].y - p[0].y + h * p[3].y;
    f = p[0].y;
    require(
      [a, b, c, d, e, f, g, h].every((v) => v.isFinite) &&
          [1.0, 1 + g, 1 + h, 1 + g + h].every((v) => v > 1e-9),
      'تحويل المنظور غير مستقر؛ عدّل الزوايا.',
    );
  }
  late final double a, b, c, d, e, f, g, h;
  Point2 at(double u, double v) {
    final denominator = g * u + h * v + 1;
    return Point2(
      (a * u + b * v + c) / denominator,
      (d * u + e * v + f) / denominator,
    );
  }
}

/// Source bytes never change. Both preview and accepted output use this exact
/// recipe/mapping; only the raster sample count is reduced for preview.
Uint8List renderPerspective(
  Uint8List original,
  ImageEditRecipe recipe, {
  int? previewLongEdge,
}) => img.encodePng(
  warpPerspective(original, recipe, previewLongEdge: previewLongEdge),
);

img.Image warpPerspective(
  Uint8List original,
  ImageEditRecipe recipe, {
  int? previewLongEdge,
}) {
  final source = decodeForProcessing(original);
  final geometry = recipe.geometry;
  final map = PerspectiveMap(geometry);
  var width = geometry.outputWidth;
  var height = geometry.outputHeight;
  if (previewLongEdge != null) {
    require(previewLongEdge > 0, 'حجم معاينة غير صالح.');
    final scale = math.min(1.0, previewLongEdge / math.max(width, height));
    width = math.max(1, (width * scale).round());
    height = math.max(1, (height * scale).round());
  }
  final output = img.Image(width: width, height: height, numChannels: 4);
  final adjustment = recipe.adjustments;
  int adjust(num value) =>
      (((value - .5) * adjustment.contrast + .5 + adjustment.brightness).clamp(
                0,
                1,
              ) *
              255)
          .round();
  for (var y = 0; y < height; y++) {
    final v = height == 1 ? .5 : y / (height - 1);
    for (var x = 0; x < width; x++) {
      final u = width == 1 ? .5 : x / (width - 1);
      final point = map.at(u, v);
      final pixel = source.getPixelInterpolate(
        (point.x * (source.width - 1)).clamp(0, source.width - 1).toDouble(),
        (point.y * (source.height - 1)).clamp(0, source.height - 1).toDouble(),
        interpolation: img.Interpolation.linear,
      );
      output.setPixelRgba(
        x,
        y,
        adjust(pixel.rNormalized),
        adjust(pixel.gNormalized),
        adjust(pixel.bNormalized),
        (pixel.aNormalized * 255).round(),
      );
    }
  }
  final rotated = adjustment.quarterTurns == 0
      ? output
      : img.copyRotate(output, angle: adjustment.quarterTurns * 90);
  return rotated;
}
