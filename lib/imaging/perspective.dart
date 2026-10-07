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
  int adjust(double value) =>
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
      final sx = (point.x * (source.width - 1))
          .clamp(0, source.width - 1)
          .toDouble();
      final sy = (point.y * (source.height - 1))
          .clamp(0, source.height - 1)
          .toDouble();
      final x0 = sx.floor(), y0 = sy.floor();
      final tx = sx - x0, ty = sy - y0;
      final p00 = source.getPixel(x0, y0);
      final p10 = source.getPixel(math.min(x0 + 1, source.width - 1), y0);
      final p01 = source.getPixel(x0, math.min(y0 + 1, source.height - 1));
      final p11 = source.getPixel(
        math.min(x0 + 1, source.width - 1),
        math.min(y0 + 1, source.height - 1),
      );
      // Keep interpolation in floating point until the final rounding. The
      // codec's 8-bit getPixelInterpolate truncates e.g. 92.999999 to 92,
      // which even changed pixels in an identity warp. Premultiplied alpha
      // also avoids dark fringes beside transparent PNG pixels.
      var w00 = (1 - tx) * (1 - ty) * p00.aNormalized;
      var w10 = tx * (1 - ty) * p10.aNormalized;
      var w01 = (1 - tx) * ty * p01.aNormalized;
      var w11 = tx * ty * p11.aNormalized;
      final alpha = w00 + w10 + w01 + w11;
      final divisor = alpha == 0 ? 1 : alpha;
      if (alpha == 0) {
        // Preserve even hidden RGB values in fully transparent identity samples.
        w00 = (1 - tx) * (1 - ty);
        w10 = tx * (1 - ty);
        w01 = (1 - tx) * ty;
        w11 = tx * ty;
      }
      var red =
          (p00.rNormalized * w00 +
              p10.rNormalized * w10 +
              p01.rNormalized * w01 +
              p11.rNormalized * w11) /
          divisor;
      var green =
          (p00.gNormalized * w00 +
              p10.gNormalized * w10 +
              p01.gNormalized * w01 +
              p11.gNormalized * w11) /
          divisor;
      var blue =
          (p00.bNormalized * w00 +
              p10.bNormalized * w10 +
              p01.bNormalized * w01 +
              p11.bNormalized * w11) /
          divisor;
      if (adjustment.sharpness > 0 && alpha > 0) {
        // A four-neighbour unsharp mask is sampled from the immutable source,
        // so sharpening needs no second full-size raster allocation. Alpha-
        // weighted averages avoid dark halos along transparent PNG edges.
        final centerX = sx.round().clamp(0, source.width - 1).toInt();
        final centerY = sy.round().clamp(0, source.height - 1).toInt();
        final left = source.getPixel(math.max(0, centerX - 1), centerY);
        final right = source.getPixel(
          math.min(source.width - 1, centerX + 1),
          centerY,
        );
        final above = source.getPixel(centerX, math.max(0, centerY - 1));
        final below = source.getPixel(
          centerX,
          math.min(source.height - 1, centerY + 1),
        );
        final neighbours = [left, right, above, below];
        final neighbourAlpha = neighbours.fold<double>(
          0,
          (sum, pixel) => sum + pixel.aNormalized,
        );
        if (neighbourAlpha > 0) {
          double meanChannel(double Function(img.Pixel) channel) =>
              neighbours.fold<double>(
                0,
                (sum, pixel) => sum + channel(pixel) * pixel.aNormalized,
              ) /
              neighbourAlpha;
          final amount = adjustment.sharpness;
          red = (red + amount * (red - meanChannel((p) => p.rNormalized)))
              .clamp(0, 1)
              .toDouble();
          green = (green + amount * (green - meanChannel((p) => p.gNormalized)))
              .clamp(0, 1)
              .toDouble();
          blue = (blue + amount * (blue - meanChannel((p) => p.bNormalized)))
              .clamp(0, 1)
              .toDouble();
        }
      }
      final luminance = .2126 * red + .7152 * green + .0722 * blue;
      output.setPixelRgba(
        x,
        y,
        adjust(luminance + (red - luminance) * adjustment.saturation),
        adjust(luminance + (green - luminance) * adjustment.saturation),
        adjust(luminance + (blue - luminance) * adjustment.saturation),
        (alpha * 255).round(),
      );
    }
  }
  final rotated = adjustment.quarterTurns == 0
      ? output
      : img.copyRotate(output, angle: adjustment.quarterTurns * 90);
  return rotated;
}
