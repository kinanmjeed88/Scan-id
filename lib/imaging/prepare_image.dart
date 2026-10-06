import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../domain/validation.dart';
import 'image_header.dart';
import 'safe_png.dart';

class PreparedImage {
  const PreparedImage({
    required this.width,
    required this.height,
    required this.extension,
    required this.working,
    required this.thumbnail,
  });
  final int width;
  final int height;
  final String extension;
  final Uint8List working;
  final Uint8List thumbnail;
}

/// Must run in an isolate. Reject oversized headers before allocating pixels.
/// Only formats explicitly budgeted for here are accepted, regardless of name.
img.Image decodeForProcessing(Uint8List bytes) {
  final header = inspectImageHeader(bytes);
  final isJpeg = header.encoding == ImageEncoding.jpeg;
  try {
    final img.Image? decoded;
    if (isJpeg) {
      // Calling startDecode followed by decodeFrame would allocate JPEG DCT
      // blocks twice. Header dimensions were already checked without a codec.
      decoded = img.decodeJpg(bytes);
    } else {
      final decoder = img.PngDecoder();
      final info = decoder.startDecode(safePng(bytes));
      require(
        info != null &&
            info.width == header.width &&
            info.height == header.height,
        'ترويسة الصورة غير متطابقة.',
      );
      require(
        decoder.numFrames() == 1,
        'الصور المتحركة ومتعددة الصفحات غير مدعومة حالياً.',
      );
      decoded = decoder.decodeFrame(0);
    }
    if (decoded == null) {
      throw const ValidationException('تعذر فك ترميز الصورة.');
    }
    // JPEG decoding already applies EXIF. Do not clone a full-resolution
    // image merely to normalize an absent/identity orientation tag.
    final normalized = normalizeChannels(decoded);
    final orientation = normalized.exif.imageIfd.orientation;
    return orientation == null || orientation == 1
        ? normalized
        : img.bakeOrientation(normalized);
  } on ValidationException {
    rethrow;
  } catch (_) {
    throw const ValidationException('تعذر قراءة الصورة؛ قد يكون الملف تالفاً.');
  }
}

PreparedImage prepareImage(Uint8List bytes) {
  final header = inspectImageHeader(bytes);
  final isJpeg = header.encoding == ImageEncoding.jpeg;
  try {
    final normalized = decodeForProcessing(bytes);
    final working = img.encodePng(normalized);
    final thumbnail = img.copyResize(
      normalized,
      width: normalized.width >= normalized.height
          ? math.min(320, normalized.width)
          : null,
      height: normalized.height > normalized.width
          ? math.min(320, normalized.height)
          : null,
      interpolation: img.Interpolation.average,
    );
    return PreparedImage(
      width: normalized.width,
      height: normalized.height,
      extension: isJpeg ? 'jpg' : 'png',
      working: working,
      thumbnail: img.encodeJpg(thumbnail, quality: 82),
    );
  } on ValidationException {
    rethrow;
  } catch (_) {
    throw const ValidationException('تعذر قراءة الصورة؛ قد يكون الملف تالفاً.');
  }
}

/// image 4.5.4 exposes absent channels as zero for packed/16-bit pixels.
/// Expand grayscale/palettes and supply opaque alpha where needed so crops
/// and raster exports do not turn valid monochrome/RGB16 sources transparent.
/// Keep ordinary RGB8/RGBA images as-is to avoid an unnecessary large copy.
img.Image normalizeChannels(img.Image image) {
  if (image.hasPalette ||
      image.numChannels < 3 ||
      (image.format != img.Format.uint8 && image.numChannels == 3)) {
    return image.convert(
      format: image.format == img.Format.uint16
          ? img.Format.uint16
          : img.Format.uint8,
      numChannels: 4,
    );
  }
  return image;
}
