import 'dart:typed_data';

import '../domain/image_limits.dart';
import '../domain/validation.dart';

enum ImageEncoding { jpeg, png }

class ImageHeader {
  ImageHeader(this.encoding, this.width, this.height) {
    require(
      withinImageBudget(width, height),
      'الصورة تتجاوز حد المعالجة (16 مليون بكسل).',
    );
  }
  final ImageEncoding encoding;
  final int width;
  final int height;
}

/// Inspect only bounded header fields, before calling image's codecs.
/// In image 4.5.4, even JpegDecoder.startDecode allocates DCT block storage!
/// This preflight is essential; a codec's "info" method is not a memory guard.
/// It is not a complete validation of compressed pixel data or metadata.
ImageHeader inspectImageHeader(Uint8List bytes) {
  require(
    bytes.isNotEmpty && bytes.length <= maxImportBytes,
    'الصورة فارغة أو أكبر من حد الاستيراد (20 MiB).',
  );
  const pngSignature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length >= 8 &&
      List.generate(8, (i) => bytes[i] == pngSignature[i]).every((v) => v)) {
    require(bytes.length >= 33, 'ترويسة PNG ناقصة.');
    final view = ByteData.sublistView(bytes);
    require(
      view.getUint32(8) == 13 && view.getUint32(12) == 0x49484452,
      'ترويسة PNG غير صالحة.',
    );
    return ImageHeader(
      ImageEncoding.png,
      view.getUint32(16),
      view.getUint32(20),
    );
  }
  require(
    bytes.length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8,
    'الصيغ المدعومة حالياً هي JPEG وPNG فقط.',
  );
  var offset = 2;
  while (offset < bytes.length) {
    require(bytes[offset] == 0xff, 'علامة JPEG غير صالحة.');
    while (offset < bytes.length && bytes[offset] == 0xff) {
      offset++;
    }
    require(offset < bytes.length, 'ترويسة JPEG ناقصة.');
    final marker = bytes[offset++];
    if (marker == 0xd9 || marker == 0xda) {
      break;
    }
    // TEM and restart markers have no length field.
    if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      continue;
    }
    require(offset + 2 <= bytes.length, 'ترويسة JPEG ناقصة.');
    final length = bytes[offset] * 256 + bytes[offset + 1];
    require(
      length >= 2 && offset + length <= bytes.length,
      'طول مقطع JPEG غير صالح.',
    );
    final isFrame =
        marker >= 0xc0 &&
        marker <= 0xcf &&
        marker != 0xc4 &&
        marker != 0xc8 &&
        marker != 0xcc;
    if (isFrame) {
      require(
        marker == 0xc0 || marker == 0xc1 || marker == 0xc2,
        'نوع ترميز JPEG غير مدعوم.',
      );
      require(length >= 8, 'ترويسة أبعاد JPEG ناقصة.');
      final header = ImageHeader(
        ImageEncoding.jpeg,
        bytes[offset + 5] * 256 + bytes[offset + 6],
        bytes[offset + 3] * 256 + bytes[offset + 4],
      );
      final channels = bytes[offset + 7];
      require(
        bytes[offset + 2] == 8 &&
            [1, 3, 4].contains(channels) &&
            length == 8 + 3 * channels,
        'بنية ألوان JPEG غير مدعومة.',
      );
      var blocks = 0;
      for (var component = 0; component < channels; component++) {
        final sampling = bytes[offset + 9 + 3 * component];
        final horizontal = sampling >> 4;
        final vertical = sampling & 15;
        require(
          horizontal >= 1 && horizontal <= 4 && vertical >= 1 && vertical <= 4,
          'معامل عينات JPEG غير صالح.',
        );
        blocks += horizontal * vertical;
      }
      require(blocks <= 10, 'ترميز JPEG يتجاوز حد العينات المدعوم.');
      return header;
    }
    offset += length;
  }
  throw const ValidationException('لم يُعثر على أبعاد JPEG صالحة.');
}
