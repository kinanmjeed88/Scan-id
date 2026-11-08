import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/presentation/crop_loupe.dart';

void main() {
  test('the loupe occupies the quadrant opposite every crop corner', () {
    final cases = <(Point2, Alignment)>[
      (Point2(0, 0), Alignment.bottomRight),
      (Point2(1, 0), Alignment.bottomLeft),
      (Point2(1, 1), Alignment.topLeft),
      (Point2(0, 1), Alignment.topRight),
    ];
    for (final (focus, expected) in cases) {
      expect(cropLoupeAlignment(focus), expected, reason: '$focus');
    }
  });

  test('loupe placement is physical and therefore independent of RTL', () {
    final topRight = Point2(.9, .1);
    expect(cropLoupeAlignment(topRight), Alignment.bottomLeft);
  });
}
