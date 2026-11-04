/// DB text-detection post-processing: a probability map becomes text-line
/// boxes (ADR-010).
///
/// This is the deterministic, model-free half of text detection and it is a
/// direct port of the reference post-processing that PP-OCR detection exports
/// are trained against:
///
/// 1. pixels at or above [defaultBitmapThreshold] are grouped into
///    eight-connected components;
/// 2. a component's score is the mean probability of its pixels, and
///    components below [defaultBoxThreshold] or thinner than `minSize` are
///    dropped, so speckle and paper texture cannot become "text";
/// 3. each component's minimum-area rotated rectangle is unclipped (grown) by
///    `area × unclipRatio / perimeter` on every side, which recovers the outer
///    edge of a shrunk text region;
/// 4. boxes are returned in reading order (top-to-bottom, then left-to-right),
///    with each quad ordered clockwise from its top-left corner and its long
///    axis horizontal, ready for recognition.
///
/// Everything here is pure: no I/O, no model, no isolate-affine state. The
/// caller supplies the probability map and the axis scales back to source
/// pixels, which is what makes the stage unit-testable without ONNX Runtime.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../domain/geometry.dart';
import '../domain/validation.dart';

/// Probability above which a pixel is inside a text region.
const double defaultBitmapThreshold = .3;

/// Mean component probability below which a box is rejected.
const double defaultBoxThreshold = .6;

/// Shrink compensation applied to every detected region.
const double defaultUnclipRatio = 1.5;

/// Boundary points sampled per component before the minimum-area rectangle is
/// fitted. Text components are narrow, so this only bounds pathological blobs.
const int _maxBoundaryPoints = 6000;

/// One detected text line, in source-image pixels.
class TextLineBox {
  TextLineBox({
    required this.corners,
    required this.score,
    required this.lineHeight,
  }) : left = _minCoordinate(corners, axis: _Axis.horizontal),
       top = _minCoordinate(corners, axis: _Axis.vertical) {
    require(corners.length == 4, 'صندوق سطر OCR يجب أن يكون أربع نقاط.');
    require(
      score.isFinite && score >= 0 && score <= 1,
      'ثقة صندوق سطر OCR يجب أن تكون بين 0 و1.',
    );
    require(
      lineHeight.isFinite && lineHeight > 0,
      'ارتفاع سطر OCR يجب أن يكون موجباً.',
    );
  }

  /// Clockwise from the top-left corner; the long axis is horizontal.
  final List<Point2> corners;

  /// Mean detector probability inside the box.
  final double score;

  /// Short side of the box, in source pixels.
  final double lineHeight;

  /// Leftmost coordinate, used for reading order.
  final double left;

  /// Topmost coordinate, used for reading order.
  final double top;
}

/// Decodes [probabilityMap] (row-major, `width × height`) into text lines.
///
/// [scaleX] and [scaleY] convert tensor coordinates to source pixels, so a
/// detector that ran on a resampled image still reports source geometry.
List<TextLineBox> decodeTextBoxes(
  Float32List probabilityMap, {
  required int width,
  required int height,
  double bitmapThreshold = defaultBitmapThreshold,
  double boxThreshold = defaultBoxThreshold,
  double unclipRatio = defaultUnclipRatio,
  int minSize = 3,
  int maxCandidates = 1000,
  double scaleX = 1,
  double scaleY = 1,
}) {
  require(
    width >= 2 && height >= 2,
    'أبعاد خريطة الاحتمال يجب أن تكون نقطتين على الأقل.',
  );
  require(
    probabilityMap.length == width * height,
    'حجم خريطة الاحتمال لا يطابق أبعادها.',
  );
  require(
    bitmapThreshold.isFinite &&
        boxThreshold.isFinite &&
        unclipRatio.isFinite &&
        unclipRatio > 0 &&
        minSize >= 1 &&
        maxCandidates >= 1 &&
        scaleX.isFinite &&
        scaleX > 0 &&
        scaleY.isFinite &&
        scaleY > 0,
    'معاملات فك صناديق النص غير صالحة.',
  );

  final mask = Uint8List(width * height);
  for (var index = 0; index < mask.length; index++) {
    final value = probabilityMap[index];
    mask[index] = value.isFinite && value >= bitmapThreshold ? 1 : 0;
  }

  final visited = Uint8List(width * height);
  final stack = Int32List(width * height);
  final components = <_Component>[];

  for (var start = 0; start < mask.length; start++) {
    if (mask[start] == 0 || visited[start] != 0) continue;
    visited[start] = 1;
    var top = 0;
    stack[top++] = start;
    var count = 0;
    var total = 0.0;
    final boundary = <Point2>[];
    while (top > 0) {
      final index = stack[--top];
      count++;
      total += probabilityMap[index];
      final x = index % width;
      final y = index ~/ width;
      var isBoundary = false;
      for (var dy = -1; dy <= 1; dy++) {
        final ny = y + dy;
        for (var dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = x + dx;
          if (nx < 0 || ny < 0 || nx >= width || ny >= height) {
            isBoundary = true;
            continue;
          }
          final neighbour = ny * width + nx;
          if (mask[neighbour] == 0) {
            isBoundary = true;
            continue;
          }
          if (visited[neighbour] != 0) continue;
          visited[neighbour] = 1;
          stack[top++] = neighbour;
        }
      }
      if (isBoundary && boundary.length < _maxBoundaryPoints) {
        boundary.add(Point2(x + .5, y + .5));
      }
    }
    if (count == 0) continue;
    components.add(
      _Component(count: count, score: total / count, boundary: boundary),
    );
  }

  final candidates = <_Candidate>[];
  for (final component in components) {
    if (component.count < minSize) continue;
    if (!component.score.isFinite || component.score < boxThreshold) continue;
    if (component.boundary.length < 3) continue;
    final rect = _minAreaRect(component.boundary);
    // The reference rejects boxes that are thinner than `minSize` in either
    // direction before unclipping; shrinking is symmetric, so testing the
    // measured rectangle is equivalent and keeps noise out.
    if (2 * rect.halfU < minSize || 2 * rect.halfV < minSize) continue;
    final area = 4 * rect.halfU * rect.halfV;
    final perimeter = 4 * (rect.halfU + rect.halfV);
    if (!area.isFinite || !perimeter.isFinite || perimeter <= 0) continue;
    final grow = area * unclipRatio / perimeter;
    if (!grow.isFinite || grow <= 0) continue;
    final halfU = rect.halfU + grow;
    final halfV = rect.halfV + grow;
    final corners = _cornersOf(
      rect,
      halfU: halfU,
      halfV: halfV,
      width: width,
      height: height,
      scaleX: scaleX,
      scaleY: scaleY,
    );
    candidates.add(
      _Candidate(
        box: TextLineBox(
          corners: corners,
          score: component.score,
          lineHeight: math.max(1.0, 2 * halfV * scaleY),
        ),
      ),
    );
  }

  candidates.sort((a, b) => b.box.score.compareTo(a.box.score));
  final capped = candidates.length > maxCandidates
      ? candidates.sublist(0, maxCandidates)
      : candidates;
  final boxes = [for (final candidate in capped) candidate.box];
  boxes.sort((a, b) {
    final vertical = a.top.compareTo(b.top);
    return vertical != 0 ? vertical : a.left.compareTo(b.left);
  });
  return List.unmodifiable(boxes);
}

enum _Axis { horizontal, vertical }

double _minCoordinate(List<Point2> corners, {required _Axis axis}) {
  var minimum = double.infinity;
  for (final corner in corners) {
    final value = axis == _Axis.horizontal ? corner.x : corner.y;
    if (value < minimum) minimum = value;
  }
  return minimum.isFinite ? minimum : 0;
}

class _Component {
  const _Component({
    required this.count,
    required this.score,
    required this.boundary,
  });

  final int count;
  final double score;
  final List<Point2> boundary;
}

class _Candidate {
  const _Candidate({required this.box});

  final TextLineBox box;
}

/// A rotated rectangle: centre, unit axes and half extents.
class _OrientedRect {
  const _OrientedRect({
    required this.center,
    required this.axisU,
    required this.axisV,
    required this.halfU,
    required this.halfV,
  });

  final Point2 center;
  final Point2 axisU;
  final Point2 axisV;
  final double halfU;
  final double halfV;
}

List<Point2> _cornersOf(
  _OrientedRect rect, {
  required double halfU,
  required double halfV,
  required int width,
  required int height,
  required double scaleX,
  required double scaleY,
}) {
  final center = rect.center;
  final u = rect.axisU;
  final v = rect.axisV;
  Point2 corner(int signU, int signV) {
    final x = center.x + signU * u.x * halfU + signV * v.x * halfV;
    final y = center.y + signU * u.y * halfU + signV * v.y * halfV;
    final clampedX = x.clamp(0.0, width.toDouble()).toDouble();
    final clampedY = y.clamp(0.0, height.toDouble()).toDouble();
    return Point2(clampedX * scaleX, clampedY * scaleY);
  }

  return [corner(-1, -1), corner(1, -1), corner(1, 1), corner(-1, 1)];
}

/// Minimum-area rectangle of [points]: convex hull, then one pass of rotating
/// calipers per hull edge.
_OrientedRect _minAreaRect(List<Point2> points) {
  final hull = _convexHull(points);
  if (hull.length < 3) return _axisAlignedRect(points);
  var bestArea = double.infinity;
  _OrientedRect? best;
  for (var index = 0; index < hull.length; index++) {
    final a = hull[index];
    final b = hull[(index + 1) % hull.length];
    final dx = b.x - a.x;
    final dy = b.y - a.y;
    final length = math.sqrt(dx * dx + dy * dy);
    if (!(length > 1e-9)) continue;
    final ex = dx / length;
    final ey = dy / length;
    var minU = double.infinity;
    var maxU = double.negativeInfinity;
    var minV = double.infinity;
    var maxV = double.negativeInfinity;
    for (final point in hull) {
      final ox = point.x - a.x;
      final oy = point.y - a.y;
      final u = ox * ex + oy * ey;
      final v = -ox * ey + oy * ex;
      if (u < minU) minU = u;
      if (u > maxU) maxU = u;
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
    }
    final area = (maxU - minU) * (maxV - minV);
    if (!area.isFinite || area >= bestArea) continue;
    bestArea = area;
    final centerU = (minU + maxU) / 2;
    final centerV = (minV + maxV) / 2;
    best = _OrientedRect(
      center: Point2(
        a.x + ex * centerU - ey * centerV,
        a.y + ey * centerU + ex * centerV,
      ),
      axisU: Point2(ex, ey),
      axisV: Point2(-ey, ex),
      halfU: (maxU - minU) / 2,
      halfV: (maxV - minV) / 2,
    );
  }
  final found = best;
  if (found == null) return _axisAlignedRect(points);
  return _readingOrientation(found);
}

/// Orders a rectangle so its long axis points right and its short axis down.
///
/// Recognition reads left-to-right along the long axis; a text line detected at
/// 90° would otherwise be fed to the recogniser as a column of characters.
_OrientedRect _readingOrientation(_OrientedRect rect) {
  var u = rect.axisU;
  var v = rect.axisV;
  var halfU = rect.halfU;
  var halfV = rect.halfV;
  if (halfU < halfV) {
    final swapAxis = u;
    u = v;
    v = swapAxis;
    final swapHalf = halfU;
    halfU = halfV;
    halfV = swapHalf;
  }
  if (u.x < 0) u = Point2(-u.x, -u.y);
  if (v.y < 0) v = Point2(-v.x, -v.y);
  return _OrientedRect(
    center: rect.center,
    axisU: u,
    axisV: v,
    halfU: halfU,
    halfV: halfV,
  );
}

_OrientedRect _axisAlignedRect(List<Point2> points) {
  var minX = double.infinity;
  var maxX = double.negativeInfinity;
  var minY = double.infinity;
  var maxY = double.negativeInfinity;
  for (final point in points) {
    if (point.x < minX) minX = point.x;
    if (point.x > maxX) maxX = point.x;
    if (point.y < minY) minY = point.y;
    if (point.y > maxY) maxY = point.y;
  }
  if (!minX.isFinite || !maxX.isFinite || !minY.isFinite || !maxY.isFinite) {
    return _OrientedRect(
      center: Point2(.5, .5),
      axisU: Point2(1, 0),
      axisV: Point2(0, 1),
      halfU: .5,
      halfV: .5,
    );
  }
  return _OrientedRect(
    center: Point2((minX + maxX) / 2, (minY + maxY) / 2),
    axisU: Point2(1, 0),
    axisV: Point2(0, 1),
    halfU: (maxX - minX) / 2,
    halfV: (maxY - minY) / 2,
  );
}

/// Andrew's monotone chain. Returns the hull counter-clockwise without the
/// duplicated closing point.
List<Point2> _convexHull(List<Point2> points) {
  if (points.length < 3) return List<Point2>.unmodifiable(points);
  final sorted = [...points]
    ..sort((a, b) {
      final horizontal = a.x.compareTo(b.x);
      return horizontal != 0 ? horizontal : a.y.compareTo(b.y);
    });
  double cross(Point2 o, Point2 a, Point2 b) =>
      (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
  final hull = <Point2>[];
  for (final point in sorted) {
    while (hull.length >= 2 &&
        cross(hull[hull.length - 2], hull[hull.length - 1], point) <= 0) {
      hull.removeLast();
    }
    hull.add(point);
  }
  final lowerSize = hull.length + 1;
  for (var index = sorted.length - 2; index >= 0; index--) {
    final point = sorted[index];
    while (hull.length >= lowerSize &&
        cross(hull[hull.length - 2], hull[hull.length - 1], point) <= 0) {
      hull.removeLast();
    }
    hull.add(point);
  }
  if (hull.isNotEmpty) hull.removeLast();
  return hull;
}
