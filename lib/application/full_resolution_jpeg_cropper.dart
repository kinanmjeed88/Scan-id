/// Bounded native extraction of one region from a large JPEG source.
///
/// Recognition measures regions on a sampled, EXIF-normalized working image.
/// This contract asks the platform decoder to extract that same normalized
/// rectangle from the immutable JPEG at its native pixel density, without
/// materialising the complete source raster in Dart. The returned crop is PNG
/// and is deliberately bounded by the ordinary processing/image-transfer
/// limits; a region that itself exceeds that safe budget is rejected explicitly
/// rather than sampled down and described as full resolution.
library;

import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../domain/image_limits.dart';
import '../domain/validation.dart';

/// Platform service for a full-density rectangular JPEG region.
///
/// [left], [top], [right] and [bottom] are normalized against the JPEG after
/// its EXIF orientation is applied. They are the measured bounds from the
/// segmenter, not a guessed document rectangle. Implementations must preserve
/// density and reject (never downsample) a region that cannot fit within
/// [maxImportPixels].
abstract interface class FullResolutionJpegCropper {
  Future<Uint8List> cropJpegRegion({
    required Uint8List source,
    required int sourceWidth,
    required int sourceHeight,
    required int orientation,
    required double left,
    required double top,
    required double right,
    required double bottom,
  });
}

/// Android and Windows implementation backed by the bounded native JPEG
/// channel. The platform side owns JPEG region decoding so Dart never decodes a
/// 16–32 MP source merely to keep one detected document.
class PlatformFullResolutionJpegCropper
    implements FullResolutionJpegCropper {
  const PlatformFullResolutionJpegCropper({this.channel = _channel});

  static const MethodChannel _channel = MethodChannel('iq.scanid/large_jpeg');
  final MethodChannel channel;

  @override
  Future<Uint8List> cropJpegRegion({
    required Uint8List source,
    required int sourceWidth,
    required int sourceHeight,
    required int orientation,
    required double left,
    required double top,
    required double right,
    required double bottom,
  }) async {
    require(
      source.isNotEmpty &&
          source.length <= maxImportBytes &&
          sourceWidth > 0 &&
          sourceHeight > 0 &&
          sourceWidth * sourceHeight <= maxScalableJpegSourcePixels &&
          orientation >= 1 &&
          orientation <= 8 &&
          [left, top, right, bottom].every((value) => value.isFinite) &&
          left >= 0 &&
          top >= 0 &&
          right <= 1 &&
          bottom <= 1 &&
          left < right &&
          top < bottom,
      'منطقة JPEG كاملة الدقة غير صالحة.',
    );
    try {
      final result = await channel
          .invokeMethod<Uint8List>('cropJpegRegion', <String, Object>{
            'bytes': source,
            'sourceWidth': sourceWidth,
            'sourceHeight': sourceHeight,
            'orientation': orientation,
            'left': left,
            'top': top,
            'right': right,
            'bottom': bottom,
            'maxPixels': maxImportPixels,
          });
      if (result == null) {
        throw const ValidationException('تعذر استخراج منطقة JPEG كاملة الدقة.');
      }
      require(
        result.isNotEmpty && result.length <= maxImportBytes,
        'منطقة JPEG كاملة الدقة تجاوزت حد النقل الآمن.',
      );
      return result;
    } on PlatformException catch (error) {
      final reason = switch (error.code) {
        'crop_too_large' =>
          'المنطقة المطلوبة أكبر من حد المعالجة كاملة الدقة (16 مليون بكسل).',
        'out_of_memory' =>
          'لا توجد ذاكرة كافية لاستخراج المنطقة كاملة الدقة بأمان.',
        'busy' => 'معالج JPEG الأصلي مشغول؛ أعد المحاولة.',
        'cancelled' => 'أُلغي استخراج المنطقة كاملة الدقة.',
        _ => 'تعذر استخراج المنطقة كاملة الدقة بأمان على هذا الجهاز.',
      };
      throw ValidationException(reason);
    } on MissingPluginException {
      throw const ValidationException(
        'لا تتوفر معالجة JPEG كاملة الدقة على هذا النظام؛ لا يمكن متابعة التقسيم دون تخفيض الدقة.',
      );
    }
  }
}
