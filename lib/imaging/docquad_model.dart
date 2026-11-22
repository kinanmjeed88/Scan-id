import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

import '../application/cancellation.dart';
import '../application/import_trace.dart';
import '../application/retirable_resource.dart';
import '../application/stage_budget.dart';
import '../domain/acceptance_policy.dart';
import '../domain/boundary_decision.dart';
import '../domain/frame_edge_band.dart';
import '../domain/geometry.dart';
import 'prepare_image.dart';

const docQuadAssetPath = 'assets/models/docquadnet256_trained_opset17.ort';

/// The id this model writes into every boundary trace. Named here so tests
/// and reports refer to the id production emits, not to a look-alike.
const docQuadNetModelId = 'DocQuadNet-256/ORT-1.28';

/// Maps DocQuadNet heatmap peaks back to source-normalized corners.
///
/// Coordinate contract, verified against the production call path:
///
/// * The frame is the image `_letterbox` was actually given. [frameWidth] and
///   [frameHeight] are `source.width`/`source.height` from the same decoded
///   image the letterbox was built from, so the two can never disagree.
/// * The bounded preview means this frame is already at most
///   `maxRecognitionPreviewLongEdge` on its long edge for every production
///   caller, so no second rescale is applied here. Adding one would shrink an
///   already-bounded frame again and move every corner away from where the
///   model placed it.
/// * `_Peak.x256`/`y256` are 4x the heatmap cell centre, so un-letterboxing
///   with `(x256 - offset) / scale` yields a pixel coordinate in the frame.
///   [frameWidth] is the pixel count, and the frame spans indices
///   `0 .. frameWidth - 1`; the fractional convention the rest of the app uses
///   is `index / (frameWidth - 1)` (see `assessQuad` and `warpPerspective`,
///   which multiply by `sourceWidth - 1`). Dividing by the pixel count instead
///   would make the normalized error `index / (frameWidth * (frameWidth - 1))`,
///   which is `index / frameWidth` pixels — under one pixel at the far edge,
///   but always inward, and always in the same direction for every corner.
///
/// Kept pure and top-level so the round trip can be asserted without a native
/// session: a plausible-looking rectangle in the wrong place passes every
/// downstream geometry gate, so only a coordinate test can catch it.
List<Point2> docQuadCorners(
  List<({double x256, double y256})> peaks, {
  required double scale,
  required double offsetX,
  required double offsetY,
  required int frameWidth,
  required int frameHeight,
  double? scaleY,
}) {
  // The two axes of the 256x256 tensor are independent: the resized copy is
  // placed at integer `left`/`top` with its own rounded width and height, so its
  // horizontal and vertical scales only coincide when the frame happened to land
  // on an exact ratio. Mapping both axes with one isotropic `scale` therefore
  // nudged every corner, by a different amount on each axis. [scaleY] carries
  // the vertical figure; omitting it keeps the single-scale behaviour.
  final scaleX = scale;
  final verticalScale = scaleY ?? scale;
  final spanX = math.max(1, frameWidth - 1).toDouble();
  final spanY = math.max(1, frameHeight - 1).toDouble();
  return [
    for (final peak in peaks)
      Point2(
        _snapToFrame(_axisFraction(peak.x256, offsetX, scaleX, spanX)),
        _snapToFrame(_axisFraction(peak.y256, offsetY, verticalScale, spanY)),
      ),
  ];
}

/// One axis of the back-mapping: tensor coordinate to a `0..1` frame fraction.
///
/// [scale] converts tensor pixels to source pixels; [span] converts source
/// pixels to a fraction of the frame. Both divisors are guarded here, in one
/// place, because a degenerate scale (a one-pixel resized axis) or a degenerate
/// span (a one-pixel-wide frame) would otherwise produce infinity or NaN that a
/// downstream gate could mistake for a deliberate out-of-frame corner.
double _axisFraction(
  double tensorCoordinate,
  double offset,
  double scale,
  double span,
) {
  final safeScale = scale.isFinite && scale > 0 ? scale : 1.0;
  final safeSpan = span.isFinite && span > 0 ? span : 1.0;
  final fraction = (tensorCoordinate - offset) / safeScale / safeSpan;
  return fraction.isFinite ? fraction : 0;
}

/// Absorbs floating-point overshoot at the frame edge, and nothing else.
///
/// Dividing by `frameWidth - 1` is the exact inverse of what `assessQuad` and
/// `warpPerspective` do, but it is not exact in binary: the last pixel of some
/// frames comes back as `1.0000000000000018`. `normalizedQuadIssue` rejects any
/// coordinate strictly greater than 1, so an un-snapped legitimate edge corner
/// would discard the whole proposal as out of bounds.
///
/// The tolerance is deliberately far smaller than one heatmap cell (which is
/// ~18 px on a 900 px frame), so a peak that really sits in the letterbox
/// padding — which is what a bogus detection looks like — still surfaces as
/// out of range and is still rejected downstream.
double _snapToFrame(double fraction) {
  const epsilon = 1e-9;
  if (fraction > 1 && fraction <= 1 + epsilon) return 1;
  if (fraction < 0 && fraction >= -epsilon) return 0;
  return fraction;
}

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
  late final _sessions = RetirableResource<OrtSession>(
    create: () => ImportTrace.stage(
      'native',
      () => _runtime.createSessionFromAsset(
        docQuadAssetPath,
        options: OrtSessionOptions(intraOpNumThreads: 2),
      ),
      phase: 'docquad-session',
    ),
    dispose: (session) => session.close(),
  );

  @override
  String get modelId => docQuadNetModelId;

  @override
  Future<BoundaryProposal?> suggestProposal(
    Uint8List preview, {
    CancellationToken? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final (sourceWidth, sourceHeight, input) = await ImportTrace.stage(
      'preprocessing',
      () => _prepareDocQuadIsolated(preview, cancellation),
      phase: 'docquad',
    );
    return ImportTrace.stage(
      'native',
      () => _sessions.run((session) async {
        cancellation?.throwIfCancelled();

        OrtValue? inputValue;
        Map<String, OrtValue>? outputs;
        try {
          inputValue = await ImportTrace.stage(
            'native',
            () => OrtValue.fromList(input.values, [
              1,
              3,
              inputHeight,
              inputWidth,
            ]),
            phase: 'tensor-create',
          );
          cancellation?.throwIfCancelled();
          final inferenceOutputs =
              await ImportTrace.stage<Map<String, OrtValue>>(
                'native',
                () => session.run({'input': inputValue!}),
                phase: 'docquad-inference',
              );
          outputs = inferenceOutputs;
          cancellation?.throwIfCancelled();
          final heatmaps = inferenceOutputs['corner_heatmaps'];
          final mask = inferenceOutputs['mask_logits'];
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
            throw StateError(
              'DocQuadNet-256 returned an unexpected tensor shape.',
            );
          }

          final values = (await ImportTrace.stage(
            'native',
            heatmaps.asFlattenedList,
            phase: 'tensor-read',
          )).cast<num>();
          final maskValues = (await ImportTrace.stage(
            'native',
            mask.asFlattenedList,
            phase: 'tensor-read',
          )).cast<num>();
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
          if (!evidence.isFinite || evidence < _minimumReviewEvidence) {
            return null;
          }

          final corners = docQuadCorners(
            [for (final peak in peaks) (x256: peak.x256, y256: peak.y256)],
            scale: input.scale,
            offsetX: input.offsetX,
            offsetY: input.offsetY,
            scaleY: input.scaleY,
            frameWidth: sourceWidth,
            frameHeight: sourceHeight,
          );
          final proposal = BoundaryProposal(
            producer: BoundaryProducer.learnedModel,
            corners: corners,
            modelConfidence: evidence,
            // A score of 55% is the requested routing threshold, not an
            // accuracy claim. Geometry and cascade agreement still apply.
            minAutoAcceptConfidence: automaticAcceptanceThreshold,
            // This model's corners are cell centres of a 64x64 map over a
            // 256px letterboxed input, so how close to a border a corner has to
            // be before the contact is real is a property of THIS model and
            // this frame, not a constant. Reporting it lets the edge gate
            // measure in the model's own resolution.
            edgeBand: FrameEdgeBand.quantisation(
              frameWidth: sourceWidth,
              frameHeight: sourceHeight,
              inputPixels: inputWidth.toDouble(),
              heatmapCells: heatmapWidth,
            ),
          );
          final verified = verifyBoundary(
            proposal,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
          );
          return verified.verification.hasUsableGeometry ? proposal : null;
        } finally {
          if (inputValue != null) {
            await ImportTrace.stage(
              'native',
              () => inputValue!.dispose(),
              phase: 'tensor-release',
            );
          }
          if (outputs != null) {
            for (final value in outputs.values) {
              await ImportTrace.stage(
                'native',
                value.dispose,
                phase: 'tensor-release',
              );
            }
          }
        }
      }),
      phase: 'docquad-operation',
    );
  }

  Future<void> close() async {
    await runStageWithin(
      _sessions.retire,
      budget: const Duration(seconds: 5),
      name: 'docquad-close',
    );
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
    // The copy goes at the IDEAL (fractional) position, not at a rounded one.
    //
    // This is what the previous code effectively did, and it is deliberate: the
    // back-mapping must be the exact inverse of the placement actually used. An
    // earlier revision of this change rounded the offset to `left`/`top` while
    // still WRITING at the ideal offset, so the recorded transform described a
    // placement the tensor did not have; on a 1200x275 frame every peak in the
    // bottom letterbox padding decoded to a fraction of 4.38 instead of >1, i.e.
    // a bogus detection became a plausible-looking corner instead of being
    // rejected as out of frame. Keeping the fractional offset makes the two
    // agree exactly, and `_snapToFrame` still keeps a genuine padding peak
    // outside `[0, 1]` so `assessQuad` can reject it.
    final offsetX = (inputWidth - scaledWidth) / 2;
    final offsetY = (inputHeight - scaledHeight) / 2;
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
        // `img` has no float bilinear paste, so each resized pixel is placed at
        // the nearest integer cell of its ideal position. The inverse below
        // models exactly this: the integer cell index minus the fractional
        // offset, so the two are consistent to within one tensor pixel.
        final index =
            (offsetY + y).round() * inputWidth + (offsetX + x).round();
        chw[index] = pixel.r.toDouble() / 255;
        chw[hw + index] = pixel.g.toDouble() / 255;
        chw[2 * hw + index] = pixel.b.toDouble() / 255;
      }
    }
    // Record the placement the tensor actually has.
    //
    // Two figures, each of which was wrong before:
    // * The OFFSET is the fractional one the loop above places the copy at.
    // * The SCALE is `(scaledExtent - 1) / (sourceExtent - 1)`, not the ideal
    //   resize factor, because `copyResize` aligns the two EXTENTS: source
    //   pixel 0 lands on the panel's first tensor row and source pixel
    //   `extent - 1` on its last. Using the ideal factor here, together with the
    //   ideal offset, is what put every corner up to 5.25 px away on a 1200x275
    //   frame — inward, with the same sign, so the quadrilateral stayed
    //   rectangular and no downstream gate could see it.
    return _DocQuadInput(
      chw,
      _axisScale(source.width, scaledWidth, scale),
      offsetX,
      offsetY,
      scaleY: _axisScale(source.height, scaledHeight, scale),
    );
  }

  /// Source pixels per tensor pixel on one axis, for a `copyResize` that aligns
  /// both endpoints. Falls back to the ideal resize factor for degenerate
  /// extents (a one-pixel axis), where no such alignment exists.
  static double _axisScale(
    int sourceExtent,
    int scaledExtent,
    double fallback,
  ) => sourceExtent > 1 && scaledExtent > 1
      ? (scaledExtent - 1) / (sourceExtent - 1)
      : fallback;

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

// Keep the isolate closure in a scope containing only transferable input, not
// the model instance or its native session manager.
Future<(int, int, _DocQuadInput)> _prepareDocQuadIsolated(
  Uint8List preview,
  CancellationToken? cancellation,
) => runCancellableIsolate(
  () {
    final source = decodeForProcessing(preview);
    return (source.width, source.height, DocQuadNet256._letterbox(source));
  },
  cancellation: cancellation,
  debugName: 'docquad-preprocess',
);

class _DocQuadInput {
  const _DocQuadInput(
    this.values,
    this.scale,
    this.offsetX,
    this.offsetY, {
    double? scaleY,
  }) : scaleY = scaleY ?? scale;

  final Float32List values;

  /// Horizontal source-pixels-per-tensor-pixel for the placement used.
  final double scale;

  /// Vertical source-pixels-per-tensor-pixel. Equal to [scale] only when both
  /// axes were resized by the same factor.
  final double scaleY;

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
