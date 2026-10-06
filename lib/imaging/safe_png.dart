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
  final clean = output.length == bytes.length ? bytes : output.takeBytes();
  // image 4.5.4 consumes a filter byte for Adam7 passes with zero width.
  // Normalize narrow images to standard non-interlaced PNG before that codec.
  return interlace == 1 && header.width < 5
      ? _deinterlaceNarrow(
          clean,
          header.width,
          header.height,
          channels * bits,
          passes,
        )
      : clean;
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

Uint8List _chunk(String tag, List<int> data) {
  final bytes = Uint8List(data.length + 12);
  final view = ByteData.sublistView(bytes);
  view.setUint32(0, data.length);
  bytes.setRange(4, 8, ascii.encode(tag));
  bytes.setRange(8, 8 + data.length, data);
  view.setUint32(bytes.length - 4, _crc(bytes, 4, bytes.length - 4));
  return bytes;
}

/// Called only after CRC, dimensions and exact expanded size are validated.
/// Output is a standards-compliant PNG; no invented empty-pass scanlines are
/// fed to the codec, and the user's original is never rewritten.
Uint8List _deinterlaceNarrow(
  Uint8List bytes,
  int width,
  int height,
  int depth,
  List<List<int>> passes,
) {
  final packed = BytesBuilder(copy: false);
  final result = BytesBuilder(copy: false)
    ..add(Uint8List.sublistView(bytes, 0, 8));
  final view = ByteData.sublistView(bytes);
  for (var offset = 8; offset < bytes.length;) {
    final size = view.getUint32(offset);
    final tag = ascii.decode(
      Uint8List.sublistView(bytes, offset + 4, offset + 8),
    );
    final data = Uint8List.sublistView(bytes, offset + 8, offset + 8 + size);
    if (tag == 'IDAT') {
      packed.add(data);
    } else if (tag == 'IHDR') {
      final header = Uint8List.fromList(data)..[12] = 0;
      result.add(_chunk(tag, header));
    } else if (tag != 'IEND') {
      result.add(Uint8List.sublistView(bytes, offset, offset + size + 12));
    }
    offset += size + 12;
  }
  final raw = ZLibDecoder().convert(packed.takeBytes());
  final stride = 1 + (width * depth + 7) ~/ 8;
  final rows = Uint8List(height * stride);
  final bpp = (depth + 7) ~/ 8;
  var input = 0;
  for (final pass in passes) {
    final pw = width <= pass[0]
        ? 0
        : (width - pass[0] + pass[2] - 1) ~/ pass[2];
    final ph = height <= pass[1]
        ? 0
        : (height - pass[1] + pass[3] - 1) ~/ pass[3];
    if (pw == 0 || ph == 0) {
      continue;
    }
    final rowBytes = (pw * depth + 7) ~/ 8;
    var previous = Uint8List(rowBytes);
    for (var y = 0; y < ph; y++) {
      final filter = raw[input++];
      require(filter <= 4, 'مرشح PNG غير صالح.');
      final row = Uint8List.fromList(raw.sublist(input, input + rowBytes));
      input += rowBytes;
      for (var i = 0; i < rowBytes; i++) {
        final a = i < bpp ? 0 : row[i - bpp];
        final b = previous[i];
        final c = i < bpp ? 0 : previous[i - bpp];
        var prediction = 0;
        if (filter == 1) {
          prediction = a;
        }
        if (filter == 2) {
          prediction = b;
        }
        if (filter == 3) {
          prediction = (a + b) ~/ 2;
        }
        if (filter == 4) {
          final p = a + b - c;
          final da = (p - a).abs(), db = (p - b).abs(), dc = (p - c).abs();
          prediction = da <= db && da <= dc
              ? a
              : db <= dc
              ? b
              : c;
        }
        row[i] = (row[i] + prediction) & 255;
      }
      final targetRow = (pass[1] + y * pass[3]) * stride + 1;
      for (var x = 0; x < pw; x++) {
        final targetX = pass[0] + x * pass[2];
        if (depth < 8) {
          final bit = x * depth;
          final value =
              (row[bit ~/ 8] >> (8 - depth - bit % 8)) & ((1 << depth) - 1);
          final targetBit = targetX * depth;
          rows[targetRow + targetBit ~/ 8] |=
              value << (8 - depth - targetBit % 8);
        } else {
          rows.setRange(
            targetRow + targetX * bpp,
            targetRow + (targetX + 1) * bpp,
            row,
            x * bpp,
          );
        }
      }
      previous = row;
    }
  }
  require(input == raw.length, 'بيانات Adam7 غير متطابقة.');
  result.add(_chunk('IDAT', ZLibEncoder().convert(rows)));
  result.add(_chunk('IEND', Uint8List(0)));
  return result.takeBytes();
}
