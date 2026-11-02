import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/geometry.dart';

// Pure hit-test used by the crop handles (P6). Synthetic coordinates only.
// Fixtures use exact binary fractions so distance ties and inclusive bounds
// are exact in IEEE-754 arithmetic.
void main() {
  final corners = [
    Point2(0.25, 0.25),
    Point2(0.75, 0.25),
    Point2(0.75, 0.75),
    Point2(0.25, 0.75),
  ];

  test('returns the corner inside the radius', () {
    expect(nearestCornerIndex(corners, Point2(0.27, 0.26), 0.05), 0);
    expect(nearestCornerIndex(corners, Point2(0.73, 0.74), 0.05), 2);
  });

  test('returns null when no corner is within the radius', () {
    expect(nearestCornerIndex(corners, Point2(0.5, 0.5), 0.1), isNull);
  });

  test('the radius bound is inclusive', () {
    // Distance to corner 0 and corner 1 is exactly 0.25.
    expect(nearestCornerIndex(corners, Point2(0.5, 0.25), 0.25), 0);
  });

  test('picks the nearest corner when two are within the radius', () {
    expect(nearestCornerIndex(corners, Point2(0.4, 0.25), 0.6), 0);
    expect(nearestCornerIndex(corners, Point2(0.6, 0.25), 0.6), 1);
  });

  test('an exact tie resolves to the lowest index, deterministically', () {
    // Equidistant from corners 0 and 1.
    final tie = Point2(0.5, 0.25);
    for (var i = 0; i < 3; i++) {
      expect(nearestCornerIndex(corners, tie, 0.5), 0);
    }
    // Reversed list: the same tie now sits between list indices 2 and 3, and
    // the lowest list index wins, which is the corner at (0.75, 0.25).
    final reversed = corners.reversed.toList();
    expect(nearestCornerIndex(reversed, tie, 0.5), 2);
  });

  test('rejects a negative or non-finite radius', () {
    expect(
      () => nearestCornerIndex(corners, Point2(0, 0), -1),
      throwsA(isA<Object>()),
    );
    expect(
      () => nearestCornerIndex(corners, Point2(0, 0), double.nan),
      throwsA(isA<Object>()),
    );
  });
}
