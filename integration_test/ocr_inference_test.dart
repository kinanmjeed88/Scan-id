import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scan_id/application/paddle_ocr_engine.dart';
import 'package:scan_id/domain/ocr_evidence.dart';

/// Renders [lines] onto a white page and returns it as PNG bytes.
///
/// The page is drawn by the platform text stack, so the glyphs are whatever the
/// host really renders — the same pixels a photograph of that page would carry,
/// without a font file entering the repository. This is a synthetic page, not a
/// scanned Iraqi document: it proves the OCR pipeline runs and reads text, and
/// it cannot prove field accuracy on real cards.
Future<Uint8List> _renderPage(
  List<String> lines, {
  required TextDirection direction,
  int width = 1000,
  double fontSize = 44,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final height = 120.0 + lines.length * fontSize * 2.2;
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  var y = 60.0;
  for (final line in lines) {
    final paragraph =
        (ui.ParagraphBuilder(
                ui.ParagraphStyle(
                  textDirection: direction,
                  fontSize: fontSize,
                  textAlign: TextAlign.center,
                ),
              )
              ..pushStyle(
                ui.TextStyle(color: const Color(0xFF000000), fontSize: fontSize),
              )
              ..addText(line))
            .build()
          ..layout(ui.ParagraphConstraints(width: width.toDouble()));
    canvas.drawParagraph(paragraph, Offset(0, y));
    y += paragraph.height + 16;
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height.round());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  expect(data, isNotNull, reason: 'the synthetic page could not be encoded');
  return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

Future<Uint8List> _blankPage({int width = 800, int height = 400}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  expect(data, isNotNull);
  return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

String _joined(OcrTextResult result) =>
    result.lines.map((line) => line.text).join(' ');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the bundled PP-OCRv5 pipeline reads Latin text and digits', (
    tester,
  ) async {
    final engine = PaddleOcrEngine();
    try {
      final bytes = await _renderPage(
        ['SCAN ID 1234567890', 'DATE 2026 11 04'],
        direction: TextDirection.ltr,
      );

      final result = await engine.recognize(bytes);

      expect(
        result.isAvailable,
        isTrue,
        reason: 'unavailable: ${result.unavailableReason}',
      );
      expect(result.lines, isNotEmpty, reason: 'no text line was detected');
      final text = _joined(result);
      printOnFailure('recognised: $text');
      expect(text.toUpperCase(), contains('SCAN'));
      for (final line in result.lines) {
        expect(line.confidence, greaterThan(0));
        expect(line.confidence, lessThanOrEqualTo(1));
        expect(line.bounds, hasLength(4));
      }
    } finally {
      await engine.close();
    }
  });

  testWidgets('the bundled Arabic recogniser emits Arabic letters', (
    tester,
  ) async {
    final engine = PaddleOcrEngine();
    try {
      final bytes = await _renderPage(
        ['وزارة الداخلية', 'البطاقة الوطنية الموحدة'],
        direction: TextDirection.rtl,
      );

      final result = await engine.recognize(bytes);

      expect(
        result.isAvailable,
        isTrue,
        reason: 'unavailable: ${result.unavailableReason}',
      );
      final text = _joined(result);
      printOnFailure('recognised: $text');
      final arabic = text.runes
          .where((rune) => rune >= 0x0600 && rune <= 0x06FF)
          .length;
      expect(
        arabic,
        greaterThan(10),
        reason:
            'the Arabic recognition graph must produce Arabic code points; '
            'Latin garbage means the dictionary, channel order or tensor '
            'layout is wrong',
      );
    } finally {
      await engine.close();
    }
  });

  testWidgets('a blank page reports no text instead of inventing it', (
    tester,
  ) async {
    final engine = PaddleOcrEngine();
    try {
      final result = await engine.recognize(await _blankPage());

      expect(result.isAvailable, isTrue);
      expect(result.lines, isEmpty);
      expect(result.confidence, isNull, reason: 'absence, not zero');
    } finally {
      await engine.close();
    }
  });

  testWidgets('two runs over the same page agree', (tester) async {
    final engine = PaddleOcrEngine();
    try {
      final bytes = await _renderPage(
        ['SCAN ID 1234567890'],
        direction: TextDirection.ltr,
      );

      final first = await engine.recognize(bytes);
      final second = await engine.recognize(bytes);

      expect(_joined(first), _joined(second));
    } finally {
      await engine.close();
    }
  });
}
