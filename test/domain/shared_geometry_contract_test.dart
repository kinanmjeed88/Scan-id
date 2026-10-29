import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/imaging/perspective.dart';

void main() {
  const valid = [
    Point2(.1, .2),
    Point2(.8, .1),
    Point2(.9, .8),
    Point2(.2, .9),
  ];

  test('one normalized ring contract feeds crop and renderer', () {
    expect(normalizedQuadIssue(valid), isNull);
    final geometry = CropGeometry(corners: valid);
    final map = PerspectiveMap(geometry);
    // The unit square corners must land on the selected document corners.
    for (var i = 0; i < 4; i++) {
      const uv = [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)];
      final mapped = map.at(uv[i].x, uv[i].y);
      expect(mapped.x, closeTo(valid[i].x, 1e-9));
      expect(mapped.y, closeTo(valid[i].y, 1e-9));
    }
  });

  test(
    'wrong count, non-finite, outside, crossed, collapsed and singular rings fail',
    () {
      expect(
        normalizedQuadIssue(valid.take(3).toList()),
        QuadGeometryIssue.wrongPointCount,
      );
      expect(
        normalizedQuadIssue([const Point2(double.nan, 0), ...valid.skip(1)]),
        QuadGeometryIssue.nonFiniteCoordinates,
      );
      expect(
        normalizedQuadIssue([const Point2(1.2, 0), ...valid.skip(1)]),
        QuadGeometryIssue.outOfBounds,
      );
      expect(
        normalizedQuadIssue(const [
          Point2(.1, .1),
          Point2(.9, .9),
          Point2(.9, .1),
          Point2(.1, .9),
        ]),
        QuadGeometryIssue.notConvex,
      );
      expect(
        normalizedQuadIssue(const [
          Point2(.2, .2),
          Point2(.8, .2),
          Point2(.8, .200001),
          Point2(.2, .200001),
        ]),
        anyOf(
          QuadGeometryIssue.collapsedArea,
          QuadGeometryIssue.singularPerspective,
        ),
      );
      expect(
        () => CropGeometry(corners: valid.take(3).toList()),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => CropGeometry(
          corners: const [
            Point2(.1, .1),
            Point2(.9, .9),
            Point2(.9, .1),
            Point2(.1, .9),
          ],
        ),
        throwsA(isA<ValidationException>()),
      );
    },
  );

  test('full-frame identity remains valid at tiny raster sizes', () {
    final geometry = CropGeometry(corners: CropDraft.fullImage().corners);
    final map = PerspectiveMap(geometry);
    expect(map.at(.25, .75), const Point2(.25, .75));
  });
}
