import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/imaging/safe_png.dart';
import 'package:scan_id/imaging/prepare_image.dart';
import '../fixtures/png_cases.dart';

void main() {
  test(
    'IDAT expansion is rejected before the image codec can accumulate it',
    () {
      expect(
        () => safePng(base64Decode(pixelBomb)),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'limit',
            contains('توسع'),
          ),
        ),
      );
    },
  );
  test(
    'compressed ICC expansion is bounded independently of pixel dimensions',
    () {
      expect(
        () => safePng(base64Decode(profileBomb)),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'limit',
            contains('توسع'),
          ),
        ),
      );
    },
  );
  test(
    'narrow Adam7 retains every sample for all filters and packed/16-bit pixels',
    () {
      for (final entry in narrowPngs.entries) {
        final parts = entry.key.split('-').map(int.parse).toList();
        final width = parts[0], bits = parts[1], color = parts[2];
        final maximum = (1 << bits) - 1;
        final original = base64Decode(entry.value);
        final decoded = decodeForProcessing(original);
        expect([decoded.width, decoded.height], [width, 17]);
        for (var y = 0; y < 17; y++) {
          for (var x = 0; x < width; x++) {
            final pixel = decoded.getPixel(x, y);
            final actual = [
              pixel.rNormalized,
              pixel.gNormalized,
              pixel.bNormalized,
              pixel.aNormalized,
            ];
            for (var c = 0; c < 4; c++) {
              final channel = color == 0 ? 0 : c;
              final expected = c == 3 && color != 6
                  ? 1.0
                  : ((x * 31 + y * 7 + channel * 19) & maximum) / maximum;
              expect(
                actual[c],
                closeTo(expected, 1e-6),
                reason: '${entry.key} pixel $x,$y channel $c',
              );
            }
          }
        }
        expect(original, base64Decode(entry.value));
      }
    },
  );
  test('valid Adam7 and 16-bit PNGs retain their pixel content', () {
    final a = decodeForProcessing(base64Decode(adam7));
    expect([a.width, a.height], [2, 2]);
    expect(safePng(base64Decode(adam7))[28], 0);
    expect(a.getPixel(0, 0).r, 255);
    expect(a.getPixel(1, 1).r, 255);
    expect(a.getPixel(1, 1).g, 255);
    expect(a.getPixel(1, 1).b, 255);
    expect(a.getPixel(0, 1).g, 255);
    expect(a.getPixel(1, 0).b, 255);
    final b = decodeForProcessing(base64Decode(sixteenBit));
    expect(b.getPixel(0, 0).rNormalized, 1);
    expect(b.getPixel(0, 0).bNormalized, closeTo(.5, .001));
  });
  test(
    'changed CRC and truncated tails are rejected without modifying input',
    () {
      final original = base64Decode(sixteenBit);
      final bad = base64Decode(sixteenBit)..[29] ^= 1;
      expect(() => safePng(bad), throwsA(isA<ValidationException>()));
      expect(
        () => safePng(original.sublist(0, original.length - 1)),
        throwsA(isA<ValidationException>()),
      );
      expect(original, base64Decode(sixteenBit));
    },
  );
}
