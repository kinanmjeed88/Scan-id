/// Two-stage learned document & ID-card detector + 4-corner polygon localizer
/// (`ScanIdDocNet-v1`, offline cross-platform ONNX execution via
/// `onnx_lite_runtime.dart`).
///
/// Architectural guarantees (`ADR-005`, `ADR-006`, `boundary_decision.dart`):
/// 1. Runs 100% locally offline from bundled SHA-256-verified ONNX assets;
///    never transmits user documents or telemetry.
/// 2. Separates Stage-1 multi-instance coarse localization (`[1, 3, 160, 160]`
///    -> `[1, 7, 40, 40]` + `[1, 2]`) from Stage-2 per-ROI 4-corner heatmap +
///    subpixel offset + boundary-edge verification (`[1, 3, 128, 128]` ->
///    `[1, 6, 64, 64]` + `[1, 2, 64, 64]` + `[1, 3]`). Never substitutes an
///    axis-aligned bounding box for a tilted/perspective card quadrilateral.
/// 3. Emits `BoundaryProposal(producer: BoundaryProducer.learnedModel)` claims
///    only — never bypasses `verifyBoundary` or mints crop authorizations.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

import '../domain/boundary_decision.dart';
import '../domain/geometry.dart';
import 'document_segmenter.dart';
import 'onnx_lite_runtime.dart';
import 'prepare_image.dart';

const String scanIdAiBundleId = 'scanid-docnet-v1';
const String scanIdManifestAssetPath = 'assets/models/MODEL_MANIFEST.json';
const String scanIdStage1AssetPath = 'assets/models/scanid_stage1_det_v1.onnx';
const String scanIdStage2AssetPath =
    'assets/models/scanid_stage2_corners_v1.onnx';

/// Frozen validation-calibrated thresholds from `MODEL_MANIFEST.json`.
class AiFrozenThresholds {
  const AiFrozenThresholds({
    this.sceneProbFloor = 0.22,
    this.shrunkMaskThresh = 0.36,
    this.centerPeakThresh = 0.28,
    this.acceptRoiValid = 0.65,
    this.acceptFourVisible = 0.65,
    this.acceptMinCornerPeak = 0.50,
    this.acceptMeanCornerPeak = 0.64,
    this.acceptMinEdgeSupport = 0.24,
    this.acceptMeanEdgeSupport = 0.36,
    this.reviewRoiValid = 0.28,
    this.reviewMinCornerPeak = 0.16,
    this.reviewMeanCornerPeak = 0.30,
    this.reviewMeanEdgeSupport = 0.20,
    this.nmsPolygonIou = 0.35,
  });

  factory AiFrozenThresholds.fromJson(Map<String, Object?> json) {
    double numOr(String key, double fallback) {
      final v = json[key];
      return v is num ? v.toDouble() : fallback;
    }

    return AiFrozenThresholds(
      sceneProbFloor: numOr('scene_prob_floor', 0.22),
      shrunkMaskThresh: numOr('shrunk_mask_thresh', 0.36),
      centerPeakThresh: numOr('center_peak_thresh', 0.28),
      acceptRoiValid: numOr('accept_roi_valid', 0.65),
      acceptFourVisible: numOr('accept_four_visible', 0.65),
      acceptMinCornerPeak: numOr('accept_min_corner_peak', 0.50),
      acceptMeanCornerPeak: numOr('accept_mean_corner_peak', 0.64),
      acceptMinEdgeSupport: numOr('accept_min_edge_support', 0.24),
      acceptMeanEdgeSupport: numOr('accept_mean_edge_support', 0.36),
      reviewRoiValid: numOr('review_roi_valid', 0.28),
      reviewMinCornerPeak: numOr('review_min_corner_peak', 0.16),
      reviewMeanCornerPeak: numOr('review_mean_corner_peak', 0.30),
      reviewMeanEdgeSupport: numOr('review_mean_edge_support', 0.20),
      nmsPolygonIou: numOr('nms_polygon_iou', 0.35),
    );
  }

  final double sceneProbFloor;
  final double shrunkMaskThresh;
  final double centerPeakThresh;
  final double acceptRoiValid;
  final double acceptFourVisible;
  final double acceptMinCornerPeak;
  final double acceptMeanCornerPeak;
  final double acceptMinEdgeSupport;
  final double acceptMeanEdgeSupport;
  final double reviewRoiValid;
  final double reviewMinCornerPeak;
  final double reviewMeanCornerPeak;
  final double reviewMeanEdgeSupport;
  final double nmsPolygonIou;
}

/// Isolate-sendable verified ONNX model bundle.
class AiModelBundle {
  const AiModelBundle({
    required this.bundleId,
    required this.stage1Bytes,
    required this.stage2Bytes,
    this.thresholds = const AiFrozenThresholds(),
  });

  /// Parses `MODEL_MANIFEST.json` and verifies SHA-256 checksums of both
  /// ONNX weight files before allowing any inference session to load (`ADR-006`).
  factory AiModelBundle.verified({
    required String manifestJson,
    required Uint8List stage1Bytes,
    required Uint8List stage2Bytes,
  }) {
    final decoded = jsonDecode(manifestJson);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Invalid MODEL_MANIFEST.json root object.');
    }
    final bundleId = (decoded['bundle_id'] as String?) ?? scanIdAiBundleId;
    final models = decoded['models'];
    if (models is! Map<String, Object?>) {
      throw const FormatException('MODEL_MANIFEST.json missing models block.');
    }
    final s1Meta = models['stage1_detector'];
    final s2Meta = models['stage2_corner_refiner'];
    if (s1Meta is! Map<String, Object?> || s2Meta is! Map<String, Object?>) {
      throw const FormatException(
        'MODEL_MANIFEST.json missing stage metadata.',
      );
    }
    final expectedS1 = s1Meta['sha256'] as String?;
    final expectedS2 = s2Meta['sha256'] as String?;
    final actualS1 = sha256.convert(stage1Bytes).toString();
    final actualS2 = sha256.convert(stage2Bytes).toString();
    if (expectedS1 != null && expectedS1 != actualS1) {
      throw FormatException(
        'Stage-1 ONNX SHA-256 mismatch: expected $expectedS1, got $actualS1',
      );
    }
    if (expectedS2 != null && expectedS2 != actualS2) {
      throw FormatException(
        'Stage-2 ONNX SHA-256 mismatch: expected $expectedS2, got $actualS2',
      );
    }
    final ftRaw = decoded['frozen_thresholds'];
    final thresholds = ftRaw is Map<String, Object?>
        ? AiFrozenThresholds.fromJson(ftRaw)
        : const AiFrozenThresholds();

    return AiModelBundle(
      bundleId: bundleId,
      stage1Bytes: stage1Bytes,
      stage2Bytes: stage2Bytes,
      thresholds: thresholds,
    );
  }

  final String bundleId;
  final Uint8List stage1Bytes;
  final Uint8List stage2Bytes;
  final AiFrozenThresholds thresholds;
}

class AiQuadProposal {
  const AiQuadProposal({
    required this.corners,
    required this.region,
    required this.confidence,
    required this.gateConfidence,
    required this.roiValidProb,
    required this.fourVisibleProb,
    required this.minCornerPeak,
    required this.meanCornerPeak,
    required this.minEdgeSupport,
    required this.meanEdgeSupport,
    required this.frameTouchCount,
    required this.eligibleForAutoAccept,
  });

  /// Ordered clockwise corners `[TL, TR, BR, BL]` in normalized `[0, 1]^2`
  /// coordinates of the EXIF-oriented source image.
  final List<Point2> corners;

  /// Normalized `[left, top, right, bottom]` bounds enclosing the proposal.
  final List<double> region;

  /// Raw calibrated neural+geometric score in `[0, 1]`.
  final double confidence;

  /// Score passed to `BoundaryProposal.modelConfidence`: `>= 0.55` only when
  /// every frozen validation threshold (`accept_*`) passed, otherwise capped
  /// below `0.55` so `verifyBoundary` routes uncertain proposals to
  /// `BoundaryDecisionKind.needsReview` without auto-cropping.
  final double gateConfidence;

  final double roiValidProb;
  final double fourVisibleProb;
  final double minCornerPeak;
  final double meanCornerPeak;
  final double minEdgeSupport;
  final double meanEdgeSupport;
  final int frameTouchCount;
  final bool eligibleForAutoAccept;

  bool get touchesFrameEdge => frameTouchCount > 0;

  AiQuadProposal asNeedsReview() => AiQuadProposal(
    corners: corners,
    region: region,
    confidence: confidence,
    gateConfidence: math.min(confidence, 0.50),
    roiValidProb: roiValidProb,
    fourVisibleProb: fourVisibleProb,
    minCornerPeak: minCornerPeak,
    meanCornerPeak: meanCornerPeak,
    minEdgeSupport: minEdgeSupport,
    meanEdgeSupport: meanEdgeSupport,
    frameTouchCount: frameTouchCount,
    eligibleForAutoAccept: false,
  );

  BoundaryProposal toBoundaryProposal({
    double? imposedAspect,
    String? imposedKindLabel,
    bool includeRegion = false,
  }) => BoundaryProposal(
    producer: BoundaryProducer.learnedModel,
    corners: corners,
    region: includeRegion ? region : null,
    imposedAspect: imposedAspect,
    imposedKindLabel: imposedKindLabel,
    modelConfidence: gateConfidence,
    minAutoAcceptConfidence: 0.55,
    touchesFrameEdge: touchesFrameEdge,
  );
}

class AiSceneDetection {
  const AiSceneDetection({
    required this.sceneHasDocProb,
    required this.sceneMultiProb,
    required this.multi,
    required this.candidates,
  });

  final double sceneHasDocProb;
  final double sceneMultiProb;
  final bool multi;
  final List<AiQuadProposal> candidates;

  /// Converts into `SegmentationResult` for `SmartIntake` / `RecognitionPipeline`.
  /// - Multi-card scenes (`>= 2` candidates) and single uncertain (`needsReview`)
  ///   candidates stay in `candidates` so region preservation + reviewable
  ///   suggested corners run cleanly.
  /// - A lone auto-accept candidate returns empty `candidates` (mirroring
  ///   `document_segmenter.dart` §5) when `singleDefersToWholeFrame` is true, OR
  ///   returns the candidate directly when `singleDefersToWholeFrame` is false.
  SegmentationResult toSegmentationResult({
    bool singleDefersToWholeFrame = true,
  }) {
    if (candidates.isEmpty) {
      return const SegmentationResult(candidates: [], multi: false);
    }
    if (singleDefersToWholeFrame &&
        candidates.length == 1 &&
        candidates.single.eligibleForAutoAccept) {
      return const SegmentationResult(candidates: [], multi: false);
    }
    final segs = [
      for (final c in candidates)
        SegmentCandidate(
          region: c.region,
          corners: c.corners,
          detectionConfidence: c.gateConfidence,
          reason: c.eligibleForAutoAccept
              ? 'ai-verified-quad'
              : 'ai-review-proposal',
          producer: BoundaryProducer.learnedModel,
          minAutoAcceptConfidence: 0.55,
          touchesFrameEdge: c.touchesFrameEdge,
        ),
    ];
    return SegmentationResult(candidates: segs, multi: segs.length >= 2);
  }
}

/// Decomposed per-stage execution timing for real Dart VM / AOT profiling
/// (Stage 6: strictly separates neural ONNX execution from pre/post-processing).
class AiLatencyBreakdown {
  const AiLatencyBreakdown({
    required this.stage1OnnxMs,
    required this.stage2OnnxMs,
    required this.preprocessMs,
    required this.postprocessMs,
    required this.fullPipelineMs,
    required this.stage2Calls,
  });

  final double stage1OnnxMs;
  final double stage2OnnxMs;
  final double preprocessMs;
  final double postprocessMs;
  final double fullPipelineMs;
  final int stage2Calls;

  double get modelOnlyMs => stage1OnnxMs + stage2OnnxMs;
}

class AiDocumentDetector {
  AiDocumentDetector({
    required OnnxLiteSession stage1,
    required OnnxLiteSession stage2,
    this.thresholds = const AiFrozenThresholds(),
  }) : _s1 = stage1,
       _s2 = stage2;

  factory AiDocumentDetector.fromBundle(AiModelBundle bundle) =>
      AiDocumentDetector(
        stage1: OnnxLiteSession.fromBytes(bundle.stage1Bytes),
        stage2: OnnxLiteSession.fromBytes(bundle.stage2Bytes),
        thresholds: bundle.thresholds,
      );

  final OnnxLiteSession _s1;
  final OnnxLiteSession _s2;
  final AiFrozenThresholds thresholds;

  OnnxLiteSession get stage1Session => _s1;
  OnnxLiteSession get stage2Session => _s2;

  AiSceneDetection detectBytes(Uint8List encodedBytes) =>
      detectImage(decodeForProcessing(encodedBytes));

  AiSceneDetection detectImage(img.Image image) =>
      detectImageWithProfile(image).$1;

  (AiSceneDetection, AiLatencyBreakdown) detectImageWithProfile(
    img.Image image,
  ) {
    final totalSw = Stopwatch()..start();
    final stepSw = Stopwatch();
    final w = image.width;
    final h = image.height;
    if (w < 32 || h < 32) {
      totalSw.stop();
      return (
        const AiSceneDetection(
          sceneHasDocProb: 0,
          sceneMultiProb: 0,
          multi: false,
          candidates: [],
        ),
        const AiLatencyBreakdown(
          stage1OnnxMs: 0,
          stage2OnnxMs: 0,
          preprocessMs: 0,
          postprocessMs: 0,
          fullPipelineMs: 0,
          stage2Calls: 0,
        ),
      );
    }

    stepSw
      ..reset()
      ..start();
    final rgb = _extractRgbBytes(image);
    final inp1 = resampleRoiToChw(rgb, w, h, 160, 160);
    var preUs = stepSw.elapsedMicroseconds;

    stepSw
      ..reset()
      ..start();
    final out1 = _s1.run({'input': inp1});
    final s1Us = stepSw.elapsedMicroseconds;
    final dense = out1['dense_map']!;
    final scProb = out1['scene_prob']!;
    final hasDocP = scProb.data[0];
    final multiP = scProb.data[1];

    final proposals = _extractStage1Proposals(
      dense.data,
      scProb.data,
      thresholds,
    );
    final rawCandidates = <AiQuadProposal>[];
    var s2Us = 0;
    var s2Calls = 0;

    for (final (coarseBox, _) in proposals) {
      final xmin = coarseBox[0];
      final ymin = coarseBox[1];
      final xmax = coarseBox[2];
      final ymax = coarseBox[3];
      final bw = xmax - xmin;
      final bh = ymax - ymin;

      double rx0, ry0, rx1, ry1;
      if (bw >= 0.96 && bh >= 0.96) {
        rx0 = 0.0;
        ry0 = 0.0;
        rx1 = 1.0;
        ry1 = 1.0;
      } else {
        rx0 = math.max(0.0, xmin - bw * 0.22);
        ry0 = math.max(0.0, ymin - bh * 0.22);
        rx1 = math.min(1.0, xmax + bw * 0.22);
        ry1 = math.min(1.0, ymax + bh * 0.22);
      }
      if (rx1 - rx0 < 0.08 || ry1 - ry0 < 0.08) continue;

      stepSw
        ..reset()
        ..start();
      final inp2 = resampleRoiToChw(
        rgb,
        w,
        h,
        128,
        128,
        rx0: rx0,
        ry0: ry0,
        rx1: rx1,
        ry1: ry1,
      );
      preUs += stepSw.elapsedMicroseconds;

      stepSw
        ..reset()
        ..start();
      final out2 = _s2.run({'input': inp2});
      s2Us += stepSw.elapsedMicroseconds;
      s2Calls++;
      final cHmaps = out2['corner_heatmaps']!.data;
      final cOffs = out2['corner_offsets']!.data;
      final rQual = out2['roi_quality']!.data;

      var (fullQ, peaks, edges, quals) = _decodeStage2Roi(
        cHmaps,
        cOffs,
        rQual,
        rx0,
        ry0,
        rx1,
        ry1,
      );

      final assess1 = _assessAiModelQuad(fullQ, w, h);
      if (!assess1.$1 || assess1.$2 >= 0.94) {
        continue;
      }
      var geomConf = assess1.$3;

      final snappedQ = _refineQuadEdgesLocally(rgb, w, h, fullQ);
      final assess2 = _assessAiModelQuad(snappedQ, w, h);
      if (assess2.$1 && assess2.$2 < 0.94) {
        fullQ = snappedQ;
        geomConf = assess2.$3;
      }

      final minCp = peaks.reduce(math.min);
      final meanCp = (peaks[0] + peaks[1] + peaks[2] + peaks[3]) * 0.25;
      final minEs = edges.reduce(math.min);
      final meanEs = (edges[0] + edges[1] + edges[2] + edges[3]) * 0.25;
      final touches = countFrameTouches(fullQ, edges: edges);
      final structuralComplete = touches == 0
          ? math.min(minCp, minEs) * 0.95
          : 0.0;
      final roiValid = math.max(quals[0], structuralComplete);
      final fourVis = math.max(quals[1], structuralComplete);

      final t = thresholds;
      if (roiValid < t.reviewRoiValid ||
          minCp < t.reviewMinCornerPeak ||
          meanCp < t.reviewMeanCornerPeak ||
          meanEs < t.reviewMeanEdgeSupport) {
        continue;
      }

      final neuralConf =
          0.30 * roiValid +
          0.15 * fourVis +
          0.25 * meanCp +
          0.15 * minCp +
          0.15 * meanEs;
      final combinedConf = math.min(geomConf, neuralConf).clamp(0.0, 1.0);

      final isAccept =
          roiValid >= t.acceptRoiValid &&
          fourVis >= t.acceptFourVisible &&
          minCp >= t.acceptMinCornerPeak &&
          meanCp >= t.acceptMeanCornerPeak &&
          minEs >= t.acceptMinEdgeSupport &&
          meanEs >= t.acceptMeanEdgeSupport &&
          touches == 0 &&
          combinedConf >= 0.55;

      final gateConf = isAccept ? combinedConf : math.min(combinedConf, 0.50);

      var rLeft = 1.0, rTop = 1.0, rRight = 0.0, rBottom = 0.0;
      for (final p in fullQ) {
        if (p.x < rLeft) rLeft = p.x;
        if (p.y < rTop) rTop = p.y;
        if (p.x > rRight) rRight = p.x;
        if (p.y > rBottom) rBottom = p.y;
      }
      // Expand region slightly (2% margin clamped to [0, 1]) so a reviewable
      // region crop preserves thin card borders for manual editing.
      final padX = (rRight - rLeft) * 0.025;
      final padY = (rBottom - rTop) * 0.025;
      final region = <double>[
        (rLeft - padX).clamp(0.0, 1.0),
        (rTop - padY).clamp(0.0, 1.0),
        (rRight + padX).clamp(0.0, 1.0),
        (rBottom + padY).clamp(0.0, 1.0),
      ];

      rawCandidates.add(
        AiQuadProposal(
          corners: fullQ,
          region: region,
          confidence: combinedConf,
          gateConfidence: gateConf,
          roiValidProb: roiValid,
          fourVisibleProb: fourVis,
          minCornerPeak: minCp,
          meanCornerPeak: meanCp,
          minEdgeSupport: minEs,
          meanEdgeSupport: meanEs,
          frameTouchCount: touches,
          eligibleForAutoAccept: isAccept,
        ),
      );
    }

    // Structural-priority Polygon NMS (exact convex Sutherland-Hodgman IoU so
    // adjacent tilted cards are never suppressed by overlapping axis-aligned
    // boxes, and inner sub-boxes never suppress enclosing valid outer cards).
    rawCandidates.sort((a, b) {
      final ka = 0.55 * a.confidence + 0.45 * a.meanEdgeSupport;
      final kb = 0.55 * b.confidence + 0.45 * b.meanEdgeSupport;
      return kb.compareTo(ka);
    });

    final kept = <AiQuadProposal>[];
    for (final cand in rawCandidates) {
      var duplicate = false;
      for (var idxP = 0; idxP < kept.length; idxP++) {
        final prev = kept[idxP];
        final iouPair = convexPolygonIou(cand.corners, prev.corners);
        final interA = polygonSignedAreaAbs(
          clipConvexPolygon(cand.corners, prev.corners),
        );
        final areaC = polygonSignedAreaAbs(cand.corners);
        final areaP = polygonSignedAreaAbs(prev.corners);
        final minA = math.min(areaC, areaP);
        final containment = minA > 1e-6 ? (interA / minA) : 0.0;
        if (iouPair > thresholds.nmsPolygonIou || containment > 0.65) {
          if (areaC >= 1.45 * areaP &&
              (interA / math.max(1e-6, areaP)) >= 0.78 &&
              cand.meanEdgeSupport >= 0.72 &&
              cand.roiValidProb >= 0.80) {
            kept[idxP] = cand;
          } else if (prev.eligibleForAutoAccept &&
              iouPair < 0.80 &&
              cand.meanEdgeSupport > prev.meanEdgeSupport + 0.08) {
            kept[idxP] = prev.asNeedsReview();
          }
          duplicate = true;
          break;
        }
      }
      if (!duplicate) kept.add(cand);
    }

    // Deterministic reading order (top-to-bottom, right-to-left for Arabic sheets)
    kept.sort((a, b) {
      final bandA = (a.region[1] * 10).round();
      final bandB = (b.region[1] * 10).round();
      if (bandA != bandB) return bandA.compareTo(bandB);
      return b.region[0].compareTo(a.region[0]);
    });

    totalSw.stop();
    final totalUs = totalSw.elapsedMicroseconds;
    final postUs = math.max(0, totalUs - s1Us - s2Us - preUs);
    return (
      AiSceneDetection(
        sceneHasDocProb: hasDocP,
        sceneMultiProb: multiP,
        multi: kept.length >= 2,
        candidates: List.unmodifiable(kept),
      ),
      AiLatencyBreakdown(
        stage1OnnxMs: s1Us / 1000.0,
        stage2OnnxMs: s2Us / 1000.0,
        preprocessMs: preUs / 1000.0,
        postprocessMs: postUs / 1000.0,
        fullPipelineMs: totalUs / 1000.0,
        stage2Calls: s2Calls,
      ),
    );
  }
}

/// Top-level isolate-safe full scene detection helper.
AiSceneDetection detectSceneWithAiBundle(
  Uint8List previewBytes,
  AiModelBundle bundle,
) {
  final det = AiDocumentDetector.fromBundle(bundle);
  return det.detectBytes(previewBytes);
}

/// Top-level isolate-safe single-document proposal helper.
BoundaryProposal? suggestProposalWithAiBundle(
  Uint8List previewBytes,
  AiModelBundle bundle,
) {
  final res = detectSceneWithAiBundle(previewBytes, bundle);
  if (res.candidates.isEmpty || res.candidates.length > 1) {
    return null;
  }
  return res.candidates.single.toBoundaryProposal();
}

/// Top-level isolate-safe interactive corner suggestion helper (for CropScreen's
/// manual "اقتراح الزوايا" button, where the user explicitly edits & previews).
List<Point2>? suggestInteractiveCornersWithAiBundle(
  Uint8List previewBytes,
  AiModelBundle bundle,
) {
  final res = detectSceneWithAiBundle(previewBytes, bundle);
  if (res.candidates.isEmpty) return null;
  return res.candidates.first.corners;
}

/// Top-level isolate-safe multi-document segmentation helper.
SegmentationResult segmentWithAiBundle(
  Uint8List previewBytes,
  AiModelBundle bundle, {
  bool singleDefersToWholeFrame = true,
}) {
  return detectSceneWithAiBundle(
    previewBytes,
    bundle,
  ).toSegmentationResult(singleDefersToWholeFrame: singleDefersToWholeFrame);
}

// ---------------------------------------------------------------------------
// Exact Deterministic Tensor Pre/Post-Processing (matches Python 1-to-1)
// ---------------------------------------------------------------------------

Uint8List _extractRgbBytes(img.Image image) {
  final w = image.width;
  final h = image.height;
  final out = Uint8List(w * h * 3);
  var k = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = image.getPixel(x, y);
      out[k++] = p.r.toInt().clamp(0, 255);
      out[k++] = p.g.toInt().clamp(0, 255);
      out[k++] = p.b.toInt().clamp(0, 255);
    }
  }
  return out;
}

/// Exact half-pixel bilinear ROI resample to `[1, 3, dstH, dstW]` in `[0, 1]`.
OnnxTensor resampleRoiToChw(
  Uint8List rgb,
  int srcW,
  int srcH,
  int dstW,
  int dstH, {
  double rx0 = 0.0,
  double ry0 = 0.0,
  double rx1 = 1.0,
  double ry1 = 1.0,
}) {
  final xStart = rx0 * (srcW - 1);
  final yStart = ry0 * (srcH - 1);
  final spanW = math.max(1e-6, (rx1 - rx0) * (srcW - 1));
  final spanH = math.max(1e-6, (ry1 - ry0) * (srcH - 1));

  final x0s = Int32List(dstW);
  final x1s = Int32List(dstW);
  final wxs = Float32List(dstW);
  for (var dx = 0; dx < dstW; dx++) {
    final sx = (xStart + ((dx + 0.5) / dstW) * spanW).clamp(
      0.0,
      (srcW - 1).toDouble(),
    );
    final i0 = sx.floor();
    x0s[dx] = i0;
    x1s[dx] = math.min(i0 + 1, srcW - 1);
    wxs[dx] = sx - i0;
  }

  final plane = dstH * dstW;
  final out = Float32List(3 * plane);
  const inv255 = 1.0 / 255.0;

  for (var dy = 0; dy < dstH; dy++) {
    final sy = (yStart + ((dy + 0.5) / dstH) * spanH).clamp(
      0.0,
      (srcH - 1).toDouble(),
    );
    final y0 = sy.floor();
    final y1 = math.min(y0 + 1, srcH - 1);
    final wy = sy - y0;
    final row0 = y0 * srcW * 3;
    final row1 = y1 * srcW * 3;
    final dstRow = dy * dstW;

    for (var dx = 0; dx < dstW; dx++) {
      final c0 = x0s[dx] * 3;
      final c1 = x1s[dx] * 3;
      final wx = wxs[dx];
      final idx = dstRow + dx;

      for (var ch = 0; ch < 3; ch++) {
        final p00 = rgb[row0 + c0 + ch] * inv255;
        final p01 = rgb[row0 + c1 + ch] * inv255;
        final p10 = rgb[row1 + c0 + ch] * inv255;
        final p11 = rgb[row1 + c1 + ch] * inv255;
        final top = p00 + (p01 - p00) * wx;
        final bot = p10 + (p11 - p10) * wx;
        out[ch * plane + idx] = top + (bot - top) * wy;
      }
    }
  }
  return OnnxTensor([1, 3, dstH, dstW], out);
}

int countFrameTouches(
  List<Point2> corners, {
  List<double>? edges,
  double margin = 0.016,
}) {
  var touches = 0;
  if (corners.any((c) => c.x <= margin)) touches++;
  if (corners.any((c) => c.x >= 1.0 - margin)) touches++;
  if (corners.any((c) => c.y <= margin)) touches++;
  if (corners.any((c) => c.y >= 1.0 - margin)) touches++;
  if (touches == 0 && edges != null && edges.length == 4) {
    const edgeMargin = 0.028;
    for (var i = 0; i < 4; i++) {
      final p1 = corners[i];
      final p2 = corners[(i + 1) % 4];
      final nearBorder =
          (p1.x <= edgeMargin && p2.x <= edgeMargin) ||
          (p1.x >= 1.0 - edgeMargin && p2.x >= 1.0 - edgeMargin) ||
          (p1.y <= edgeMargin && p2.y <= edgeMargin) ||
          (p1.y >= 1.0 - edgeMargin && p2.y >= 1.0 - edgeMargin);
      if (nearBorder) {
        var otherSum = 0.0;
        for (var j = 0; j < 4; j++) {
          if (j != i) otherSum += edges[j];
        }
        if (edges[i] < 0.48 && (otherSum / 3.0) >= 0.70) {
          touches++;
          break;
        }
      }
    }
  }
  return touches;
}

List<Point2> canonicalizeQuadClockwiseTl(List<Point2> pts) {
  var cx = 0.0, cy = 0.0;
  for (final p in pts) {
    cx += p.x * 0.25;
    cy += p.y * 0.25;
  }
  final indexed = List<Point2>.from(pts)
    ..sort(
      (a, b) => math
          .atan2(a.y - cy, a.x - cx)
          .compareTo(math.atan2(b.y - cy, b.x - cx)),
    );
  // Ensure clockwise winding in image coordinates (+x right, +y down)
  var signedArea2 = 0.0;
  for (var i = 0; i < 4; i++) {
    final p = indexed[i];
    final q = indexed[(i + 1) % 4];
    signedArea2 += p.x * q.y - q.x * p.y;
  }
  if (signedArea2 < 0) {
    final tmp = indexed[1];
    indexed[1] = indexed[3];
    indexed[3] = tmp;
  }
  var bestIdx = 0;
  var bestSum = double.infinity;
  for (var i = 0; i < 4; i++) {
    final s = indexed[i].x + indexed[i].y;
    if (s < bestSum) {
      bestSum = s;
      bestIdx = i;
    }
  }
  return [for (var i = 0; i < 4; i++) indexed[(bestIdx + i) % 4]];
}

List<(List<double>, double)> _extractStage1Proposals(
  Float32List dense,
  Float32List scProb,
  AiFrozenThresholds t,
) {
  const grid = 40;
  const plane = grid * grid;
  final proposals = <(List<double>, double)>[];

  double at(int ch, int y, int x) => dense[ch * plane + y * grid + x];

  // 1. Center local maxima
  for (var gy = 0; gy < grid; gy++) {
    for (var gx = 0; gx < grid; gx++) {
      final val = at(0, gy, gx);
      if (val < t.centerPeakThresh) continue;
      final y0 = math.max(0, gy - 1), y1 = math.min(grid, gy + 2);
      final x0 = math.max(0, gx - 1), x1 = math.min(grid, gx + 2);
      var maxN = -1.0;
      for (var ny = y0; ny < y1; ny++) {
        for (var nx = x0; nx < x1; nx++) {
          final v = at(0, ny, nx);
          if (v > maxN) maxN = v;
        }
      }
      if (val < maxN) continue;

      var bx0 = 0.0, by0 = 0.0, bx1 = 0.0, by1 = 0.0, wSum = 0.0;
      for (var ny = y0; ny < y1; ny++) {
        for (var nx = x0; nx < x1; nx++) {
          final w = at(0, ny, nx) * math.max(0.15, at(1, ny, nx));
          final cxN = (nx + 0.5) / grid;
          final cyN = (ny + 0.5) / grid;
          bx0 += w * (cxN + at(3, ny, nx));
          by0 += w * (cyN + at(4, ny, nx));
          bx1 += w * (cxN + at(5, ny, nx));
          by1 += w * (cyN + at(6, ny, nx));
          wSum += w;
        }
      }
      if (wSum > 0) {
        final xMin = (bx0 / wSum).clamp(0.0, 1.0);
        final yMin = (by0 / wSum).clamp(0.0, 1.0);
        final xMax = (bx1 / wSum).clamp(0.0, 1.0);
        final yMax = (by1 / wSum).clamp(0.0, 1.0);
        if (xMax - xMin > 0.05 && yMax - yMin > 0.05) {
          proposals.add(([xMin, yMin, xMax, yMax], val));
        }
      }
    }
  }

  // 2. 8-connected components on shrunk mask
  final visited = Uint8List(plane);
  for (var gy = 0; gy < grid; gy++) {
    for (var gx = 0; gx < grid; gx++) {
      final idx0 = gy * grid + gx;
      if (visited[idx0] != 0 || at(1, gy, gx) < t.shrunkMaskThresh) continue;
      final stack = <(int, int)>[(gx, gy)];
      visited[idx0] = 1;
      final cells = <(int, int)>[];
      while (stack.isNotEmpty) {
        final (cxI, cyI) = stack.removeLast();
        cells.add((cxI, cyI));
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            final nx = cxI + dx, ny = cyI + dy;
            if (nx >= 0 && nx < grid && ny >= 0 && ny < grid) {
              final nIdx = ny * grid + nx;
              if (visited[nIdx] == 0 && at(1, ny, nx) >= t.shrunkMaskThresh) {
                visited[nIdx] = 1;
                stack.add((nx, ny));
              }
            }
          }
        }
      }
      if (cells.length < 2) continue;

      var bx0 = 0.0, by0 = 0.0, bx1 = 0.0, by1 = 0.0, wSum = 0.0, maxS = 0.0;
      var minCx = grid, maxCx = 0, minCy = grid, maxCy = 0;
      for (final (nx, ny) in cells) {
        if (nx < minCx) minCx = nx;
        if (nx > maxCx) maxCx = nx;
        if (ny < minCy) minCy = ny;
        if (ny > maxCy) maxCy = ny;
        final sVal = at(1, ny, nx);
        final cVal = at(0, ny, nx);
        final w = sVal * (0.4 + 0.6 * cVal);
        maxS = math.max(maxS, 0.5 * (sVal + cVal));
        final cxN = (nx + 0.5) / grid;
        final cyN = (ny + 0.5) / grid;
        bx0 += w * (cxN + at(3, ny, nx));
        by0 += w * (cyN + at(4, ny, nx));
        bx1 += w * (cxN + at(5, ny, nx));
        by1 += w * (cyN + at(6, ny, nx));
        wSum += w;
      }
      if (wSum > 0) {
        final ccCx = (minCx + maxCx + 1.0) * 0.5 / grid;
        final ccCy = (minCy + maxCy + 1.0) * 0.5 / grid;
        final ccHw = ((maxCx - minCx + 1.0) * 0.5 / grid) / 0.60;
        final ccHh = ((maxCy - minCy + 1.0) * 0.5 / grid) / 0.60;
        final xMin = (0.65 * (bx0 / wSum) + 0.35 * (ccCx - ccHw)).clamp(
          0.0,
          1.0,
        );
        final yMin = (0.65 * (by0 / wSum) + 0.35 * (ccCy - ccHh)).clamp(
          0.0,
          1.0,
        );
        final xMax = (0.65 * (bx1 / wSum) + 0.35 * (ccCx + ccHw)).clamp(
          0.0,
          1.0,
        );
        final yMax = (0.65 * (by1 / wSum) + 0.35 * (ccCy + ccHh)).clamp(
          0.0,
          1.0,
        );
        if (xMax - xMin > 0.05 && yMax - yMin > 0.05) {
          proposals.add(([xMin, yMin, xMax, yMax], maxS));
        }
      }
    }
  }

  double boxIou(List<double> a, List<double> b) {
    final ix0 = math.max(a[0], b[0]), iy0 = math.max(a[1], b[1]);
    final ix1 = math.min(a[2], b[2]), iy1 = math.min(a[3], b[3]);
    final inter = math.max(0.0, ix1 - ix0) * math.max(0.0, iy1 - iy0);
    if (inter <= 0.0) return 0.0;
    final ua =
        (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter;
    return inter / math.max(ua, 1e-9);
  }

  proposals.sort((a, b) => b.$2.compareTo(a.$2));
  final kept = <(List<double>, double)>[];
  for (final item in proposals) {
    if (kept.any((k) => boxIou(item.$1, k.$1) > 0.50)) continue;
    kept.add(item);
    if (kept.length >= 6) break;
  }

  if (kept.isEmpty && scProb[0] >= t.sceneProbFloor * 0.4) {
    kept.add(([0.0, 0.0, 1.0, 1.0], scProb[0]));
  } else if (kept.length == 1 && scProb[1] < 0.40) {
    kept.add(([0.0, 0.0, 1.0, 1.0], scProb[0] * 0.85));
  }
  return kept;
}

(double, double) _subpixelAtCell(
  Float32List unionHm,
  Float32List cornerOffsets,
  int px,
  int py,
) {
  const grid = 64;
  const plane = grid * grid;
  final peakVal = unionHm[py * grid + px];
  final thresh = math.max(0.05, peakVal * 0.35);
  var xSum = 0.0, ySum = 0.0, wSum = 0.0;
  for (var dy = -2; dy <= 2; dy++) {
    for (var dx = -2; dx <= 2; dx++) {
      final nx = px + dx, ny = py + dy;
      if (nx >= 0 && nx < grid && ny >= 0 && ny < grid) {
        final v = unionHm[ny * grid + nx];
        if (v >= thresh) {
          final w = v * v;
          xSum += w * nx;
          ySum += w * ny;
          wSum += w;
        }
      }
    }
  }
  final subX = wSum > 1e-8 ? (xSum / wSum) : px.toDouble();
  final subY = wSum > 1e-8 ? (ySum / wSum) : py.toDouble();
  final offX = cornerOffsets[py * grid + px];
  final offY = cornerOffsets[plane + py * grid + px];
  final u = ((0.55 * (px + 0.5 + offX) + 0.45 * (subX + 0.5)) / grid).clamp(
    0.0,
    1.0,
  );
  final v = ((0.55 * (py + 0.5 + offY) + 0.45 * (subY + 0.5)) / grid).clamp(
    0.0,
    1.0,
  );
  return (u, v);
}

List<double> _edgeSupportForQuad(Float32List edgeMap, List<Point2> cornersRoi) {
  const grid = 64;
  const nSamples = 24;
  final supports = <double>[];
  for (var sIdx = 0; sIdx < 4; sIdx++) {
    final p1 = cornersRoi[sIdx];
    final p2 = cornersRoi[(sIdx + 1) % 4];
    final x1 = p1.x * (grid - 1), y1 = p1.y * (grid - 1);
    final x2 = p2.x * (grid - 1), y2 = p2.y * (grid - 1);
    var acc = 0.0;
    for (var k = 1; k < nSamples - 1; k++) {
      final t = k / (nSamples - 1);
      final sx = (x1 + (x2 - x1) * t).round();
      final sy = (y1 + (y2 - y1) * t).round();
      final r0 = math.max(0, sy - 1), r1 = math.min(grid, sy + 2);
      final c0 = math.max(0, sx - 1), c1 = math.min(grid, sx + 2);
      var best = 0.0;
      for (var ry = r0; ry < r1; ry++) {
        for (var rx = c0; rx < c1; rx++) {
          final v = edgeMap[ry * grid + rx];
          if (v > best) best = v;
        }
      }
      acc += best;
    }
    supports.add(acc / (nSamples - 2));
  }
  return supports;
}

/// Exact 1-to-1 geometric scorer matching `assess_quad_domain` in
/// `tool/ai/inference_pipeline.py` (calibrated against `MODEL_MANIFEST.json`).
/// Note: downstream `verifyBoundary` in `lib/domain/boundary_decision.dart`
/// independently runs the domain `assessQuad` check before authorizing any crop.
(bool, double, double) _assessAiModelQuad(
  List<Point2> corners,
  int sourceW,
  int sourceH, {
  double minAreaFraction = 0.015,
  double maxAspectRatio = 7.0,
}) {
  if (corners.length != 4 || sourceW <= 0 || sourceH <= 0) {
    return (false, 0.0, 0.0);
  }
  for (final c in corners) {
    if (!c.x.isFinite ||
        !c.y.isFinite ||
        c.x < -1e-6 ||
        c.x > 1.0 + 1e-6 ||
        c.y < -1e-6 ||
        c.y > 1.0 + 1e-6) {
      return (false, 0.0, 0.0);
    }
  }
  final sx = math.max(1, sourceW - 1).toDouble();
  final sy = math.max(1, sourceH - 1).toDouble();
  final px = [for (final c in corners) (c.x * sx, c.y * sy)];

  double dist((double, double) a, (double, double) b) {
    final dx = b.$1 - a.$1, dy = b.$2 - a.$2;
    return math.sqrt(dx * dx + dy * dy);
  }

  final sides = [for (var i = 0; i < 4; i++) dist(px[i], px[(i + 1) % 4])];
  if (sides.any((s) => s < 1e-3) ||
      dist(px[0], px[2]) < 1e-3 ||
      dist(px[1], px[3]) < 1e-3) {
    return (false, 0.0, 0.0);
  }

  bool segInter(
    (double, double) a,
    (double, double) b,
    (double, double) c,
    (double, double) d,
  ) {
    double cross((double, double) o, (double, double) p, (double, double) q) =>
        (p.$1 - o.$1) * (q.$2 - o.$2) - (p.$2 - o.$2) * (q.$1 - o.$1);
    final d1 = cross(a, b, c), d2 = cross(a, b, d);
    final d3 = cross(c, d, a), d4 = cross(c, d, b);
    return (d1 * d2 < 0) && (d3 * d4 < 0);
  }

  if (segInter(px[0], px[1], px[2], px[3]) ||
      segInter(px[1], px[2], px[3], px[0])) {
    return (false, 0.0, 0.0);
  }

  var posCross = true;
  var negCross = true;
  var minAngleDeg = 180.0;
  var maxAngleDeg = 0.0;
  for (var i = 0; i < 4; i++) {
    final prevP = px[(i + 3) % 4];
    final currP = px[i];
    final nextP = px[(i + 1) % 4];
    final v1x = currP.$1 - prevP.$1, v1y = currP.$2 - prevP.$2;
    final v2x = nextP.$1 - currP.$1, v2y = nextP.$2 - currP.$2;
    final cr = v1x * v2y - v1y * v2x;
    if (cr <= 0) posCross = false;
    if (cr >= 0) negCross = false;
    final u1x = prevP.$1 - currP.$1, u1y = prevP.$2 - currP.$2;
    final u2x = nextP.$1 - currP.$1, u2y = nextP.$2 - currP.$2;
    final denom = math.max(
      1e-9,
      math.sqrt(u1x * u1x + u1y * u1y) * math.sqrt(u2x * u2x + u2y * u2y),
    );
    final cosA = ((u1x * u2x + u1y * u2y) / denom).clamp(-1.0, 1.0);
    final ang = math.acos(cosA) * 180.0 / math.pi;
    if (ang < minAngleDeg) minAngleDeg = ang;
    if (ang > maxAngleDeg) maxAngleDeg = ang;
  }
  if (!posCross && !negCross) {
    return (false, 0.0, 0.0);
  }

  var twiceArea = 0.0;
  for (var i = 0; i < 4; i++) {
    final a = px[i], b = px[(i + 1) % 4];
    twiceArea += a.$1 * b.$2 - b.$1 * a.$2;
  }
  final areaPx = 0.5 * twiceArea.abs();
  final frameArea = math.max(1.0, sx * sy);
  final areaFrac = areaPx / frameArea;
  if (areaFrac < minAreaFraction) {
    return (false, areaFrac, 0.0);
  }

  final meanW = 0.5 * (sides[0] + sides[2]);
  final meanH = 0.5 * (sides[1] + sides[3]);
  final aspect =
      math.max(meanW, meanH) / math.max(1e-6, math.min(meanW, meanH));
  if (aspect > maxAspectRatio) {
    return (false, areaFrac, 0.0);
  }

  final oppTb =
      math.max(sides[0], sides[2]) /
      math.max(1e-6, math.min(sides[0], sides[2]));
  final oppLr =
      math.max(sides[1], sides[3]) /
      math.max(1e-6, math.min(sides[1], sides[3]));
  final maxOpp = math.max(oppTb, oppLr);
  if (maxOpp > 3.2 || minAngleDeg < 24.0 || maxAngleDeg > 162.0) {
    return (false, areaFrac, 0.0);
  }

  final taperScore = (1.0 - (maxOpp - 1.0) / 2.2).clamp(0.0, 1.0);
  final angleScore = ((minAngleDeg - 24.0) / 50.0).clamp(0.0, 1.0);
  final geomConf = 0.55 * taperScore + 0.45 * angleScore;
  return (true, areaFrac, geomConf);
}

(List<Point2>, List<double>, List<double>, List<double>) _decodeStage2Roi(
  Float32List cornerHeatmaps,
  Float32List cornerOffsets,
  Float32List roiQuality,
  double rx0,
  double ry0,
  double rx1,
  double ry1,
) {
  const grid = 64;
  const plane = grid * grid;
  final unionHm = Float32List(plane);
  for (var i = 0; i < plane; i++) {
    var m = 0.0;
    for (var c = 0; c < 5; c++) {
      final v = cornerHeatmaps[c * plane + i];
      if (v > m) m = v;
    }
    unionHm[i] = m;
  }
  final edgeMap = Float32List.sublistView(cornerHeatmaps, 5 * plane, 6 * plane);
  final isFullRoi = (rx1 - rx0) >= 0.95 && (ry1 - ry0) >= 0.95;
  final minRoiArea = isFullRoi ? 0.015 : 0.14;

  double? scoreRoiCandidate(List<Point2> qC, List<double> pC, List<double> eC) {
    final (ok, areaC, geomC) = _assessAiModelQuad(
      qC,
      256,
      256,
      minAreaFraction: minRoiArea,
    );
    if (!ok) return null;
    final areaBonus = isFullRoi ? 0.0 : 0.45 * math.min(1.0, areaC / 0.38);
    final minP = pC.reduce(math.min);
    final meanP = (pC[0] + pC[1] + pC[2] + pC[3]) * 0.25;
    final minE = eC.reduce(math.min);
    final meanE = (eC[0] + eC[1] + eC[2] + eC[3]) * 0.25;
    return 0.85 * minP +
        0.45 * meanP +
        0.75 * minE +
        0.65 * meanE +
        0.25 * geomC +
        areaBonus;
  }

  final candidatesRoi = <(double, List<Point2>, List<double>, List<double>)>[];

  // Candidate A: Greedy distinct-cell assignment across ordered channels 0..3
  final rawPtsA = <Point2>[];
  final peaksA = <double>[];
  final chosenCells = <(int, int)>[];
  for (var cIdx = 0; cIdx < 4; cIdx++) {
    final hmC = Float32List.fromList(
      Float32List.sublistView(cornerHeatmaps, cIdx * plane, (cIdx + 1) * plane),
    );
    for (final (ox, oy) in chosenCells) {
      final y0 = math.max(0, oy - 4), y1 = math.min(grid, oy + 5);
      final x0 = math.max(0, ox - 4), x1 = math.min(grid, ox + 5);
      for (var yy = y0; yy < y1; yy++) {
        for (var xx = x0; xx < x1; xx++) {
          hmC[yy * grid + xx] = -1.0;
        }
      }
    }
    var bestIdx = 0;
    var bestVal = -2.0;
    for (var i = 0; i < plane; i++) {
      if (hmC[i] > bestVal) {
        bestVal = hmC[i];
        bestIdx = i;
      }
    }
    final py = bestIdx ~/ grid;
    final px = bestIdx % grid;
    chosenCells.add((px, py));
    peaksA.add(
      math.max(cornerHeatmaps[cIdx * plane + bestIdx], unionHm[bestIdx] * 0.95),
    );
    final (u, v) = _subpixelAtCell(unionHm, cornerOffsets, px, py);
    rawPtsA.add(Point2(u, v));
  }
  final quadA = canonicalizeQuadClockwiseTl(rawPtsA);
  final edgesA = _edgeSupportForQuad(edgeMap, quadA);
  final scA = scoreRoiCandidate(quadA, peaksA, edgesA);
  if (scA != null) {
    candidatesRoi.add((scA, quadA, peaksA, edgesA));
  }

  // Candidate B: Top-8 distinct local maxima on unionHm
  final localPeaks = <(double, int, int)>[];
  for (var py = 0; py < grid; py++) {
    for (var px = 0; px < grid; px++) {
      final val = unionHm[py * grid + px];
      if (val < 0.14) continue;
      final y0 = math.max(0, py - 2), y1 = math.min(grid, py + 3);
      final x0 = math.max(0, px - 2), x1 = math.min(grid, px + 3);
      var maxN = -1.0;
      for (var ny = y0; ny < y1; ny++) {
        for (var nx = x0; nx < x1; nx++) {
          final v = unionHm[ny * grid + nx];
          if (v > maxN) maxN = v;
        }
      }
      if (val >= maxN) {
        localPeaks.add((val, px, py));
      }
    }
  }
  localPeaks.sort((a, b) => b.$1.compareTo(a.$1));
  final distinctPeaks = <(double, int, int)>[];
  for (final item in localPeaks) {
    final (_, px, py) = item;
    if (distinctPeaks.any(
      (o) => (px - o.$2) * (px - o.$2) + (py - o.$3) * (py - o.$3) < 25,
    )) {
      continue;
    }
    distinctPeaks.add(item);
    if (distinctPeaks.length >= 8) break;
  }

  if (distinctPeaks.length >= 4) {
    final ptsSub = [
      for (final (val, px, py) in distinctPeaks)
        (() {
          final (u, v) = _subpixelAtCell(unionHm, cornerOffsets, px, py);
          return (Point2(u, v), val);
        })(),
    ];
    final m = ptsSub.length;
    for (var i = 0; i < m - 3; i++) {
      for (var j = i + 1; j < m - 2; j++) {
        for (var k = j + 1; k < m - 1; k++) {
          for (var l = k + 1; l < m; l++) {
            final qCand = canonicalizeQuadClockwiseTl([
              ptsSub[i].$1,
              ptsSub[j].$1,
              ptsSub[k].$1,
              ptsSub[l].$1,
            ]);
            final pCand = [
              ptsSub[i].$2,
              ptsSub[j].$2,
              ptsSub[k].$2,
              ptsSub[l].$2,
            ];
            final eCand = _edgeSupportForQuad(edgeMap, qCand);
            final scB = scoreRoiCandidate(qCand, pCand, eCand);
            if (scB != null) {
              candidatesRoi.add((scB, qCand, pCand, eCand));
            }
          }
        }
      }
    }
  }

  List<Point2> bestQuad;
  List<double> bestPeaks;
  List<double> bestEdges;
  if (candidatesRoi.isNotEmpty) {
    candidatesRoi.sort((a, b) => b.$1.compareTo(a.$1));
    bestQuad = candidatesRoi.first.$2;
    bestPeaks = candidatesRoi.first.$3;
    bestEdges = candidatesRoi.first.$4;
  } else {
    bestQuad = quadA;
    bestPeaks = peaksA;
    bestEdges = edgesA;
  }

  final mapped = canonicalizeQuadClockwiseTl([
    for (final p in bestQuad)
      Point2(
        (rx0 + p.x * (rx1 - rx0)).clamp(0.0, 1.0),
        (ry0 + p.y * (ry1 - ry0)).clamp(0.0, 1.0),
      ),
  ]);
  return (
    mapped,
    bestPeaks,
    bestEdges,
    [roiQuality[0], roiQuality[1], roiQuality[2]],
  );
}

List<Point2> _refineQuadEdgesLocally(
  Uint8List rgb,
  int w,
  int h,
  List<Point2> quadNorm, {
  double maxShiftNorm = 0.014,
}) {
  if (math.min(w, h) < 80) return quadNorm;
  final luma = Float32List(w * h);
  for (var i = 0; i < w * h; i++) {
    final k = i * 3;
    luma[i] = 0.299 * rgb[k] + 0.587 * rgb[k + 1] + 0.114 * rgb[k + 2];
  }

  final sxScale = w - 1.0;
  final syScale = h - 1.0;
  final ptsPx = [for (final p in quadNorm) (p.x * sxScale, p.y * syScale)];
  final maxR = math.max(
    2,
    math.min(14, (math.min(w, h) * maxShiftNorm).round()),
  );
  final profileLen = 2 * maxR + 1;

  final refinedLines = <(double, double, double, double)>[];
  for (var i = 0; i < 4; i++) {
    final (x1, y1) = ptsPx[i];
    final (x2, y2) = ptsPx[(i + 1) % 4];
    final dx = x2 - x1;
    final dy = y2 - y1;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 16.0) return quadNorm;
    final tx = dx / len, ty = dy / len;
    final nx = -ty, ny = tx;

    const nStat = 20;
    final gradProfile = Float64List(profileLen);
    var validStat = 0;
    for (var s = 0; s < nStat; s++) {
      final t = 0.15 + 0.70 * (s / (nStat - 1));
      final bx = x1 + tx * (len * t);
      final by = y1 + ty * (len * t);
      final xsMin = bx - nx.abs() * maxR;
      final xsMax = bx + nx.abs() * maxR;
      final ysMin = by - ny.abs() * maxR;
      final ysMax = by + ny.abs() * maxR;
      if (xsMin < 1 || xsMax >= w - 2 || ysMin < 1 || ysMax >= h - 2) continue;

      final vals = Float64List(profileLen);
      for (var oi = 0; oi < profileLen; oi++) {
        final off = oi - maxR;
        final xi = (bx + nx * off).round();
        final yi = (by + ny * off).round();
        vals[oi] = luma[yi * w + xi];
      }
      for (var oi = 1; oi < profileLen - 1; oi++) {
        gradProfile[oi] += (vals[oi + 1] - vals[oi - 1]).abs();
      }
      validStat++;
    }

    if (validStat >= 10) {
      var bestIdx = 0;
      var bestGrad = -1.0;
      final sorted = <double>[];
      for (var oi = 0; oi < profileLen; oi++) {
        gradProfile[oi] /= validStat;
        sorted.add(gradProfile[oi]);
        if (gradProfile[oi] > bestGrad) {
          bestGrad = gradProfile[oi];
          bestIdx = oi;
        }
      }
      sorted.sort();
      final medianGrad = sorted[sorted.length ~/ 2];
      if (bestGrad >= 14.0 && bestGrad >= medianGrad * 1.85) {
        final shift = (bestIdx - maxR).toDouble();
        refinedLines.add((x1 + shift * nx, y1 + shift * ny, tx, ty));
      } else {
        refinedLines.add((x1, y1, tx, ty));
      }
    } else {
      refinedLines.add((x1, y1, tx, ty));
    }
  }

  final newNorm = <Point2>[];
  for (var i = 0; i < 4; i++) {
    final (px1, py1, dx1, dy1) = refinedLines[(i + 3) % 4];
    final (px2, py2, dx2, dy2) = refinedLines[i];
    final denom = dx1 * dy2 - dy1 * dx2;
    if (denom.abs() < 1e-6) return quadNorm;
    final diffX = px2 - px1, diffY = py2 - py1;
    final tVal = (diffX * dy2 - diffY * dx2) / denom;
    final ux = (px1 + dx1 * tVal) / sxScale;
    final uy = (py1 + dy1 * tVal) / syScale;
    if (!ux.isFinite ||
        !uy.isFinite ||
        ux < 0.0 ||
        ux > 1.0 ||
        uy < 0.0 ||
        uy > 1.0) {
      return quadNorm;
    }
    final moveDx = ux - quadNorm[i].x;
    final moveDy = uy - quadNorm[i].y;
    final move = math.sqrt(moveDx * moveDx + moveDy * moveDy);
    if (move > maxShiftNorm * 1.6) return quadNorm;
    newNorm.add(Point2(ux, uy));
  }

  final (ok, _, _) = _assessAiModelQuad(newNorm, w, h);
  if (!ok) return quadNorm;
  return canonicalizeQuadClockwiseTl(newNorm);
}

// Convex polygon clipping (Sutherland-Hodgman) for exact Polygon IoU NMS
double polygonSignedAreaAbs(List<Point2> poly) {
  if (poly.length < 3) return 0.0;
  var acc = 0.0;
  for (var i = 0; i < poly.length; i++) {
    final a = poly[i];
    final b = poly[(i + 1) % poly.length];
    acc += a.x * b.y - b.x * a.y;
  }
  return 0.5 * acc.abs();
}

List<Point2> clipConvexPolygon(List<Point2> subject, List<Point2> clipper) {
  if (subject.length < 3 || clipper.length < 3) return const [];
  var signed = 0.0;
  for (var i = 0; i < clipper.length; i++) {
    final a = clipper[i], b = clipper[(i + 1) % clipper.length];
    signed += a.x * b.y - b.x * a.y;
  }
  final sign = signed >= 0 ? 1.0 : -1.0;

  var out = List<Point2>.from(subject);
  for (var i = 0; i < clipper.length; i++) {
    final cp1 = clipper[i];
    final cp2 = clipper[(i + 1) % clipper.length];
    final inp = out;
    out = <Point2>[];
    if (inp.isEmpty) break;
    var s = inp.last;
    for (final e in inp) {
      final dE =
          sign *
          ((cp2.x - cp1.x) * (e.y - cp1.y) - (cp2.y - cp1.y) * (e.x - cp1.x));
      final dS =
          sign *
          ((cp2.x - cp1.x) * (s.y - cp1.y) - (cp2.y - cp1.y) * (s.x - cp1.x));
      if (dE >= -1e-9) {
        if (dS < -1e-9) {
          final denom = dS - dE;
          final t = denom.abs() > 1e-12 ? dS / denom : 0.0;
          out.add(Point2(s.x + t * (e.x - s.x), s.y + t * (e.y - s.y)));
        }
        out.add(e);
      } else if (dS >= -1e-9) {
        final denom = dS - dE;
        final t = denom.abs() > 1e-12 ? dS / denom : 0.0;
        out.add(Point2(s.x + t * (e.x - s.x), s.y + t * (e.y - s.y)));
      }
      s = e;
    }
  }
  return out;
}

double convexPolygonIou(List<Point2> a, List<Point2> b) {
  final inter = polygonSignedAreaAbs(clipConvexPolygon(a, b));
  if (inter <= 0.0) return 0.0;
  final ua = polygonSignedAreaAbs(a) + polygonSignedAreaAbs(b) - inter;
  return ua > 1e-9 ? inter / ua : 0.0;
}
