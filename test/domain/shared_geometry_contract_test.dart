import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/imaging/perspective.dart';

void main() {
  final valid = [
    Point2(.1, .2),
    Point2(.8, .1),
    Point2(.9, .8),
    Point2(.2, .9),
  ];
  CropGeometry geometry(List<Point2> corners) =>
      CropGeometry(corners: corners, outputWidth: 400, outputHeight: 300);

  test('one normalized ring contract feeds crop and renderer', () {
    expect(normalizedQuadIssue(valid), isNull);
    final map = PerspectiveMap(geometry(valid));
    final uv = [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)];
    for (var i = 0; i < 4; i++) {
      final mapped = map.at(uv[i].x, uv[i].y);
      expect(mapped.x, closeTo(valid[i].x, 1e-9));
      expect(mapped.y, closeTo(valid[i].y, 1e-9));
    }
  });

  test('wrong count, outside, crossed and collapsed rings fail everywhere', () {
    expect(
      normalizedQuadIssue(valid.take(3).toList()),
      QuadGeometryIssue.wrongPointCount,
    );
    expect(
      normalizedQuadIssue([Point2(1.2, 0), ...valid.skip(1)]),
      QuadGeometryIssue.outOfBounds,
    );
    final crossed = [
      Point2(.1, .1),
      Point2(.9, .9),
      Point2(.9, .1),
      Point2(.1, .9),
    ];
    expect(normalizedQuadIssue(crossed), QuadGeometryIssue.notConvex);
    final collapsed = [
      Point2(.2, .2),
      Point2(.8, .2),
      Point2(.8, .200001),
      Point2(.2, .200001),
    ];
    expect(
      normalizedQuadIssue(collapsed),
      anyOf(
        QuadGeometryIssue.collapsedArea,
        QuadGeometryIssue.singularPerspective,
      ),
    );
    expect(
      () => geometry(valid.take(3).toList()),
      throwsA(isA<ValidationException>()),
    );
    expect(() => geometry(crossed), throwsA(isA<ValidationException>()));
    expect(() => geometry(collapsed), throwsA(isA<ValidationException>()));
  });

  test('full-frame identity remains valid', () {
    final full = [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)];
    final map = PerspectiveMap(geometry(full));
    expect(map.at(.25, .75).x, closeTo(.25, 1e-12));
    expect(map.at(.25, .75).y, closeTo(.75, 1e-12));
  });
}
