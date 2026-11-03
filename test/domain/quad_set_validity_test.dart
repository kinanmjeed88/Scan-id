import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/manual_quad_selection.dart';
import 'package:scan_id/domain/validation.dart';

// Synthetic fixtures only. Canonical order: TL, TR, BR, BL.
final List<Point2> _rect = [
  Point2(.2, .2),
  Point2(.8, .2),
  Point2(.8, .8),
  Point2(.2, .8),
];

/// The 8 dihedral orderings of a ring: its rotations and reflections. Every
/// other permutation of four points can be a bow-tie.
List<List<T>> _ringOrders<T>(List<T> ring) => [
  for (final base in [ring, ring.reversed.toList()])
    for (var k = 0; k < ring.length; k++)
      [...base.sublist(k), ...base.sublist(0, k)],
];

List<List<T>> _permutations<T>(List<T> items) {
  if (items.length <= 1) return [items];
  return [
    for (var i = 0; i < items.length; i++)
      for (final rest in _permutations([...items]..removeAt(i)))
        [items[i], ...rest],
  ];
}

ManualQuadSelection _tapped(List<Point2> taps) {
  var selection = ManualQuadSelection.empty();
  for (final tap in taps) {
    selection = selection.addTap(tap, minSeparation: 0.001);
  }
  return selection;
}

void main() {
  group('quadEdgesCross (drag-time crossing gate)', () {
    test('a bow-tie is a proper crossing in any starting corner', () {
      // Edges 0-1 and 2-3 cross at the centre.
      final bowTie = [
        Point2(.2, .2),
        Point2(.8, .8),
        Point2(.8, .2),
        Point2(.2, .8),
      ];
      expect(quadEdgesCross(bowTie), isTrue);
    });

    test('a convex rectangle, in any ring order, never crosses', () {
      for (final order in _ringOrders(_rect)) {
        expect(quadEdgesCross(order), isFalse, reason: '$order');
      }
    });

    test('touching is not a crossing (corner on an edge, shared point)', () {
      // Corner 3 lies exactly on the interior of edge 0-1.
      final tJunctionOnEdge = [
        Point2(.2, .2),
        Point2(.8, .2),
        Point2(.8, .8),
        Point2(.5, .2),
      ];
      expect(quadEdgesCross(tJunctionOnEdge), isFalse);
      // Coincident corners (the existing drag-onto-corner case) are not
      // crossings either; normalizedQuadIssue rejects them as notConvex.
      final coincident = [
        Point2(.8, .8),
        Point2(.8, .2),
        Point2(.8, .8),
        Point2(.2, .8),
      ];
      expect(quadEdgesCross(coincident), isFalse);
      expect(normalizedQuadIssue(coincident), QuadGeometryIssue.notConvex);
    });

    test('a bow-tie is still rejected by the unchanged validator', () {
      final bowTie = [
        Point2(.2, .2),
        Point2(.8, .8),
        Point2(.8, .2),
        Point2(.2, .8),
      ];
      expect(normalizedQuadIssue(bowTie), QuadGeometryIssue.notConvex);
    });
  });

  group('unorderedQuadIssue (tap-set convex position)', () {
    test('a rectangle is valid in every tap order', () {
      for (final order in _permutations(_rect)) {
        expect(unorderedQuadIssue(order), isNull, reason: '$order');
      }
    });

    test('a point inside the triangle of the other three is rejected', () {
      final concave = [
        Point2(.2, .2),
        Point2(.8, .2),
        Point2(.5, .5),
        Point2(.2, .8),
      ];
      expect(unorderedQuadIssue(concave), QuadGeometryIssue.notConvex);
    });

    test('three collinear points are rejected', () {
      final collinear = [
        Point2(.2, .2),
        Point2(.5, .5),
        Point2(.8, .8),
        Point2(.2, .8),
      ];
      expect(unorderedQuadIssue(collinear), QuadGeometryIssue.notConvex);
    });

    test('count and bounds defects keep their own categories', () {
      expect(
        unorderedQuadIssue([Point2(0, 0), Point2(1, 0), Point2(1, 1)]),
        QuadGeometryIssue.wrongPointCount,
      );
      expect(
        unorderedQuadIssue([
          Point2(.2, .2),
          Point2(1.2, .2),
          Point2(.8, .8),
          Point2(.2, .8),
        ]),
        QuadGeometryIssue.outOfBounds,
      );
      // Non-finite coordinates cannot reach this check: Point2 refuses them at
      // construction, so nonFiniteCoordinates is a defensive branch only.
    });
  });

  group('ManualQuadSelection.completedCorners', () {
    test('order-independent: every tap order of a valid set is accepted', () {
      for (final order in _permutations(_rect)) {
        final corners = _tapped(order).completedCorners();
        expect(corners, hasLength(4));
        expect(corners[0].x, closeTo(.2, 1e-9));
        expect(corners[0].y, closeTo(.2, 1e-9));
        expect(corners[2].x, closeTo(.8, 1e-9));
        expect(corners[2].y, closeTo(.8, 1e-9));
      }
    });

    test('a non-convex set is rejected in every tap order', () {
      final concave = [
        Point2(.2, .2),
        Point2(.8, .2),
        Point2(.5, .5),
        Point2(.2, .8),
      ];
      for (final order in _permutations(concave)) {
        expect(
          () => _tapped(order).completedCorners(),
          throwsA(isA<ValidationException>()),
          reason: '$order',
        );
      }
    });

    test('tap SEQUENCE is not a rejection reason (bow-tie order accepted)', () {
      // The square's corners tapped in crossing order: the set is convex, so
      // canonical ordering yields the rectangle. This must still be accepted.
      final crossingOrder = [
        Point2(.2, .2),
        Point2(.8, .8),
        Point2(.8, .2),
        Point2(.2, .8),
      ];
      final corners = _tapped(crossingOrder).completedCorners();
      expect(normalizedQuadIssue(corners), isNull);
      expect(corners[1].x, closeTo(.8, 1e-9));
      expect(corners[1].y, closeTo(.2, 1e-9));
    });
  });
}
