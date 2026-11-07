import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/presentation/boundary_handle.dart';

// Pure hit-testing contract for the crop boundary. Real presses used to be
// ignored because only four 24 px circles were hittable; the boundary is now
// four 64 px corner targets plus four 36 px edge bands.
void main() {
  final corners = <Point2>[
    Point2(0, 0),
    Point2(100, 0),
    Point2(100, 80),
    Point2(0, 80),
  ];

  test('a corner target is wider than the 40 px circle drawn on screen', () {
    expect(cornerCaptureRadiusPx * 2, greaterThan(40));
    expect(cornerCaptureRadiusPx, 32);
    expect(edgeCaptureWidthPx, 18);
  });

  test('a press anywhere on a visible handle selects that corner', () {
    final offsets = <Point2>[
      Point2(19, 19),
      Point2(-19, 19),
      Point2(19, -19),
      Point2(-19, -19),
      Point2(0, 20),
      Point2(20, 0),
    ];
    for (var i = 0; i < 4; i++) {
      final c = corners[i];
      for (final offset in offsets) {
        final handle = boundaryHandleAt(
          corners,
          Point2(c.x + offset.x, c.y + offset.y),
        );
        expect(handle, isA<CornerHandle>(), reason: 'corner $i at $offset');
        expect((handle! as CornerHandle).index, i);
      }
    }
  });

  test('pressing the middle of a side selects the whole edge', () {
    final cases = <Point2, int>{
      Point2(50, 0): 0,
      Point2(100, 40): 1,
      Point2(50, 80): 2,
      Point2(0, 40): 3,
    };
    for (final entry in cases.entries) {
      final handle = boundaryHandleAt(corners, entry.key);
      expect(handle, isA<EdgeHandle>(), reason: '${entry.key}');
      expect((handle! as EdgeHandle).index, entry.value);
    }
  });

  test('corners win near an endpoint so a corner never turns into an edge', () {
    final handle = boundaryHandleAt(corners, Point2(5, 5));
    expect(handle, const CornerHandle(0));
  });

  test('empty space returns null, leaving the pointer free to pan', () {
    expect(boundaryHandleAt(corners, Point2(50, 40)), isNull);
    expect(boundaryHandleAt(corners, Point2(50, 25)), isNull);
  });

  test('distanceToSegment clamps the projection to the segment', () {
    expect(
      distanceToSegment(Point2(50, 10), Point2(0, 0), Point2(100, 0)),
      closeTo(10, 1e-9),
    );
    expect(
      distanceToSegment(Point2(150, 0), Point2(0, 0), Point2(100, 0)),
      closeTo(50, 1e-9),
    );
  });

  test('an edge moves exactly its two endpoints', () {
    expect(edgeCorners(0), (first: 0, second: 1));
    expect(edgeCorners(3), (first: 3, second: 0));
  });

  test('capture radii scale with zoom so screen targets stay constant', () {
    // handleAt divides by the viewer scale; the pure function uses the same
    // contract with explicitly scaled radii.
    final scaled = boundaryHandleAt(
      corners,
      Point2(50, 6),
      cornerRadius: cornerCaptureRadiusPx / 3,
      edgeWidth: edgeCaptureWidthPx / 3,
    );
    expect(scaled, isNull, reason: '8 content px > 6 px band at zoom 3');
    expect(
      boundaryHandleAt(
        corners,
        Point2(50, 4),
        cornerRadius: cornerCaptureRadiusPx / 3,
        edgeWidth: edgeCaptureWidthPx / 3,
      ),
      const EdgeHandle(0),
    );
  });
}
