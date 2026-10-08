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
  test('two separated cards segment into two corner candidates', () {
    final image = _background(900, 700);
    _card(image, 60, 60, 420, 290); // top card ≈ ID-1 shape
    _card(image, 60, 400, 420, 630); // bottom card
    final result = segmentDecoded(image);
    expect(result.multi, isTrue);
    final quads = result.candidates.where((c) => c.corners != null).toList();
    expect(quads, hasLength(2));
    for (final candidate in quads) {
      expect(candidate.corners, hasLength(4));
      expect(candidate.detectionConfidence, isNotNull);
      expect(candidate.detectionConfidence, lessThanOrEqualTo(.9));
      for (final p in candidate.corners!) {
        expect(p.x, inInclusiveRange(0, 1));
        expect(p.y, inInclusiveRange(0, 1));
      }
    }
    // Deterministic top-to-bottom order: first candidate is the top card.
    final first = result.candidates.first;
    final second = result.candidates[1];
    expect(first.region[1], lessThan(second.region[1]));
    // Mapped corners sit around the drawn rectangles.
    expect(first.corners![0].y, closeTo(60 / 699, .05));
    expect(second.corners![0].y, closeTo(400 / 699, .05));
  });

  test('a single card reports no multi-document structure', () {
    final image = _background(900, 700);
    _card(image, 150, 150, 740, 540);
    final result = segmentDecoded(image);
    expect(result.multi, isFalse);
  });

  test('a blank image reports no structure at all', () {
    final result = segmentDecoded(_background(600, 400));
    expect(result.multi, isFalse);
    expect(result.candidates, isEmpty);
  });

  test('tiny images are rejected safely', () {
    final result = segmentDecoded(img.Image(width: 20, height: 20));
    expect(result.multi, isFalse);
    expect(result.candidates, isEmpty);
  });

  test('segmentation is deterministic for identical input', () {
    final image = _background(900, 700);
    _card(image, 60, 60, 420, 290);
    _card(image, 460, 380, 830, 610);
    final a = segmentDecoded(image);
    final b = segmentDecoded(image);
    expect(a.multi, b.multi);
    expect(a.candidates.length, b.candidates.length);
    for (var i = 0; i < a.candidates.length; i++) {
      expect(a.candidates[i].region, b.candidates[i].region);
      expect(
        a.candidates[i].detectionConfidence,
        b.candidates[i].detectionConfidence,
      );
    }
  });

  test('bytes entry point decodes and matches the decoded path', () {
    final image = _background(600, 500);
    _card(image, 40, 40, 280, 200);
    _card(image, 40, 280, 280, 440);
    final bytes = img.encodePng(image);
    final fromBytes = segmentDocumentBytes(bytes);
    final fromImage = segmentDecoded(image);
    expect(fromBytes.multi, fromImage.multi);
    expect(fromBytes.candidates.length, fromImage.candidates.length);
  });
}
