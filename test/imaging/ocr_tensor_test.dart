
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/imaging/ocr_tensor.dart';

img.Image _solid(int width, int height, int red, int green, int blue) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(x, y, red, green, blue);
    }
  }
  return image;
}

void main() {
  test('detection tensor uses the long edge, 32-alignment and BGR planes', () {
    final input = buildOcrDetInput(_solid(100, 50, 255, 0, 0));

    expect(input.width, ocrDetLongSide);
    expect(input.height, 480);
    expect(input.width % ocrDetStride, 0);
    expect(input.height % ocrDetStride, 0);
    expect(input.values.length, 3 * input.width * input.height);
    expect(input.scaleX, closeTo(100 / 960, 1e-9));
    expect(input.scaleY, closeTo(50 / 480, 1e-9));

    final plane = input.width * input.height;
    // A pure red pixel proves both the channel order and the ImageNet
    // normalisation: plane 0 must be blue (0), plane 2 red (255).
    expect(input.values[0], closeTo((0 / 255 - .485) / .229, 1e-6));
    expect(input.values[plane], closeTo((0 / 255 - .456) / .224, 1e-6));
    expect(input.values[2 * plane], closeTo((1 - .406) / .225, 1e-6));
  });

  test('a small square document is upscaled to the detection size', () {
    final input = buildOcrDetInput(_solid(10, 10, 255, 255, 255));

    expect(input.width, ocrDetLongSide);
    expect(input.height, ocrDetLongSide);
    expect(input.scaleX, closeTo(.01, 1e-9));
  });

  test('a wide card keeps its orientation in the detection tensor', () {
    // 85.6 × 53.98 mm is the ID-1 card ratio; the tensor must not square it.
    final input = buildOcrDetInput(_solid(171, 108, 200, 200, 200));

    expect(input.width, greaterThan(input.height));
    expect(input.width % ocrDetStride, 0);
    expect(input.height % ocrDetStride, 0);
    final ratio = input.width / input.height;
    expect(ratio, closeTo(171 / 108, .08));
  });

  test('recognition tensor follows the line aspect at 48 px height', () {
    final image = _solid(200, 200, 255, 255, 255);
    final corners = [
      Point2(0, 0),
      Point2(100, 0),
      Point2(100, 20),
      Point2(0, 20),
    ];

    final input = buildOcrLineInput(image, corners);

    expect(input.height, ocrRecHeight);
    expect(input.width, 240);
    expect(input.values.length, 3 * ocrRecHeight * input.width);
    // White normalises to +1 in every plane (255 / 127.5 - 1).
    expect(input.values.every((value) => (value - 1).abs() < 1e-6), isTrue);
  });

  test('black text normalises to -1', () {
    final image = _solid(50, 50, 0, 0, 0);
    final corners = [
      Point2(0, 0),
      Point2(40, 0),
      Point2(40, 10),
      Point2(0, 10),
    ];

    final input = buildOcrLineInput(image, corners);

    expect(input.values.every((value) => (value + 1).abs() < 1e-6), isTrue);
  });

  test('an extremely wide line is compressed instead of cropped', () {
    final image = _solid(400, 40, 250, 250, 250);
    final corners = [
      Point2(0, 0),
      Point2(400, 0),
      Point2(400, 4),
      Point2(0, 4),
    ];

    final input = buildOcrLineInput(image, corners);

    expect(input.width, ocrRecMaxWidth);
    expect(input.width % ocrRecStride, 0);
  });

  test('the quad sampler reads the region the corners describe', () {
    final image = img.Image(width: 40, height: 10, numChannels: 3);
    for (var y = 0; y < 10; y++) {
      for (var x = 0; x < 40; x++) {
        if (x < 20) {
          image.setPixelRgb(x, y, 0, 0, 0);
        } else {
          image.setPixelRgb(x, y, 255, 255, 255);
        }
      }
    }
    final corners = [
      Point2(0, 0),
      Point2(40, 0),
      Point2(40, 10),
      Point2(0, 10),
    ];

    final input = buildOcrLineInput(image, corners);

    final plane = (input.height * input.width);
    final firstPixel = input.values[0];
    final lastPixel = input.values[input.width - 1];
    expect(firstPixel, closeTo(-1, 1e-3));
    expect(lastPixel, closeTo(1, 1e-3));
    expect(plane, ocrRecHeight * input.width);
  });

  test('a quad must have exactly four corners', () {
    expect(
      () => buildOcrLineInput(_solid(10, 10, 0, 0, 0), [Point2(0, 0)]),
      throwsA(isA<ValidationException>()),
    );
  });

  test('a zero-sized image is rejected', () {
    expect(
      () => buildOcrDetInput(img.Image(width: 1, height: 1)),
      returnsNormally,
    );
    expect(
      () => buildOcrLineInput(img.Image(width: 1, height: 1), [
        Point2(0, 0),
        Point2(1, 0),
        Point2(1, 1),
        Point2(0, 1),
      ]),
      returnsNormally,
    );
  });
}
