import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/imaging/docaligner_model.dart';

void main() {
  test('preprocess uses direct 256 square resize and normalized BGR NCHW', () {
    final source = img.Image(width: 4, height: 2);
    img.fill(source, color: img.ColorRgb8(255, 64, 0));

    final input = DocAlignerFastViT.prepareBgrInput(source);
    const plane = 256 * 256;

    expect(input, hasLength(3 * plane));
    expect(input[0], 0); // blue plane first
    expect(input[plane], closeTo(64 / 255, 1e-6));
    expect(input[2 * plane], 1); // red plane last
    expect(input.every((value) => value >= 0 && value <= 1), isTrue);
  });

  test(
    'postprocess finds four largest thresholded corner blobs in model order',
    () {
      const width = 8;
      const height = 8;
      final heatmaps = List<double>.filled(4 * width * height, 0.0);
      void setBlob(int channel, int x, int y) {
        for (var dy = 0; dy < 2; dy++) {
          for (var dx = 0; dx < 2; dx++) {
            heatmaps[channel * width * height + (y + dy) * width + x + dx] = .8;
          }
        }
      }

      setBlob(0, 0, 0); // top-left
      setBlob(1, 6, 0); // top-right
      setBlob(2, 6, 6); // bottom-right
      setBlob(3, 0, 6); // bottom-left

      final points = DocAlignerFastViT.postprocessHeatmaps(
        heatmaps,
        width: width,
        height: height,
      );

      expect(points, isNotNull);
      final corners = points!;
      expect(corners, hasLength(4));
      expect(corners[0].x, closeTo(.125, 1e-9));
      expect(corners[0].y, closeTo(.125, 1e-9));
      expect(corners[1].x, closeTo(.875, 1e-9));
      expect(corners[1].y, closeTo(.125, 1e-9));
      expect(corners[2].x, closeTo(.875, 1e-9));
      expect(corners[2].y, closeTo(.875, 1e-9));
      expect(corners[3].x, closeTo(.125, 1e-9));
      expect(corners[3].y, closeTo(.875, 1e-9));
    },
  );

  test('postprocess refuses empty or malformed heatmap outputs', () {
    expect(
      DocAlignerFastViT.postprocessHeatmaps(
        List<double>.filled(4 * 8 * 8, 0),
        width: 8,
        height: 8,
      ),
      isNull,
    );
    expect(
      DocAlignerFastViT.postprocessHeatmaps(
        const [double.nan],
        width: 8,
        height: 8,
      ),
      isNull,
    );
  });
}
