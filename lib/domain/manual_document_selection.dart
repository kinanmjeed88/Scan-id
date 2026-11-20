import 'dart:math' as math;

import 'document_kind.dart';
import 'geometry.dart';
import 'recognition.dart';
import 'validation.dart';

/// One document the person outlined by hand inside a single photograph.
///
/// The corners are the four points they placed, in NORMALIZED image coordinates
/// (0..1 on both axes) so the selection is independent of how the photo is
/// zoomed, panned or displayed. Nothing here infers a boundary: a selection is
/// something a person drew, and [corners] is exactly what they drew.
///
/// Each selection carries its own category and side, because that is how a
/// photo of several documents actually is: a national ID beside a ration card,
/// one face up and one face down.
class ManualDocumentSelection {
  ManualDocumentSelection({
    required this.id,
    required List<Point2> corners,
    this.kind = DocumentKind.unknown,
    this.side = SideKind.unknown,
    this.customSizeMm,
  }) : corners = List.unmodifiable(corners);

  /// Stable within the session, so the list can key on it while corners move.
  final String id;

  final List<Point2> corners;
  final DocumentKind kind;
  final SideKind side;

  /// A size the person measured themselves, for a category with no documented
  /// dimensions. Null means "use the catalog, or leave it off the sheet".
  final PhysicalSizeMm? customSizeMm;

  bool get isComplete =>
      corners.length == ManualDocumentSelection.requiredCorners;

  static const int requiredCorners = 4;

  /// The safe, canonically ordered ring, or null while incomplete or invalid.
  ///
  /// Returns null rather than throwing so the UI can mark a selection as
  /// unfinished while the person is still working on it, and so a defect in one
  /// selection never blocks the others.
  List<Point2>? get validatedCorners {
    if (!isComplete) return null;
    if (unorderedQuadIssue(corners) != null) return null;
    final ordered = canonicalQuadCorners(corners);
    if (normalizedQuadIssue(ordered) != null) return null;
    return ordered;
  }

  /// Why this selection cannot be cropped, or null when it can.
  ///
  /// The reason names the actual defect — too few corners, out of the photo,
  /// crossed edges, collapsed area — because «تحديد غير صالح» for every case
  /// tells the person nothing about what to fix.
  String? get issue {
    if (!isComplete) {
      return 'التحديد يحتاج ${requiredCorners - corners.length} زاوية أخرى.';
    }
    final unordered = unorderedQuadIssue(corners);
    if (unordered != null) return _message(unordered);
    final ordered = canonicalQuadCorners(corners);
    final orderedIssue = normalizedQuadIssue(ordered);
    if (orderedIssue != null) return _message(orderedIssue);
    return null;
  }

  bool get isValid => issue == null;

  /// The cropped width / height once the reading device is known, or null while
  /// the selection is invalid. Used to decide landscape vs portrait size.
  double? get outputAspect {
    final ring = validatedCorners;
    if (ring == null) return null;
    final width =
        (math.sqrt(
              math.pow(ring[1].x - ring[0].x, 2) +
                  math.pow(ring[1].y - ring[0].y, 2),
            ) +
            math.sqrt(
              math.pow(ring[2].x - ring[3].x, 2) +
                  math.pow(ring[2].y - ring[3].y, 2),
            )) /
        2;
    final height =
        (math.sqrt(
              math.pow(ring[3].x - ring[0].x, 2) +
                  math.pow(ring[3].y - ring[0].y, 2),
            ) +
            math.sqrt(
              math.pow(ring[2].x - ring[1].x, 2) +
                  math.pow(ring[2].y - ring[1].y, 2),
            )) /
        2;
    if (width <= 0 || height <= 0) return null;
    return width / height;
  }

  ManualDocumentSelection copyWith({
    List<Point2>? corners,
    DocumentKind? kind,
    SideKind? side,
    PhysicalSizeMm? customSizeMm,
    bool clearCustomSize = false,
  }) => ManualDocumentSelection(
    id: id,
    corners: corners ?? this.corners,
    kind: kind ?? this.kind,
    side: side ?? this.side,
    customSizeMm: clearCustomSize ? null : (customSizeMm ?? this.customSizeMm),
  );

  static String _message(QuadGeometryIssue issue) => switch (issue) {
    QuadGeometryIssue.wrongPointCount => 'التحديد يحتاج أربع زوايا بالضبط.',
    QuadGeometryIssue.nonFiniteCoordinates =>
      'إحدى الزوايا غير صالحة؛ أعد تحديدها.',
    QuadGeometryIssue.outOfBounds => 'إحدى الزوايا خارج أبعاد الصورة.',
    QuadGeometryIssue.notConvex =>
      'الحدود متقاطعة أو مقعّرة؛ رتّب الزوايا حول المستند دون تقاطع.',
    QuadGeometryIssue.collapsedArea =>
      'مساحة التحديد صفرية تقريباً؛ وسّع الحدود.',
    QuadGeometryIssue.singularPerspective =>
      'التحديد لا يقبل تصحيح المنظور؛ أعد رسم الزوايا الأربع.',
  };
}

/// The set of manual selections for ONE photograph.
///
/// Immutable: every operation returns a new set, so the editor can hold one and
/// rebuild without risking a half-applied change. Invariants enforced here —
/// not in the widget — because they are properties of the data:
///
/// * a photograph yields at most [maxSelections] documents;
/// * no two completed selections may share screen area, because cropping the
///   same pixels twice would create two documents from one region silently;
/// * adding or removing one selection never mutates another.
class ManualSelectionSet {
  ManualSelectionSet._(this.selections);

  factory ManualSelectionSet.empty() => ManualSelectionSet._(const []);

  final List<ManualDocumentSelection> selections;

  /// Ten documents in one photograph is already an extreme sheet; beyond that
  /// the person is almost certainly working on the wrong photo.
  static const int maxSelections = 10;

  /// The one message both the set and the screen show at the limit, so the two
  /// can never state different numbers.
  static const String atCapacityMessage =
      'يمكن تحديد $maxSelections مستمسكات كحد أقصى في الصورة الواحدة.';

  bool get isEmpty => selections.isEmpty;
  bool get isNotEmpty => selections.isNotEmpty;
  int get length => selections.length;

  /// Every selection that could be cropped right now.
  List<ManualDocumentSelection> get valid => [
    for (final selection in selections)
      if (selection.isValid) selection,
  ];

  /// Selections still missing corners or geometrically unsafe.
  List<ManualDocumentSelection> get invalid => [
    for (final selection in selections)
      if (!selection.isValid) selection,
  ];

  /// True when the batch may be applied: at least one selection, and every
  /// selection is valid.
  ///
  /// Deliberately ALL-or-nothing. Adding only the valid ones would silently
  /// drop a document the person drew, which is the failure mode this feature
  /// exists to prevent.
  bool get canApply => isNotEmpty && invalid.isEmpty;

  ManualDocumentSelection? byId(String id) =>
      selections.where((selection) => selection.id == id).firstOrNull;

  /// Adds a new, incomplete selection.
  ///
  /// [id] must be unique; the caller supplies it so the widget layer owns id
  /// generation and this type stays free of side effects.
  ManualSelectionSet add(ManualDocumentSelection selection) {
    require(selections.length < maxSelections, atCapacityMessage);
    require(byId(selection.id) == null, 'معرّف التحديد مستخدم بالفعل.');
    return ManualSelectionSet._([...selections, selection]);
  }

  /// The one place the missing-id message lives, with a non-null result so
  /// callers do not have to re-assert what this method already checked.
  ManualDocumentSelection _requireById(String id) =>
      byId(id) ??
      (throw const ValidationException('التحديد غير موجود.'));

  /// Replaces one selection in place, keeping the order the person sees.
  ManualSelectionSet replace(ManualDocumentSelection selection) {
    require(byId(selection.id) != null, 'التحديد المراد تعديله غير موجود.');
    final next = [
      for (final existing in selections)
        existing.id == selection.id ? selection : existing,
    ];
    _requireNoOverlap(next);
    return ManualSelectionSet._(next);
  }

  ManualSelectionSet remove(String id) {
    require(byId(id) != null, 'التحديد المراد حذفه غير موجود.');
    return ManualSelectionSet._([
      for (final selection in selections)
        if (selection.id != id) selection,
    ]);
  }

  /// Appends a corner to one incomplete selection.
  ///
  /// Rejects a point outside the photo, a fifth corner, and a corner closer
  /// than [minSeparation] to one already placed — the same rules the
  /// single-document tap selection uses, so both surfaces behave identically.
  ManualSelectionSet addCorner(
    String id,
    Point2 point, {
    required double minSeparation,
  }) {
    // A throwing lookup, not require(): `require` is a plain function and cannot
    // promote the type, and a nullable target would have to be force-unwrapped
    // at every use below.
    final target = _requireById(id);
    require(!target.isComplete, 'اكتمل تحديد الزوايا الأربع لهذا المستمسك.');
    require(
      point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1,
      'النقطة خارج حدود الصورة.',
    );
    for (final existing in target.corners) {
      final distance = math.sqrt(
        math.pow(point.x - existing.x, 2) + math.pow(point.y - existing.y, 2),
      );
      require(
        distance >= minSeparation,
        'النقطة قريبة جداً من زاوية محددة مسبقاً.',
      );
    }
    return replace(target.copyWith(corners: [...target.corners, point]));
  }

  /// Moves one corner of one selection, leaving every other point and every
  /// other selection untouched.
  ManualSelectionSet moveCorner(String id, int index, Point2 point) {
    final target = _requireById(id);
    require(
      index >= 0 && index < target.corners.length,
      'زاوية غير موجودة في هذا التحديد.',
    );
    require(
      point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1,
      'النقطة خارج حدود الصورة.',
    );
    final corners = [...target.corners];
    corners[index] = point;
    return replace(target.copyWith(corners: corners));
  }

  /// Removes the most recent corner of one selection.
  ManualSelectionSet undoCorner(String id) {
    final target = _requireById(id);
    if (target.corners.isEmpty) return this;
    return replace(
      target.copyWith(
        corners: target.corners.sublist(0, target.corners.length - 1),
      ),
    );
  }

  /// Two completed selections may not overlap, because two documents cannot be
  /// the same pixels. Incomplete ones are exempt: a person drawing the second
  /// document naturally starts with a corner inside the first.
  static void _requireNoOverlap(List<ManualDocumentSelection> candidates) {
    final complete = [
      for (final selection in candidates)
        if (selection.validatedCorners case final ring?) (selection, ring),
    ];
    for (var i = 0; i < complete.length; i++) {
      for (var j = i + 1; j < complete.length; j++) {
        if (quadRingsOverlap(complete[i].$2, complete[j].$2)) {
          throw ValidationException(
            'التحديد «${complete[j].$1.id}» يتقاطع مع تحديد آخر؛ '
            'لا يمكن أن يشير مستمسكان إلى نفس المساحة.',
          );
        }
      }
    }
  }
}

/// Whether two convex quadrilaterals share interior area.
///
/// Uses the separating-axis theorem on the eight edges. Touching at an edge or
/// a corner is NOT an overlap: two cards laid side by side share a border, and
/// refusing that would make an ordinary photo impossible to outline.
bool quadRingsOverlap(List<Point2> a, List<Point2> b) {
  if (a.length != 4 || b.length != 4) return false;
  for (final ring in [a, b]) {
    for (var i = 0; i < 4; i++) {
      final p = ring[i];
      final q = ring[(i + 1) % 4];
      // Inward normal of this edge; a gap on any axis separates the rings.
      final axisX = p.y - q.y;
      final axisY = q.x - p.x;
      if (!_separated(a, b, axisX, axisY)) return false;
    }
  }
  return true;
}

bool _separated(List<Point2> a, List<Point2> b, double axisX, double axisY) {
  var aMin = double.infinity, aMax = double.negativeInfinity;
  var bMin = double.infinity, bMax = double.negativeInfinity;
  for (final point in a) {
    final value = point.x * axisX + point.y * axisY;
    if (value < aMin) aMin = value;
    if (value > aMax) aMax = value;
  }
  for (final point in b) {
    final value = point.x * axisX + point.y * axisY;
    if (value < bMin) bMin = value;
    if (value > bMax) bMax = value;
  }
  // A shared border must not count: require a real gap, not merely a touching
  // edge, so separate documents can butt against each other.
  return aMax <= bMin + 1e-9 || bMax <= aMin + 1e-9;
}
