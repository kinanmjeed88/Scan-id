import 'dart:math' as math;

import 'geometry.dart';

/// Which side of the camera frame a corner sits on.
enum FrameEdgeSide { left, top, right, bottom }

/// How close a corner may sit to a frame border before the claim is treated as
/// touching it, measured on each axis separately as a fraction of that axis.
///
/// Why this is a small type instead of the constant `0.016` it replaces:
///
/// * A learned proposal's corners are quantised to one heatmap cell. On a
///   256-pixel input with a 64-cell map that cell is 4 input px, which is
///   `4 / scale` frame px. Expressing that as a fraction of the frame gives a
///   band that SHRINKS on a large frame and GROWS on a small one, which is the
///   opposite of a fixed fraction and the opposite of what the geometry means.
/// * One cell is a different FRACTION of each axis whenever the frame is not
///   square, because the frame's two spans differ while the source pixel size
///   does not. On a 1200x900 frame a cell is about 18.75 source px, which is
///   `.0156` of the width but `.0209` of the height. A single `0.016` is
///   therefore too wide on the long axis and too NARROW on the short one, so a
///   corner that the heatmap genuinely could not resolve on the short axis was
///   reported as strictly interior, i.e. as an unclipped document.
///
/// The band is deliberately expressed independently per side so a single axis
/// can never mask the other, and [FrameEdgeBand.quantisation] is the only
/// constructor a detector should use.
class FrameEdgeBand {
  const FrameEdgeBand({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  /// The band the app used before provenance was modelled. Kept as the
  /// fallback for producers that report no quantisation (classical detector,
  /// segmenter, manual input, recovery replay of an older recipe), so their
  /// behaviour does not change.
  factory FrameEdgeBand.uniform(double value) => FrameEdgeBand(
    left: value,
    top: value,
    right: value,
    bottom: value,
  );

  /// Default for producers with no modelled quantisation.
  static const FrameEdgeBand legacy = FrameEdgeBand(
    left: agentlessBand,
    top: agentlessBand,
    right: agentlessBand,
    bottom: agentlessBand,
  );

  /// The historical `0.016`. Named so no call site repeats the literal.
  static const double agentlessBand = .016;

  /// Band derived from a heatmap-quantised producer.
  ///
  /// [heatmapCells] cells span [inputPixels] input pixels, and the input was
  /// mapped onto a frame of [frameWidth] x [frameHeight]. One cell is therefore
  /// `inputPixels / heatmapCells / scale` frame pixels, where `scale` is the
  /// uniform letterbox scale the producer applied. The result is that
  /// displacement expressed as a fraction of each frame axis, capped at
  /// [maximumFraction] so a degenerate frame can never widen the band into the
  /// middle of the image.
  ///
  /// Returns [legacy] when the inputs cannot describe a band, rather than
  /// inventing one: a producer that cannot state its quantisation keeps the
  /// old conservative behaviour.
  factory FrameEdgeBand.quantisation({
    required int frameWidth,
    required int frameHeight,
    required double inputPixels,
    required int heatmapCells,
    double maximumFraction = .05,
  }) {
    if (frameWidth < 2 ||
        frameHeight < 2 ||
        !inputPixels.isFinite ||
        inputPixels <= 0 ||
        heatmapCells <= 0 ||
        !maximumFraction.isFinite ||
        maximumFraction <= 0) {
      return legacy;
    }
    // The producer letterboxes by the smaller of the two axis scales.
    final scale = math.min(
      inputPixels / frameWidth,
      inputPixels / frameHeight,
    );
    if (!scale.isFinite || scale <= 0) return legacy;
    final cellPixels = inputPixels / heatmapCells / scale;
    // Fraction of an axis measured in index units: the frame spans
    // `0 .. extent - 1`, matching `assessQuad` and `warpPerspective`.
    final left = math.min(
      maximumFraction,
      cellPixels / math.max(1, frameWidth - 1),
    );
    final top = math.min(
      maximumFraction,
      cellPixels / math.max(1, frameHeight - 1),
    );
    if (!left.isFinite || !top.isFinite || left <= 0 || top <= 0) {
      return legacy;
    }
    return FrameEdgeBand(left: left, top: top, right: left, bottom: top);
  }

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get maximumSide => math.max(
    math.max(left, top),
    math.max(right, bottom),
  );

  /// Sides whose own band at least one corner reaches.
  ///
  /// A side is reported when ANY corner lies within that side's band, because
  /// the question is whether the document was cut by the frame on that side,
  /// and one corner is enough to clip the document's outline. The test is
  /// per-side: a corner near the left edge says nothing about the right edge.
  Set<FrameEdgeSide> sidesTouchedBy(List<Point2> corners) {
    final touched = <FrameEdgeSide>{};
    for (final point in corners) {
      if (!point.x.isFinite || !point.y.isFinite) continue;
      if (point.x <= left) touched.add(FrameEdgeSide.left);
      if (point.x >= 1 - right) touched.add(FrameEdgeSide.right);
      if (point.y <= top) touched.add(FrameEdgeSide.top);
      if (point.y >= 1 - bottom) touched.add(FrameEdgeSide.bottom);
    }
    return touched;
  }

  /// True when any corner lies strictly outside the frame by more than a
  /// floating-point overshoot.
  ///
  /// This is a DISTINCT fact from [sidesTouchedBy]. A corner outside the frame
  /// is a coordinate defect (a peak in letterbox padding, a bad remap), while a
  /// corner inside the band is a physical statement about the document. Folding
  /// the two into one reason hid which one happened.
  static bool anyCornerOutsideFrame(List<Point2> corners) {
    const epsilon = 1e-9;
    for (final point in corners) {
      if (!point.x.isFinite || !point.y.isFinite) return true;
      if (point.x < -epsilon ||
          point.x > 1 + epsilon ||
          point.y < -epsilon ||
          point.y > 1 + epsilon) {
        return true;
      }
    }
    return false;
  }
}
