import 'dart:typed_data';

import '../domain/image_limits.dart';
import '../domain/validation.dart';

Future<Uint8List> readBoundedImage(Stream<List<int>> stream) async {
  final builder = BytesBuilder();
  await for (final chunk in stream) {
    require(
      builder.length + chunk.length <= maxImportBytes,
      'الصورة أكبر من حد الاستيراد (20 MiB).',
    );
    builder.add(chunk);
  }
  return builder.takeBytes();
}
