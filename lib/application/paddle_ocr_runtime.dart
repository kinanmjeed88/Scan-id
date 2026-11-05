/// ONNX Runtime binding for the two PP-OCR graphs (ADR-010).
///
/// The runtime is separated from the engine so the engine's orchestration —
/// bounding work, cancellation, confidence handling and honest failure — can be
/// unit-tested without a native session, while the ONNX boundary here stays the
/// only place that knows tensor names or ONNX Runtime at all.
///
/// Neither graph is trusted to keep its I/O names: the input name is read from
/// the session and the output is chosen by rank and dtype, so an upstream
/// re-export that renames `x` cannot break the app silently.
library;

import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../imaging/ocr_tensor.dart';
import 'import_trace.dart';
import 'ocr_model_assets.dart';
import 'retirable_resource.dart';
import 'stage_budget.dart';

/// How long shutdown waits for a session that may still be in flight.
///
/// A native call that never answered must not hold `close()` open: whatever
/// arrives later is closed by then, and the caller keeps control.
const Duration defaultSessionCloseBudget = Duration(seconds: 5);

/// The two graphs, so a stalled stage releases only its own session.
enum PpocrGraph { detection, recognition }

/// Detection probability map returned by the detector graph.
class OcrDetOutput {
  const OcrDetOutput({
    required this.values,
    required this.width,
    required this.height,
  });

  /// Row-major probabilities, `width × height`.
  final Float32List values;
  final int width;
  final int height;
}

/// One recognition row returned by the recogniser graph.
class OcrRecOutput {
  const OcrRecOutput({
    required this.values,
    required this.timeSteps,
    required this.classes,
  });

  /// Row-major probabilities, `timeSteps × classes`.
  final Float32List values;
  final int timeSteps;
  final int classes;
}

/// The two inference calls the OCR engine needs.
abstract interface class PpocrRuntime {
  Future<OcrDetOutput> runDetection(OcrDetInput input);

  Future<OcrRecOutput> runRecognition(OcrLineInput input);

  Future<void> close();

  /// Drops the [graph] whose creation or inference never answered.
  ///
  /// A native call that fails inside the plugin's platform thread never replies,
  /// so the memoised future stays pending forever and every later attempt would
  /// await the same dead future. Abandoning it lets a retry start a fresh
  /// session. The detached session is closed only after all calls using it
  /// finish, including calls awaiting creation. If native code never returns,
  /// its session remains retained rather than being freed while still in use.
  /// The other graph is left alone.
  void abandonStalledSessions(PpocrGraph graph);
}

/// ONNX Runtime implementation, created lazily on first use.
class OrtPpocrRuntime implements PpocrRuntime {
  OrtPpocrRuntime({OnnxRuntime? runtime}) {
    final backend = runtime ?? OnnxRuntime();
    _detection = RetirableResource<OrtSession>(
      create: () => ImportTrace.stage(
        'native',
        () => backend.createSessionFromAsset(
          ocrDetectionAssetPath,
          options: OrtSessionOptions(intraOpNumThreads: 2),
        ),
        phase: 'ocr-detection-session',
      ),
      dispose: (session) => session.close(),
    );
    _recognition = RetirableResource<OrtSession>(
      create: () => ImportTrace.stage(
        'native',
        () => backend.createSessionFromAsset(
          ocrRecognizerAssetPath,
          options: OrtSessionOptions(intraOpNumThreads: 2),
        ),
        phase: 'ocr-recognition-session',
      ),
      dispose: (session) => session.close(),
    );
  }

  late final RetirableResource<OrtSession> _detection;
  late final RetirableResource<OrtSession> _recognition;

  @override
  Future<OcrDetOutput> runDetection(OcrDetInput input) => ImportTrace.stage(
    'native',
    () => _detection.run((session) async {
      final values = await _run(session, input.values, [
        1,
        3,
        input.height,
        input.width,
      ], expectRank: 4);
      final shape = values.shape;
      return OcrDetOutput(
        values: values.values,
        width: shape[3],
        height: shape[2],
      );
    }),
    phase: 'ocr-detection-operation',
  );

  @override
  Future<OcrRecOutput> runRecognition(OcrLineInput input) => ImportTrace.stage(
    'native',
    () => _recognition.run((session) async {
      final values = await _run(session, input.values, [
        1,
        3,
        input.height,
        input.width,
      ], expectRank: 3);
      final shape = values.shape;
      return OcrRecOutput(
        values: values.values,
        timeSteps: shape[1],
        classes: shape[2],
      );
    }),
    phase: 'ocr-recognition-operation',
  );

  @override
  Future<void> close() async {
    // Detach both before waiting, so neither can be closed while an inference
    // still uses it. Waiting is bounded even if native code never returns.
    final releases = Future.wait([_detection.retire(), _recognition.retire()]);
    await runStageWithin(
      () => releases,
      budget: defaultSessionCloseBudget,
      name: 'ocr-close',
    );
  }

  @override
  void abandonStalledSessions(PpocrGraph graph) {
    switch (graph) {
      case PpocrGraph.detection:
        _detection.retire();
      case PpocrGraph.recognition:
        _recognition.retire();
    }
  }

  /// Runs one graph and returns its single expected float output.
  Future<({Float32List values, List<int> shape})> _run(
    OrtSession session,
    Float32List input,
    List<int> shape, {
    required int expectRank,
  }) async {
    final inputName = session.inputNames.isEmpty ? 'x' : session.inputNames[0];
    OrtValue? inputValue;
    Map<String, OrtValue>? outputs;
    try {
      inputValue = await ImportTrace.stage(
        'native',
        () => OrtValue.fromList(input, shape),
        phase: 'tensor-create',
      );
      final inferenceOutputs = await ImportTrace.stage<Map<String, OrtValue>>(
        'native',
        () => session.run({inputName: inputValue!}),
        phase: 'ocr-inference',
      );
      outputs = inferenceOutputs;
      final tensor = _expectedTensor(inferenceOutputs, expectRank);
      final flat = await ImportTrace.stage(
        'native',
        tensor.asFlattenedList,
        phase: 'tensor-read',
      );
      return (values: _toFloat32(flat), shape: tensor.shape);
    } finally {
      if (inputValue != null) {
        await ImportTrace.stage(
          'native',
          () => inputValue!.dispose(),
          phase: 'tensor-release',
        );
      }
      if (outputs != null) {
        for (final output in outputs.values) {
          await ImportTrace.stage(
            'native',
            output.dispose,
            phase: 'tensor-release',
          );
        }
      }
    }
  }

  /// The graph's float output of [rank].
  ///
  /// Selection is by dtype and rank, never by name: the exports name their
  /// outputs `sigmoid_0.tmp_0` and `softmax_0.tmp_0`, and a re-export may not.
  OrtValue _expectedTensor(Map<String, OrtValue> outputs, int rank) {
    for (final output in outputs.values) {
      if (output.dataType != OrtDataType.float32) continue;
      if (output.shape.length != rank) continue;
      if (output.shape.any((dimension) => dimension <= 0)) continue;
      return output;
    }
    throw StateError('unexpected OCR graph output shape');
  }

  Float32List _toFloat32(List<Object?> values) {
    final result = Float32List(values.length);
    for (var index = 0; index < values.length; index++) {
      final value = values[index];
      if (value is num && value.isFinite) {
        result[index] = value.toDouble();
      }
    }
    return result;
  }
}
