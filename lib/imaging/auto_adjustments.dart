import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../domain/image_adjustments.dart';
import '../domain/validation.dart';
import 'prepare_image.dart';

/// Local, deterministic baseline for a document photo. It samples at most about
/// 65K pixels, never uploads the image, and returns ordinary editable slider
/// values rather than baking changes into the source.
ImageAdjustments suggestAutoAdjustments(
  Uint8List preview, {
  int quarterTurns = 0,
}) {
  final image = decodeForProcessing(preview);
  final stride = math
      .max(1, math.sqrt(image.width * image.height / 65000).ceil())
      .toInt();
  final histogram = Int32List(256);
  var count = 0;
  var totalLuma = 0.0;
  var totalSaturation = 0.0;
  var horizontalEdge = 0.0;
  var edgeCount = 0;

  double luma(img.Pixel pixel) =>
      (.2126 * pixel.r + .7152 * pixel.g + .0722 * pixel.b) / 255;

  for (var y = 0; y < image.height; y += stride) {
    for (var x = 0; x < image.width; x += stride) {
      final pixel = image.getPixel(x, y);
      final light = luma(pixel).clamp(0, 1).toDouble();
      histogram[(light * 255).round()]++;
      totalLuma += light;
      final maximum = math.max(pixel.r, math.max(pixel.g, pixel.b)).toDouble();
      final minimum = math.min(pixel.r, math.min(pixel.g, pixel.b)).toDouble();
      if (maximum > 0) totalSaturation += (maximum - minimum) / maximum;
      count++;
      if (x + stride < image.width) {
        horizontalEdge += (light - luma(image.getPixel(x + stride, y))).abs();
        edgeCount++;
      }
    }
  }
  require(count > 0, 'لا توجد بكسلات كافية لضبط الصورة.');

  int percentile(double value) {
    final target = (count * value).ceil();
    var accumulated = 0;
    for (var level = 0; level < histogram.length; level++) {
      accumulated += histogram[level];
      if (accumulated >= target) return level;
    }
    return 255;
  }

  final low = percentile(.04), high = percentile(.96);
  final range = (high - low) / 255;
  final contrast = range < .82
      ? (.82 / math.max(.1, range)).clamp(1.0, 1.28).toDouble()
      : 1.0;
  final mean = totalLuma / count;
  final brightness = ((.5 - mean) * .18).clamp(-.08, .08).toDouble();
  final meanSaturation = totalSaturation / count;
  final saturation = meanSaturation < .24 ? 1.08 : 1.0;
  final edge = edgeCount == 0 ? 0.0 : horizontalEdge / edgeCount;
  final sharpness = edge < .045 ? .14 : .07;

  return ImageAdjustments(
    brightness: brightness,
    contrast: contrast,
    saturation: saturation,
    sharpness: sharpness,
    quarterTurns: quarterTurns,
  );
}
