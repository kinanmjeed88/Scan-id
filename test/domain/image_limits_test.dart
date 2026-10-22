import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/image_limits.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/imaging/image_header.dart';

void main() {
  const validJpegSizes = <(int, int)>[
    (1, 1),
    (65535, 1),
    (1, 65535),
    (65535, 488),
    (488, 65535),
    (8000, 4000),
    (4000, 8000),
  ];
  final invalidJpegSizes = <(int, int)>[
    (0, 1),
    (1, 0),
    (-1, 1),
    (1, -1),
    (65536, 1),
    (1, 65536),
    (65535, 489),
    (489, 65535),
    (8001, 4000),
    (4000, 8001),
    (1 << 32, 1 << 32),
    (1 << 62, 4),
    (4, 1 << 62),
  ];

  test('JPEG format and inclusive source pixel limits remain unchanged', () {
    for (final (width, height) in validJpegSizes) {
      expect(withinScalableJpegSourceBudget(width, height), isTrue);
      final header = ImageHeader(ImageEncoding.jpeg, width, height);
      expect((header.width, header.height), (width, height));
    }
  });

  test('JPEG dimensions are bounded before multiplying untrusted integers', () {
    for (final (width, height) in invalidJpegSizes) {
      expect(withinScalableJpegSourceBudget(width, height), isFalse);
      expect(
        () => ImageHeader(ImageEncoding.jpeg, width, height),
        throwsA(isA<ValidationException>()),
      );
    }
  });

  test('the JPEG side limit does not restrict valid narrow PNG sources', () {
    for (final (width, height) in [(65536, 1), (1, 65536)]) {
      expect(withinScalableJpegSourceBudget(width, height), isFalse);
      expect(withinImageBudget(width, height), isTrue);
      final header = ImageHeader(ImageEncoding.png, width, height);
      expect((header.width, header.height), (width, height));
    }
  });

  test('direct processing stays at 16 MP while JPEG sources may reach 32 MP', () {
    expect(withinImageBudget(4000, 4000), isTrue);
    expect(withinImageBudget(8000, 4000), isFalse);
    expect(withinScalableJpegSourceBudget(8000, 4000), isTrue);
    expect(withinScalableJpegSourceBudget(8001, 4000), isFalse);
  });
}
