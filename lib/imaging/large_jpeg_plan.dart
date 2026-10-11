import 'dart:math' as math;

import '../domain/image_limits.dart';
import '../domain/validation.dart';
import 'image_header.dart';

/// Explicit, aspect-preserving resource plan for the native sampled JPEG path.
///
/// The normal Dart codecs still accept at most [maxImportPixels]. Only JPEGs
/// above that ceiling and no larger than [maxScalableJpegSourcePixels] enter
/// this path; a platform decoder must downsample before returning pixels. The
/// 4 MP cap bounds the working raster and leaves PNG as an explicit rejection
/// when no safe scaled PNG decoder is available.
class LargeJpegPlan {
  LargeJpegPlan._({
    required this.sourceWidth,
    required this.sourceHeight,
    required this.orientation,
    required this.targetWidth,
    required this.targetHeight,
  });

  factory LargeJpegPlan.fromHeader(ImageHeader header) {
    require(
      header.encoding == ImageEncoding.jpeg,
      'للمعالجة الكبيرة الآمنة، استخدم JPEG؛ لا يمكن تصغير PNG بأمان هنا.',
    );
    final sourcePixels = header.width * header.height;
    require(
      sourcePixels > maxImportPixels,
      'لا تحتاج الصورة إلى مسار التصغير الكبير.',
    );
    require(
      sourcePixels <= maxScalableJpegSourcePixels,
      'صورة JPEG تتجاوز حد المصدر الآمن (32 مليون بكسل).',
    );
    final scale = math.sqrt(maxScaledWorkingPixels / sourcePixels);
    final width = math.max(1, (header.width * scale).floor());
    final height = math.max(1, (header.height * scale).floor());
    require(
      width <= header.width &&
          height <= header.height &&
          width * height <= maxScaledWorkingPixels,
      'تعذر وضع الصورة ضمن حد المعالجة الآمن.',
    );
    final longEdge = math.max(width, height);
    final shortEdge = math.min(width, height);
    // Reject only when the existing 1200 px preview pipeline would fall below
    // the segmenter's own 40 px minimum on its short edge; no new CV threshold
    // is introduced by the scaler.
    final previewShortEdge =
        (shortEdge * math.min(1, maxRecognitionPreviewLongEdge / longEdge))
            .floor();
    require(
      previewShortEdge >= minRecognitionPreviewSide,
      'أبعاد JPEG تصبح أصغر من حد التحليل بعد التصغير الآمن؛ '
      'استورد نسخة أقل استطالة أو أصغر حجماً.',
    );
    return LargeJpegPlan._(
      sourceWidth: header.width,
      sourceHeight: header.height,
      orientation: header.orientation,
      targetWidth: width,
      targetHeight: height,
    );
  }

  final int sourceWidth;
  final int sourceHeight;
  final int orientation;
  final int targetWidth;
  final int targetHeight;

  int get targetPixels => targetWidth * targetHeight;

  /// Short audit text stored alongside the untouched original bytes.
  String get transformNote =>
      'large-jpeg:${sourceWidth}x${sourceHeight}->${targetWidth}x${targetHeight}-exif$orientation';
}
