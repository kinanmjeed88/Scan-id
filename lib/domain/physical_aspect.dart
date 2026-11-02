/// Physical aspect of a planar document recovered from its four corners.
///
/// Derivation (pinhole camera, square pixels, zero skew, principal point o at
/// the image centre, pixel coordinates):
///
/// 1. The image vanishing points of the two side directions are v1 (width) and
///    v2 (height). For orthogonal world directions the focal length f satisfies
///    (v1 - o)·(v2 - o) + f² = 0. So f is determined only when both vanishing
///    points are finite.
/// 2. Let G = [g0 g1 g2] be the homography from the unit square to the four
///    corners. Then K⁻¹·g0 = λ·W·r1 and K⁻¹·g1 = λ·H·r2, where r1 and r2 are
///    orthonormal and λ is the unknown homography scale. Dividing gives
///    W/H = |K⁻¹·g0| / |K⁻¹·g1|, and λ cancels.
///
/// Under single-axis tilt, or for an affine view, one vanishing point is at
/// infinity and f is not determined. The result is then null ("not
/// determinable"). The caller keeps its averaged-edge estimate, which is exact
/// for an affine view. The estimate is never used to confirm a physical size.
library;

import 'dart:math' as math;

import 'geometry.dart';

/// Plausible focal length, as a multiple of the longer image edge. A physical
/// focal length f_mm on a sensor of long edge s_mm gives f_px = (f_mm / s_mm) ×
/// long_px. Ordinary phone, camera, and scanner optics fall near 0.4–2.0. The
/// bounds are wider than that, so reasonable optics are not refused. Values
/// outside the bounds mean the vanishing points are unreliable.
const double minFocalToLongEdge = .25;
const double maxFocalToLongEdge = 4;

/// Aspect bounds shared with CropDraft.aspectRatio (.1 to 10).
const double minPhysicalAspect = .1;
const double maxPhysicalAspect = 10;

/// A determinable physical aspect and the focal length it was derived with.
class PhysicalAspectEstimate {
  const PhysicalAspectEstimate({
    required this.aspect,
    required this.focalPixels,
  });

  /// Physical width divided by physical height.
  final double aspect;

  /// Recovered focal length in source pixels.
  final double focalPixels;
}

/// Estimates the physical width/height ratio of the document bounded by
/// [corners] (normalized, clockwise `[TL, TR, BR, BL]`) in a source image of
/// [sourceWidth] × [sourceHeight] pixels. Returns null when the ratio cannot be
/// determined from the four corners alone.
PhysicalAspectEstimate? estimatePhysicalAspect(
  List<Point2> corners, {
  required int sourceWidth,
  required int sourceHeight,
}) {
  if (corners.length != 4 || sourceWidth < 2 || sourceHeight < 2) return null;
  final sx = (sourceWidth - 1).toDouble();
  final sy = (sourceHeight - 1).toDouble();
  final q = [for (final c in corners) Point2(c.x * sx, c.y * sy)];
  // Top and bottom edges run along the width direction; left and right edges
  // run along the height direction.
  final widthVanishing = _intersect(q[0], q[1], q[3], q[2]);
  final heightVanishing = _intersect(q[0], q[3], q[1], q[2]);
  if (widthVanishing == null || heightVanishing == null) return null;
  final cx = sx / 2;
  final cy = sy / 2;
  final ax = widthVanishing.x - cx;
  final ay = widthVanishing.y - cy;
  final bx = heightVanishing.x - cx;
  final by = heightVanishing.y - cy;
  final focalSquared = -(ax * bx + ay * by);
  if (!focalSquared.isFinite || focalSquared <= 0) return null;
  final focal = math.sqrt(focalSquared);
  final longEdge = math.max(sourceWidth, sourceHeight).toDouble();
  if (focal < minFocalToLongEdge * longEdge ||
      focal > maxFocalToLongEdge * longEdge) {
    return null;
  }
  final h = _unitSquareHomography(q);
  if (h == null) return null;
  final g0 = _kInverseNorm(h, 0, cx, cy, focal);
  final g1 = _kInverseNorm(h, 1, cx, cy, focal);
  if (g0 == null || g1 == null || g1 == 0) return null;
  final aspect = g0 / g1;
  // The same bounds as CropDraft.aspectRatio, so a recovered ratio is always a
  // valid draft ratio.
  if (!aspect.isFinite ||
      aspect < minPhysicalAspect ||
      aspect > maxPhysicalAspect) {
    return null;
  }
  return PhysicalAspectEstimate(aspect: aspect, focalPixels: focal);
}

/// Intersection of the infinite line through [a]–[b] with the line through
/// [c]–[d], or null when the lines are parallel to rounding precision.
Point2? _intersect(Point2 a, Point2 b, Point2 c, Point2 d) {
  final rx = b.x - a.x;
  final ry = b.y - a.y;
  final sx = d.x - c.x;
  final sy = d.y - c.y;
  final denominator = rx * sy - ry * sx;
  final scale = math.sqrt((rx * rx + ry * ry) * (sx * sx + sy * sy));
  if (!(scale > 0) || denominator.abs() <= 1e-12 * scale) return null;
  final t = ((c.x - a.x) * sy - (c.y - a.y) * sx) / denominator;
  final x = a.x + t * rx;
  final y = a.y + t * ry;
  if (!x.isFinite || !y.isFinite) return null;
  return Point2(x, y);
}

/// Homography from the unit square to [q] (TL, TR, BR, BL), with h33 = 1.
/// Returns the nine entries row-major, or null when the system is singular.
List<double>? _unitSquareHomography(List<Point2> q) {
  const source = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)];
  final rows = <List<double>>[];
  final rhs = <double>[];
  for (var i = 0; i < 4; i++) {
    final (x, y) = source[i];
    final u = q[i].x;
    final v = q[i].y;
    rows.add([x, y, 1, 0, 0, 0, -u * x, -u * y]);
    rhs.add(u);
    rows.add([0, 0, 0, x, y, 1, -v * x, -v * y]);
    rhs.add(v);
  }
  final solution = _solve(rows, rhs);
  if (solution == null) return null;
  return [...solution, 1];
}

/// Norm of K⁻¹·(column [column] of the homography [h]) for the camera with
/// focal [focal] and principal point ([cx], [cy]).
double? _kInverseNorm(
  List<double> h,
  int column,
  double cx,
  double cy,
  double focal,
) {
  final gx = h[column];
  final gy = h[3 + column];
  final gw = h[6 + column];
  final x = (gx - cx * gw) / focal;
  final y = (gy - cy * gw) / focal;
  final norm = math.sqrt(x * x + y * y + gw * gw);
  return norm.isFinite && norm > 0 ? norm : null;
}

/// Gaussian elimination with partial pivoting for a square system.
List<double>? _solve(List<List<double>> a, List<double> b) {
  final n = b.length;
  final m = [
    for (var i = 0; i < n; i++) [...a[i], b[i]],
  ];
  for (var c = 0; c < n; c++) {
    var pivot = c;
    for (var r = c + 1; r < n; r++) {
      if (m[r][c].abs() > m[pivot][c].abs()) pivot = r;
    }
    if (!(m[pivot][c].abs() > 1e-12)) return null;
    final tmp = m[c];
    m[c] = m[pivot];
    m[pivot] = tmp;
    for (var r = 0; r < n; r++) {
      if (r == c) continue;
      final factor = m[r][c] / m[c][c];
      for (var k = c; k <= n; k++) {
        m[r][k] -= factor * m[c][k];
      }
    }
  }
  final x = [for (var i = 0; i < n; i++) m[i][n] / m[i][i]];
  return x.every((v) => v.isFinite) ? x : null;
}
