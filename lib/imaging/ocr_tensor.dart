/// PP-OCR input tensors: the detection image, the recognition text line, and
/// the bilinear quad sampler that cuts one text line out of a document.
///
/// The conventions are the ones the bundled ONNX exports were trained with, and
/// they are pinned here rather than tuned per call site:
///
/// * **detection** — the longer edge is resampled to [ocrDetLongSide] and the
///   other edge is aligned to a multiple of [ocrDetStride], because DB's encoder
///   divides both edges by 32; channels are written planar in **BGR** order and
///   normalised with the ImageNet mean/std the export declares.
/// * **recognition** — a text line is resampled to [ocrRecHeight] px high with
///   its own aspect ratio (width aligned to [ocrRecStride]) and normalised as
///   `value / 127.5 - 1`, again planar BGR.
///
/// Channel order and normalisation are graph properties, not preferences:
/// swapping R and B quietly degrades recognition instead of failing, which is
/// exactly the kind of defect a unit test has to catch. [buildOcrDetInput] and
/// [buildOcrLineInput] are pure functions of a decoded image, so they are
/// covered without a model.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../domain/geometry.dart';
import '../domain/validation.dart';

/// Long edge of the detection input, as the PP-OCR detection export declares.
const int ocrDetLongSide = 960;

/// Alignment the DB encoder requires, in pixels.
const int ocrDetStride = 32;

/// Height of a recognition line, in pixels.
const int ocrRecHeight = 48;

/// Width alignment of a recognition line, in pixels.
const int ocrRecStride = 8;

/// Widest recognition line, in pixels. Wider lines are compressed, not cropped:
/// losing a character would change the meaning of a document number.
const int ocrRecMaxWidth = 960;

const double _detMeanBlue = .485;
const double _detMeanGreen = .456;
const double _detMeanRed = .406;
const double _detStdBlue = .229;
const double _detStdGreen = .224;
const double _detStdRed = .225;

/// Detection input tensor plus the map back to source pixels.
class OcrDetInput {
  const OcrDetInput({
    required this.values,
    required this.width,
    required this.height,
    required this.scaleX,
    required this.scaleY,
  });

  /// Planar BGR, `3 × height × width`, normalised.
  final Float32List values;
  final int width;
  final int height;

  /// Source pixels per tensor pixel, per axis.
  final double scaleX;
  final double scaleY;
}

/// Recognition input tensor for one text line.
class OcrLineInput {
  const OcrLineInput({
    required this.values,
    required this.width,
    required this.height,
  });

  /// Planar BGR, `3 × height × width`, normalised.
  final Float32List values;
  final int width;
  final int height;
}

/// Builds the detection tensor for [source].
///
/// Both edges are aligned to [ocrDetStride] after the long-edge rescale; the
/// returned scales are the *actual* ratios of that resize, so a detector box
/// maps back to source pixels exactly even when the alignment rounded one axis.
OcrDetInput buildOcrDetInput(img.Image source) {
  require(source.width > 0 && source.height > 0, 'صورة OCR غير صالحة.');
  final longSide = math.max(source.width, source.height);
  final scale = ocrDetLongSide / longSide;
  final width = _alignToStride((source.width * scale).round(), ocrDetStride);
  final height = _alignToStride((source.height * scale).round(), ocrDetStride);
  final resized = width == source.width && height == source.height
      ? source
      : img.copyResize(
          source,
          width: width,
          height: height,
          interpolation: img.Interpolation.linear,
        );
  final plane = width * height;
  final values = Float32List(3 * plane);
  for (var y = 0; y < height; y++) {
    final row = y * width;
    for (var x = 0; x < width; x++) {
      final pixel = resized.getPixel(x, y);
      final index = row + x;
      values[index] = (pixel.b.toDouble() / 255 - _detMeanBlue) / _detStdBlue;
      values[plane + index] =
          (pixel.g.toDouble() / 255 - _detMeanGreen) / _detStdGreen;
      values[2 * plane + index] =
          (pixel.r.toDouble() / 255 - _detMeanRed) / _detStdRed;
    }
  }
  return OcrDetInput(
    values: values,
    width: width,
    height: height,
    scaleX: source.width / width,
    scaleY: source.height / height,
  );
}

/// Cuts the quadrilateral [corners] (source pixels, clockwise from top-left) out
/// of [source] and resamples it into a recognition tensor.
///
/// The sampler is bilinear on the source grid; it never allocates an
/// intermediate image, so a card with thirty text lines does not add thirty
/// bitmaps to the peak footprint.
OcrLineInput buildOcrLineInput(img.Image source, List<Point2> corners) {
  require(corners.length == 4, 'حدود سطر OCR يجب أن تكون أربع نقاط.');
  require(source.width > 0 && source.height > 0, 'صورة OCR غير صالحة.');
  final width = _recognitionWidth(corners);
  final plane = width * ocrRecHeight;
  final values = Float32List(3 * plane);
  final topLeft = corners[0];
  final topRight = corners[1];
  final bottomRight = corners[2];
  final bottomLeft = corners[3];
  for (var y = 0; y < ocrRecHeight; y++) {
    final v = (y + .5) / ocrRecHeight;
    for (var x = 0; x < width; x++) {
      final u = (x + .5) / width;
      final sourceX =
          (1 - u) * (1 - v) * topLeft.x +
          u * (1 - v) * topRight.x +
          u * v * bottomRight.x +
          (1 - u) * v * bottomLeft.x;
      final sourceY =
          (1 - u) * (1 - v) * topLeft.y +
          u * (1 - v) * topRight.y +
          u * v * bottomRight.y +
          (1 - u) * v * bottomLeft.y;
      final index = y * width + x;
      final sample = _sample(source, sourceX, sourceY);
      values[index] = sample.blue / 127.5 - 1;
      values[plane + index] = sample.green / 127.5 - 1;
      values[2 * plane + index] = sample.red / 127.5 - 1;
    }
  }
  return OcrLineInput(values: values, width: width, height: ocrRecHeight);
}

/// Recognition width for a quad: its own aspect ratio, aligned and bounded.
int _recognitionWidth(List<Point2> corners) {
  final horizontal =
      (_distance(corners[0], corners[1]) + _distance(corners[3], corners[2])) /
      2;
  final vertical =
      (_distance(corners[0], corners[3]) + _distance(corners[1], corners[2])) /
      2;
  if (!horizontal.isFinite || !vertical.isFinite || horizontal <= 0) {
    return ocrRecStride * 4;
  }
  final target = math.max(vertical, 1.0);
  final raw = (ocrRecHeight * horizontal / target).round();
  return _alignToStride(
    raw,
    ocrRecStride,
  ).clamp(ocrRecStride * 4, ocrRecMaxWidth).toInt();
}

double _distance(Point2 a, Point2 b) {
  final dx = b.x - a.x;
  final dy = b.y - a.y;
  return math.sqrt(dx * dx + dy * dy);
}

int _alignToStride(int value, int stride) {
  final rounded = ((value + stride ~/ 2) ~/ stride) * stride;
  return math.max(stride, rounded);
}

/// Bilinear RGB sample at a source-pixel position, clamped to the image.
_Triple _sample(img.Image source, double x, double y) {
  final maxX = (source.width - 1).toDouble();
  final maxY = (source.height - 1).toDouble();
  final sx = x.isFinite ? x.clamp(0.0, maxX).toDouble() : 0.0;
  final sy = y.isFinite ? y.clamp(0.0, maxY).toDouble() : 0.0;
  final x0 = sx.floor();
  final y0 = sy.floor();
  final x1 = math.min(x0 + 1, source.width - 1);
  final y1 = math.min(y0 + 1, source.height - 1);
  final tx = sx - x0;
  final ty = sy - y0;
  final p00 = source.getPixel(x0, y0);
  final p10 = source.getPixel(x1, y0);
  final p01 = source.getPixel(x0, y1);
  final p11 = source.getPixel(x1, y1);
  final w00 = (1 - tx) * (1 - ty);
  final w10 = tx * (1 - ty);
  final w01 = (1 - tx) * ty;
  final w11 = tx * ty;
  return _Triple(
    red:
        p00.r.toDouble() * w00 +
        p10.r.toDouble() * w10 +
        p01.r.toDouble() * w01 +
        p11.r.toDouble() * w11,
    green:
        p00.g.toDouble() * w00 +
        p10.g.toDouble() * w10 +
        p01.g.toDouble() * w01 +
        p11.g.toDouble() * w11,
    blue:
        p00.b.toDouble() * w00 +
        p10.b.toDouble() * w10 +
        p01.b.toDouble() * w01 +
        p11.b.toDouble() * w11,
  );
}

/// One sampled pixel, kept in floating point until it is normalised.
class _Triple {
  const _Triple({required this.red, required this.green, required this.blue});

  final double red;
  final double green;
  final double blue;
}
