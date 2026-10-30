import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

import '../application/cancellation.dart';
import '../domain/boundary_decision.dart';
import '../domain/geometry.dart';
import 'prepare_image.dart';

const docQuadAssetPath = 'assets/models/docquadnet256_trained_opset17.ort';

/// Small seam that allows the image editor to use a learned proposer while
/// keeping geometric validation, persistence and manual approval in the app.
abstract interface class BoundaryProposalModel {
  String get modelId;

  Future<BoundaryProposal?> suggestProposal(
    Uint8List preview, {
    CancellationToken? cancellation,
  });
}

/// On-device DocQuadNet-256 inference through ONNX Runtime.
///
/// The source image is already oriented and bounded by [LocalImageEditor]. This
/// class only preprocesses that preview, runs the bundled model, and returns a
/// normalized proposal. It never writes image pixels or authorizes a crop.
class DocQuadNet256 implements BoundaryProposalModel {
  DocQuadNet256({OnnxRuntime? runtime}) : _runtime = runtime ?? OnnxRuntime();

  static const inputWidth = 256;
  static const inputHeight = 256;
  static const heatmapWidth = 64;
  static const heatmapHeight = 64;
  static const _minimumReviewEvidence = 0.05;

  final OnnxRuntime _runtime;
  Future<OrtSession>? _sessionFuture;

  @override
  String get modelId => 'DocQuadNet-256/ORT-1.28';

  Future<OrtSession> _session() =>
      _sessionFuture ??= _runtime.createSessionFromAsset(
        docQuadAssetPath,
        options: OrtSessionOptions(intraOpNumThreads: 2),
      );

  @override
  Future<BoundaryProposal?> suggestProposal(
    Uint8List preview, {
    CancellationToken? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final oriented = decodeForProcessing(preview);
    if (oriented.width <= 0 || oriented.height <= 0) return null;
    final input = _letterbox(oriented);
    final session = await _session();
    cancellation?.throwIfCancelled();

    OrtValue? inputValue;
    Map<String, OrtValue>? outputs;
    try {
      inputValue = await OrtValue.fromList(input.values, [
        1,
        3,
        inputHeight,
        inputWidth,
      ]);
      cancellation?.throwIfCancelled();
      outputs = await session.run({'input': inputValue});
      cancellation?.throwIfCancelled();
      final heatmaps = outputs['corner_heatmaps'];
      final mask = outputs['mask_logits'];
      if (heatmaps == null || mask == null) return null;
      if (heatmaps.dataType != OrtDataType.float32 ||
          heatmaps.shape.length != 4 ||
          heatmaps.shape[0] != 1 ||
          heatmaps.shape[1] != 4 ||
          heatmaps.shape[2] != heatmapHeight ||
          heatmaps.shape[3] != heatmapWidth ||
          mask.dataType != OrtDataType.float32 ||
          mask.shape.length != 4 ||
          mask.shape[0] != 1 ||
          mask.shape[1] != 1 ||
          mask.shape[2] != heatmapHeight ||
          mask.shape[3] != heatmapWidth) {
        throw StateError('DocQuadNet-256 returned an unexpected tensor shape.');
      }

      final values = (await heatmaps.asFlattenedList()).cast<num>();
      final maskValues = (await mask.asFlattenedList()).cast<num>();
      if (values.length != 4 * heatmapWidth * heatmapHeight ||
          maskValues.length != heatmapWidth * heatmapHeight ||
          values.any((value) => !value.isFinite) ||
          maskValues.any((value) => !value.isFinite)) {
        throw StateError(
          'DocQuadNet-256 returned non-finite or incomplete data.',
        );
      }
      final peaks = _peaks(values);
      final evidence =
          _cornerMaskIou(peaks, maskValues) *
          peaks.fold<double>(
            1,
            (minimum, peak) =>
                minimum < peak.probability ? minimum : peak.probability,
          );
      if (!evidence.isFinite || evidence < _minimumReviewEvidence) return null;

      final corners = [
        for (final peak in peaks)
          Point2(
            ((peak.x256 - input.offsetX) / input.scale) / oriented.width,
            ((peak.y256 - input.offsetY) / input.scale) / oriented.height,
          ),
      ];
      final proposal = BoundaryProposal(
        producer: BoundaryProducer.learnedModel,
        corners: corners,
        modelConfidence: evidence,
        // The model has not been calibrated on a licensed Iraqi-card holdout.
        // Keep every result review-only; this threshold is intentionally
        // unreachable for a probability score and is not an accuracy claim.
        minAutoAcceptConfidence: 1.01,
      );
      final verified = verifyBoundary(
        proposal,
        sourceWidth: oriented.width,
        sourceHeight: oriented.height,
      );
      return verified.verification.hasUsableGeometry ? proposal : null;
    } finally {
      if (inputValue != null) await inputValue.dispose();
      if (outputs != null) {
        for (final value in outputs.values) {
          await value.dispose();
        }
      }
    }
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

  static _DocQuadInput _letterbox(img.Image source) {
    final scale = math
        .min(inputWidth / source.width, inputHeight / source.height)
        .toDouble();
    final scaledWidth = (source.width * scale)
        .round()
        .clamp(1, inputWidth)
        .toInt();
    final scaledHeight = (source.height * scale)
        .round()
        .clamp(1, inputHeight)
        .toInt();
    final offsetX = (inputWidth - source.width * scale) / 2;
    final offsetY = (inputHeight - source.height * scale) / 2;
    final left = ((inputWidth - scaledWidth) / 2).floor();
    final top = ((inputHeight - scaledHeight) / 2).floor();
    final resized = img.copyResize(
      source,
      width: scaledWidth,
      height: scaledHeight,
      interpolation: img.Interpolation.linear,
    );
    final hw = inputWidth * inputHeight;
    final chw = Float32List(3 * hw);
    for (var y = 0; y < scaledHeight; y++) {
      for (var x = 0; x < scaledWidth; x++) {
        final pixel = resized.getPixel(x, y);
        final index = (top + y) * inputWidth + left + x;
        chw[index] = pixel.r.toDouble() / 255;
        chw[hw + index] = pixel.g.toDouble() / 255;
        chw[2 * hw + index] = pixel.b.toDouble() / 255;
      }
    }
    return _DocQuadInput(chw, scale, offsetX, offsetY);
  }

  static List<_Peak> _peaks(List<num> heatmaps) => [
    for (var channel = 0; channel < 4; channel++) _peak(heatmaps, channel),
  ];

  static _Peak _peak(List<num> heatmaps, int channel) {
    final channelStart = channel * heatmapWidth * heatmapHeight;
    var bestIndex = 0;
    var bestLogit = double.negativeInfinity;
    for (var index = 0; index < heatmapWidth * heatmapHeight; index++) {
      final value = heatmaps[channelStart + index].toDouble();
      if (value > bestLogit) {
        bestLogit = value;
        bestIndex = index;
      }
    }
    final probability = bestLogit >= 0
        ? 1 / (1 + math.exp(-bestLogit))
        : math.exp(bestLogit) / (1 + math.exp(bestLogit));
    final x = bestIndex % heatmapWidth;
    final y = bestIndex ~/ heatmapWidth;
    return _Peak(
      x: x + .5,
      y: y + .5,
      x256: (x + .5) * 4,
      y256: (y + .5) * 4,
      probability: probability,
    );
  }

  static double _cornerMaskIou(List<_Peak> peaks, List<num> mask) {
    var intersection = 0;
    var union = 0;
    for (var y = 0; y < heatmapHeight; y++) {
      for (var x = 0; x < heatmapWidth; x++) {
        var inside = false;
        for (var i = 0; i < 4; i++) {
          final a = peaks[i];
          final b = peaks[(i + 1) % 4];
          if ((a.y > y + .5) != (b.y > y + .5) &&
              x + .5 < a.x + (y + .5 - a.y) * (b.x - a.x) / (b.y - a.y)) {
            inside = !inside;
          }
        }
        final inMask = mask[y * heatmapWidth + x].toDouble() > 0;
        if (inside && inMask) intersection++;
        if (inside || inMask) union++;
      }
    }
    return union == 0 ? 0 : intersection / union;
  }
}

class _DocQuadInput {
  const _DocQuadInput(this.values, this.scale, this.offsetX, this.offsetY);
  final Float32List values;
  final double scale;
  final double offsetX;
  final double offsetY;
}

class _Peak {
  const _Peak({
    required this.x,
    required this.y,
    required this.x256,
    required this.y256,
    required this.probability,
  });
  final double x;
  final double y;
  final double x256;
  final double y256;
  final double probability;
}
