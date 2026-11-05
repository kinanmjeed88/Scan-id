import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scan_id/application/import_trace.dart';
import 'package:scan_id/application/paddle_ocr_engine.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/application/recognition_worker.dart';
import 'package:scan_id/imaging/boundary_proposal_cascade.dart';
import 'package:scan_id/imaging/docaligner_model.dart';
import 'package:scan_id/imaging/docquad_model.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/presentation/intake.dart';

/// A synthetic, public test page. This proves the native release path runs;
/// it makes no claim about recognition accuracy on a person's document.
Future<Uint8List> _syntheticPage() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 1000, 700),
    Paint()..color = const Color(0xFF3E3730),
  );
  canvas.drawRect(
    const Rect.fromLTWH(100, 100, 800, 500),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  var y = 210.0;
  for (final text in ['SCAN ID 1234567890', 'DATE 2026 11 05']) {
    final paragraph =
        (ui.ParagraphBuilder(
                ui.ParagraphStyle(
                  textDirection: TextDirection.ltr,
                  fontSize: 54,
                ),
              )
              ..pushStyle(
                ui.TextStyle(color: const Color(0xFF000000), fontSize: 54),
              )
              ..addText(text))
            .build()
          ..layout(const ui.ParagraphConstraints(width: 740));
    canvas.drawParagraph(paragraph, Offset(130, y));
    y += 130;
    paragraph.dispose();
  }
  final image = await recorder.endRecording().toImage(1000, 700);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  expect(data, isNotNull);
  return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'R8 release intake and retry complete with real JNI inference',
    (tester) async {
      expect(
        const bool.fromEnvironment('dart.vm.product'),
        isTrue,
        reason:
            'This regression must run in an AOT release package, not Debug.',
      );
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      final photo = await _syntheticPage();
      final originalHash = sha256.convert(photo).toString();
      final root = await Directory.systemTemp.createTemp('scan_id_r8_intake');
      LocalProjectRepository? repository;
      final primary = DocQuadNet256();
      final secondary = DocAlignerFastViT();
      final ocr = PaddleOcrEngine();
      final events = <ImportTraceEvent>[];
      const nativePhases = {
        'docquad-inference',
        'docaligner-inference',
        'ocr-inference',
      };

      try {
        repository = await LocalProjectRepository.open(root);
        final assets = LocalAssetRepository(repository.files);
        final editor = LocalImageEditor(
          repository.files,
          boundaryProposer: BoundaryProposalCascade(
            primary: primary,
            secondary: secondary,
          ),
        );
        final service = ProjectService(
          repository,
          assets,
          imageEditor: editor,
          smartRecognitionEnabled: true,
          ocr: ocr,
        );
        final project = await service.create('اختبار التحليل في Release');
        final progress = <BatchProgress>[];
        final run =
            await IntakeRunner(
              service: service,
              project: project,
              onTrace: events.add,
            ).run([
              ImportSource('synthetic.png', () => Stream.value(photo)),
            ], onProgress: progress.add);

        expect(run.error, isNull);
        expect(run.importedCount, 1);
        expect(run.layout, isNotNull);
        expect(progress.last.completed, progress.last.total);
        expect(progress.last.stage, 'تجهيز وحفظ النتائج');
        expect(run.project.assets, hasLength(1));
        expect(run.project.items, hasLength(1));
        final asset = run.project.assets.single;
        expect(run.project.items.single.assetId, asset.id);
        final original = await assets.resolve(asset.originalPath);
        expect(
          sha256.convert(await original.readAsBytes()).toString(),
          originalHash,
        );

        // The cascade/OCR deliberately catch failures for manual fallback.
        // A completed dialog alone would therefore hide the original defect.
        // Require successful native round trips and text availability instead.
        for (final phase in nativePhases) {
          expect(
            events.where(
              (event) =>
                  event.phase == phase && event.event == 'native_completed',
            ),
            isNotEmpty,
            reason: 'Release JNI inference did not complete: $phase',
          );
        }
        expect(events.any((event) => event.event == 'ocr_completed'), isTrue);
        expect(
          events.where(
            (event) =>
                event.event == 'native_failed' ||
                event.event == 'ocr_failed' ||
                event.event == 'ocr_runtime_failed' ||
                event.event == 'stage_timeout',
          ),
          isEmpty,
        );
        expect(secondary.inferenceRuns, greaterThanOrEqualTo(1));

        // Reopen the committed project, then retry the SAME source. The retry
        // must reuse healthy sessions without duplicating its item or changing
        // the original. Unknown kind/manual crop remains the safe honest state.
        final projectId = run.project.id;
        final itemId = run.project.items.single.id;
        await repository.close();
        repository = await LocalProjectRepository.open(root);
        final reopened = await repository.get(projectId);
        expect(reopened.assets.single.id, asset.id);
        expect(reopened.items.single.id, itemId);
        final retryAssets = LocalAssetRepository(repository.files);
        final retryService = ProjectService(
          repository,
          retryAssets,
          imageEditor: LocalImageEditor(
            repository.files,
            boundaryProposer: BoundaryProposalCascade(
              primary: primary,
              secondary: secondary,
            ),
          ),
          smartRecognitionEnabled: true,
          ocr: ocr,
        );
        final retryProgress = <BatchProgress>[];
        final retry = await retryService.reprocessImages(reopened, [
          asset.id,
        ], onProgress: retryProgress.add);
        expect(retry, isNotNull);
        expect(
          retry!.warnings.where(
            (warning) =>
                warning.contains('فشل OCR') ||
                warning.contains('المهلة الزمنية'),
          ),
          isEmpty,
        );
        expect(retryProgress.last.completed, retryProgress.last.total);
        expect(retry.project.items.map((item) => item.id), [itemId]);
        expect(retry.project.assets, hasLength(1));
        final retryOriginal = await retryAssets.resolve(
          retry.project.assets.single.originalPath,
        );
        expect(
          sha256.convert(await retryOriginal.readAsBytes()).toString(),
          originalHash,
        );
        expect(secondary.inferenceRuns, greaterThanOrEqualTo(2));
      } finally {
        await ocr.close();
        await primary.close();
        await secondary.close();
        await repository?.close();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
