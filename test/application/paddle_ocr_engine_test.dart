import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/cancellation.dart';
import 'package:scan_id/application/paddle_ocr_engine.dart';
import 'package:scan_id/application/paddle_ocr_runtime.dart';
import 'package:scan_id/domain/ocr_decoding.dart';
import 'package:scan_id/imaging/ocr_tensor.dart';

const String _dictionaryAsset = 'assets/ocr/ppocrv5_arabic_dict.txt';

/// 120 Arabic code points, one per line: the shape of the shipped dictionary.
String _dictionary() {
  final characters = <String>[];
  for (var index = 0; index < 120; index++) {
    characters.add(String.fromCharCode(0x0627 + index % 20));
  }
  return characters.join('\n');
}

/// Alphabet = blank + 120 dictionary entries + space.
const int _classes = 122;

Uint8List _documentPng() {
  final image = img.Image(width: 40, height: 20, numChannels: 3);
  for (var y = 0; y < 20; y++) {
    for (var x = 0; x < 40; x++) {
      image.setPixelRgb(x, y, 255, 255, 255);
    }
  }
  return img.encodePng(image);
}

/// A probability map with [count] horizontal bands, in tensor coordinates.
OcrDetOutput _detectionWithBands(OcrDetInput input, int count) {
  final values = Float32List(input.width * input.height);
  for (var band = 0; band < count; band++) {
    final top = 30 + band * 60;
    for (var y = top; y < top + 24 && y < input.height; y++) {
      for (var x = 40; x < 400 && x < input.width; x++) {
        values[y * input.width + x] = .95;
      }
    }
  }
  return OcrDetOutput(values: values, width: input.width, height: input.height);
}

/// A recognition row whose best class is [index] at [probability].
OcrRecOutput _row(int index, {double probability = .95}) {
  final values = Float32List(4 * _classes);
  for (var step = 0; step < 4; step++) {
    values[step * _classes + index] = probability;
    if (index != 0) values[step * _classes] = 1 - probability;
  }
  return OcrRecOutput(values: values, timeSteps: 4, classes: _classes);
}

class _FakeRuntime implements PpocrRuntime {
  _FakeRuntime({this.detection, this.recognition});

  final OcrDetOutput Function(OcrDetInput input)? detection;
  final OcrRecOutput Function(int call)? recognition;
  final List<OcrLineInput> recognitionCalls = [];

  @override
  Future<OcrDetOutput> runDetection(OcrDetInput input) async {
    final handler = detection;
    if (handler == null) throw PlatformException(code: 'model-missing');
    return handler(input);
  }

  @override
  Future<OcrRecOutput> runRecognition(OcrLineInput input) async {
    recognitionCalls.add(input);
    final handler = recognition;
    if (handler == null) throw StateError('recognition graph failed');
    return handler(recognitionCalls.length - 1);
  }

  var abandoned = 0;

  @override
  void abandonStalledSessions() => abandoned++;

  @override
  Future<void> close() async {}
}

PaddleOcrEngine _engine(PpocrRuntime runtime, {int maxLines = 32}) {
  return PaddleOcrEngine(
    runtime: runtime,
    dictionaryLoader: (assetKey) async => _dictionary(),
    maxLines: maxLines,
  );
}

void main() {
  test('a detected line keeps text, bounds and confidence', () async {
    final runtime = _FakeRuntime(
      detection: (input) => _detectionWithBands(input, 1),
      recognition: (call) => _row(1),
    );

    final result = await _engine(runtime).recognize(_documentPng());

    expect(result.isAvailable, isTrue);
    expect(result.lines, hasLength(1));
    final line = result.lines.single;
    expect(line.text, 'ا', reason: 'alphabet index 1 is the first entry');
    expect(line.confidence, closeTo(.95, 1e-6));
    expect(line.bounds, hasLength(4));
    for (final corner in line.bounds!) {
      expect(corner.x, inInclusiveRange(0, 1));
      expect(corner.y, inInclusiveRange(0, 1));
    }
    expect(result.engineVersion, isNotEmpty);
  });

  test('a blank map is an available run with no lines', () async {
    final runtime = _FakeRuntime(
      detection: (input) => _detectionWithBands(input, 0),
      recognition: (call) => _row(1),
    );

    final result = await _engine(runtime).recognize(_documentPng());

    expect(result.isAvailable, isTrue);
    expect(result.lines, isEmpty);
    expect(result.confidence, isNull, reason: 'absence, not zero');
    expect(runtime.recognitionCalls, isEmpty);
  });

  test('a recognition graph failure is reported as unavailable', () async {
    final runtime = _FakeRuntime(
      detection: (input) => _detectionWithBands(input, 1),
    );

    final result = await _engine(runtime).recognize(_documentPng());

    expect(result.isAvailable, isFalse);
    expect(result.unavailableReason, 'engine-failure');
    expect(result.lines, isEmpty);
  });

  test('a missing model is unavailable, never empty text', () async {
    final runtime = _FakeRuntime(recognition: (call) => _row(1));

    final result = await _engine(runtime).recognize(_documentPng());

    expect(result.isAvailable, isFalse);
    expect(result.unavailableReason, 'model-unavailable');
  });

  test('a low-confidence row is dropped instead of guessed', () async {
    final runtime = _FakeRuntime(
      detection: (input) => _detectionWithBands(input, 1),
      recognition: (call) => _row(1, probability: .2),
    );

    final result = await _engine(runtime).recognize(_documentPng());

    expect(result.isAvailable, isTrue);
    expect(result.lines, isEmpty);
    expect(runtime.recognitionCalls, hasLength(1));
  });

  test('the line cap bounds how much work one document can cause', () async {
    final runtime = _FakeRuntime(
      detection: (input) => _detectionWithBands(input, 5),
      recognition: (call) => _row(1),
    );
    final engine = _engine(runtime, maxLines: 2);

    final result = await engine.recognize(_documentPng());

    expect(runtime.recognitionCalls, hasLength(2));
    expect(result.lines, hasLength(2));
  });

  test('cancellation propagates instead of becoming an OCR failure', () async {
    final runtime = _FakeRuntime(
      detection: (input) => _detectionWithBands(input, 1),
      recognition: (call) => _row(1),
    );
    final token = CancellationToken()..cancel();

    await expectLater(
      _engine(runtime).recognize(_documentPng(), token: token),
      throwsA(isA<OperationCancelled>()),
    );
    expect(runtime.recognitionCalls, isEmpty);
  });

  test('the engine advertises the pinned version and is enabled', () {
    final engine = _engine(_FakeRuntime());

    expect(engine.isEnabled, isTrue);
    expect(engine.version, startsWith('ppocrv5'));
  });

  test('a stalled detection graph expires instead of hanging', () async {
    // This is the reported Android symptom: the plugin never replies, the
    // future stays pending and the import counter never leaves 0 / 1. The
    // engine must end the call with an explicit, diagnosable result.
    final runtime = _StalledRuntime();
    final engine = PaddleOcrEngine(
      runtime: runtime,
      dictionaryLoader: (assetKey) async => _dictionary(),
      timeBudget: const Duration(milliseconds: 250),
    );

    final result = await engine.recognize(_documentPng());

    expect(result.isAvailable, isFalse);
    expect(result.unavailableReason, 'time-budget-exceeded');
    expect(result.lines, isEmpty);
    expect(runtime.abandoned, 1, reason: 'the stuck session is dropped');
  });

  test('a stalled recognition graph keeps the lines already decoded', () async {
    final runtime = _SlowRecognitionRuntime(
      detection: (input) => _detectionWithBands(input, 2),
    );
    final engine = PaddleOcrEngine(
      runtime: runtime,
      dictionaryLoader: (assetKey) async => _dictionary(),
      timeBudget: const Duration(milliseconds: 250),
    );

    final result = await engine.recognize(_documentPng());

    // One line completes, then the second stalls: the transcript is partial and
    // the engine says the budget was hit rather than inventing confidence.
    expect(result.lines, hasLength(1));
    expect(runtime.abandoned, 1);
  });

  test('the shipped dictionary parses to the pinned alphabet size', () async {
    final source = await File(_dictionaryAsset).readAsString();
    final dictionary = parseOcrDictionary(source);

    expect(dictionary, hasLength(747));
    expect(dictionary.first, '!');
    expect(buildOcrAlphabet(dictionary), hasLength(749));
  });
}

/// A runtime whose detection never answers, like a native call that failed on
/// the platform thread without replying.
class _StalledRuntime extends _FakeRuntime {
  _StalledRuntime() : super(recognition: (call) => _row(1));

  @override
  Future<OcrDetOutput> runDetection(OcrDetInput input) =>
      Completer<OcrDetOutput>().future;
}

/// Answers the first recognition row, then never answers again.
class _SlowRecognitionRuntime extends _FakeRuntime {
  _SlowRecognitionRuntime({required this.slowDetection})
    : super(
        detection: (input) => slowDetection(input),
        recognition: (call) => _row(1),
      );

  final OcrDetOutput Function(OcrDetInput input) slowDetection;

  var _answered = 0;

  @override
  Future<OcrRecOutput> runRecognition(OcrLineInput input) {
    recognitionCalls.add(input);
    if (_answered++ == 0) return Future<OcrRecOutput>.value(_row(1));
    return Completer<OcrRecOutput>().future;
  }
}
