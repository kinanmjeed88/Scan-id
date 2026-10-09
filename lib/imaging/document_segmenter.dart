/// Multi-document segmentation (AUDIT.md §G SEGMENT): splits one source image
/// into independent document candidates so one photo of several cards becomes
/// several logical documents.
///
/// Purely local, deterministic classical CV:
/// 1. A ≤360 px working copy; background colour estimated from the border.
/// 2. Foreground = colour distance from the background over an Otsu threshold.
/// 3. 4-connected components, filtered by area/fill/size, merged on overlap.
/// 4. Candidate-quality validation of every MERGED region — before any crop is
///    rendered and before any corner is searched for — so a frame edge, a
///    shadow strip or a region too small to crop never becomes a document
///    ([RegionRejection]). Rejections are measured and reported, never silent.
/// 5. Fewer than two ACCEPTED regions → explicit single-image fallback (the
///    caller then runs the precise single-document detector).
/// 6. Per region, the existing corner detector runs on the region crop at
///    preview resolution; corners are mapped back to full-image coordinates.
/// 7. Duplicate quads are suppressed by bounding-box IoU, preferring a region
///    that HAS a trustworthy quadrilateral and otherwise keeping the first in
///    the deterministic top-to-bottom, left-to-right region order.
///
/// Detection confidence is a measured support value (region fill ratio), not
/// a calibrated probability; a region without a trustworthy quadrilateral is
/// an explicit failure candidate, never a guessed rectangle.
///
/// Acceptance is deliberately conservative in BOTH directions: a region is
/// rejected only when a measurement says it cannot be a document of any
/// catalogued shape, and a region that is merely hard to outline is KEPT as an
/// unresolved candidate so a genuine document is never lost because its
/// boundaries were uncertain.
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

/// Why a MEASURED foreground region was not accepted as a document candidate.
///
/// A rejection is a decision about the candidate only. It never crops,
/// overwrites or otherwise touches the original image (ADR-003): the photo
/// stays whole and every part of it remains croppable by hand from the
/// library. Rejecting a region is therefore always recoverable, while
/// accepting one creates a derived file, a document record and a layout item.
enum RegionRejection {
  /// It reaches two or more frame edges, so it is the frame edge itself, a
  /// vignette or a table edge — or a document the photo cut in half — rather
  /// than a separable document lying on a surface.
  frameArtifact,

  /// A strip: its proportion is more extreme than any catalogued document
  /// shape can be, even allowing for perspective.
  implausibleAspect,

  /// The crop it would produce is too small to be a usable document image
  /// (thumbnail, manual crop, print).
  unusableCrop,

  /// One photo yielded more plausible regions than [maxSegmentCandidates]; the
  /// weakest measured regions give way to the strongest.
  candidateCap,
}

/// A measured region that was NOT accepted, with the measurements that decided
/// it. Kept so a rejection is explainable instead of invisible.
class RejectedRegion {
  const RejectedRegion({
    required this.region,
    required this.rejection,
    required this.aspect,
    required this.areaFraction,
    required this.fill,
    required this.borderSides,
    required this.cropWidth,
    required this.cropHeight,
  });

  /// Normalized region [left, top, right, bottom] in the source image, exactly
  /// as the accepted candidates carry it, so a rejection stays locatable.
  final List<double> region;
  final RegionRejection rejection;

  /// Long edge / short edge of the measured component, in working pixels.
  final double aspect;

  /// Component foreground area as a fraction of the working frame.
  final double areaFraction;

  /// Foreground pixels / bounding-box pixels.
  final double fill;

  /// How many of the four frame edges the component touches (0..4).
  final int borderSides;

  /// Size the axis-aligned crop of this region would have had, in preview
  /// pixels — the measurement behind [RegionRejection.unusableCrop].
  final int cropWidth;
  final int cropHeight;

  @override
  String toString() =>
      'RejectedRegion(${rejection.name}, aspect=${aspect.toStringAsFixed(2)}, '
      'area=${areaFraction.toStringAsFixed(3)}, border=$borderSides, '
      'crop=${cropWidth}x$cropHeight)';
}

/// Longest/shortest side ratio a document region may have.
///
/// Derived from the application's OWN definition of a document shape, not from
/// a screenshot: the most extreme catalogued size is the ration card at
/// 287 / 52 = 5.52 (`DocumentSizeCatalog.defaultRationCard`), so a bound below
/// that would reject a document the catalog itself sells. 8.0 leaves that shape
/// ~45 % headroom for perspective, rotation and measurement error.
///
/// Measured on the fixtures this repository ships (`test/imaging` and
/// `test/application`): genuine documents — landscape, portrait, rotated,
/// distant, low-contrast, washed-out, textured background, blank margins, and
/// the ration-card proportion itself — measure 1.26 to 5.49, where 5.49 IS the
/// ration card. Shadow/border strips measure 12.00 to 22.50. The bound sits
/// with margin on both sides: 1.46x above the most extreme genuine document and
/// 33 % below the narrowest strip.
///
/// The gap is not accidental and must not be closed. A dark strip drawn to the
/// ration card's own catalogued proportion measures 5.62 against the genuine
/// card's 5.49, and BOTH are accepted: any aspect bound low enough to reject
/// that strip also rejects the real ration card. Such a region is therefore
/// ambiguous, not invalid, and is left to the caller's review path instead of
/// being refused here (ADR-012).
///
/// This is ONE of three gates, never the whole decision: aspect alone cannot
/// tell a blank sheet of paper from a document, and a genuine document with an
/// uncertain outline must not be rejected for lacking corners.
const maxPlausibleRegionAspect = 8.0;

/// Shortest side, in PREVIEW pixels, that a region crop must have to be a
/// usable document image. The derived crop is what the user thumbnails, crops
/// by hand and prints; below this it cannot serve any of those.
///
/// A floor, not a discriminator, and deliberately far below the evidence: the
/// smallest genuine crop on the fixtures this repository ships is 215 px (the
/// distant document and the ration-card proportion, whose 52 mm side is short
/// by nature) — 4.5x this bound — while the refused artifacts measure 43 to
/// 104 px on their short side. Every artifact above 43 px is already refused by
/// the aspect or frame-edge gate with margin; raising this floor to 160 px to
/// catch them too would leave only 1.34x to the genuine minimum, which is
/// tuning to the fixture rather than to the domain.
///
/// The floor binds only for SMALL sources. A region that clears the segmenter's
/// own 10 px box floor crops to at least `previewLongEdge / 20` px once the 8 %
/// margin is added, so with the editor's 1200 px preview this branch cannot
/// fire at all; it is sources whose long edge is below ~960 px that can produce
/// a region too small to crop. What the bound changes is that such a region is
/// now REFUSED with a reason instead of being emitted as a `region-too-small`
/// candidate that the intake went on to turn into a document record and an
/// editor item.
const minUsableRegionCropPx = 48;

/// Most document candidates one photo may yield.
///
/// A single photograph realistically holds a handful of identity documents.
/// The cap stops a noisy threshold from turning one photo into dozens of
/// editor items; it keeps the strongest measured regions (most foreground
/// area, ties broken by the deterministic region order) and reports the rest
/// through [RegionRejection.candidateCap] instead of dropping them silently.
const maxSegmentCandidates = 12;

class SegmentationResult {
  const SegmentationResult({
    required this.candidates,
    required this.multi,
    this.rejected = const [],
  });

  /// With [multi] true: one candidate per segmented document. With [multi]
  /// false: segmentation found no reliable multi-document structure and the
  /// caller should use the single-document path on the whole image.
  ///
  /// Every entry here is a PLAUSIBLE document region: either it carries a
  /// trustworthy quadrilateral, or it is an explicitly unresolved region the
  /// caller must keep for review. Regions that cannot be documents are in
  /// [rejected], never here.
  final List<SegmentCandidate> candidates;
  final bool multi;

  /// Measured regions that candidate-quality validation refused, with the
  /// measurements that decided each one. Empty for a clean photo.
  final List<RejectedRegion> rejected;
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

  // Candidate-quality validation. Measured HERE — before any crop is rendered,
  // before any corner is searched for and long before a derived file, a
  // document record or a layout item exists — because this is the earliest
  // point where the measurements that decide it are all available. A region
  // refused here costs nothing; the same region accepted costs a derived file
  // and an editor item the user has to delete by hand.
  final measured = [
    for (final box in merged) _measure(box, w, h, image.width, image.height),
  ];
  final accepted = <_Measurement>[];
  final rejected = <RejectedRegion>[];
  for (final measurement in measured) {
    final rejection = _rejectionFor(measurement);
    if (rejection == null) {
      accepted.add(measurement);
    } else {
      rejected.add(_rejectedRegion(measurement, rejection, total));
    }
  }
  _applyCandidateCap(accepted, rejected, total);

  if (accepted.length < 2) {
    // One plausible document (or none) is the single-document path's job: the
    // precise detector sees the whole frame and the rejections above are
    // reported, so this is never a silent loss of a measured region.
    return SegmentationResult(
      candidates: const [],
      multi: false,
      rejected: List.unmodifiable(rejected),
    );
  }

  // Map each ACCEPTED region back to the preview-resolution image and detect
  // corners.
  final candidates = <SegmentCandidate>[];
  for (final measurement in accepted) {
    final region = measurement.region;
    final subLeft = measurement.subLeft;
    final subTop = measurement.subTop;
    final subWidth = measurement.subWidth;
    final subHeight = measurement.subHeight;
    final box = measurement.box;
    if (subWidth < 20 || subHeight < 20) {
      // Unreachable for an accepted region ([minUsableRegionCropPx] is
      // larger); kept as a defensive branch so a future bound change can never
      // reintroduce a too-small crop as a document.
      rejected.add(
        _rejectedRegion(measurement, RegionRejection.unusableCrop, total),
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
    rejected: List.unmodifiable(rejected),
  );
}

/// One merged component plus everything the acceptance gates measure about it:
/// its normalized region and the size that region's crop would have at preview
/// resolution. Computed once so validation and rendering cannot disagree.
class _Measurement {
  const _Measurement({
    required this.box,
    required this.region,
    required this.subLeft,
    required this.subTop,
    required this.subWidth,
    required this.subHeight,
    required this.borderSides,
  });

  final _Box box;

  /// Normalized [left, top, right, bottom] in the source image.
  final List<double> region;
  final int subLeft;
  final int subTop;
  final int subWidth;
  final int subHeight;

  /// How many of the four working-frame edges the component touches.
  final int borderSides;

  double get aspect {
    final long = math.max(box.width, box.height).toDouble();
    final short = math.max(1, math.min(box.width, box.height)).toDouble();
    return long / short;
  }

  int get cropShortSide => math.min(subWidth, subHeight);
}

/// The margin-expanded, clamped region of [box] and its preview-resolution crop
/// size. This is the SAME arithmetic the corner-detection loop has always used,
/// lifted out so validation measures exactly what rendering would produce.
_Measurement _measure(
  _Box box,
  int w,
  int h,
  int imageWidth,
  int imageHeight,
) {
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
  final subLeft = (region[0] * (imageWidth - 1)).round();
  final subTop = (region[1] * (imageHeight - 1)).round();
  final subRight = (region[2] * (imageWidth - 1)).round();
  final subBottom = (region[3] * (imageHeight - 1)).round();
  final borderSides =
      (box.left == 0 ? 1 : 0) +
      (box.top == 0 ? 1 : 0) +
      (box.right == w - 1 ? 1 : 0) +
      (box.bottom == h - 1 ? 1 : 0);
  return _Measurement(
    box: box,
    region: region,
    subLeft: subLeft,
    subTop: subTop,
    subWidth: subRight - subLeft + 1,
    subHeight: subBottom - subTop + 1,
    borderSides: borderSides,
  );
}

/// The gate that refuses [measurement], or null when the region is a plausible
/// document candidate.
///
/// Every branch is a measurement that CANNOT fire on a plausible document, so
/// the gate is conservative in the direction that matters: it never rejects a
/// region merely because its outline was hard to find. A genuine document with
/// an uncertain boundary stays a candidate and is resolved by the caller's
/// unresolved-region review path.
///
/// Order is the order of decisiveness, so the reported reason is the strongest
/// one available:
/// - a region reaching two frame edges is frame furniture or a document the
///   photo cut in half, whichever it is it is not a separable document;
/// - a proportion no catalogued document can have is a strip or a shadow band;
/// - a crop too small to thumbnail, hand-crop or print is not usable.
RegionRejection? _rejectionFor(_Measurement measurement) {
  if (measurement.borderSides >= 2) return RegionRejection.frameArtifact;
  if (measurement.aspect > maxPlausibleRegionAspect) {
    return RegionRejection.implausibleAspect;
  }
  if (measurement.cropShortSide < minUsableRegionCropPx) {
    return RegionRejection.unusableCrop;
  }
  return null;
}

RejectedRegion _rejectedRegion(
  _Measurement measurement,
  RegionRejection rejection,
  double total,
) {
  final box = measurement.box;
  return RejectedRegion(
    region: measurement.region,
    rejection: rejection,
    aspect: measurement.aspect,
    areaFraction: total <= 0 ? 0.0 : box.area / total,
    fill: box.fill,
    borderSides: measurement.borderSides,
    cropWidth: measurement.subWidth,
    cropHeight: measurement.subHeight,
  );
}

/// Keeps at most [maxSegmentCandidates] regions: the ones with the most
/// measured foreground, ties broken by the deterministic region order. The rest
/// are reported as [RegionRejection.candidateCap] rather than dropped, and the
/// survivors stay in region order so downstream results remain deterministic.
void _applyCandidateCap(
  List<_Measurement> accepted,
  List<RejectedRegion> rejected,
  double total,
) {
  if (accepted.length <= maxSegmentCandidates) return;
  final ranked = [
    for (var index = 0; index < accepted.length; index++)
      (index, accepted[index]),
  ]..sort((a, b) {
    final byArea = b.$2.box.area.compareTo(a.$2.box.area);
    return byArea != 0 ? byArea : a.$1.compareTo(b.$1);
  });
  final keep = <int>{
    for (final entry in ranked.take(maxSegmentCandidates)) entry.$1,
  };
  final survivors = <_Measurement>[];
  for (var index = 0; index < accepted.length; index++) {
    if (keep.contains(index)) {
      survivors.add(accepted[index]);
    } else {
      rejected.add(
        _rejectedRegion(accepted[index], RegionRejection.candidateCap, total),
      );
    }
  }
  accepted
    ..clear()
    ..addAll(survivors);
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
///
/// A region that HAS a trustworthy quadrilateral wins over an overlapping
/// region without one, whichever came first in the region order: suppression
/// must be consistent between region detection, crop generation and document
/// creation, and letting an unresolved artifact suppress a resolved document
/// would lose a real detection while keeping its duplicate-free neighbour.
/// Survivors are returned in the deterministic region order.
List<SegmentCandidate> _suppressDuplicates(List<SegmentCandidate> input) {
  final preference = [
    for (var index = 0; index < input.length; index++) index,
  ]..sort((a, b) {
    final byQuad = _hasQuad(input[b]).compareTo(_hasQuad(input[a]));
    return byQuad != 0 ? byQuad : a.compareTo(b);
  });
  final kept = <SegmentCandidate>[];
  final survivors = <int>{};
  for (final index in preference) {
    final candidate = input[index];
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
    if (!duplicate) {
      kept.add(candidate);
      survivors.add(index);
    }
  }
  final ordered = survivors.toList()..sort();
  return [for (final index in ordered) input[index]];
}

int _hasQuad(SegmentCandidate candidate) => candidate.corners != null ? 1 : 0;

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
