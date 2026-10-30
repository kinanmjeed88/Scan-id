import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

import '../application/cancellation.dart';
import '../domain/boundary_decision.dart';
import '../domain/geometry.dart';
import 'docquad_model.dart';
import 'prepare_image.dart';

const docAlignerAssetPath =
    'assets/models/docaligner_fastvit_sa24_7f9f5a89.onnx';
const docAlignerExpectedSha256 =
    '7f9f5a8935b2eb22b3ee0245d34996063f54562df390d34714af2d76928695bc';
const docAlignerExpectedBytes = 83084930;

/// Local ONNX Runtime adapter for the upstream DocAligner 1.1.1 FastViT-SA24
/// heatmap model. The caller supplies an already-oriented, bounded preview.
/// This model only proposes normalized corners; it never crops or approves.
class DocAlignerFastViT implements BoundaryProposalModel {
  DocAlignerFastViT({OnnxRuntime? runtime})
    : _runtime = runtime ?? OnnxRuntime();

  static const inputWidth = 256;
  static const inputHeight = 256;
  static const _heatmapThreshold = 0.3;

  final OnnxRuntime _runtime;
  Future<OrtSession>? _sessionFuture;
  int inferenceRuns = 0;
  List<int>? lastOutputShape;

  @override
  String get modelId => 'docaligner-1.1.1-fastvit-sa24-7f9f5a89';

  Future<OrtSession> _session() =>
      _sessionFuture ??= _runtime.createSessionFromAsset(
        docAlignerAssetPath,
        options: OrtSessionOptions(intraOpNumThreads: 2),
      );

  /// Runs the released ONNX graph with its single discovered input/output name.
  /// The shape checks below are deliberately against the actual loaded graph,
  /// not a mock signature or an inferred filename convention.
  @override
  Future<BoundaryProposal?> suggestProposal(
    Uint8List preview, {
    CancellationToken? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final source = decodeForProcessing(preview);
    if (source.width <= 0 || source.height <= 0) return null;
    final input = prepareBgrInput(source);
    final session = await _session();
    cancellation?.throwIfCancelled();
    if (session.inputNames.length != 1 || session.outputNames.length != 1) {
      throw StateError(
        'DocAligner 1.1.1 must expose exactly one image input and one heatmap '
        'output; found ${session.inputNames.length} inputs and '
        '${session.outputNames.length} outputs.',
      );
    }

    OrtValue? inputValue;
    Map<String, OrtValue>? outputs;
    try {
      inputValue = await OrtValue.fromList(input, [
        1,
        3,
        inputHeight,
        inputWidth,
      ]);
      cancellation?.throwIfCancelled();
      outputs = await session.run({session.inputNames.single: inputValue});
      inferenceRuns++;
      cancellation?.throwIfCancelled();

      final heatmap = outputs[session.outputNames.single];
      if (heatmap == null || heatmap.dataType != OrtDataType.float32) {
        throw StateError('DocAligner returned no float32 heatmap tensor.');
      }
      final shape = heatmap.shape;
      if (shape.length != 4 ||
          shape[0] != 1 ||
          shape[1] != 4 ||
          shape[2] <= 0 ||
          shape[3] <= 0 ||
          shape[2] > 512 ||
          shape[3] > 512) {
        throw StateError(
          'DocAligner returned an unexpected heatmap shape: $shape',
        );
      }
      lastOutputShape = List.unmodifiable(shape);
      final values = (await heatmap.asFlattenedList()).cast<num>();
      final mapHeight = shape[2];
      final mapWidth = shape[3];
      if (values.length != 4 * mapHeight * mapWidth ||
          values.any((value) => !value.isFinite)) {
        throw StateError(
          'DocAligner returned incomplete or non-finite heatmaps.',
        );
      }
      cancellation?.throwIfCancelled();
      var minimumPeak = double.infinity;
      for (var channel = 0; channel < 4; channel++) {
        final start = channel * mapWidth * mapHeight;
        final end = start + mapWidth * mapHeight;
        for (var i = start; i < end; i++) {
          final value = values[i].toDouble();
          if (value < 0 || value > 1) {
            throw StateError(
              'DocAligner heatmap values must be probabilities in [0, 1].',
            );
          }
        }
        var peak = 0.0;
        for (var i = start; i < end; i++) {
          final value = values[i].toDouble();
          if (value > peak) peak = value;
        }
        if (peak < minimumPeak) minimumPeak = peak;
      }
      final points = postprocessHeatmaps(
        values,
        width: mapWidth,
        height: mapHeight,
      );
      if (points == null) return null;

      // Heatmap peaks are useful diagnostics but are not calibrated confidence.
      // Keep all model output review-only until an independently labelled
      // validation set establishes a defensible automatic-accept threshold.
      final proposal = BoundaryProposal(
        producer: BoundaryProducer.learnedModel,
        corners: points,
        modelConfidence: minimumPeak.clamp(0.0, 1.0).toDouble(),
        minAutoAcceptConfidence: 1.01,
      );
      final verification = verifyBoundary(
        proposal,
        sourceWidth: source.width,
        sourceHeight: source.height,
      );
      return verification.verification.hasUsableGeometry ? proposal : null;
    } finally {
      if (inputValue != null) await inputValue.dispose();
      if (outputs != null) {
        for (final value in outputs.values) {
          await value.dispose();
        }
      }
    }
  }

  /// Extracts one largest thresholded component centroid from each of the
  /// model's TL, TR, BR and BL heatmaps. Returned points are normalized in the
  /// uncropped source frame using the inverse heatmap-to-image scale.
  static List<Point2>? postprocessHeatmaps(
    List<num> values, {
    required int width,
    required int height,
  }) {
    if (width <= 0 ||
        height <= 0 ||
        width > 512 ||
        height > 512 ||
        values.length != 4 * width * height ||
        values.any((value) => !value.isFinite || value < 0 || value > 1)) {
      return null;
    }
    final points = <Point2>[];
    for (var channel = 0; channel < 4; channel++) {
      final centroid = _largestThresholdComponent(
        values,
        channelStart: channel * width * height,
        width: width,
        height: height,
      );
      if (centroid == null) return null;
      points.add(Point2(centroid.x / width, centroid.y / height));
    }
    return List.unmodifiable(points);
  }

  /// Upstream `preprocess`: direct 256×256 resize, HWC BGR → NCHW float32,
  /// and division by 255. Their README explicitly converts its RGB sample to
  /// BGR before inference; there is no mean/std normalization or letterboxing.
  static Float32List prepareBgrInput(img.Image source) {
    final resized = img.copyResize(
      source,
      width: inputWidth,
      height: inputHeight,
      interpolation: img.Interpolation.linear,
    );
    final planeSize = inputWidth * inputHeight;
    final nchw = Float32List(3 * planeSize);
    for (var y = 0; y < inputHeight; y++) {
      for (var x = 0; x < inputWidth; x++) {
        final pixel = resized.getPixel(x, y);
        final index = y * inputWidth + x;
        nchw[index] = pixel.b.toDouble() / 255;
        nchw[planeSize + index] = pixel.g.toDouble() / 255;
        nchw[2 * planeSize + index] = pixel.r.toDouble() / 255;
      }
    }
    return nchw;
  }

  /// Mirrors the upstream threshold=0.3 + largest-contour-centroid policy on
  /// each of its four heatmaps. Eight-connected components are used as the
  /// local contour-area approximation; points are returned in heatmap/source
  /// normalized coordinates and are still subject to the shared geometry gate.
  static Point2? _largestThresholdComponent(
    List<num> values, {
    required int channelStart,
    required int width,
    required int height,
  }) {
    final count = width * height;
    final visited = Uint8List(count);
    var bestArea = 0;
    var bestX = 0.0;
    var bestY = 0.0;
    final queue = List<int>.filled(count, 0);

    for (var start = 0; start < count; start++) {
      if (visited[start] != 0 ||
          values[channelStart + start].toDouble() < _heatmapThreshold) {
        continue;
      }
      var head = 0;
      var tail = 0;
      queue[tail++] = start;
      visited[start] = 1;
      var area = 0;
      var sumX = 0.0;
      var sumY = 0.0;
      while (head < tail) {
        final index = queue[head++];
        final x = index % width;
        final y = index ~/ width;
        area++;
        sumX += x + 0.5;
        sumY += y + 0.5;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            final nx = x + dx;
            final ny = y + dy;
            if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
            final next = ny * width + nx;
            if (visited[next] != 0 ||
                values[channelStart + next].toDouble() < _heatmapThreshold) {
              continue;
            }
            visited[next] = 1;
            queue[tail++] = next;
          }
        }
      }
      if (area > bestArea) {
        bestArea = area;
        bestX = sumX / area;
        bestY = sumY / area;
      }
    }
    if (bestArea == 0) return null;
    return Point2(bestX, bestY);
  }

  Future<void> close() async {
    final session = _sessionFuture;
    if (session == null) return;
    try {
      await (await session).close();
    } finally {
      _sessionFuture = null;
    }
  }
}
