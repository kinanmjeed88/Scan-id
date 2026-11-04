import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/imaging/db_text_boxes.dart';

/// A probability map with every pixel at [fill].
Float32List _filled(int width, int height, double fill) =>
    Float32List(width * height)..fillRange(0, width * height, fill);

/// Sets a solid axis-aligned blob of probability [value].
void _blob(
  Float32List map, {
  required int width,
  required int left,
  required int top,
  required int right,
  required int bottom,
  double value = .9,
}) {
  for (var y = top; y < bottom; y++) {
    for (var x = left; x < right; x++) {
      map[y * width + x] = value;
    }
  }
}

void main() {
  test('a solid region becomes one unclipped text box', () {
    const width = 32;
    const height = 16;
    final map = _filled(width, height, 0);
    _blob(map, width: width, left: 4, top: 6, right: 20, bottom: 10);

    final boxes = decodeTextBoxes(map, width: width, height: height);

    expect(boxes, hasLength(1));
    final box = boxes.single;
    expect(box.score, closeTo(.9, 1e-6));
    // Boundary pixels are sampled at pixel centres, so the measured rectangle is
    // 15 × 3 with half extents 7.5 × 1.5. Unclip grows it by
    // area × 1.5 / perimeter = 45 × 1.5 / 36 = 1.875 on every side.
    expect(box.corners[0].x, closeTo(12 - 9.375, .01));
    expect(box.corners[0].y, closeTo(8 - 3.375, .01));
    expect(box.corners[2].x, closeTo(12 + 9.375, .01));
    expect(box.corners[2].y, closeTo(8 + 3.375, .01));
    expect(box.lineHeight, closeTo(6.75, .01));
  });

  test('boxes are returned in reading order, top to bottom then left', () {
    const width = 64;
    const height = 48;
    final map = _filled(width, height, 0);
    _blob(map, width: width, left: 4, top: 30, right: 20, bottom: 34);
    _blob(map, width: width, left: 30, top: 4, right: 50, bottom: 8);
    _blob(map, width: width, left: 8, top: 4, right: 24, bottom: 8);

    final boxes = decodeTextBoxes(map, width: width, height: height);

    expect(boxes, hasLength(3));
    final order = <String>[
      for (final box in boxes) '${box.top}/${box.left}',
    ].join(' ');
    for (var index = 1; index < boxes.length; index++) {
      final previous = boxes[index - 1];
      final current = boxes[index];
      final sameRow = previous.top == current.top;
      final ordered =
          previous.top < current.top ||
          (sameRow && previous.left <= current.left);
      expect(ordered, isTrue, reason: 'reading order was $order');
    }
  });

  test('a region below the box threshold is not text', () {
    const width = 32;
    const height = 16;
    final map = _filled(width, height, 0);
    _blob(map, width: width, left: 4, top: 4, right: 24, bottom: 10, value: .4);

    expect(decodeTextBoxes(map, width: width, height: height), isEmpty);
  });

  test('a region below the bitmap threshold is never collected', () {
    final map = _filled(16, 16, .2);
    expect(decodeTextBoxes(map, width: 16, height: 16), isEmpty);
  });

  test('a sliver thinner than minSize is rejected', () {
    const width = 32;
    const height = 8;
    final map = _filled(width, height, 0);
    _blob(map, width: width, left: 4, top: 4, right: 28, bottom: 5);

    expect(decodeTextBoxes(map, width: width, height: height), isEmpty);
  });

  test('maxCandidates keeps the strongest regions only', () {
    const width = 64;
    const height = 64;
    final map = _filled(width, height, 0);
    _blob(map, width: width, left: 2, top: 2, right: 14, bottom: 8, value: .7);
    _blob(
      map,
      width: width,
      left: 2,
      top: 20,
      right: 14,
      bottom: 26,
      value: .8,
    );
    _blob(
      map,
      width: width,
      left: 2,
      top: 40,
      right: 14,
      bottom: 46,
      value: .9,
    );

    final boxes = decodeTextBoxes(
      map,
      width: width,
      height: height,
      maxCandidates: 2,
    );

    expect(boxes, hasLength(2));
    expect(boxes.map((box) => box.score), everyElement(greaterThan(.75)));
  });

  test('source scales map the box back to the original pixels', () {
    const width = 32;
    const height = 16;
    final map = _filled(width, height, 0);
    _blob(map, width: width, left: 4, top: 6, right: 20, bottom: 10);

    final scaled = decodeTextBoxes(
      map,
      width: width,
      height: height,
      scaleX: 3,
      scaleY: 2,
    );

    expect(scaled.single.corners[0].x, closeTo((12 - 9.375) * 3, .01));
    expect(scaled.single.corners[0].y, closeTo((8 - 3.375) * 2, .01));
    expect(scaled.single.lineHeight, closeTo(13.5, .01));
  });

  test('a slanted band yields a rotated box whose long axis is horizontal', () {
    const width = 64;
    const height = 32;
    final map = _filled(width, height, 0);
    for (var x = 6; x < 48; x++) {
      final center = 10 + ((x - 6) * .25).round();
      for (var dy = -2; dy <= 2; dy++) {
        final y = center + dy;
        if (y < 0 || y >= height) continue;
        map[y * width + x] = .95;
      }
    }

    final boxes = decodeTextBoxes(map, width: width, height: height);

    expect(boxes, hasLength(1));
    final corners = boxes.single.corners;
    final horizontalSpan = corners[1].x - corners[0].x;
    final verticalSpan = corners[3].y - corners[0].y;
    expect(horizontalSpan, greaterThan(verticalSpan));
    // The left edge is slanted, so the top-left and bottom-left corners differ
    // in x: this is what proves the box was fitted to the pixel band instead of
    // its bounding rectangle.
    expect((corners[0].x - corners[3].x).abs(), greaterThan(.5));
  });

  test('non-finite probabilities are treated as background', () {
    const width = 16;
    const height = 16;
    final map = _filled(width, height, double.nan);
    for (var y = 6; y < 10; y++) {
      for (var x = 4; x < 12; x++) {
        map[y * width + x] = .9;
      }
    }

    final boxes = decodeTextBoxes(map, width: width, height: height);

    expect(boxes, hasLength(1));
    expect(boxes.single.score.isFinite, isTrue);
  });

  test('an invalid map size is rejected', () {
    expect(
      () => decodeTextBoxes(Float32List(4), width: 8, height: 8),
      throwsA(isA<ValidationException>()),
    );
    expect(
      () => decodeTextBoxes(Float32List(4), width: 1, height: 4),
      throwsA(isA<ValidationException>()),
    );
  });
}
