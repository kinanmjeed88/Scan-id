import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/ids.dart';
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/export_plan.dart';
import 'package:scan_id/domain/page_layout.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/export/document_exporter.dart';
import 'package:scan_id/persistence/journey_log_store.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';
import 'package:scan_id/presentation/intake.dart';

// Synthetic pixels and unavailable OCR exercise wiring and persistence, not
// the detection or recognition accuracy of any real model.
void main() {
  test('mixed intake persists, reopens and exports A4 without changing source', () async {
    final root = await Directory.systemTemp.createTemp('intake_pipeline_');
    final support = await Directory.systemTemp.createTemp('intake_journal_');
    final output = await Directory.systemTemp.createTemp('intake_output_');
    var projects = await LocalProjectRepository.open(root);
    try {
      var assets = LocalAssetRepository(projects.files);
      final log = LocalJourneyLog(supportDirectory: () async => support);
      final service = ProjectService(
        projects,
        assets,
        imageEditor: LocalImageEditor(projects.files),
        journeyLog: log,
        smartRecognitionEnabled: true,
      );
      final input = Uint8List.fromList(img.encodePng(img.Image(width: 180, height: 120)));
      final before = sha256.convert(input).toString();
      final project = await service.create('اختبار تكامل');
      final run = await IntakeRunner(service: service, project: project).run([
        ImportSource('valid.png', () => Stream.value(input)),
        ImportSource('broken.png', () => Stream.value(<int>[1, 2, 3])),
      ]);
      expect(run.importedCount, 1);
      expect(run.failures, hasLength(1));
      expect(run.project.assets, hasLength(1));
      expect(run.journeyWriteFailed, isFalse);
      final journeys = await log.read();
      expect(journeys, hasLength(2));
      expect(journeys.where((j) => j.imported), hasLength(1));
      expect(journeys.where((j) => !j.imported), hasLength(1));
      final asset = run.project.assets.single;
      expect(sha256.convert(await (await assets.resolve(asset.originalPath)).readAsBytes()).toString(), before);

      // Explicit manual placement: never claim the unavailable OCR classified it.
      final item = DocumentItem(id: newId(), assetId: asset.id, x: 10, y: 10,
          width: 85, height: 55, sizeConfirmed: true);
      final saved = await projects.save(PageLayout.addMany(run.project, [item]));
      await projects.close();
      projects = await LocalProjectRepository.open(root);
      assets = LocalAssetRepository(projects.files);
      final reopened = await projects.get(saved.id);
      expect(reopened.assets.single.id, asset.id);
      expect(reopened.assets.single.revisionId, asset.revisionId);
      expect(reopened.items.any((value) => value.id == item.id), isTrue);
      expect(sha256.convert(await (await assets.resolve(asset.originalPath)).readAsBytes()).toString(), before);
      final plan = ExportPlan(reopened, ExportProfile(format: ExportFormat.pdf, dpi: 300));
      expect(reopened.paper.width, 210);
      expect(reopened.paper.height, 297);
      final pdf = await DocumentExporter(assets).generate(plan, output);
      final bytes = await File(pdf.files.single).readAsBytes();
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    } finally {
      await projects.close();
      await root.delete(recursive: true);
      await support.delete(recursive: true);
      await output.delete(recursive: true);
    }
  });
}
