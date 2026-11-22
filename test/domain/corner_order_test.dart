import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/corner_order.dart';
import 'package:scan_id/domain/geometry.dart';

/// Unit tests for the re-indexing primitives. Arithmetic on synthetic
/// coordinates only: no image, no model, no threshold.

final List<Point2> tlTrBrBl = [
  Point2(.2, .2),
  Point2(.8, .2),
  Point2(.8, .8),
  Point2(.2, .8),
];

/// The SAME four physical corners, numbered starting from a different corner.
List<Point2> rotated(int shift) => [
  for (var i = 0; i < 4; i++) tlTrBrBl[(i + shift) % 4],
];

void expectSameRing(List<Point2> actual, List<Point2> expected) {
  expect(actual, hasLength(expected.length));
  for (var i = 0; i < expected.length; i++) {
    expect(actual[i].x, closeTo(expected[i].x, 1e-12), reason: 'corner $i');
    expect(actual[i].y, closeTo(expected[i].y, 1e-12), reason: 'corner $i');
  }
}

void main() {
  group('canonicalCornerRing', () {
    test('leaves an already canonical ring exactly as it was', () {
      expectSameRing(canonicalCornerRing(tlTrBrBl), tlTrBrBl);
    });

    test('re-indexes a rotated ring to the same canonical order', () {
      for (var shift = 0; shift < 4; shift++) {
        expectSameRing(canonicalCornerRing(rotated(shift)), tlTrBrBl);
      }
    });

    test('reverses a counter-clockwise ring into clockwise screen order', () {
      // Reversed winding: the first edge would otherwise run along the left
      // side, which every consumer treats as a top edge.
      expectSameRing(canonicalCornerRing(tlTrBrBl.reversed.toList()), tlTrBrBl);
    });

    test('does not repair a bow-tie, and returns it unchanged', () {
      // Crossed ring: TL, BR, TR, BL. Its signed area is zero, so no winding or
      // start point can be established. What matters is that the function
      // refuses to invent one, so the caller's geometry gate still sees the
      // crossing.
      final crossed = [
        Point2(.2, .2),
        Point2(.8, .8),
        Point2(.8, .2),
        Point2(.2, .8),
      ];
      expectSameRing(canonicalCornerRing(crossed), crossed);
    });

    test('returns a wrongly sized ring untouched', () {
      final three = [Point2(.1, .1), Point2(.9, .1), Point2(.5, .9)];
      expect(canonicalCornerRing(three), hasLength(3));
      expect(canonicalCornerRing(<Point2>[]), isEmpty);
    });

    test('a degenerate ring of four identical points is left alone', () {
      final collapsed = [for (var i = 0; i < 4; i++) Point2(.5, .5)];
      for (final point in canonicalCornerRing(collapsed)) {
        expect(point.x, .5);
        expect(point.y, .5);
      }
    });
  });

  group('minimumCyclicCornerDisplacementPixels', () {
    const width = 1000;
    const height = 700;

    test('is zero for the same ring under every rotation', () {
      for (var shift = 0; shift < 4; shift++) {
        expect(
          minimumCyclicCornerDisplacementPixels(
            tlTrBrBl,
            rotated(shift),
            width: width,
            height: height,
          ),
          closeTo(0, 1e-9),
          reason: 'shift $shift',
        );
      }
    });

    test('is symmetric in its two arguments', () {
      for (var shift = 0; shift < 4; shift++) {
        final forward = minimumCyclicCornerDisplacementPixels(
          tlTrBrBl,
          rotated(shift),
          width: width,
          height: height,
        );
        final backward = minimumCyclicCornerDisplacementPixels(
          rotated(shift),
          tlTrBrBl,
          width: width,
          height: height,
        );
        expect(forward, closeTo(backward, 1e-9), reason: 'shift $shift');
      }
    });

    test('a mirrored ring is the same quadrilateral, not a disagreement', () {
      // Swapping two corners reflects the ring. The four points are unchanged,
      // so this is the same document and must measure as agreement; treating it
      // as a mismatch would route a perfectly good pair to manual review.
      final mirrored = [
        Point2(.8, .2),
        Point2(.2, .2),
        Point2(.2, .8),
        Point2(.8, .8),
      ];
      expect(
        minimumCyclicCornerDisplacementPixels(
          tlTrBrBl,
          mirrored,
          width: width,
          height: height,
        ),
        closeTo(0, 1e-9),
      );
    });

    test('a negative offset that is the same corner reads as agreement', () {
      // The distance is signed by differencing coordinates, so the smallest
      // possible displacement must be zero and not an absolute-value artefact.
      final offset = [
        Point2(.21, .21),
        Point2(.81, .21),
        Point2(.81, .81),
        Point2(.21, .81),
      ];
      expect(
        minimumCyclicCornerDisplacementPixels(
          offset,
          offset,
          width: width,
          height: height,
        ),
        0,
      );
    });

    test('a genuinely different quadrilateral exceeds the 4% rule', () {
      final different = [
        Point2(.05, .1),
        Point2(.95, .1),
        Point2(.95, .95),
        Point2(.05, .95),
      ];
      expect(
        minimumCyclicCornerDisplacementFraction(
          tlTrBrBl,
          different,
          width: width,
          height: height,
        ),
        greaterThan(.04),
      );
    });

    test('a badly formed pair reports total disagreement, not agreement', () {
      expect(
        minimumCyclicCornerDisplacementPixels(
          tlTrBrBl,
          [Point2(.1, .1)],
          width: width,
          height: height,
        ),
        double.infinity,
      );
    });

    test('a degenerate frame size reports total disagreement', () {
      expect(
        minimumCyclicCornerDisplacementPixels(
          tlTrBrBl,
          tlTrBrBl,
          width: 1,
          height: 1,
        ),
        double.infinity,
      );
    });
  });

  test('the fraction stays inside 0..1 for every rotation', () {
    for (var shift = 0; shift < 4; shift++) {
      final fraction = minimumCyclicCornerDisplacementFraction(
        tlTrBrBl,
        rotated(shift),
        width: 1000,
        height: 700,
      );
      expect(fraction, inInclusiveRange(0, 1));
      expect(fraction, closeTo(0, 1e-12));
    }
  });
}
