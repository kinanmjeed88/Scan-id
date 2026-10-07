import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/imaging/auto_adjustments.dart';

void main() {
  test(
    'auto enhancement is deterministic, bounded and leaves rotation alone',
    () {
      final image = img.Image(width: 160, height: 100);
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          final value = 35 + ((x + y) % 90);
          image.setPixelRgb(x, y, value, value, value);
        }
      }
      final bytes = img.encodePng(image);
      final first = suggestAutoAdjustments(bytes, quarterTurns: 2);
      final second = suggestAutoAdjustments(bytes, quarterTurns: 2);

      expect(first.toJson(), second.toJson());
      expect(first.brightness, inInclusiveRange(-.08, .08));
      expect(first.contrast, inInclusiveRange(1, 1.28));
      expect(first.saturation, inInclusiveRange(1, 1.08));
      expect(first.sharpness, inInclusiveRange(.07, .14));
      expect(first.quarterTurns, 2);
    },
  );
}
