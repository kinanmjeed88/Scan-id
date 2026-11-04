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
import 'ocr_model_assets.dart';

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
}

/// ONNX Runtime implementation, created lazily on first use.
class OrtPpocrRuntime implements PpocrRuntime {
  OrtPpocrRuntime({OnnxRuntime? runtime}) : _runtime = runtime ?? OnnxRuntime();

  final OnnxRuntime _runtime;
  Future<OrtSession>? _detection;
  Future<OrtSession>? _recognition;

  Future<OrtSession> _detectionSession() => _detection ??=
      _runtime.createSessionFromAsset(
        ocrDetectionAssetPath,
        options: OrtSessionOptions(intraOpNumThreads: 2),
      );

  Future<OrtSession> _recognitionSession() => _recognition ??=
      _runtime.createSessionFromAsset(
        ocrRecognizerAssetPath,
        options: OrtSessionOptions(intraOpNumThreads: 2),
      );

  @override
  Future<OcrDetOutput> runDetection(OcrDetInput input) async {
    final session = await _detectionSession();
    final values = await _run(
      session,
      input.values,
      [1, 3, input.height, input.width],
      expectRank: 4,
    );
    final shape = values.shape;
    return OcrDetOutput(
      values: values.values,
      width: shape[3],
      height: shape[2],
    );
  }

  @override
  Future<OcrRecOutput> runRecognition(OcrLineInput input) async {
    final session = await _recognitionSession();
    final values = await _run(
      session,
      input.values,
      [1, 3, input.height, input.width],
      expectRank: 3,
    );
    final shape = values.shape;
    return OcrRecOutput(
      values: values.values,
      timeSteps: shape[1],
      classes: shape[2],
    );
  }

  @override
  Future<void> close() async {
    final detection = _detection;
    final recognition = _recognition;
    _detection = null;
    _recognition = null;
    if (detection != null) await (await detection).close();
    if (recognition != null) await (await recognition).close();
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
      inputValue = await OrtValue.fromList(input, shape);
      outputs = await session.run({inputName: inputValue});
      final tensor = _expectedTensor(outputs, expectRank);
      final flat = await tensor.asFlattenedList();
      return (values: _toFloat32(flat), shape: tensor.shape);
    } finally {
      if (inputValue != null) await inputValue.dispose();
      if (outputs != null) {
        for (final output in outputs.values) {
          await output.dispose();
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
