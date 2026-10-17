import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/imaging/document_segmenter.dart';

img.Image _background(int width, int height) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(45, 55, 70));
  return image;
}

void _card(img.Image image, int x1, int y1, int x2, int y2) {
  img.fillRect(
    image,
    x1: x1,
    y1: y1,
    x2: x2,
    y2: y2,
    color: img.ColorRgb8(235, 233, 228),
  );
}

void main() {
  test('an empty background yields no document candidates', () {
    final image = _background(600, 400);
    final result = segmentDecoded(image);
    expect(result.candidates, isEmpty);
    expect(result.multi, isFalse);
  });

  test('two separated cards segment into two candidates', () {
    final image = _background(900, 700);
    _card(image, 60, 60, 420, 290);
    _card(image, 60, 400, 420, 630);
    final result = segmentDecoded(image);
    expect(result.candidates, hasLength(greaterThanOrEqualTo(2)));
  });
}
