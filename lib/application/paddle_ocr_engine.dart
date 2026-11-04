/// The production OCR engine: PP-OCRv5 mobile detection + Arabic recognition on
/// ONNX Runtime, fully on device (ADR-005, ADR-010).
///
/// Responsibilities, in the order they run:
///
/// 1. decode the isolated document crop the pipeline handed over, build the
///    detection tensor (planar BGR, long edge 960, 32-aligned);
/// 2. run the detection graph and turn its probability map into text-line
///    quads ([decodeTextBoxes]);
/// 3. cut each line with the bilinear sampler and run the recognition graph
///    (48 px high, planar BGR, aspect-preserving width);
/// 4. greedy-CTC decode with the exported Arabic dictionary and report each
///    line with its mean character confidence and its normalised bounds.
///
/// Safety properties this class owns:
///
/// * **bounded work** — at most [defaultMaxLines] lines and [timeBudget] per
///   call, so one dense page cannot monopolise the phone;
/// * **no fabrication** — an empty or failed run never invents text or a
///   confidence, it returns an explicit unavailable/empty result;
/// * **no persistence** — recognised text lives in this call only; the pipeline
///   derives keyword evidence and drops it;
/// * **cooperative cancellation** — [OperationCancelled] is the only exception
///   that escapes; every engine failure is reported as an unavailable result
///   with a machine-safe reason.
///
/// Heavy pixel work runs in [Isolate.run] so the frame loop is never blocked by
/// the sampling; the ONNX calls themselves are already asynchronous.
library;

import 'dart:isolate';
import 'package:flutter/services.dart';

import '../domain/geometry.dart';
import '../domain/ocr_decoding.dart';
import '../domain/ocr_evidence.dart';
import '../domain/validation.dart';
import '../imaging/db_text_boxes.dart';
import '../imaging/ocr_tensor.dart';
import '../imaging/prepare_image.dart';
import 'cancellation.dart';
import 'ocr_engine.dart';
import 'ocr_model_assets.dart';
import 'paddle_ocr_runtime.dart';
import 'stage_budget.dart';

/// Most text lines recognised per document. A card carries far fewer; the cap
/// bounds memory and time for a dense page or a misdetected region.
const int defaultMaxLines = 32;

/// Wall-clock budget for one document's OCR. Exceeding it returns the lines that
/// were already decoded instead of failing the whole analysis.
const Duration defaultOcrTimeBudget = Duration(seconds: 25);

/// Mean character probability below which a decoded line is discarded: a
/// low-confidence line is worse than no line, because it can anchor a wrong
/// document type.
const double defaultMinLineConfidence = .3;

PaddleOcrEngine createPlatformOcrEngine() => PaddleOcrEngine();

/// Decodes [imageBytes] and builds the detection tensor. Runs in an isolate.
OcrDetInput prepareOcrDetection(Uint8List imageBytes) =>
    buildOcrDetInput(decodeForProcessing(imageBytes));

/// Maps a detector probability map onto source pixels. Runs in an isolate.
List<TextLineBox> locateOcrLines({
  required OcrDetOutput map,
  required OcrDetInput detection,
}) {
  require(
    detection.width > 0 && detection.height > 0,
    'أبعاد مدخل كشف النص غير صالحة.',
  );
  final sourceWidth = detection.width * detection.scaleX;
  final sourceHeight = detection.height * detection.scaleY;
  return decodeTextBoxes(
    map.values,
    width: map.width,
    height: map.height,
    scaleX: sourceWidth / map.width,
    scaleY: sourceHeight / map.height,
  );
}

/// Builds one recognition tensor per text line. Runs in an isolate.
List<OcrLineInput> prepareOcrLineInputs(
  Uint8List imageBytes,
  List<List<Point2>> quads,
) {
  final image = decodeForProcessing(imageBytes);
  return [for (final quad in quads) buildOcrLineInput(image, quad)];
}

class PaddleOcrEngine implements OcrEngine {
  PaddleOcrEngine({
    PpocrRuntime? runtime,
    Future<String> Function(String assetKey)? dictionaryLoader,
    this.maxLines = defaultMaxLines,
    this.timeBudget = defaultOcrTimeBudget,
    this.minLineConfidence = defaultMinLineConfidence,
  }) : _runtime = runtime ?? OrtPpocrRuntime(),
       _loadDictionary = dictionaryLoader ?? _loadBundledDictionary;

  final PpocrRuntime _runtime;
  final Future<String> Function(String assetKey) _loadDictionary;

  /// Upper bound on text lines recognised per document.
  final int maxLines;

  /// Upper bound on wall-clock time spent on one document.
  final Duration timeBudget;

  /// Lines whose mean character probability is below this are dropped.
  final double minLineConfidence;

  Future<List<String>>? _alphabet;

  @override
  String get version => ocrEngineVersion;

  /// A local backend is configured: both graphs and the dictionary are bundled.
  /// Whether the files are actually present is only known when a session is
  /// created, and a missing file then reports an explicit unavailable result
  /// instead of silently claiming there was no text.
  @override
  bool get isEnabled => true;

  @override
  Future<OcrTextResult> recognize(
    Uint8List imageBytes, {
    CancellationToken? token,
  }) async {
    token?.throwIfCancelled();
    final stopwatch = Stopwatch()..start();
    // The budget covers EVERY native stage, not just the recognition loop. A
    // session that never answers used to leave this future pending forever,
    // which in the UI is an import dialog stuck at 0 / 1. Each native call is
    // therefore bounded by what is left of the budget and an expired stage is
    // reported as an explicit unavailable result.
    Duration remaining() {
      final left = timeBudget - stopwatch.elapsed;
      if (left < const Duration(seconds: 1)) return const Duration(seconds: 1);
      return left;
    }

    try {
      final detection = await Isolate.run(
        () => prepareOcrDetection(imageBytes),
      );
      token?.throwIfCancelled();
      final detectionOutcome = await runStageWithin(
        () => _runtime.runDetection(detection),
        budget: remaining(),
        name: 'ocr-detection',
        cancellation: token,
      );
      if (detectionOutcome.wasCancelled) throw const OperationCancelled();
      if (detectionOutcome.didTimeOut) {
        _runtime.abandonStalledSessions();
        return OcrTextResult.unavailable(
          unavailableReason: 'time-budget-exceeded',
          engineVersion: version,
        );
      }
      final detectionError = detectionOutcome.error;
      if (detectionError != null) {
        Error.throwWithStackTrace(detectionError, detectionOutcome.stackTrace!);
      }
      final map = detectionOutcome.value!;
      token?.throwIfCancelled();
      final located = await Isolate.run(
        () => locateOcrLines(map: map, detection: detection),
      );
      token?.throwIfCancelled();
      if (located.isEmpty) {
        return OcrTextResult.available(lines: const [], engineVersion: version);
      }
      final alphabetOutcome = await runStageWithin(
        _loadAlphabet,
        budget: remaining(),
        name: 'ocr-alphabet',
        cancellation: token,
      );
      if (alphabetOutcome.wasCancelled) throw const OperationCancelled();
      if (alphabetOutcome.didTimeOut) {
        return OcrTextResult.unavailable(
          unavailableReason: 'time-budget-exceeded',
          engineVersion: version,
        );
      }
      final alphabetError = alphabetOutcome.error;
      if (alphabetError != null) {
        Error.throwWithStackTrace(alphabetError, alphabetOutcome.stackTrace!);
      }
      final alphabet = alphabetOutcome.value!;
      token?.throwIfCancelled();
      final quads = [for (final box in located.take(maxLines)) box.corners];
      final inputs = await Isolate.run(
        () => prepareOcrLineInputs(imageBytes, quads),
      );
      final sourceWidth = detection.width * detection.scaleX;
      final sourceHeight = detection.height * detection.scaleY;
      final lines = <OcrLine>[];
      var budgetExhausted = false;
      for (var index = 0; index < inputs.length; index++) {
        token?.throwIfCancelled();
        if (stopwatch.elapsed > timeBudget) {
          budgetExhausted = true;
          break;
        }
        final recognitionOutcome = await runStageWithin(
          () => _runtime.runRecognition(inputs[index]),
          budget: remaining(),
          name: 'ocr-recognition',
          cancellation: token,
        );
        if (recognitionOutcome.wasCancelled) throw const OperationCancelled();
        if (recognitionOutcome.didTimeOut) {
          // Keep the lines already decoded: a partial transcript is honest
          // evidence, and the caller still learns the budget was hit.
          budgetExhausted = true;
          _runtime.abandonStalledSessions();
          break;
        }
        final recognitionError = recognitionOutcome.error;
        if (recognitionError != null) {
          Error.throwWithStackTrace(
            recognitionError,
            recognitionOutcome.stackTrace!,
          );
        }
        final output = recognitionOutcome.value!;
        final decoded = decodeCtcLine(
          values: output.values,
          timeSteps: output.timeSteps,
          classes: output.classes,
          alphabet: alphabet,
          minConfidence: minLineConfidence,
        );
        if (decoded.isEmpty || decoded.confidence < minLineConfidence) continue;
        lines.add(
          OcrLine(
            text: decoded.text,
            confidence: decoded.confidence.clamp(0.0, 1.0).toDouble(),
            bounds: [
              for (final corner in quads[index])
                Point2(
                  (corner.x / sourceWidth).clamp(0.0, 1.0).toDouble(),
                  (corner.y / sourceHeight).clamp(0.0, 1.0).toDouble(),
                ),
            ],
          ),
        );
      }
      if (lines.isEmpty && budgetExhausted) {
        return OcrTextResult.unavailable(
          unavailableReason: 'time-budget-exceeded',
          engineVersion: version,
        );
      }
      return OcrTextResult.available(
        lines: List.unmodifiable(lines),
        engineVersion: version,
      );
    } on OperationCancelled {
      rethrow;
    } on PlatformException {
      // A missing or unreadable model/session is an explicit unavailable state,
      // never an empty success: "no text found" and "could not look" must stay
      // distinguishable to the classifier and to the user.
      return OcrTextResult.unavailable(
        unavailableReason: 'model-unavailable',
        engineVersion: version,
      );
    } catch (_) {
      return OcrTextResult.unavailable(
        unavailableReason: 'engine-failure',
        engineVersion: version,
      );
    }
  }

  /// Releases the native sessions.
  Future<void> close() => _runtime.close();

  Future<List<String>> _loadAlphabet() => _alphabet ??= _readAlphabet();

  Future<List<String>> _readAlphabet() async {
    final source = await _loadDictionary(ocrDictionaryAssetPath);
    return buildOcrAlphabet(parseOcrDictionary(source));
  }

  static Future<String> _loadBundledDictionary(String assetKey) =>
      rootBundle.loadString(assetKey);
}
