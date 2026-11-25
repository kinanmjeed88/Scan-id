import 'dart:math' as math;

import 'geometry.dart';

/// Rewrites four corners into the canonical ring the rest of the app assumes:
/// clockwise in screen space (y down), starting at the top-left corner.
///
/// Reversing a ring is a pure re-indexing, not a repair: the same four corners
/// traversed the other way describe the same quadrilateral, so `[TL, BL, BR,
/// TR]` becomes `[TL, TR, BR, BL]` and nothing about the shape changes. A
/// MIRRORED proposal is likewise the same corner set and is normalised the
/// same way; what a reversal must never do is turn a CROSSED ring (a bow-tie)
/// into a simple one, and that is why self-intersection is tested directly
/// instead of being inferred from the winding sign.
///
/// Why this exists. `assessQuad`, `CropDraft.toRecipe` and `warpPerspective`
/// all treat corner `i` and corner `i + 1` as a shared EDGE, and treat the ring
/// as `[TL, TR, BR, BL]`. A detector that returns the same physical document
/// with its channel order rotated still describes the same four points; the
/// ring is simply an acceptable rotation of the canonical one, with the START
/// in the wrong place. Comparing two such rings index by index therefore
/// reports diagonal-corner distances for what is one rectangle, which is how a
/// pair of agreeing detectors was routed to review as `modelDisagreement`.
///
/// A rotation is NOT the same as a crossing. Rotating keeps the ring simple;
/// a ring that pairs diagonal corners is a bow-tie, and this function leaves it
/// exactly as it found it.
///
/// What this function does NOT do:
/// * It never changes which points were proposed, only their order, so the
///   area, the aspect and the edge lengths are identical afterwards.
/// * It never "fixes" a self-intersecting ring. A bow-tie has a near-zero
///   signed area — the two lobes cancel exactly — so the winding sign says
///   nothing about it, and reversing it would merely pick one of its two
///   traversals. It is returned unchanged and the caller's geometry gate is
///   still the only thing that can reject it.
/// * It returns the input unchanged when it cannot establish an order, so an
///   invalid ring is never disguised as a valid one.
///
/// The canonical start is the corner that is most "top-left" by the usual
/// sum of coordinates, which is stable for every convex quadrilateral. Ties
/// resolve to the lowest index so the result never depends on list identity.
List<Point2> canonicalCornerRing(List<Point2> corners) {
  if (corners.length != 4) return corners;
  for (final point in corners) {
    if (!point.x.isFinite || !point.y.isFinite) return corners;
  }

  // Winding in screen space (y grows downward): a positive signed area here is
  // clockwise on screen, which is the contract every consumer documents.
  var twiceArea = 0.0;
  for (var i = 0; i < 4; i++) {
    final a = corners[i];
    final b = corners[(i + 1) % 4];
    twiceArea += a.x * b.y - b.x * a.y;
  }
  // A collapsed or self-intersecting ring has no meaningful order. The
  // shoelace of a bow-tie cancels to zero, so it cannot be told apart from a
  // collapsed quad by area alone; both are handed back untouched for the
  // geometry gate to reject on its own terms.
  if (!twiceArea.isFinite || twiceArea.abs() <= 1e-12) return corners;
  if (_selfIntersects(corners)) return corners;

  final ordered = twiceArea > 0 ? corners : corners.reversed.toList();

  // Start at the most top-left vertex. `x + y` is minimised at the TL corner of
  // any convex quad and, unlike `atan2`, needs no branch on the winding sign.
  var start = 0;
  var best = double.infinity;
  for (var i = 0; i < 4; i++) {
    final score = ordered[i].x + ordered[i].y;
    if (score < best) {
      best = score;
      start = i;
    }
  }
  if (start == 0) return List.unmodifiable(ordered);
  return List.unmodifiable([
    for (var i = 0; i < 4; i++) ordered[(start + i) % 4],
  ]);
}

/// Smallest corner-to-corner displacement between two rings, in source pixels.
///
/// Compares the four valid cyclic re-indexings of [second] against [first] and
/// returns the best (smallest) worst-corner distance. Rotation is a pure
/// re-indexing: the same four physical corners described starting from a
/// different channel, which a heatmap model can legitimately return when its
/// four output channels are not in the same order as the other model's.
///
/// Two properties matter for safety:
/// * Only rotation is tried. A reversal is never considered as a candidate
///   alignment on top of canonicalisation, so the function cannot search its
///   way into calling two genuinely different rings the same. (Canonicalisation
///   does normalise winding and mirroring, which is correct: those describe the
///   SAME four corners. Turning a bow-tie into a simple quad is the thing that
///   must not happen, and that is prevented in [canonicalCornerRing].)
/// * The returned distance is a real measurement. A genuinely different
///   quadrilateral still reports a large distance under every rotation, so
///   rotation tolerance cannot hide a real disagreement.
///
/// Returns [double.infinity] when either ring is not four finite points, and
/// the image diagonal (i.e. total disagreement) when it is degenerate, so a
/// malformed pair is never reported as agreement.
double minimumCyclicCornerDisplacementPixels(
  List<Point2> first,
  List<Point2> second, {
  required int width,
  required int height,
}) {
  if (first.length != 4 || second.length != 4) return double.infinity;
  if (width < 2 || height < 2) return double.infinity;

  final a = canonicalCornerRing(first);
  final b = canonicalCornerRing(second);
  if (a.length != 4 || b.length != 4) return double.infinity;

  var best = double.infinity;
  for (var shift = 0; shift < 4; shift++) {
    var worst = 0.0;
    for (var i = 0; i < 4; i++) {
      final dx = (a[i].x - b[(i + shift) % 4].x) * (width - 1);
      final dy = (a[i].y - b[(i + shift) % 4].y) * (height - 1);
      final distance = math.sqrt(dx * dx + dy * dy);
      if (!distance.isFinite) return double.infinity;
      if (distance > worst) worst = distance;
    }
    if (worst < best) best = worst;
  }
  return best;
}

/// [minimumCyclicCornerDisplacementPixels] as a fraction of the frame diagonal.
///
/// This is the unit the cascade's material-disagreement rule is written in.
double minimumCyclicCornerDisplacementFraction(
  List<Point2> first,
  List<Point2> second, {
  required int width,
  required int height,
}) {
  final pixels = minimumCyclicCornerDisplacementPixels(
    first,
    second,
    width: width,
    height: height,
  );
  if (!pixels.isFinite) return 1;
  final diagonal = math.sqrt(
    (width - 1).toDouble() * (width - 1) + (height - 1) * (height - 1),
  );
  if (!diagonal.isFinite || diagonal <= 0) return 1;
  return (pixels / diagonal).clamp(0.0, 1.0);
}

/// Whether the ring `0-1-2-3-0` crosses itself.
///
/// Only the two pairs of non-adjacent edges can cross in a quadrilateral. The
/// test is a strict proper crossing: touching at a shared endpoint is not a
/// crossing, because adjacent edges meet there by construction and four
/// coincident points are already rejected as collapsed.
bool _selfIntersects(List<Point2> corners) {
  // Edges (0,1) and (2,3) are one non-adjacent pair; (1,2) and (3,0) are the
  // other. The remaining pairs share an endpoint by construction.
  const pairs = <({int a, int b, int c, int d})>[
    (a: 0, b: 1, c: 2, d: 3),
    (a: 1, b: 2, c: 3, d: 0),
  ];
  for (final pair in pairs) {
    if (_segmentsCross(
      corners[pair.a],
      corners[pair.b],
      corners[pair.c],
      corners[pair.d],
    )) {
      return true;
    }
  }
  return false;
}

bool _segmentsCross(Point2 p1, Point2 p2, Point2 p3, Point2 p4) {
  final d1 = _cross(p3, p4, p1);
  final d2 = _cross(p3, p4, p2);
  final d3 = _cross(p1, p2, p3);
  final d4 = _cross(p1, p2, p4);
  return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
      ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
}

double _cross(Point2 a, Point2 b, Point2 c) =>
    (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
