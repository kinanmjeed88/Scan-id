import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../domain/validation.dart';
import '../imaging/large_jpeg_plan.dart';

/// A platform decoder which reduces JPEG samples before they reach Dart.
///
/// Implementations must not decode the complete source raster and resize it
/// afterwards. Android uses BitmapFactory sampling and Windows uses WIC's
/// source-transform decode. Other platforms fail closed.
abstract interface class LargeJpegScaler {
  Future<Uint8List> scaleJpeg(Uint8List source, LargeJpegPlan plan);
}

class PlatformLargeJpegScaler implements LargeJpegScaler {
  const PlatformLargeJpegScaler({this.channel = _channel});

  static const MethodChannel _channel = MethodChannel('iq.scanid/large_jpeg');
  final MethodChannel channel;

  @override
  Future<Uint8List> scaleJpeg(Uint8List source, LargeJpegPlan plan) async {
    try {
      final result = await channel
          .invokeMethod<Uint8List>('scaleJpeg', <String, Object>{
            'bytes': source,
            'sourceWidth': plan.sourceWidth,
            'sourceHeight': plan.sourceHeight,
            'orientation': plan.orientation,
            'targetWidth': plan.targetWidth,
            'targetHeight': plan.targetHeight,
            'maxPixels': plan.targetPixels,
          });
      if (result == null) {
        throw const ValidationException('تعذر تصغير صورة JPEG بأمان.');
      }
      return result;
    } on PlatformException {
      throw const ValidationException(
        'تعذر تصغير صورة JPEG الكبيرة بأمان على هذا الجهاز؛ '
        'استورد صورة أصغر أو احفظها بصيغة JPEG مدعومة.',
      );
    } on MissingPluginException {
      throw const ValidationException(
        'لا يتوفر فك JPEG كبير آمن على هذا النظام؛ استورد صورة أصغر.',
      );
    }
  }
}
