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

/// Image rectangle fitted uniformly inside an item slot, centered.
///
/// The returned size has the source aspect. One slot edge matches; the other
/// is shorter, so the difference is a margin rather than a stretch. Units are
/// the same as [itemWidth] and [itemHeight] (millimetres at the call site).
({double x, double y, double width, double height}) containedDocumentRect({
  required double itemX,
  required double itemY,
  required double itemWidth,
  required double itemHeight,
  required int imageWidth,
  required int imageHeight,
}) {
  require(
    [itemX, itemY, itemWidth, itemHeight].every((value) => value.isFinite) &&
        itemWidth > 0 &&
        itemHeight > 0 &&
        imageWidth > 0 &&
        imageHeight > 0,
    'أبعاد الاحتواء غير صالحة.',
  );
  final imageAspect = imageWidth / imageHeight;
  final boxAspect = itemWidth / itemHeight;
  final width = imageAspect >= boxAspect ? itemWidth : itemHeight * imageAspect;
  final height = imageAspect >= boxAspect
      ? itemWidth / imageAspect
      : itemHeight;
  return (
    x: itemX + (itemWidth - width) / 2,
    y: itemY + (itemHeight - height) / 2,
    width: width,
    height: height,
  );
}

/// Native pixel density at the actual contained size, not the empty slot.
/// Rotation of the slot does not change this density.
double containedDocumentDpi({
  required double itemWidth,
  required double itemHeight,
  required int imageWidth,
  required int imageHeight,
}) {
  final fitted = containedDocumentRect(
    itemX: 0,
    itemY: 0,
    itemWidth: itemWidth,
    itemHeight: itemHeight,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
  );
  // The limiting edge gives the uniform scale directly. Taking the minimum
  // of both fitted-axis ratios introduces rounding from the derived edge:
  // 80x8 in 50.8mm can become 39.99999999999999 instead of 40 DPI.
  return fitted.width == itemWidth
      ? imageWidth * 25.4 / itemWidth
      : imageHeight * 25.4 / itemHeight;
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
/// Why a normalized crop ring cannot be used by a perspective renderer.
enum QuadGeometryIssue {
  wrongPointCount,
  nonFiniteCoordinates,
  outOfBounds,
  notConvex,
  collapsedArea,
  singularPerspective,
}

/// Projective unit-square -> normalized source mapping.
///
/// This is pure domain mathematics: the manual validator, detector assessment,
/// persisted geometry and raster renderer all use the same singularity contract.
/// It does not infer a document, a physical size, or an output aspect ratio.
class PerspectiveCoefficients {
  const PerspectiveCoefficients._(
    this.a,
    this.b,
    this.c,
    this.d,
    this.e,
    this.f,
    this.g,
    this.h,
  );

  static PerspectiveCoefficients? tryFrom(List<Point2> p) {
    if (p.length != 4 ||
        p.any((point) => !point.x.isFinite || !point.y.isFinite)) {
      return null;
    }
    final dx1 = p[1].x - p[2].x;
    final dx2 = p[3].x - p[2].x;
    final dx3 = p[0].x - p[1].x + p[2].x - p[3].x;
    final dy1 = p[1].y - p[2].y;
    final dy2 = p[3].y - p[2].y;
    final dy3 = p[0].y - p[1].y + p[2].y - p[3].y;
    double g = 0, h = 0;
    if (dx3.abs() + dy3.abs() >= 1e-12) {
      final determinant = dx1 * dy2 - dx2 * dy1;
      if (!determinant.isFinite || determinant.abs() <= 1e-12) return null;
      g = (dx3 * dy2 - dx2 * dy3) / determinant;
      h = (dx1 * dy3 - dx3 * dy1) / determinant;
    }
    final result = PerspectiveCoefficients._(
      p[1].x - p[0].x + g * p[1].x,
      p[3].x - p[0].x + h * p[3].x,
      p[0].x,
      p[1].y - p[0].y + g * p[1].y,
      p[3].y - p[0].y + h * p[3].y,
      p[0].y,
      g,
      h,
    );
    final values = [
      result.a,
      result.b,
      result.c,
      result.d,
      result.e,
      result.f,
      result.g,
      result.h,
    ];
    final denominators = [1.0, 1 + g, 1 + h, 1 + g + h];
    if (!values.every((v) => v.isFinite) ||
        !denominators.every((v) => v.isFinite && v > 1e-9)) {
      return null;
    }
    return result;
  }

  final double a, b, c, d, e, f, g, h;

  Point2 at(double u, double v) {
    final denominator = g * u + h * v + 1;
    return Point2(
      (a * u + b * v + c) / denominator,
      (d * u + e * v + f) / denominator,
    );
  }
}

/// Validates the ordered normalized ring, independently of image content.
/// Caller-specific area/edge/confidence gates remain in their own layers.
QuadGeometryIssue? normalizedQuadIssue(List<Point2> corners) {
  if (corners.length != 4) return QuadGeometryIssue.wrongPointCount;
  if (corners.any((p) => !p.x.isFinite || !p.y.isFinite)) {
    return QuadGeometryIssue.nonFiniteCoordinates;
  }
  if (corners.any((p) => p.x < 0 || p.x > 1 || p.y < 0 || p.y > 1)) {
    return QuadGeometryIssue.outOfBounds;
  }
  var twiceArea = 0.0;
  for (var i = 0; i < 4; i++) {
    final a = corners[i];
    final b = corners[(i + 1) % 4];
    final c = corners[(i + 2) % 4];
    final cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
    if (!cross.isFinite || cross <= 1e-6) return QuadGeometryIssue.notConvex;
    twiceArea += a.x * b.y - b.x * a.y;
  }
  if (!twiceArea.isFinite || twiceArea <= 1e-4) {
    return QuadGeometryIssue.collapsedArea;
  }
  if (PerspectiveCoefficients.tryFrom(corners) == null) {
    return QuadGeometryIssue.singularPerspective;
  }
  return null;
}

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
    const messages = {
      QuadGeometryIssue.wrongPointCount: 'يجب تحديد أربع زوايا.',
      QuadGeometryIssue.nonFiniteCoordinates: 'إحداثيات زوايا القص غير صالحة.',
      QuadGeometryIssue.outOfBounds: 'زوايا القص خارج الصورة.',
      QuadGeometryIssue.notConvex:
          'زوايا القص متقاطعة أو غير مرتبة أو متقاربة جداً.',
      QuadGeometryIssue.collapsedArea: 'مساحة القص صغيرة جداً.',
      QuadGeometryIssue.singularPerspective:
          'تحويل المنظور غير مستقر؛ عدّل الزوايا.',
    };
    final issue = normalizedQuadIssue(corners);
    require(issue == null, messages[issue] ?? 'زوايا القص غير صالحة.');
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
