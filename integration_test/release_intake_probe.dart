import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
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

/// Deterministic public test input; no claim about real-document accuracy.
Future<Uint8List> _syntheticPage() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 1000, 700),
    ui.Paint()..color = const ui.Color(0xFF3E3730),
  );
  canvas.drawRect(
    const ui.Rect.fromLTWH(100, 100, 800, 500),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  var y = 210.0;
  for (final text in ['SCAN ID 1234567890', 'DATE 2026 11 05']) {
    final paragraph =
        (ui.ParagraphBuilder(
                ui.ParagraphStyle(
                  textDirection: ui.TextDirection.ltr,
                  fontSize: 54,
                ),
              )
              ..pushStyle(
                ui.TextStyle(color: const ui.Color(0xFF000000), fontSize: 54),
              )
              ..addText(text))
            .build()
          ..layout(const ui.ParagraphConstraints(width: 740));
    canvas.drawParagraph(paragraph, ui.Offset(130, y));
    y += 130;
    paragraph.dispose();
  }
  final image = await recorder.endRecording().toImage(1000, 700);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  if (data == null) {
    throw StateError('Synthetic page encoding returned no PNG.');
  }
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

/// Shared by the host-side test and the actual Release Dart entrypoint.
///
/// The native Release runner does not need integration_test's dev dependency or
/// a VM service. It executes this same production intake/reopen/retry path and
/// receives the returned evidence over a test-only MethodChannel.
Future<Map<String, Object?>> runReleaseIntakeProbe() async {
  final photo = await _syntheticPage();
  final originalHash = sha256.convert(photo).toString();
  final root = await Directory.systemTemp.createTemp('scan_id_release_intake');
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

    _require(run.error == null, 'Intake failed: ${run.error}');
    _require(run.importedCount == 1, 'Intake did not import exactly one page.');
    _require(run.layout != null, 'Intake returned no honest paper/layout.');
    _require(
      progress.last.completed == progress.last.total,
      'Intake progress did not complete.',
    );
    _require(
      run.project.assets.length == 1,
      'Original asset was not retained.',
    );
    _require(run.project.items.length == 1, 'Paper/item was not retained.');
    final asset = run.project.assets.single;
    _require(
      run.project.items.single.assetId == asset.id,
      'The retained item does not reference the original asset.',
    );
    final original = await assets.resolve(asset.originalPath);
    _require(
      sha256.convert(await original.readAsBytes()).toString() == originalHash,
      'Intake mutated the original bytes.',
    );

    // Completed UI alone can hide a native failure because manual fallback is
    // intentionally safe. Require real JNI round trips, not a silent fallback.
    for (final phase in nativePhases) {
      _require(
        events.any(
          (event) => event.phase == phase && event.event == 'native_completed',
        ),
        'Release JNI inference did not complete: $phase',
      );
    }
    _require(
      !events.any(
        (event) =>
            event.event == 'native_failed' ||
            event.event == 'ocr_failed' ||
            event.event == 'ocr_runtime_failed' ||
            event.event == 'stage_timeout',
      ),
      'Intake hid a native/OCR failure or timeout behind manual fallback.',
    );
    _require(secondary.inferenceRuns >= 1, 'DocAligner did not run.');

    final projectId = run.project.id;
    final itemId = run.project.items.single.id;
    await repository.close();
    repository = await LocalProjectRepository.open(root);
    final reopened = await repository.get(projectId);
    _require(reopened.assets.single.id == asset.id, 'Reopen changed asset id.');
    _require(reopened.items.single.id == itemId, 'Reopen changed item id.');
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
    _require(retry != null, 'Retry returned no project.');
    _require(
      !retry!.warnings.any(
        (warning) =>
            warning.contains('فشل OCR') || warning.contains('المهلة الزمنية'),
      ),
      'Retry hid an OCR failure or timeout: ${retry.warnings}',
    );
    _require(
      retryProgress.last.completed == retryProgress.last.total,
      'Retry progress did not complete.',
    );
    _require(
      retry.project.items.length == 1 &&
          retry.project.items.single.id == itemId,
      'Retry duplicated or replaced the item.',
    );
    _require(
      retry.project.assets.length == 1,
      'Retry duplicated the original.',
    );
    final retryOriginal = await retryAssets.resolve(
      retry.project.assets.single.originalPath,
    );
    _require(
      sha256.convert(await retryOriginal.readAsBytes()).toString() ==
          originalHash,
      'Retry mutated the original bytes.',
    );
    _require(
      secondary.inferenceRuns >= 2,
      'Retry did not reuse/run inference.',
    );

    return <String, Object?>{
      'originalSha256': originalHash,
      'importedCount': run.importedCount,
      'assetCount': retry.project.assets.length,
      'itemCount': retry.project.items.length,
      'nativePhases': nativePhases.toList(),
      'docAlignerRuns': secondary.inferenceRuns,
      'originalUnchanged': true,
      'retryOriginalUnchanged': true,
    };
  } finally {
    await ocr.close();
    await primary.close();
    await secondary.close();
    await repository?.close();
    await root.delete(recursive: true);
  }
}
