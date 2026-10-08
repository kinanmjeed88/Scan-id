/// Geometry refinement for detected quadrilaterals: deterministic validation
/// plus a measured geometry confidence (AUDIT.md §D.2).
///
/// The confidence here is derived from NAMED, measurable factors (corner
/// angles, opposite-edge agreement, covered area). It is a geometry quality
/// score, deliberately separate from detection and classification confidence,
/// and it is never invented for a rejected quadrilateral.
library;

import 'dart:math' as math;

import 'geometry.dart';

/// Why a quadrilateral was rejected, when it was.
enum QuadRejection {
  wrongPointCount,
  outOfBounds,
  notConvex,
  tooSmall,
  degenerateEdges,
  implausibleAspect,
}

class QuadAssessment {
  const QuadAssessment._({
    required this.acceptable,
    this.rejection,
    this.geometryConfidence,
    this.aspect,
    this.areaFraction,
  });

  const QuadAssessment.rejected(QuadRejection reason)
    : this._(acceptable: false, rejection: reason);

  const QuadAssessment.accepted({
    required double geometryConfidence,
    required double aspect,
    required double areaFraction,
  }) : this._(
         acceptable: true,
         geometryConfidence: geometryConfidence,
         aspect: aspect,
         areaFraction: areaFraction,
       );

  final bool acceptable;
  final QuadRejection? rejection;

  /// Measured geometry quality in 0..1; null when rejected.
  final double? geometryConfidence;

  /// Long edge / short edge of the quadrilateral in PIXEL space; null when
  /// rejected. Uses the source pixel aspect so a perspective-corrected crop of
  /// this quad has approximately this proportion.
  final double? aspect;

  /// Quad area as a fraction of the full frame; null when rejected.
  final double? areaFraction;
}

double _distance(Point2 a, Point2 b, int width, int height) => math.sqrt(
  math.pow((a.x - b.x) * (width - 1), 2) +
      math.pow((a.y - b.y) * (height - 1), 2),
);

/// Validates [corners] (normalized 0..1, ordered like `CropGeometry`: a
/// clockwise screen-space ring starting top-left) against [sourceWidth] ×
/// [sourceHeight] and scores the accepted geometry.
QuadAssessment assessQuad(
  List<Point2> corners, {
  required int sourceWidth,
  required int sourceHeight,
}) {
  if (corners.length != 4) {
    return const QuadAssessment.rejected(QuadRejection.wrongPointCount);
  }
  for (final p in corners) {
    if (p.x < -0.001 || p.x > 1.001 || p.y < -0.001 || p.y > 1.001) {
      return const QuadAssessment.rejected(QuadRejection.outOfBounds);
    }
  }
  // Convexity and consistent winding in pixel space.
  final px = [for (final p in corners) p.x * (sourceWidth - 1)];
  final py = [for (final p in corners) p.y * (sourceHeight - 1)];
  var twiceArea = 0.0;
  for (var i = 0; i < 4; i++) {
    final j = (i + 1) % 4;
    final k = (i + 2) % 4;
    final cross =
        (px[j] - px[i]) * (py[k] - py[j]) - (py[j] - py[i]) * (px[k] - px[j]);
    if (cross <= 0) {
      return const QuadAssessment.rejected(QuadRejection.notConvex);
    }
    twiceArea += px[i] * py[j] - px[j] * py[i];
  }
  final area = twiceArea.abs() / 2;
  final frame = (sourceWidth - 1).toDouble() * (sourceHeight - 1);
  final areaFraction = frame <= 0 ? 0.0 : area / frame;
  if (areaFraction < .02) {
    return const QuadAssessment.rejected(QuadRejection.tooSmall);
  }
  final top = _distance(corners[0], corners[1], sourceWidth, sourceHeight);
  final bottom = _distance(corners[3], corners[2], sourceWidth, sourceHeight);
  final left = _distance(corners[0], corners[3], sourceWidth, sourceHeight);
  final right = _distance(corners[1], corners[2], sourceWidth, sourceHeight);
  final edges = [top, bottom, left, right];
  if (edges.any((e) => e < 4)) {
    return const QuadAssessment.rejected(QuadRejection.degenerateEdges);
  }
  // Opposite edges of a perspective view of a rectangle stay comparable.
  final horizontalRatio = math.max(top, bottom) / math.min(top, bottom);
  final verticalRatio = math.max(left, right) / math.min(left, right);
  if (horizontalRatio > 2.5 || verticalRatio > 2.5) {
    return const QuadAssessment.rejected(QuadRejection.degenerateEdges);
  }
  final width = (top + bottom) / 2;
  final height = (left + right) / 2;
  final aspect = math.max(width, height) / math.min(width, height);
  if (aspect > 12) {
    return const QuadAssessment.rejected(QuadRejection.implausibleAspect);
  }
  // Measured quality factors, each in 0..1:
  // 1. Corner angles close to 90° (a rectangle under mild perspective).
  var angleScore = 1.0;
  for (var i = 0; i < 4; i++) {
    final previous = (i + 3) % 4;
    final next = (i + 1) % 4;
    final v1x = px[previous] - px[i], v1y = py[previous] - py[i];
    final v2x = px[next] - px[i], v2y = py[next] - py[i];
    final n1 = math.sqrt(v1x * v1x + v1y * v1y);
    final n2 = math.sqrt(v2x * v2x + v2y * v2y);
    final cosine = ((v1x * v2x + v1y * v2y) / (n1 * n2)).clamp(-1.0, 1.0);
    final angle = math.acos(cosine) * 180 / math.pi;
    final deviation = (angle - 90).abs();
    angleScore = math.min(angleScore, (1 - deviation / 45).clamp(0.0, 1.0));
  }
  // 2. Opposite-edge agreement (1 at ratio 1, 0 at the 2.5 rejection bound).
  final edgeScore = (1 - (math.max(horizontalRatio, verticalRatio) - 1) / 1.5)
      .clamp(0.0, 1.0);
  // 3. Covered area (full marks from 15% of the frame upwards).
  final areaScore = (areaFraction / .15).clamp(0.0, 1.0);
  final confidence = (.5 * angleScore + .3 * edgeScore + .2 * areaScore).clamp(
    0.0,
    1.0,
  );
  return QuadAssessment.accepted(
    geometryConfidence: confidence,
    aspect: aspect,
    areaFraction: areaFraction,
  );
}

/// An orientation proposal for a detected document. Geometry alone can only
/// distinguish landscape from portrait — never 0° from 180° — so the estimate
/// is explicit about its uncertainty instead of rotating blindly.
class OrientationEstimate {
  const OrientationEstimate({
    required this.quarterTurns,
    required this.confident,
    required this.reason,
  });
  final int quarterTurns;
  final bool confident;
  final String reason;
}

/// Proposes a quarter-turn so the crop's orientation matches the natural
/// orientation of a document whose natural width / height is [expectedAspect]
/// (null when the kind is unknown). [pixelAspect] is crop width / height.
OrientationEstimate estimateOrientation({
  required double pixelAspect,
  double? expectedAspect,
}) {
  if (expectedAspect == null) {
    return const OrientationEstimate(
      quarterTurns: 0,
      confident: false,
      reason: 'نوع غير معروف؛ لا مقاس مرجعي للاتجاه',
    );
  }
  final isLandscapeCrop = pixelAspect >= 1;
  final isLandscapeDocument = expectedAspect >= 1;
  if (isLandscapeCrop == isLandscapeDocument) {
    return const OrientationEstimate(
      quarterTurns: 0,
      confident: false,
      reason: 'الاتجاه مطابق؛ 0° مقابل 180° غير قابل للحسم هندسياً',
    );
  }
  return const OrientationEstimate(
    quarterTurns: 1,
    confident: false,
    reason: 'اقتراح ربع لفة لمطابقة الاتجاه الطبيعي؛ يحتاج تأكيد المستخدم',
  );
}
