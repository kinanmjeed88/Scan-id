import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/manual_quad_selection.dart';
import 'package:scan_id/domain/validation.dart';

// Canonical order for these fixtures: top-left, top-right, bottom-right,
// bottom-left (the CropGeometry convention).
final List<Point2> _rect = [
  Point2(.2, .2),
  Point2(.8, .2),
  Point2(.8, .8),
  Point2(.2, .8),
];

List<List<int>> _permutations(List<int> items) {
  if (items.length <= 1) return [items];
  return [
    for (var i = 0; i < items.length; i++)
      for (final rest in _permutations([...items]..removeAt(i)))
        [items[i], ...rest],
  ];
}

void _expectSameCorners(List<Point2> actual, List<Point2> expected) {
  expect(actual, hasLength(4));
  for (var i = 0; i < 4; i++) {
    expect(actual[i].x, closeTo(expected[i].x, 1e-12), reason: 'corner $i x');
    expect(actual[i].y, closeTo(expected[i].y, 1e-12), reason: 'corner $i y');
  }
}

ManualQuadSelection _tapAll(List<Point2> taps) {
  var selection = ManualQuadSelection.empty();
  for (final tap in taps) {
    selection = selection.addTap(tap, minSeparation: .01);
  }
  return selection;
}

void main() {
  group('canonicalQuadCorners', () {
    test('orders an axis-aligned rectangle as TL, TR, BR, BL', () {
      _expectSameCorners(
        canonicalQuadCorners([_rect[2], _rect[0], _rect[3], _rect[1]]),
        _rect,
      );
    });

    test('every input permutation gives the same canonical order', () {
      for (final perm in _permutations([0, 1, 2, 3])) {
        _expectSameCorners(
          canonicalQuadCorners([for (final i in perm) _rect[i]]),
          _rect,
        );
      }
    });

    test('a card tilted by 20 degrees keeps its top edge as TL to TR', () {
      const theta = 20 * math.pi / 180;
      Point2 rotate(double dx, double dy) => Point2(
        .5 + dx * math.cos(theta) - dy * math.sin(theta),
        .5 + dx * math.sin(theta) + dy * math.cos(theta),
      );
      final card = [
        rotate(-.3, -.2),
        rotate(.3, -.2),
        rotate(.3, .2),
        rotate(-.3, .2),
      ];
      _expectSameCorners(
        canonicalQuadCorners([card[2], card[0], card[3], card[1]]),
        card,
      );
    });

    test('rejects input that is not exactly four points', () {
      expect(
        () => canonicalQuadCorners([_rect[0], _rect[1], _rect[2]]),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('ManualQuadSelection', () {
    test('four valid taps complete to canonical corners in any tap order', () {
      for (final perm in _permutations([0, 1, 2, 3])) {
        final selection = _tapAll([for (final i in perm) _rect[i]]);
        expect(selection.isComplete, isTrue);
        _expectSameCorners(selection.completedCorners(), _rect);
      }
    });

    test('a partial selection cannot complete', () {
      final partial = _tapAll([_rect[0], _rect[1], _rect[2]]);
      expect(partial.isComplete, isFalse);
      expect(partial.completedCorners, throwsA(isA<ValidationException>()));
    });

    test('a fifth tap is rejected and does not change the selection', () {
      final full = _tapAll(_rect);
      expect(
        () => full.addTap(Point2(.5, .5), minSeparation: .01),
        throwsA(isA<ValidationException>()),
      );
      expect(full.points, hasLength(4));
    });

    test('an out-of-frame tap is rejected', () {
      expect(
        () => ManualQuadSelection.empty().addTap(
          Point2(1.2, .5),
          minSeparation: .01,
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('a tap closer than the minimum separation is rejected', () {
      final one = ManualQuadSelection.empty().addTap(
        Point2(.5, .5),
        minSeparation: .05,
      );
      expect(
        () => one.addTap(Point2(.52, .5), minSeparation: .05),
        throwsA(isA<ValidationException>()),
      );
      expect(
        one.addTap(Point2(.56, .5), minSeparation: .05).points,
        hasLength(2),
      );
    });

    test('undo removes only the most recent tap', () {
      final two = _tapAll([_rect[0], _rect[1]]);
      final one = two.undo();
      expect(one.points.single.x, _rect[0].x);
      expect(one.undo().points, isEmpty);
      expect(ManualQuadSelection.empty().undo().points, isEmpty);
    });

    test('a concave dart is rejected before it can reach crop', () {
      // Angle order about the centroid gives a reflex vertex at (.6, .5).
      final dart = _tapAll([
        Point2(0, 0),
        Point2(1, 0),
        Point2(1, 1),
        Point2(.6, .5),
      ]);
      expect(dart.isComplete, isTrue);
      expect(dart.completedCorners, throwsA(isA<ValidationException>()));
    });
  });
}
