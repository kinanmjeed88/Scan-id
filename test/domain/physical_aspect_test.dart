import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/physical_aspect.dart';

// Synthetic, licensed-free geometry only: a pinhole camera looks at a flat
// rectangle. The corners are projected here and then passed to the production
// estimator, which never sees the answer. The expected bounds were measured on
// the same arithmetic in a Python port of physical_aspect.dart (pure geometry,
// not a Dart run; CI is the Dart verification).

typedef _Matrix = List<List<double>>;

/// Fixed corner perturbation (source pixels) used by the noise cases.
const List<(double, double)> _fixedPattern = [
  (2.0, -2.0),
  (-2.0, 2.0),
  (2.0, 2.0),
  (-2.0, -2.0),
];

_Matrix _multiply(_Matrix a, _Matrix b) {
  final product = [
    [0.0, 0.0, 0.0],
    [0.0, 0.0, 0.0],
    [0.0, 0.0, 0.0],
  ];
  for (var i = 0; i < 3; i++) {
    for (var j = 0; j < 3; j++) {
      for (var k = 0; k < 3; k++) {
        product[i][j] += a[i][k] * b[k][j];
      }
    }
  }
  return product;
}

_Matrix _rotationX(double t) {
  final c = math.cos(t);
  final s = math.sin(t);
  return [
    [1, 0, 0],
    [0, c, -s],
    [0, s, c],
  ];
}

_Matrix _rotationY(double t) {
  final c = math.cos(t);
  final s = math.sin(t);
  return [
    [c, 0, s],
    [0, 1, 0],
    [-s, 0, c],
  ];
}

_Matrix _rotationZ(double t) {
  final c = math.cos(t);
  final s = math.sin(t);
  return [
    [c, -s, 0],
    [s, c, 0],
    [0, 0, 1],
  ];
}

/// Projects a flat [physicalWidth] × [physicalHeight] rectangle (any unit,
/// used only as a ratio) seen by a camera at [distance] after rotating the
/// plane by tiltX, tiltY, then roll (radians). Returns the four corners as
/// normalized image points, TL, TR, BR, BL, the order CropDraft uses.
/// [pixelOffsets] adds a fixed corner perturbation in source pixels.
List<Point2> _projectRectangle({
  required double physicalWidth,
  required double physicalHeight,
  required int sourceWidth,
  required int sourceHeight,
  required double focal,
  double tiltX = 0,
  double tiltY = 0,
  double roll = 0,
  double distance = 170,
  List<(double, double)> pixelOffsets = const [],
}) {
  final rotation = _multiply(
    _multiply(_rotationX(tiltX), _rotationY(tiltY)),
    _rotationZ(roll),
  );
  final planar = [
    (-physicalWidth / 2, -physicalHeight / 2),
    (physicalWidth / 2, -physicalHeight / 2),
    (physicalWidth / 2, physicalHeight / 2),
    (-physicalWidth / 2, physicalHeight / 2),
  ];
  final cx = sourceWidth / 2;
  final cy = sourceHeight / 2;
  final corners = <Point2>[];
  for (var i = 0; i < 4; i++) {
    final (x, y) = planar[i];
    final p0 = rotation[0][0] * x + rotation[0][1] * y;
    final p1 = rotation[1][0] * x + rotation[1][1] * y;
    final depth = rotation[2][0] * x + rotation[2][1] * y + distance;
    var u = focal * p0 / depth + cx;
    var v = focal * p1 / depth + cy;
    if (pixelOffsets.isNotEmpty) {
      u += pixelOffsets[i].$1;
      v += pixelOffsets[i].$2;
    }
    corners.add(Point2(u / (sourceWidth - 1), v / (sourceHeight - 1)));
  }
  return corners;
}

void _expectRatio(
  PhysicalAspectEstimate? estimate,
  double expectedRatio, {
  required double tolerance,
}) {
  expect(estimate, isNotNull, reason: 'the ratio is determinable here');
  expect(estimate!.aspect / expectedRatio, closeTo(1, tolerance));
}

PhysicalAspectEstimate? _estimateFor(
  List<Point2> corners,
  int sourceWidth,
  int sourceHeight,
) => estimatePhysicalAspect(
  corners,
  sourceWidth: sourceWidth,
  sourceHeight: sourceHeight,
);

void main() {
  group('estimatePhysicalAspect', () {
    test('two-axis perspective recovers the physical ratio', () {
      const cases = [
        (85.6, 54.0),
        (210.0, 297.0),
        (125.0, 88.0),
        (100.0, 100.0),
        (54.0, 85.6),
      ];
      for (final (w, h) in cases) {
        final corners = _projectRectangle(
          physicalWidth: w,
          physicalHeight: h,
          sourceWidth: 3000,
          sourceHeight: 4000,
          focal: 3500,
          tiltX: _deg(25),
          tiltY: _deg(25),
        );
        _expectRatio(
          _estimateFor(corners, 3000, 4000),
          w / h,
          tolerance: .005,
        );
      }
    });

    test('in-plane roll up to 45 degrees keeps the ratio', () {
      for (final roll in [0.0, 10.0, 20.0, 30.0, 45.0]) {
        final corners = _projectRectangle(
          physicalWidth: 85.6,
          physicalHeight: 54,
          sourceWidth: 3000,
          sourceHeight: 4000,
          focal: 3500,
          tiltX: _deg(25),
          tiltY: _deg(25),
          roll: _deg(roll),
        );
        _expectRatio(
          _estimateFor(corners, 3000, 4000),
          85.6 / 54,
          tolerance: .005,
        );
      }
    });

    test('asymmetric perspective keeps the ratio', () {
      const tilts = [
        (20.0, 20.0),
        (30.0, 30.0),
        (30.0, -30.0),
        (40.0, 25.0),
        (15.0, 35.0),
        (10.0, 45.0),
      ];
      for (final (tx, ty) in tilts) {
        final corners = _projectRectangle(
          physicalWidth: 85.6,
          physicalHeight: 54,
          sourceWidth: 3000,
          sourceHeight: 4000,
          focal: 3500,
          tiltX: _deg(tx),
          tiltY: _deg(ty),
        );
        _expectRatio(
          _estimateFor(corners, 3000, 4000),
          85.6 / 54,
          tolerance: .005,
        );
      }
    });

    test('varying image sizes and focal lengths keep the ratio', () {
      const views = [
        (1200, 1600, 1400.0),
        (4000, 3000, 4500.0),
        (2000, 2000, 2200.0),
        (6000, 4000, 7000.0),
      ];
      for (final (sw, sh, f) in views) {
        final corners = _projectRectangle(
          physicalWidth: 85.6,
          physicalHeight: 54,
          sourceWidth: sw,
          sourceHeight: sh,
          focal: f,
          tiltX: _deg(25),
          tiltY: _deg(25),
        );
        _expectRatio(
          _estimateFor(corners, sw, sh),
          85.6 / 54,
          tolerance: .005,
        );
      }
    });

    test('a fixed two-pixel corner pattern stays within its bound', () {
      // Observed errors on this fixed pattern: 0.61 % (30/30) and 2.53 %
      // (40/25 with roll 20). The bounds are about 1.6 and 1.4 times those.
      final mild = _projectRectangle(
        physicalWidth: 85.6,
        physicalHeight: 54,
        sourceWidth: 3000,
        sourceHeight: 4000,
        focal: 3500,
        tiltX: _deg(30),
        tiltY: _deg(30),
        pixelOffsets: _fixedPattern,
      );
      _expectRatio(
        _estimateFor(mild, 3000, 4000),
        85.6 / 54,
        tolerance: .01,
      );

      final strong = _projectRectangle(
        physicalWidth: 85.6,
        physicalHeight: 54,
        sourceWidth: 3000,
        sourceHeight: 4000,
        focal: 3500,
        tiltX: _deg(40),
        tiltY: _deg(25),
        roll: _deg(20),
        pixelOffsets: _fixedPattern,
      );
      _expectRatio(
        _estimateFor(strong, 3000, 4000),
        85.6 / 54,
        tolerance: .035,
      );
    });

    test('single-axis tilt and in-plane rotation are not determinable', () {
      // With one vanishing point at infinity the focal length is not
      // determined, so the ratio must stay unknown. The caller then keeps the
      // averaged-edge shape, which is exact for these affine views.
      final xTilt = _projectRectangle(
        physicalWidth: 85.6,
        physicalHeight: 54,
        sourceWidth: 3000,
        sourceHeight: 4000,
        focal: 3500,
        tiltX: _deg(30),
      );
      final yTilt = _projectRectangle(
        physicalWidth: 85.6,
        physicalHeight: 54,
        sourceWidth: 3000,
        sourceHeight: 4000,
        focal: 3500,
        tiltY: _deg(30),
      );
      final rollOnly = _projectRectangle(
        physicalWidth: 85.6,
        physicalHeight: 54,
        sourceWidth: 3000,
        sourceHeight: 4000,
        focal: 3500,
        roll: _deg(30),
      );
      expect(_estimateFor(xTilt, 3000, 4000), isNull);
      expect(_estimateFor(yTilt, 3000, 4000), isNull);
      expect(_estimateFor(rollOnly, 3000, 4000), isNull);
    });

    test('repeated corners and degenerate input return null', () {
      final repeated = [
        Point2(0, 0),
        Point2(0, 0),
        Point2(1, 1),
        Point2(0, 1),
      ];
      final unitSquare = [
        Point2(0, 0),
        Point2(1, 0),
        Point2(1, 1),
        Point2(0, 1),
      ];
      expect(_estimateFor(repeated, 1000, 1000), isNull);
      expect(_estimateFor(unitSquare, 1000, 1000), isNull);
      expect(_estimateFor(unitSquare.take(3).toList(), 1000, 1000), isNull);
      expect(_estimateFor(unitSquare, 1, 1000), isNull);
    });
  });

  group('CropDraft.toRecipe on a free crop', () {
    test('rectifies a two-axis perspective crop to the document ratio', () {
      final corners = _projectRectangle(
        physicalWidth: 85.6,
        physicalHeight: 54,
        sourceWidth: 3000,
        sourceHeight: 4000,
        focal: 3500,
        tiltX: _deg(25),
        tiltY: _deg(25),
      );
      final draft = CropDraft(corners: corners);
      final geometry = draft.toRecipe(3000, 4000).geometry;
      final ratio = geometry.outputWidth / geometry.outputHeight;
      expect(ratio / (85.6 / 54), closeTo(1, .02));
    });

    test('a crop without perspective keeps its averaged shape', () {
      // Axis-aligned edges have a vanishing point at infinity, so the physical
      // estimate is absent and the averaged-edge shape (about 2:1) stays.
      final rectangle = [
        Point2(.1, .1),
        Point2(.9, .1),
        Point2(.9, .6),
        Point2(.1, .6),
      ];
      final draft = CropDraft(corners: rectangle);
      final geometry = draft.toRecipe(1000, 800).geometry;
      final ratio = geometry.outputWidth / geometry.outputHeight;
      expect(ratio / 2, closeTo(1, .01));
    });
  });
}

double _deg(double degrees) => degrees * math.pi / 180;
