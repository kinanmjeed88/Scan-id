import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../domain/geometry.dart';
import '../domain/validation.dart';
import 'prepare_image.dart';

/// Conservative local edge-component proposal. It may return null and never
/// applies a crop. No neural model, network request or optimality claim.
List<Point2>? suggestDocumentCorners(Uint8List preview) {
  final decoded = decodeForProcessing(preview);
  if (decoded.width < 20 || decoded.height < 20) {
    return null;
  }
  final source = img.copyResize(
    decoded,
    width: decoded.width >= decoded.height
        ? math.min(512, decoded.width)
        : null,
    height: decoded.height > decoded.width
        ? math.min(512, decoded.height)
        : null,
  );
  final gray = img.gaussianBlur(img.grayscale(source), radius: 1);
  final width = gray.width, height = gray.height;
  final strength = Float64List(width * height);
  var peak = 0.0;
  double luma(int x, int y) => gray.getPixel(x, y).r.toDouble();
  for (var y = 1; y < height - 1; y++) {
    for (var x = 1; x < width - 1; x++) {
      final gx =
          -luma(x - 1, y - 1) -
          2 * luma(x - 1, y) -
          luma(x - 1, y + 1) +
          luma(x + 1, y - 1) +
          2 * luma(x + 1, y) +
          luma(x + 1, y + 1);
      final gy =
          -luma(x - 1, y - 1) -
          2 * luma(x, y - 1) -
          luma(x + 1, y - 1) +
          luma(x - 1, y + 1) +
          2 * luma(x, y + 1) +
          luma(x + 1, y + 1);
      final value = math.sqrt(gx * gx + gy * gy);
      strength[y * width + x] = value;
      peak = math.max(peak, value);
    }
  }
  if (peak < 60) {
    return null;
  }
  final threshold = math.max(40.0, peak * .22);
  final visited = Uint8List(width * height);
  List<Point2>? best;
  var bestArea = 0.0;
  for (var start = 0; start < strength.length; start++) {
    if (visited[start] != 0 || strength[start] < threshold) {
      continue;
    }
    final queue = <int>[start];
    visited[start] = 1;
    final points = <Point2>[];
    for (var head = 0; head < queue.length; head++) {
      final index = queue[head], x = index % width, y = index ~/ width;
      points.add(Point2(x.toDouble(), y.toDouble()));
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final nx = x + dx, ny = y + dy;
          if (nx < 1 || ny < 1 || nx >= width - 1 || ny >= height - 1) {
            continue;
          }
          final next = ny * width + nx;
          if (visited[next] == 0 && strength[next] >= threshold) {
            visited[next] = 1;
            queue.add(next);
          }
        }
      }
    }
    if (points.length < 40) {
      continue;
    }
    final hull = _hull(points);
    if (hull.length < 4) {
      continue;
    }
    final hullArea = _area(hull);
    if (hullArea < width * height * .08) {
      continue;
    }
    final quad = [...hull];
    while (quad.length > 4) {
      var remove = 0, smallest = double.infinity;
      for (var i = 0; i < quad.length; i++) {
        final cost = _cross(
          quad[(i - 1 + quad.length) % quad.length],
          quad[i],
          quad[(i + 1) % quad.length],
        ).abs();
        if (cost < smallest) {
          smallest = cost;
          remove = i;
        }
      }
      quad.removeAt(remove);
    }
    final area = _area(quad);
    if (area / hullArea < .9 || area <= bestArea) {
      continue;
    }
    // An edge touching the photo border is ambiguous, not an automatic crop.
    if (quad.any(
      (p) => p.x <= 1 || p.y <= 1 || p.x >= width - 2 || p.y >= height - 2,
    )) {
      continue;
    }
    var first = 0;
    for (var i = 1; i < 4; i++) {
      if (quad[i].x + quad[i].y < quad[first].x + quad[first].y) {
        first = i;
      }
    }
    final normalized = List.generate(4, (i) {
      final p = quad[(first + i) % 4];
      return Point2(p.x / (width - 1), p.y / (height - 1));
    });
    try {
      CropGeometry(corners: normalized, outputWidth: 1, outputHeight: 1);
      best = normalized;
      bestArea = area;
    } on ValidationException {
      continue;
    }
  }
  return best;
}

double _cross(Point2 a, Point2 b, Point2 c) =>
    (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
double _area(List<Point2> points) {
  var value = 0.0;
  for (var i = 0; i < points.length; i++) {
    final a = points[i], b = points[(i + 1) % points.length];
    value += a.x * b.y - b.x * a.y;
  }
  return value.abs() / 2;
}

List<Point2> _hull(List<Point2> points) {
  points.sort((a, b) {
    final x = a.x.compareTo(b.x);
    return x == 0 ? a.y.compareTo(b.y) : x;
  });
  final lower = <Point2>[], upper = <Point2>[];
  for (final p in points) {
    while (lower.length >= 2 &&
        _cross(lower[lower.length - 2], lower.last, p) <= 0) {
      lower.removeLast();
    }
    lower.add(p);
  }
  for (final p in points.reversed) {
    while (upper.length >= 2 &&
        _cross(upper[upper.length - 2], upper.last, p) <= 0) {
      upper.removeLast();
    }
    upper.add(p);
  }
  return [...lower.take(lower.length - 1), ...upper.take(upper.length - 1)];
}
