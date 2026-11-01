import 'dart:math' as math;

import 'geometry.dart';
import 'validation.dart';

/// Tap-by-tap manual selection of a document quadrilateral.
///
/// Taps are stored in tap order and are immutable: every operation returns a new
/// selection. The four points become a [CropGeometry] corner list only through
/// [completedCorners], which orders them canonically and rejects any
/// quadrilateral that [normalizedQuadIssue] reports as unsafe. A partial
/// selection never reaches crop.
class ManualQuadSelection {
  ManualQuadSelection._(this.points);

  /// A selection with no taps yet.
  factory ManualQuadSelection.empty() => ManualQuadSelection._(const []);

  static const int pointCount = 4;

  /// Normalized points in tap order (0..1 frame coordinates).
  final List<Point2> points;

  bool get isComplete => points.length == pointCount;

  /// Returns a new selection with [tap] appended.
  ///
  /// Rejects a tap after four points, a non-finite or out-of-frame tap, and a
  /// tap closer than [minSeparation] (normalized units) to an existing point.
  /// The caller derives [minSeparation] from its on-screen unit; this type does
  /// not choose it.
  ManualQuadSelection addTap(Point2 tap, {required double minSeparation}) {
    require(!isComplete, 'اكتمل تحديد الزوايا الأربع.');
    require(
      minSeparation.isFinite && minSeparation >= 0,
      'مسافة التمييز بين النقاط غير صالحة.',
    );
    require(
      tap.x >= 0 && tap.x <= 1 && tap.y >= 0 && tap.y <= 1,
      'النقطة خارج حدود الصورة.',
    );
    for (final existing in points) {
      final distance = math.sqrt(
        math.pow(tap.x - existing.x, 2) + math.pow(tap.y - existing.y, 2),
      );
      require(
        distance >= minSeparation,
        'النقطة قريبة جدا من زاوية محددة مسبقا.',
      );
    }
    return ManualQuadSelection._([...points, tap]);
  }

  /// Removes the most recent tap. A no-op on an empty selection.
  ManualQuadSelection undo() => points.isEmpty
      ? this
      : ManualQuadSelection._(points.sublist(0, points.length - 1));

  /// Canonical TL, TR, BR, BL corners of the completed selection.
  ///
  /// Throws [ValidationException] when the selection is incomplete or when the
  /// canonical quadrilateral is not a safe crop quadrilateral.
  List<Point2> completedCorners() {
    require(isComplete, 'يلزم تحديد أربع زوايا قبل القص.');
    final corners = canonicalQuadCorners(points);
    final issue = normalizedQuadIssue(corners);
    require(
      issue == null,
      'الزوايا المحددة لا تكوّن مستطيلا صالحا؛ أعد التحديد.',
    );
    return corners;
  }
}
