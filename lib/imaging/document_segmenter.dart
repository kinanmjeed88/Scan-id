/// Multi-document segmentation (AUDIT.md §G SEGMENT): splits one source image
/// into independent document candidates so one photo of several cards becomes
/// several logical documents.
///
/// Purely local, deterministic classical CV:
/// 1. A ≤360 px working copy; background colour estimated from the border.
/// 2. Foreground = colour distance from the background over an Otsu threshold.
/// 3. 4-connected components, filtered by area/fill/size, merged on overlap.
/// 4. Fewer than two usable regions → explicit single-image fallback (the
///    caller then runs the precise single-document detector).
/// 5. Per region, the existing corner detector runs on the region crop at
///    preview resolution; corners are mapped back to full-image coordinates.
/// 6. Duplicate quads are suppressed by bounding-box IoU, keeping the first
///    in the deterministic top-to-bottom, left-to-right region order.
///
/// Detection confidence is a measured support value (region fill ratio), not
/// a calibrated probability; a region without a trustworthy quadrilateral is
/// an explicit failure candidate, never a guessed rectangle.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../domain/geometry.dart';
import 'document_detector.dart';
import 'prepare_image.dart';

/// One detected document candidate inside the source image.
class SegmentCandidate {
  const SegmentCandidate({
    required this.region,
    required this.reason,
    this.corners,
    this.detectionConfidence,
  });

  /// Normalized region [left, top, right, bottom] in the source image.
  final List<double> region;

  /// Normalized full-image corner quadrilateral (CropGeometry order), or
  /// null when no trustworthy boundary was found inside the region.
  final List<Point2>? corners;

  /// Measured region support (0..1) when a quadrilateral was found; absent
  /// otherwise — never fabricated.
  final double? detectionConfidence;
  final String reason;
}

class SegmentationResult {
  const SegmentationResult({required this.candidates, required this.multi});

  /// With [multi] true: one candidate per segmented document. With [multi]
  /// false: segmentation found no reliable multi-document structure and the
  /// caller should use the single-document path on the whole image.
  final List<SegmentCandidate> candidates;
  final bool multi;
}

const segmenterVersion = 'segment-1';

/// Decodes [previewBytes] and segments it. The preview is the bounded
/// (≤1200 px) copy produced by the editor; the original is never touched.
SegmentationResult segmentDocumentBytes(Uint8List previewBytes) =>
    segmentDecoded(decodeForProcessing(previewBytes));

SegmentationResult segmentDecoded(img.Image image) {
  if (image.width < 40 || image.height < 40) {
    return const SegmentationResult(candidates: [], multi: false);
  }
  const workSide = 360;
  final longest = math.max(image.width, image.height);
  final scale = longest > workSide ? workSide / longest : 1.0;
  final work = scale < 1
      ? img.copyResize(
          image,
          width: math.max(1, (image.width * scale).round()),
          height: math.max(1, (image.height * scale).round()),
          interpolation: img.Interpolation.average,
        )
      : image;
  final w = work.width, h = work.height;
  final red = Float32List(w * h);
  final green = Float32List(w * h);
  final blue = Float32List(w * h);
  var i = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++, i++) {
      final pixel = work.getPixel(x, y);
      red[i] = pixel.rNormalized.toDouble() * 255;
      green[i] = pixel.gNormalized.toDouble() * 255;
      blue[i] = pixel.bNormalized.toDouble() * 255;
    }
  }
  // Background estimate: per-channel median of a 2 px border band.
  final borderR = <double>[], borderG = <double>[], borderB = <double>[];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (x > 1 && x < w - 2 && y > 1 && y < h - 2) continue;
      final index = y * w + x;
      borderR.add(red[index]);
      borderG.add(green[index]);
      borderB.add(blue[index]);
    }
  }
  final backgroundR = _median(borderR);
  final backgroundG = _median(borderG);
  final backgroundB = _median(borderB);
  final distance = Float32List(w * h);
  for (var index = 0; index < w * h; index++) {
    distance[index] =
        (red[index] - backgroundR).abs() +
        (green[index] - backgroundG).abs() +
        (blue[index] - backgroundB).abs();
  }
  final threshold = _otsu(distance, 765);
  final mask = Uint8List(w * h);
  for (var index = 0; index < w * h; index++) {
    if (distance[index] > threshold) mask[index] = 1;
  }
  // Connected components (4-neighbourhood, iterative BFS).
  final boxes = _componentBoxes(mask, w, h);
  // Filter implausible regions.
  final total = (w * h).toDouble();
  final usable = <_Box>[
    for (final box in boxes)
      if (box.area >= total * .015 &&
          box.width >= 10 &&
          box.height >= 10 &&
          box.fill >= .4 &&
          box.width * box.height <= total * .95)
        box,
  ];
  final merged = _mergeBoxes(usable);
  merged.sort((a, b) {
    final byTop = a.top.compareTo(b.top);
    if (byTop != 0) return byTop;
    return a.left.compareTo(b.left);
  });
  if (merged.length < 2) {
    return const SegmentationResult(candidates: [], multi: false);
  }
  // Map each region back to the preview-resolution image and detect corners.
  final candidates = <SegmentCandidate>[];
  for (final box in merged) {
    final marginX = math.max(4, (box.width * .08).round());
    final marginY = math.max(4, (box.height * .08).round());
    final left = math.max(0, box.left - marginX);
    final top = math.max(0, box.top - marginY);
    final right = math.min(w - 1, box.right + marginX);
    final bottom = math.min(h - 1, box.bottom + marginY);
    final region = [
      left / (w - 1),
      top / (h - 1),
      right / (w - 1),
      bottom / (h - 1),
    ];
    final subLeft = (region[0] * (image.width - 1)).round();
    final subTop = (region[1] * (image.height - 1)).round();
    final subRight = (region[2] * (image.width - 1)).round();
    final subBottom = (region[3] * (image.height - 1)).round();
    final subWidth = subRight - subLeft + 1;
    final subHeight = subBottom - subTop + 1;
    if (subWidth < 20 || subHeight < 20) {
      candidates.add(
        SegmentCandidate(region: region, reason: 'region-too-small'),
      );
      continue;
    }
    final sub = img.copyCrop(
      image,
      x: subLeft,
      y: subTop,
      width: subWidth,
      height: subHeight,
    );
    final corners = detectDocumentCorners(sub);
    if (corners == null) {
      candidates.add(
        SegmentCandidate(region: region, reason: 'no-trustworthy-quad'),
      );
      continue;
    }
    final mapped = [
      for (final p in corners)
        Point2(
          ((subLeft + p.x * (subWidth - 1)) / (image.width - 1)).clamp(
            0.0,
            1.0,
          ),
          ((subTop + p.y * (subHeight - 1)) / (image.height - 1)).clamp(
            0.0,
            1.0,
          ),
        ),
    ];
    final support = (.45 + .5 * box.fill).clamp(0.0, .9);
    candidates.add(
      SegmentCandidate(
        region: region,
        corners: mapped,
        detectionConfidence: support,
        reason: 'component-support',
      ),
    );
  }
  final deduplicated = _suppressDuplicates(candidates);
  final quads = deduplicated.where((c) => c.corners != null).length;
  return SegmentationResult(
    candidates: deduplicated,
    multi: deduplicated.length >= 2 && quads >= 1,
  );
}

class _Box {
  _Box(this.left, this.top, this.right, this.bottom, this.area);
  int left, top, right, bottom;
  double area;
  int get width => right - left + 1;
  int get height => bottom - top + 1;
  double get fill => area / (width * height);
}

List<_Box> _componentBoxes(Uint8List mask, int w, int h) {
  final seen = Uint8List(w * h);
  final queue = Int32List(w * h);
  final boxes = <_Box>[];
  for (var start = 0; start < w * h; start++) {
    if (mask[start] == 0 || seen[start] != 0) continue;
    var head = 0, tail = 0;
    queue[tail++] = start;
    seen[start] = 1;
    var left = start % w, right = start % w;
    var top = start ~/ w, bottom = start ~/ w;
    var area = 0;
    while (head < tail) {
      final index = queue[head++];
      area++;
      final x = index % w, y = index ~/ w;
      if (x < left) left = x;
      if (x > right) right = x;
      if (y < top) top = y;
      if (y > bottom) bottom = y;
      if (x > 0 && mask[index - 1] != 0 && seen[index - 1] == 0) {
        seen[index - 1] = 1;
        queue[tail++] = index - 1;
      }
      if (x < w - 1 && mask[index + 1] != 0 && seen[index + 1] == 0) {
        seen[index + 1] = 1;
        queue[tail++] = index + 1;
      }
      if (y > 0 && mask[index - w] != 0 && seen[index - w] == 0) {
        seen[index - w] = 1;
        queue[tail++] = index - w;
      }
      if (y < h - 1 && mask[index + w] != 0 && seen[index + w] == 0) {
        seen[index + w] = 1;
        queue[tail++] = index + w;
      }
    }
    boxes.add(_Box(left, top, right, bottom, area.toDouble()));
  }
  return boxes;
}

/// Merges boxes that overlap (IoU > .2) or contain each other, so one card
/// split by glare/texture becomes one region instead of duplicates.
List<_Box> _mergeBoxes(List<_Box> input) {
  final boxes = [...input];
  var changed = true;
  while (changed) {
    changed = false;
    outer:
    for (var a = 0; a < boxes.length; a++) {
      for (var b = a + 1; b < boxes.length; b++) {
        if (_boxIou(boxes[a], boxes[b]) > .2 ||
            _contains(boxes[a], boxes[b]) ||
            _contains(boxes[b], boxes[a])) {
          final merged = _Box(
            math.min(boxes[a].left, boxes[b].left),
            math.min(boxes[a].top, boxes[b].top),
            math.max(boxes[a].right, boxes[b].right),
            math.max(boxes[a].bottom, boxes[b].bottom),
            boxes[a].area + boxes[b].area,
          );
          boxes
            ..removeAt(b)
            ..removeAt(a)
            ..add(merged);
          changed = true;
          break outer;
        }
      }
    }
  }
  return boxes;
}

double _boxIou(_Box a, _Box b) {
  final left = math.max(a.left, b.left);
  final top = math.max(a.top, b.top);
  final right = math.min(a.right, b.right);
  final bottom = math.min(a.bottom, b.bottom);
  if (right < left || bottom < top) return 0;
  final intersection = (right - left + 1).toDouble() * (bottom - top + 1);
  final union = a.width * a.height + b.width * b.height - intersection;
  return intersection / union;
}

bool _contains(_Box outer, _Box inner) =>
    inner.left >= outer.left &&
    inner.top >= outer.top &&
    inner.right <= outer.right &&
    inner.bottom <= outer.bottom;

/// Suppresses candidates whose corner quads overlap an earlier candidate
/// (bounding-box IoU > .5). Candidates without corners are kept as explicit
/// failures unless their region overlaps an earlier quad.
List<SegmentCandidate> _suppressDuplicates(List<SegmentCandidate> input) {
  final kept = <SegmentCandidate>[];
  for (final candidate in input) {
    final bounds = candidate.corners != null
        ? _quadBounds(candidate.corners!)
        : candidate.region;
    var duplicate = false;
    for (final existing in kept) {
      final other = existing.corners != null
          ? _quadBounds(existing.corners!)
          : existing.region;
      if (_normalizedIou(bounds, other) > .5) {
        duplicate = true;
        break;
      }
    }
    if (!duplicate) kept.add(candidate);
  }
  return kept;
}

List<double> _quadBounds(List<Point2> corners) {
  var left = 1.0, top = 1.0, right = 0.0, bottom = 0.0;
  for (final p in corners) {
    if (p.x < left) left = p.x;
    if (p.x > right) right = p.x;
    if (p.y < top) top = p.y;
    if (p.y > bottom) bottom = p.y;
  }
  return [left, top, right, bottom];
}

double _normalizedIou(List<double> a, List<double> b) {
  final left = math.max(a[0], b[0]);
  final top = math.max(a[1], b[1]);
  final right = math.min(a[2], b[2]);
  final bottom = math.min(a[3], b[3]);
  if (right <= left || bottom <= top) return 0;
  final intersection = (right - left) * (bottom - top);
  final areaA = (a[2] - a[0]) * (a[3] - a[1]);
  final areaB = (b[2] - b[0]) * (b[3] - b[1]);
  final union = areaA + areaB - intersection;
  return union <= 0 ? 0 : intersection / union;
}

double _median(List<double> values) {
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}

double _otsu(Float32List values, double maxValue, {int bins = 128}) {
  final histogram = List<int>.filled(bins, 0);
  for (final value in values) {
    final bin = ((value / maxValue) * (bins - 1)).clamp(0, bins - 1).round();
    histogram[bin]++;
  }
  final total = values.length;
  var sum = 0.0;
  for (var index = 0; index < bins; index++) {
    sum += index * histogram[index];
  }
  var sumBackground = 0.0;
  var weightBackground = 0;
  var best = 0.0;
  var bestThreshold = bins ~/ 2;
  for (var index = 0; index < bins; index++) {
    weightBackground += histogram[index];
    if (weightBackground == 0) continue;
    final weightForeground = total - weightBackground;
    if (weightForeground == 0) break;
    sumBackground += index * histogram[index];
    final meanBackground = sumBackground / weightBackground;
    final meanForeground = (sum - sumBackground) / weightForeground;
    final between =
        weightBackground.toDouble() *
        weightForeground *
        math.pow(meanBackground - meanForeground, 2);
    if (between > best) {
      best = between;
      bestThreshold = index;
    }
  }
  return bestThreshold / (bins - 1) * maxValue;
}
