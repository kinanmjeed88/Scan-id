import 'dart:math' as math;

import 'validation.dart';
import 'image_limits.dart';

double millimetersToPixels(double mm, int dpi) {
  require(mm.isFinite && mm >= 0 && dpi > 0, 'قياس أو دقة غير صالحين.');
  return mm / 25.4 * dpi;
}

double millimetersToPoints(double mm) {
  require(mm.isFinite && mm >= 0, 'قياس غير صالح.');
  return mm / 25.4 * 72;
}

class Point2 {
  Point2(this.x, this.y) {
    require(x.isFinite && y.isFinite, 'إحداثيات غير صالحة.');
  }
  final double x;
  final double y;
  Map<String, Object?> toJson() => {'x': x, 'y': y};
  factory Point2.fromJson(Object? json) {
    final map = objectMap(json);
    return Point2(finiteNumber(map['x'], 'x'), finiteNumber(map['y'], 'y'));
  }
}

class RectMm {
  RectMm(this.x, this.y, this.width, this.height) {
    require(
      [x, y, width, height].every((v) => v.isFinite) && width > 0 && height > 0,
      'أبعاد المستطيل غير صالحة.',
    );
  }
  final double x;
  final double y;
  final double width;
  final double height;
  double get right => x + width;
  double get bottom => y + height;

  Map<String, Object?> toJson() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };
  factory RectMm.fromJson(Object? json) {
    final m = objectMap(json);
    return RectMm(
      finiteNumber(m['x'], 'x'),
      finiteNumber(m['y'], 'y'),
      finiteNumber(m['width'], 'width'),
      finiteNumber(m['height'], 'height'),
    );
  }

  bool contains(RectMm other, {double tolerance = 0.000001}) =>
      other.x >= x - tolerance &&
      other.y >= y - tolerance &&
      other.right <= right + tolerance &&
      other.bottom <= bottom + tolerance;

  bool overlaps(RectMm other) =>
      x < other.right &&
      right > other.x &&
      y < other.bottom &&
      bottom > other.y;

  /// Axis-aligned bounding box of a rotation around the rectangle center.
  RectMm rotatedBounds(double degrees) {
    require(degrees.isFinite, 'زاوية غير صالحة.');
    final radians = degrees * math.pi / 180;
    final c = math.cos(radians).abs();
    final s = math.sin(radians).abs();
    final w = width * c + height * s;
    final h = width * s + height * c;
    return RectMm(x + (width - w) / 2, y + (height - h) / 2, w, h);
  }
}

/// Ordered TL, TR, BR, BL in image coordinates (positive Y downwards).
/// A convex clockwise quadrilateral is required; a crossed or degenerate
/// polygon can never become a processing request.
class CropGeometry {
  CropGeometry({
    required List<Point2> corners,
    required this.outputWidth,
    required this.outputHeight,
  }) : corners = List.unmodifiable(corners) {
    require(corners.length == 4, 'يجب تحديد أربع زوايا.');
    require(
      withinImageBudget(outputWidth, outputHeight),
      'أبعاد القص تتجاوز حد المعالجة الآمن.',
    );
    for (final p in corners) {
      require(
        p.x >= 0 && p.x <= 1 && p.y >= 0 && p.y <= 1,
        'زوايا القص خارج الصورة.',
      );
    }
    var twiceArea = 0.0;
    for (var i = 0; i < 4; i++) {
      final a = corners[i];
      final b = corners[(i + 1) % 4];
      final c = corners[(i + 2) % 4];
      final cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
      require(
        cross > 0.000001,
        'زوايا القص متقاطعة أو غير مرتبة أو متقاربة جداً.',
      );
      twiceArea += a.x * b.y - b.x * a.y;
    }
    require(twiceArea > 0.0001, 'مساحة القص صغيرة جداً.');
  }
  final List<Point2> corners;
  final int outputWidth;
  final int outputHeight;

  Map<String, Object?> toJson() => {
    'corners': corners.map((p) => p.toJson()).toList(),
    'outputWidth': outputWidth,
    'outputHeight': outputHeight,
  };
  factory CropGeometry.fromJson(Object? json) {
    final map = objectMap(json);
    return CropGeometry(
      corners: objectList(map['corners']).map(Point2.fromJson).toList(),
      outputWidth: integer(map['outputWidth'], 'outputWidth'),
      outputHeight: integer(map['outputHeight'], 'outputHeight'),
    );
  }
}
