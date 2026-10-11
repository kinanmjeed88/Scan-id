import 'dart:typed_data';

import '../domain/image_limits.dart';
import '../domain/validation.dart';

enum ImageEncoding { jpeg, png }

class ImageHeader {
  ImageHeader(this.encoding, this.width, this.height, {this.orientation = 1}) {
    require(
      width > 0 && height > 0 && width <= 65535 && height <= 65535,
      'أبعاد الصورة خارج المجال المدعوم.',
    );
    require(orientation >= 1 && orientation <= 8, 'اتجاه JPEG غير صالح.');
    if (encoding == ImageEncoding.jpeg) {
      require(
        width * height <= maxScalableJpegSourcePixels,
        'صورة JPEG تتجاوز حد المصدر الآمن (32 مليون بكسل).',
      );
    }
  }
  final ImageEncoding encoding;
  final int width;
  final int height;

  /// EXIF orientation; large-image native decoders bake it into the working
  /// image before returning pixels. One means no transform.
  final int orientation;
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
  var orientation = 1;
  int? frameWidth;
  int? frameHeight;
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
    if (marker == 0xe1) {
      orientation =
          _exifOrientation(bytes, offset + 2, offset + length) ?? orientation;
    }
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
      require(frameWidth == null, 'ترويسة JPEG تحتوي أكثر من إطار.');
      frameWidth = bytes[offset + 5] * 256 + bytes[offset + 6];
      frameHeight = bytes[offset + 3] * 256 + bytes[offset + 4];
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
    }
    offset += length;
  }
  if (frameWidth != null && frameHeight != null) {
    return ImageHeader(
      ImageEncoding.jpeg,
      frameWidth,
      frameHeight,
      orientation: orientation,
    );
  }
  throw const ValidationException('لم يُعثر على أبعاد JPEG صالحة.');
}

/// Reads the bounded TIFF Orientation tag inside one APP1 segment. Malformed
/// EXIF is ignored like the image decoder does: it never changes the source
/// dimensions or creates an orientation guess.
int? _exifOrientation(Uint8List bytes, int start, int end) {
  const signature = [0x45, 0x78, 0x69, 0x66, 0, 0];
  if (end - start < 14 ||
      !List.generate(
        6,
        (index) => bytes[start + index] == signature[index],
      ).every((matches) => matches)) {
    return null;
  }
  final tiff = start + 6;
  final littleEndian = bytes[tiff] == 0x49 && bytes[tiff + 1] == 0x49;
  if (!littleEndian && !(bytes[tiff] == 0x4d && bytes[tiff + 1] == 0x4d)) {
    return null;
  }

  int read16(int offset) {
    if (offset < tiff || offset + 2 > end) return -1;
    return littleEndian
        ? bytes[offset] | (bytes[offset + 1] << 8)
        : (bytes[offset] << 8) | bytes[offset + 1];
  }

  int read32(int offset) {
    if (offset < tiff || offset + 4 > end) return -1;
    return littleEndian
        ? bytes[offset] |
              (bytes[offset + 1] << 8) |
              (bytes[offset + 2] << 16) |
              (bytes[offset + 3] << 24)
        : (bytes[offset] << 24) |
              (bytes[offset + 1] << 16) |
              (bytes[offset + 2] << 8) |
              bytes[offset + 3];
  }

  if (read16(tiff + 2) != 42) return null;
  final relativeIfd = read32(tiff + 4);
  if (relativeIfd < 8) return null;
  final ifd = tiff + relativeIfd;
  final entries = read16(ifd);
  if (entries < 0) return null;
  for (var index = 0; index < entries; index++) {
    final entry = ifd + 2 + index * 12;
    if (entry + 12 > end) return null;
    if (read16(entry) != 0x0112 ||
        read16(entry + 2) != 3 ||
        read32(entry + 4) != 1) {
      continue;
    }
    final value = read16(entry + 8);
    return value >= 1 && value <= 8 ? value : null;
  }
  return null;
}
