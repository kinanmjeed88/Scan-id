import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../domain/image_limits.dart';
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
  require(
    withinImageBudget(header.width, header.height),
    'الصورة تتجاوز حد المعالجة المباشرة (16 مليون بكسل).',
  );
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

/// Prepares an already platform-downsampled PNG without re-encoding its
/// working pixels. The original JPEG remains stored separately and unchanged.
PreparedImage prepareScaledWorkingPng(Uint8List bytes) {
  final header = inspectImageHeader(bytes);
  require(
    header.encoding == ImageEncoding.png &&
        header.width * header.height <= maxScaledWorkingPixels,
    'نتيجة تصغير الصورة غير صالحة أو تتجاوز حد البكسلات.',
  );
  final image = decodeForProcessing(bytes);
  final thumbnail = img.copyResize(
    image,
    width: image.width >= image.height ? math.min(320, image.width) : null,
    height: image.height > image.width ? math.min(320, image.height) : null,
    interpolation: img.Interpolation.average,
  );
  return PreparedImage(
    width: image.width,
    height: image.height,
    extension: 'png',
    working: bytes,
    thumbnail: img.encodeJpg(thumbnail, quality: 82),
  );
}

/// Produces a bounded display preview after header-gated decoding. Large JPEG
/// callers must first use the native sampled path; this function never receives
/// an over-budget source raster.
Uint8List prepareBoundedPreview(Uint8List bytes) {
  final image = decodeForProcessing(bytes);
  final reduced = img.copyResize(
    image,
    width: image.width >= image.height
        ? math.min(maxRecognitionPreviewLongEdge, image.width)
        : null,
    height: image.height > image.width
        ? math.min(maxRecognitionPreviewLongEdge, image.height)
        : null,
    interpolation: img.Interpolation.average,
  );
  return Uint8List.fromList(img.encodePng(reduced));
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
