import 'dart:math' as math;

import 'package:image/image.dart' as img;

import '../domain/boundary_decision.dart';
import '../domain/geometry.dart';
import '../domain/quad_assessment.dart';
import 'document_detector.dart';
import 'document_segmenter.dart';

/// Measured physical step-edge & sampling evidence for one quadrilateral.
///
/// Separate by design from neural `modelConfidence` (`ScanIdDocNet-v1`) and
/// from the domain acceptance gate (`verifyBoundary`):
/// - Out-of-frame sample locations are NEVER clamped onto border pixels; sides
///   whose outward normal crosses the image boundary are counted explicitly in
///   [outOfFrameSides].
/// - Geometric validity (convexity, corner angles, area fraction, perspective
///   edge ratio) is delegated to `assessQuad`, not approximated with affine
///   parallelogram similarity.
class QuadPhysicalMetrics {
  const QuadPhysicalMetrics({
    required this.minAllSideStep,
    required this.minInteriorSideStep,
    required this.meanSideStep,
    required this.parallelogramSimilarity,
    required this.maxOutsideSideDeviation,
    required this.areaFraction,
    required this.outOfFrameSides,
    required this.interiorSidesCount,
  });

  /// Minimum median normal RGB L2 step across all 4 sides (`0` if clipped).
  final double minAllSideStep;

  /// Minimum median normal RGB L2 step across non-clipped interior sides.
  final double minInteriorSideStep;

  /// Mean median normal RGB L2 step across the 4 quadrilateral edges.
  final double meanSideStep;

  /// 2D affine opposite-edge symmetry diagnostic in `[0..1]` (informational;
  /// never used to reject valid 3D perspective foreshortening).
  final double parallelogramSimilarity;

  /// Maximum L2 RGB deviation of one valid outward strip from the median of
  /// the remaining valid outward strips.
  final double maxOutsideSideDeviation;

  /// Normalized polygon area fraction in `[0..1]`.
  final double areaFraction;

  /// Count of sides whose outward strip falls outside `[0..w-1] × [0..h-1]`
  /// or hugs the outer camera border within `0.8%`.
  final int outOfFrameSides;

  /// Count of sides with full in-bounds interior & exterior normal samples.
  final int interiorSidesCount;

  /// Backwards-compatible alias for the weakest full-perimeter contrast step.
  double get minSideStep => minAllSideStep;

  /// Backwards-compatible alias for camera-clipped side count.
  int get clippedCameraSides => outOfFrameSides;
}

/// Evaluates symmetric step-edge contrast, true un-clamped out-of-frame
/// clipping, and outward strip coherence for [quad].
QuadPhysicalMetrics measureQuadPhysics(img.Image image, List<Point2> quad) {
  final w = image.width, h = image.height;
  final sx = math.max(1, w - 1).toDouble();
  final sy = math.max(1, h - 1).toDouble();
  final stepOffset = (0.008 * math.max(w, h)).clamp(3.0, 8.0);
  final outOffset = (0.025 * math.max(w, h)).clamp(6.0, 18.0);

  final allSteps = <double>[];
  final interiorSteps = <double>[];
  final validOutMedians = <List<double>>[];
  var outOfFrameSides = 0;

  for (var i = 0; i < 4; i++) {
    final a = quad[i], b = quad[(i + 1) % 4];
    final nearFrameEdge =
        (a.x <= .008 && b.x <= .008) ||
        (a.x >= .992 && b.x >= .992) ||
        (a.y <= .008 && b.y <= .008) ||
        (a.y >= .992 && b.y >= .992);

    final ax = a.x * sx, ay = a.y * sy;
    final bx = b.x * sx, by = b.y * sy;
    final length = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
    if (length < 4) {
      allSteps.add(0);
      outOfFrameSides++;
      continue;
    }

    // Clockwise [TL, TR, BR, BL] in y-down image coords -> outward unit normal.
    final nx = (by - ay) / length, ny = -(bx - ax) / length;
    final diffs = <double>[];
    final outR = <double>[], outG = <double>[], outB = <double>[];

    for (var k = 0; k < 20; k++) {
      final t = .08 + .84 * k / 19.0;
      final px = ax + (bx - ax) * t, py = ay + (by - ay) * t;
      final ix = (px - nx * stepOffset).round();
      final iy = (py - ny * stepOffset).round();
      final ox = (px + nx * stepOffset).round();
      final oy = (py + ny * stepOffset).round();
      if (ix >= 0 &&
          ix < w &&
          iy >= 0 &&
          iy < h &&
          ox >= 0 &&
          ox < w &&
          oy >= 0 &&
          oy < h) {
        final pin = image.getPixel(ix, iy);
        final pout = image.getPixel(ox, oy);
        final dr =
            (pin.rNormalized.toDouble() - pout.rNormalized.toDouble()) * 255;
        final dg =
            (pin.gNormalized.toDouble() - pout.gNormalized.toDouble()) * 255;
        final db =
            (pin.bNormalized.toDouble() - pout.bNormalized.toDouble()) * 255;
        diffs.add(math.sqrt(dr * dr + dg * dg + db * db));
      }

      final fx = (px + nx * outOffset).round();
      final fy = (py + ny * outOffset).round();
      if (fx >= 0 && fx < w && fy >= 0 && fy < h) {
        final pf = image.getPixel(fx, fy);
        outR.add(pf.rNormalized.toDouble() * 255);
        outG.add(pf.gNormalized.toDouble() * 255);
        outB.add(pf.bNormalized.toDouble() * 255);
      }
    }

    if (nearFrameEdge || diffs.length < 10) {
      outOfFrameSides++;
      allSteps.add(diffs.isEmpty ? 0.0 : _medianList(diffs));
    } else {
      final step = _medianList(diffs);
      allSteps.add(step);
      interiorSteps.add(step);
      if (outR.length >= 6) {
        validOutMedians.add([
          _medianList(outR),
          _medianList(outG),
          _medianList(outB),
        ]);
      }
    }
  }

  var maxOutDev = 0.0;
  if (validOutMedians.length >= 3) {
    for (var i = 0; i < validOutMedians.length; i++) {
      final otherR = <double>[], otherG = <double>[], otherB = <double>[];
      for (var j = 0; j < validOutMedians.length; j++) {
        if (j == i) continue;
        otherR.add(validOutMedians[j][0]);
        otherG.add(validOutMedians[j][1]);
        otherB.add(validOutMedians[j][2]);
      }
      final dr = validOutMedians[i][0] - _medianList(otherR);
      final dg = validOutMedians[i][1] - _medianList(otherG);
      final db = validOutMedians[i][2] - _medianList(otherB);
      final dev = math.sqrt(dr * dr + dg * dg + db * db);
      if (dev > maxOutDev) maxOutDev = dev;
    }
  }

  final edges = <(double, double, double)>[];
  for (var i = 0; i < 4; i++) {
    final dx = (quad[(i + 1) % 4].x - quad[i].x) * sx;
    final dy = (quad[(i + 1) % 4].y - quad[i].y) * sy;
    edges.add((dx, dy, math.sqrt(dx * dx + dy * dy)));
  }
  final r02 =
      math.min(edges[0].$3, edges[2].$3) /
      math.max(1e-6, edges[0].$3 >= edges[2].$3 ? edges[0].$3 : edges[2].$3);
  final r13 =
      math.min(edges[1].$3, edges[3].$3) /
      math.max(1e-6, edges[1].$3 >= edges[3].$3 ? edges[1].$3 : edges[3].$3);
  final cos02 =
      -(edges[0].$1 * edges[2].$1 + edges[0].$2 * edges[2].$2) /
      math.max(1e-6, edges[0].$3 * edges[2].$3);
  final cos13 =
      -(edges[1].$1 * edges[3].$1 + edges[1].$2 * edges[3].$2) /
      math.max(1e-6, edges[1].$3 * edges[3].$3);
  final parallelogramSim =
      (.5 * (r02 * r13) +
              .5 * math.min(math.max(0.0, cos02), math.max(0.0, cos13)))
          .clamp(0.0, 1.0);

  return QuadPhysicalMetrics(
    minAllSideStep: allSteps.reduce(math.min),
    minInteriorSideStep: interiorSteps.isEmpty
        ? 0.0
        : interiorSteps.reduce(math.min),
    meanSideStep: allSteps.reduce((a, b) => a + b) / 4.0,
    parallelogramSimilarity: parallelogramSim,
    maxOutsideSideDeviation: maxOutDev,
    areaFraction: _polygonAreaNorm(quad),
    outOfFrameSides: outOfFrameSides,
    interiorSidesCount: interiorSteps.length,
  );
}

/// Arbitrates multi-document scene segmentation without ever merging Stage-2A
/// candidates:
/// - Suppresses false AI multi-splits when fewer than two AI candidates sit on
///   real physical edges (`minAllSideStep >= 20`) or when a single outer physical
///   card encloses all AI fragments with `> 2.2×` stronger minimum step contrast.
/// - Recovers genuine multi-document sheets missed by Stage-1 (such as light
///   cards laid out on a white A4 sheet) via `segmentDecoded`.
SegmentationResult arbitrateSceneBoundaries(
  img.Image preview,
  SegmentationResult? aiScene,
) {
  if (aiScene != null && aiScene.multi && aiScene.candidates.length >= 2) {
    final classicalSingle = detectDocumentCornersScored(preview);
    final singleMetrics = classicalSingle != null
        ? measureQuadPhysics(preview, classicalSingle.corners)
        : null;

    var physicallyValidCount = 0;
    var strongestSubMinStep = 0.0;
    for (final c in aiScene.candidates) {
      if (c.corners == null || (c.detectionConfidence ?? 0) < .35) continue;
      final assess = assessQuad(
        c.corners!,
        sourceWidth: preview.width,
        sourceHeight: preview.height,
      );
      if (!assess.acceptable) continue;
      final m = measureQuadPhysics(preview, c.corners!);
      if (m.minAllSideStep > strongestSubMinStep) {
        strongestSubMinStep = m.minAllSideStep;
      }
      if (m.minAllSideStep >= 20.0) {
        physicallyValidCount++;
      }
    }

    if (physicallyValidCount < 2) {
      return const SegmentationResult(candidates: [], multi: false);
    }

    if (classicalSingle != null && singleMetrics != null) {
      final allInsideOuterCard = aiScene.candidates.every(
        (c) =>
            c.corners != null &&
            _intersectionOverFirst(c.corners!, classicalSingle.corners) >= .85,
      );
      if (allInsideOuterCard &&
          singleMetrics.minAllSideStep > 2.2 * strongestSubMinStep) {
        return const SegmentationResult(candidates: [], multi: false);
      }
    }
    return aiScene;
  }

  final classicalMulti = segmentDecoded(preview);
  if (classicalMulti.multi && classicalMulti.candidates.length >= 2) {
    final validClassicalMulti = <SegmentCandidate>[];
    for (final c in classicalMulti.candidates) {
      if (c.corners == null) continue;
      final assess = assessQuad(
        c.corners!,
        sourceWidth: preview.width,
        sourceHeight: preview.height,
      );
      if (!assess.acceptable) continue;
      if (aiScene != null) {
        final m = measureQuadPhysics(preview, c.corners!);
        // Stage-2A did not corroborate multi-document presence on this preview:
        // preserve authentic classical `segmenter` provenance and gate to
        // `needsReview` via `minAutoAcceptConfidence` without inflating
        // confidence or silently auto-cropping non-document multi-box sheets.
        validClassicalMulti.add(
          SegmentCandidate(
            region: c.region,
            corners: c.corners,
            detectionConfidence: 0.0,
            producer: BoundaryProducer.segmenter,
            minAutoAcceptConfidence: .55,
            touchesFrameEdge: c.touchesFrameEdge || m.outOfFrameSides > 0,
            reason: c.reason,
          ),
        );
      } else {
        validClassicalMulti.add(c);
      }
    }
    if (validClassicalMulti.length >= 2) {
      return SegmentationResult(
        candidates: validClassicalMulti,
        multi: true,
        rejected: classicalMulti.rejected,
      );
    }
  }
  // Single-document scenes (including lone uncertain AI candidates) always
  // defer to whole-frame single-document arbitration (`suggestProposal`) so
  // physical edge cross-checking runs identically across all single-doc inputs.
  return const SegmentationResult(candidates: [], multi: false);
}

/// Arbitrates single-document boundary claims across `ScanIdDocNet-v1`
/// candidates and `detectDocumentCornersScored` with strict separation between:
/// 1. Raw model probability (`modelConfidence` is NEVER fabricated or inflated),
/// 2. Measured physical boundary evidence (`measureQuadPhysics` + `assessQuad`),
/// 3. Final crop authorization (`verifyBoundary` in `lib/domain/boundary_decision.dart`).
BoundaryProposal? arbitrateSingleBoundary(
  img.Image preview,
  BoundaryProposal? aiProposal, {
  List<BoundaryProposal> extraAiProposals = const [],
  bool hasLearnedModel = true,
}) {
  final allAi = <BoundaryProposal>[
    if (aiProposal != null) aiProposal,
    ...extraAiProposals,
  ];

  BoundaryProposal? bestAi;
  QuadPhysicalMetrics? bestAiMetrics;
  var bestAiScore = double.negativeInfinity;
  for (final p in allAi) {
    final c = p.corners;
    if (c == null || c.length != 4) continue;
    final assess = assessQuad(
      c,
      sourceWidth: preview.width,
      sourceHeight: preview.height,
    );
    if (!assess.acceptable) continue;
    final m = measureQuadPhysics(preview, c);
    final score =
        m.minAllSideStep + .25 * m.meanSideStep + 40.0 * m.areaFraction;
    if (score > bestAiScore) {
      bestAiScore = score;
      bestAi = p;
      bestAiMetrics = m;
    }
  }

  final classical = detectDocumentCornersScored(preview);
  final clAssess = classical == null
      ? null
      : assessQuad(
          classical.corners,
          sourceWidth: preview.width,
          sourceHeight: preview.height,
        );
  final validClassical =
      classical != null && clAssess != null && clAssess.acceptable
      ? classical
      : null;
  final clMetrics = validClassical != null
      ? measureQuadPhysics(preview, validClassical.corners)
      : null;

  // Pure classical mode (`aiBundle == null`): emit authentic whole-frame
  // detector provenance without inventing any neural confidence fields.
  if (!hasLearnedModel) {
    if (validClassical == null || clMetrics == null) return null;
    return BoundaryProposal(
      producer: BoundaryProducer.wholeFrameDetector,
      corners: validClassical.corners,
      touchesFrameEdge: clMetrics.outOfFrameSides > 0,
    );
  }

  // Case 1: Learned model produced a physically sound 4-edge document claim,
  // unless the classical whole-frame detector strictly encloses the neural box
  // inside a substantially larger outer physical card with >2× stronger edge
  // contrast (indicating the neural box locked onto an internal card feature).
  final enclosedInnerFeature =
      bestAi != null &&
      bestAiMetrics != null &&
      validClassical != null &&
      clMetrics != null &&
      clMetrics.outOfFrameSides == 0 &&
      clMetrics.areaFraction >= 1.25 * bestAiMetrics.areaFraction &&
      clMetrics.minAllSideStep > bestAiMetrics.minAllSideStep * 2.0 &&
      _intersectionOverFirst(bestAi.corners!, validClassical.corners) >= .90;

  if (!enclosedInnerFeature &&
      bestAi != null &&
      bestAiMetrics != null &&
      bestAiMetrics.outOfFrameSides == 0 &&
      bestAiMetrics.minAllSideStep >= 35.0) {
    var chosenCorners = bestAi.corners!;
    if (validClassical != null && clMetrics != null) {
      final iou = _quadIouNorm(chosenCorners, validClassical.corners);
      if (iou >= .85 &&
          clMetrics.outOfFrameSides == 0 &&
          clMetrics.minAllSideStep > bestAiMetrics.minAllSideStep * 1.15) {
        chosenCorners = validClassical.corners;
      }
    }
    return BoundaryProposal(
      producer: bestAi.producer,
      corners: chosenCorners,
      region: bestAi.region,
      imposedAspect: bestAi.imposedAspect,
      imposedKindLabel: bestAi.imposedKindLabel,
      modelConfidence: bestAi.modelConfidence,
      minAutoAcceptConfidence: bestAi.minAutoAcceptConfidence,
      touchesFrameEdge: bestAi.touchesFrameEdge,
    );
  }

  // Case 2: Neural model missed, locked onto an inner sub-feature, or proposed
  // a physically broken quad (`minAllSideStep < 35` or border-clipped).
  // Never auto-crop uncorroborated disagreement silently: emit authentic
  // `wholeFrameDetector` provenance with uninflated `modelConfidence = 0.0` so
  // `verifyBoundary` routes the recovered corners to user review.
  if (validClassical != null && clMetrics != null) {
    final classicalPlausible =
        clMetrics.interiorSidesCount >= 1 &&
        clMetrics.meanSideStep >= 25.0 &&
        clMetrics.minInteriorSideStep >= 10.0;
    if (classicalPlausible) {
      final unverifiedConfidence =
          bestAi != null &&
              bestAi.modelConfidence != null &&
              bestAi.minAutoAcceptConfidence != null &&
              bestAi.modelConfidence! < bestAi.minAutoAcceptConfidence!
          ? bestAi.modelConfidence!
          : 0.0;
      return BoundaryProposal(
        producer: BoundaryProducer.wholeFrameDetector,
        corners: validClassical.corners,
        imposedAspect: bestAi?.imposedAspect,
        imposedKindLabel: bestAi?.imposedKindLabel,
        modelConfidence: unverifiedConfidence,
        minAutoAcceptConfidence: bestAi?.minAutoAcceptConfidence ?? .55,
        touchesFrameEdge: clMetrics.outOfFrameSides > 0,
      );
    }
  }

  // Case 3: Only an unverified AI proposal remains (no stronger classical quad).
  // Never let a physically broken AI boundary silently auto-crop: route to
  // review while retaining the proposed corners for manual adjustment.
  if (bestAi != null && bestAiMetrics != null) {
    final rawConf = bestAi.modelConfidence;
    final minAuto = bestAi.minAutoAcceptConfidence ?? .55;
    return BoundaryProposal(
      producer: bestAi.producer,
      corners: bestAi.corners,
      region: bestAi.region,
      imposedAspect: bestAi.imposedAspect,
      imposedKindLabel: bestAi.imposedKindLabel,
      modelConfidence: (rawConf != null && rawConf < minAuto) ? rawConf : 0.0,
      minAutoAcceptConfidence: minAuto,
      touchesFrameEdge:
          bestAi.touchesFrameEdge || bestAiMetrics.outOfFrameSides > 0,
    );
  }

  return aiProposal;
}

double _medianList(List<double> values) {
  if (values.isEmpty) return 0;
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}

double _signedAreaNorm(List<Point2> poly) {
  var sum = 0.0;
  for (var i = 0; i < poly.length; i++) {
    final a = poly[i], b = poly[(i + 1) % poly.length];
    sum += a.x * b.y - b.x * a.y;
  }
  return sum / 2.0;
}

double _polygonAreaNorm(List<Point2> poly) => _signedAreaNorm(poly).abs();

List<Point2> _clipConvexPolygon(List<Point2> subject, List<Point2> clip) {
  var clipped = [...subject];
  final orient = _signedAreaNorm(clip) >= 0 ? 1.0 : -1.0;
  for (var edge = 0; edge < clip.length && clipped.isNotEmpty; edge++) {
    final e1 = clip[edge], e2 = clip[(edge + 1) % clip.length];
    double side(Point2 p) =>
        orient * ((e2.x - e1.x) * (p.y - e1.y) - (e2.y - e1.y) * (p.x - e1.x));
    final next = <Point2>[];
    for (var i = 0; i < clipped.length; i++) {
      final cur = clipped[i];
      final prev = clipped[(i + clipped.length - 1) % clipped.length];
      final cs = side(cur), ps = side(prev);
      final ci = cs >= 0, pi = ps >= 0;
      if (ci != pi) {
        final t = ps / (ps - cs);
        next.add(
          Point2(prev.x + (cur.x - prev.x) * t, prev.y + (cur.y - prev.y) * t),
        );
      }
      if (ci) next.add(cur);
    }
    clipped = next;
  }
  return clipped;
}

double _quadIouNorm(List<Point2> a, List<Point2> b) {
  final areaA = _polygonAreaNorm(a), areaB = _polygonAreaNorm(b);
  if (areaA <= 0 || areaB <= 0) return 0;
  final interPoly = _clipConvexPolygon(a, b);
  if (interPoly.length < 3) return 0;
  final inter = _polygonAreaNorm(interPoly);
  final union = areaA + areaB - inter;
  return union <= 0 ? 0 : inter / union;
}

double _intersectionOverFirst(List<Point2> inner, List<Point2> outer) {
  final areaInner = _polygonAreaNorm(inner);
  if (areaInner <= 0) return 0;
  final interPoly = _clipConvexPolygon(inner, outer);
  if (interPoly.length < 3) return 0;
  return _polygonAreaNorm(interPoly) / areaInner;
}
