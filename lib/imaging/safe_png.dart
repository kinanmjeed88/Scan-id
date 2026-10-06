import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../domain/validation.dart';
import 'image_header.dart';

/// Validate PNG inflation with native streaming zlib BEFORE image's codec
/// accumulates a full decompressed IDAT buffer. Originals remain unchanged.
Uint8List safePng(Uint8List bytes) {
  try {
    return _safePng(bytes);
  } on ValidationException {
    rethrow;
  } catch (_) {
    throw const ValidationException('PNG تالف أو مضغوط بصورة غير صالحة.');
  }
}

Uint8List _safePng(Uint8List bytes) {
  require(
    bytes.length >= 33 && bytes.length <= 128 * 1024 * 1024,
    'حجم PNG غير صالح.',
  );
  final header = inspectImageHeader(Uint8List.sublistView(bytes, 0, 33));
  require(header.encoding == ImageEncoding.png, 'يلزم PNG.');
  final view = ByteData.sublistView(bytes);
  final bits = bytes[24], type = bytes[25], interlace = bytes[28];
  const validBits = {
    0: [1, 2, 4, 8, 16],
    2: [8, 16],
    3: [1, 2, 4, 8],
    4: [8, 16],
    6: [8, 16],
  };
  require(
    validBits[type]?.contains(bits) == true &&
        bytes[26] == 0 &&
        bytes[27] == 0 &&
        interlace <= 1,
    'ترميز PNG غير مدعوم.',
  );
  final channels = const {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[type]!;
  var expected = 0;
  final passes = interlace == 0
      ? [
          [0, 0, 1, 1],
        ]
      : [
          [0, 0, 8, 8],
          [4, 0, 8, 8],
          [0, 4, 4, 8],
          [2, 0, 4, 4],
          [0, 2, 2, 4],
          [1, 0, 2, 2],
          [0, 1, 1, 2],
        ];
  for (final pass in passes) {
    final w = header.width <= pass[0]
        ? 0
        : (header.width - pass[0] + pass[2] - 1) ~/ pass[2];
    final h = header.height <= pass[1]
        ? 0
        : (header.height - pass[1] + pass[3] - 1) ~/ pass[3];
    if (w > 0 && h > 0) {
      expected += h * (1 + (w * channels * bits + 7) ~/ 8);
    }
  }
  final expanded = _Budget(expected);
  final inflater = ZLibDecoder().startChunkedConversion(expanded);
  final output = BytesBuilder(copy: false)
    ..add(Uint8List.sublistView(bytes, 0, 8));
  var offset = 8, count = 0, metadata = 0;
  var seenData = false,
      endedData = false,
      ended = false,
      seenPalette = false,
      seenProfile = false;
  while (offset < bytes.length) {
    require(
      ++count <= 4096 && offset + 12 <= bytes.length,
      'مقاطع PNG ناقصة أو كثيرة جداً.',
    );
    final size = view.getUint32(offset);
    require(size <= bytes.length - offset - 12, 'طول مقطع PNG غير صالح.');
    final end = offset + 12 + size;
    final tag = ascii.decode(
      Uint8List.sublistView(bytes, offset + 4, offset + 8),
    );
    require(RegExp(r'^[A-Za-z]{4}$').hasMatch(tag), 'اسم مقطع PNG غير صالح.');
    require(
      _crc(bytes, offset + 4, end - 4) == view.getUint32(end - 4),
      'فشل تحقق CRC لصورة PNG.',
    );
    final data = Uint8List.sublistView(bytes, offset + 8, end - 4);
    if (tag != 'IDAT' && seenData) {
      endedData = true;
    }
    var keep = true;
    switch (tag) {
      case 'IHDR':
        require(offset == 8 && size == 13, 'ترويسة PNG مكررة.');
      case 'IDAT':
        require(
          !endedData && (type != 3 || seenPalette),
          'ترتيب مقاطع PNG غير صالح.',
        );
        seenData = true;
        inflater.add(data);
      case 'IEND':
        require(
          size == 0 && seenData && end == bytes.length,
          'نهاية PNG غير صالحة.',
        );
        inflater.close();
        require(expanded.count == expected, 'بيانات PNG ناقصة.');
        ended = true;
      case 'PLTE':
        require(
          !seenPalette && !seenData && size > 0 && size <= 768 && size % 3 == 0,
          'لوحة PNG غير صالحة.',
        );
        seenPalette = true;
      case 'tRNS':
        require(!seenData && size <= 256, 'شفافية PNG غير صالحة.');
      case 'iCCP':
        require(
          !seenProfile && !seenData && size <= 1024 * 1024,
          'ملف ألوان PNG كبير أو مكرر.',
        );
        seenProfile = true;
        final zero = data.indexOf(0);
        require(
          zero > 0 && zero <= 79 && zero + 2 < size && data[zero + 1] == 0,
          'ملف ألوان PNG غير صالح.',
        );
        final budget = _Budget(4 * 1024 * 1024);
        final profile = ZLibDecoder().startChunkedConversion(budget);
        profile.add(Uint8List.sublistView(data, zero + 2));
        profile.close();
      case 'gAMA':
        require(size == 4, 'قيمة gamma غير صالحة.');
      case 'sRGB':
        require(size == 1, 'قيمة sRGB غير صالحة.');
      case 'cHRM':
        require(size == 32, 'قيمة cHRM غير صالحة.');
      case 'pHYs':
        require(size == 9, 'قيمة pHYs غير صالحة.');
      case 'acTL':
      case 'fcTL':
      case 'fdAT':
        throw const ValidationException('PNG المتحرك غير مدعوم.');
      default:
        require((bytes[offset + 4] & 32) != 0, 'مقطع PNG أساسي غير مدعوم.');
        // Do not let ancillary text or private metadata reach codec parsers.
        // The untouched original still contains every original byte.
        keep = false;
    }
    if (tag != 'IDAT') {
      metadata += size;
      require(metadata <= 2 * 1024 * 1024, 'بيانات PNG الإضافية كبيرة جداً.');
    }
    if (keep) {
      output.add(Uint8List.sublistView(bytes, offset, end));
    }
    offset = end;
  }
  require(ended, 'نهاية PNG مفقودة.');
  return output.length == bytes.length ? bytes : output.takeBytes();
}

class _Budget extends ByteConversionSinkBase {
  _Budget(this.limit);
  final int limit;
  int count = 0;
  @override
  void add(List<int> data) => addSlice(data, 0, data.length, false);
  @override
  void addSlice(List<int> data, int start, int end, bool isLast) {
    count += end - start;
    require(count <= limit, 'توسع PNG المضغوط يتجاوز الحجم المسموح.');
  }

  @override
  void close() {}
}

final _table = List<int>.generate(256, (i) {
  var value = i;
  for (var bit = 0; bit < 8; bit++) {
    value = (value & 1) == 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  }
  return value;
});
int _crc(Uint8List bytes, int start, int end) {
  var value = 0xffffffff;
  for (var i = start; i < end; i++) {
    value = _table[(value ^ bytes[i]) & 255] ^ (value >>> 8);
  }
  return (value ^ 0xffffffff) & 0xffffffff;
}
