import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/reference_annotation/main.dart';

void main() {
  test('canonicalizes four taps to clockwise TL, TR, BR, BL coordinates', () {
    final taps = <List<double>>[
      [0.85, 0.8],
      [0.15, 0.2],
      [0.15, 0.8],
      [0.85, 0.2],
    ];

    expect(canonicalizeReferencePolygon(taps), <List<double>>[
      [0.15, 0.2],
      [0.85, 0.2],
      [0.85, 0.8],
      [0.15, 0.8],
    ]);
  });
}
