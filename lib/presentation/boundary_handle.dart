import 'dart:math' as math;

import '../domain/geometry.dart';

/// What the user grabbed on the crop boundary.
///
/// A crop boundary has four corners and four EDGES. Only offering the corners
/// made the editor feel unresponsive: people naturally press the line they want
/// to move, not always the numbered circle. Representing both explicitly keeps
/// hit testing, dragging and the magnifier on one contract.
sealed class BoundaryHandle {
  const BoundaryHandle();

  /// Corner index, or the index of the edge's first corner.
  int get index;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is BoundaryHandle &&
      other.index == index;

  @override
  int get hashCode => Object.hash(runtimeType, index);
}

/// One of the four corner circles, index 0..3 in `CropGeometry` order.
final class CornerHandle extends BoundaryHandle {
  const CornerHandle(this.index);

  @override
  final int index;

  @override
  String toString() => 'CornerHandle($index)';
}

/// The edge from `corners[index]` to `corners[(index + 1) % 4]`.
final class EdgeHandle extends BoundaryHandle {
  const EdgeHandle(this.index);

  @override
  final int index;

  @override
  String toString() => 'EdgeHandle($index)';
}

/// Screen-space capture radius of a corner, in logical pixels.
///
/// 32 logical px gives a 64 px target — above the platform minimum touch
/// target — and is larger than the 40 px handle drawn on screen, so a finger
/// that lands anywhere on the visible circle always starts the drag.
const double cornerCaptureRadiusPx = 32;

/// Screen-space half-width of an edge's capture band, in logical pixels.
const double edgeCaptureWidthPx = 18;

/// Shortest distance from [point] to the segment [a]–[b].
///
/// The projection is clamped to the segment, so grabbing near (but beyond) an
/// endpoint does not select that edge; corners take priority there.
double distanceToSegment(Point2 point, Point2 a, Point2 b) {
  final dx = b.x - a.x;
  final dy = b.y - a.y;
  final lengthSquared = dx * dx + dy * dy;
  if (lengthSquared <= 0) {
    final ex = point.x - a.x;
    final ey = point.y - a.y;
    return math.sqrt(ex * ex + ey * ey);
  }
  final t = (((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared)
      .clamp(0.0, 1.0);
  final px = a.x + t * dx - point.x;
  final py = a.y + t * dy - point.y;
  return math.sqrt(px * px + py * py);
}

/// The handle under [point], where [corners] and [point] are in the SAME
/// coordinate space (the viewer's content coordinates).
///
/// Corners win over edges: near an endpoint the user is adjusting that corner,
/// not sliding the whole edge. Exact ties resolve to the lowest index, so the
/// result never depends on pointer order or float noise. Returns null outside
/// every capture region, leaving the pointer free to pan the viewer.
BoundaryHandle? boundaryHandleAt(
  List<Point2> corners,
  Point2 point, {
  double cornerRadius = cornerCaptureRadiusPx,
  double edgeWidth = edgeCaptureWidthPx,
}) {
  if (corners.length != 4 ||
      !cornerRadius.isFinite ||
      !edgeWidth.isFinite ||
      cornerRadius < 0 ||
      edgeWidth < 0) {
    return null;
  }

  int? bestCorner;
  var bestCornerDistance = double.infinity;
  for (var i = 0; i < 4; i++) {
    final dx = corners[i].x - point.x;
    final dy = corners[i].y - point.y;
    final distance = math.sqrt(dx * dx + dy * dy);
    if (distance <= cornerRadius && distance < bestCornerDistance) {
      bestCorner = i;
      bestCornerDistance = distance;
    }
  }
  if (bestCorner != null) return CornerHandle(bestCorner);

  int? bestEdge;
  var bestEdgeDistance = double.infinity;
  for (var i = 0; i < 4; i++) {
    final distance = distanceToSegment(point, corners[i], corners[(i + 1) % 4]);
    if (distance <= edgeWidth && distance < bestEdgeDistance) {
      bestEdge = i;
      bestEdgeDistance = distance;
    }
  }
  return bestEdge == null ? null : EdgeHandle(bestEdge);
}

/// The two corner indices an [EdgeHandle] moves together.
({int first, int second}) edgeCorners(int edgeIndex) =>
    (first: edgeIndex % 4, second: (edgeIndex + 1) % 4);
