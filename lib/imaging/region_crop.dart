/// Axis-aligned crop of one measured document region (AUDIT.md §G SEGMENT).
///
/// This is the RECOVERY path for a segmented region whose quadrilateral could
/// not be trusted. It is deliberately the least opinionated operation in the
/// imaging layer:
///
/// - it keeps every measured pixel of the region;
/// - it invents nothing — no guessed rectangle, no perspective warp, no
///   rescaling, no aspect correction;
/// - it never touches the original file (ADR-003): the caller passes bytes
///   read from the immutable original and gets new bytes back.
///
/// The result is a plain derived image the user can crop precisely by hand in
/// the editor, which is the safe recovery path for an unresolved region.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'prepare_image.dart';

/// The normalized whole-image region used when a region measurement is absent.
const List<double> fullFrameRegion = [0, 0, 1, 1];

/// Crops [region] — normalized `[left, top, right, bottom]`, each in 0..1 —
/// out of [originalBytes] and returns a fresh PNG.
///
/// Out-of-range or inverted coordinates are clamped to the image, so a hostile
/// or degenerate measurement can only ever yield a smaller crop, never an
/// out-of-bounds read.
Uint8List cropRegionBytes(Uint8List originalBytes, List<double> region) {
  final image = decodeForProcessing(originalBytes);
  final width = image.width;
  final height = image.height;
  double at(int index) => index < region.length
      ? (region[index].isFinite ? region[index].clamp(0.0, 1.0) : 0.0)
      : 0.0;
  final left = (at(0) * (width - 1)).round().clamp(0, width - 1).toInt();
  final top = (at(1) * (height - 1)).round().clamp(0, height - 1).toInt();
  final right = (at(2) * (width - 1)).round().clamp(0, width - 1).toInt();
  final bottom = (at(3) * (height - 1)).round().clamp(0, height - 1).toInt();
  final x = math.min(left, right);
  final y = math.min(top, bottom);
  final boxWidth = math.min(width - x, (right - left).abs() + 1);
  final boxHeight = math.min(height - y, (bottom - top).abs() + 1);
  // A 1×1 crop is the smallest honest result: it keeps the region's position
  // without failing the whole intake over one bad measurement.
  final cropped = img.copyCrop(
    image,
    x: x,
    y: y,
    width: math.max(1, boxWidth),
    height: math.max(1, boxHeight),
  );
  return Uint8List.fromList(img.encodePng(cropped));
}
