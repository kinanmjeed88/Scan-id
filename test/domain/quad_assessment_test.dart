import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/quad_assessment.dart';

List<Point2> _rect({
  double left = .1,
  double top = .1,
  double right = .9,
  double bottom = .9,
}) => [
  Point2(left, top),
  Point2(right, top),
  Point2(right, bottom),
  Point2(left, bottom),
];

void main() {
  group('rejections', () {
    test('wrong point count', () {
      final result = assessQuad(
        [Point2(0, 0), Point2(1, 0), Point2(1, 1)],
        sourceWidth: 800,
        sourceHeight: 600,
      );
      expect(result.acceptable, isFalse);
      expect(result.rejection, QuadRejection.wrongPointCount);
      expect(result.geometryConfidence, isNull, reason: 'never invented');
      expect(result.aspect, isNull);
    });

    test('out of bounds', () {
      final result = assessQuad(
        [Point2(-.2, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)],
        sourceWidth: 800,
        sourceHeight: 600,
      );
      expect(result.rejection, QuadRejection.outOfBounds);
    });

    test('non-convex (crossed) corners', () {
      final result = assessQuad(
        [Point2(.1, .1), Point2(.9, .9), Point2(.9, .1), Point2(.1, .9)],
        sourceWidth: 800,
        sourceHeight: 600,
      );
      expect(result.rejection, QuadRejection.notConvex);
    });

    test('too small an area', () {
      final result = assessQuad(
        _rect(left: .4, top: .4, right: .45, bottom: .45),
        sourceWidth: 800,
        sourceHeight: 600,
      );
      expect(result.rejection, QuadRejection.tooSmall);
    });

    test('implausible aspect ratio', () {
      final result = assessQuad(
        _rect(top: .48, bottom: .52),
        sourceWidth: 2000,
        sourceHeight: 2000,
      );
      expect(result.rejection, QuadRejection.implausibleAspect);
    });
  });

  group('accepted geometry', () {
    test('an axis-aligned rectangle scores high with its true aspect', () {
      final result = assessQuad(_rect(), sourceWidth: 860, sourceHeight: 540);
      expect(result.acceptable, isTrue);
      expect(result.rejection, isNull);
      expect(result.geometryConfidence, greaterThan(.9));
      // 0.8*859 by 0.8*539 → aspect = long/short.
      expect(result.aspect, closeTo((859 * .8) / (539 * .8), 1e-6));
      expect(result.areaFraction, closeTo(.64, .01));
    });

    test('mild perspective lowers but keeps confidence', () {
      final mild = assessQuad(
        [Point2(.12, .11), Point2(.88, .14), Point2(.9, .87), Point2(.1, .84)],
        sourceWidth: 860,
        sourceHeight: 540,
      );
      expect(mild.acceptable, isTrue);
      expect(mild.geometryConfidence, lessThan(1));
      expect(mild.geometryConfidence, greaterThan(.3));
    });

    test('deterministic: same input gives the same scores', () {
      final a = assessQuad(_rect(), sourceWidth: 860, sourceHeight: 540);
      final b = assessQuad(_rect(), sourceWidth: 860, sourceHeight: 540);
      expect(a.geometryConfidence, b.geometryConfidence);
      expect(a.aspect, b.aspect);
    });
  });

  group('orientation', () {
    test('unknown kind: no proposal, not confident', () {
      final estimate = estimateOrientation(pixelAspect: 1.6);
      expect(estimate.quarterTurns, 0);
      expect(estimate.confident, isFalse);
    });

    test('matching orientation: 0 turns, 0° vs 180° left undecided', () {
      final estimate = estimateOrientation(
        pixelAspect: 1.6,
        expectedAspect: 85.6 / 53.98,
      );
      expect(estimate.quarterTurns, 0);
      expect(estimate.confident, isFalse);
    });

    test('crossed orientation proposes a quarter turn, unconfident', () {
      final estimate = estimateOrientation(
        pixelAspect: .6,
        expectedAspect: 85.6 / 53.98,
      );
      expect(estimate.quarterTurns, 1);
      expect(estimate.confident, isFalse, reason: 'user confirms rotation');
    });
  });
}
