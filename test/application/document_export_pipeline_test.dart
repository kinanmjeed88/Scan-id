import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/export_plan.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/export/document_exporter.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

// The same simple synthetic card shape used by boundary_gate_test.dart.
// No detector, boundary verifier, cropper, repository or exporter is mocked.
// This is path/regression coverage, not evidence of real-document accuracy.
Uint8List _cardPhoto() {
  final image = img.Image(width: 640, height: 480);
  img.fill(image, color: img.ColorRgb8(40, 48, 60));
  img.fillRect(
    image,
    x1: 90,
    y1: 100,
    x2: 550,
    y2: 390,
    color: img.ColorRgb8(235, 233, 228),
  );
  return img.encodePng(image);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalProjectRepository projects;
  late LocalAssetRepository assets;
  late ProjectService service;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan-pipeline-export-');
    projects = await LocalProjectRepository.open(root);
    assets = LocalAssetRepository(projects.files);
    service = ProjectService(
      projects,
      assets,
      imageEditor: LocalImageEditor(projects.files),
    );
  });
  tearDown(() async {
    await projects.close();
    await root.delete(recursive: true);
  });

  Future<AutomaticLayoutReport> importAndArrange(
    String name,
    Uint8List bytes,
  ) async {
    final created = await service.create('اختبار اصطناعي');
    final imported = await service.importImages(created, [
      ImportSource(name, () => Stream.value(bytes)),
    ]);
    expect(imported.failures, isEmpty);
    final source = imported.project.assets.single;
    final original = await assets.resolve(source.originalPath);
    expect(await original.readAsBytes(), bytes);
    return service.arrangeImportedImages(imported.project, [source.id]);
  }

  test(
    'real local intake, authorized crop, persistence and A4 export stay connected',
    () async {
      final bytes = _cardPhoto();
      final report = await importAndArrange(
        'البطاقة الوطنية الموحدة.png',
        bytes,
      );
      expect(service.smartRecognitionEnabled, isFalse);
      expect(service.multiDocumentSegmentationEnabled, isTrue);
      expect(report.cropped, 1);
      expect(report.notDetected, 0);
      final project = await projects.get(report.project.id);
      expect(project.toJson(), report.project.toJson());
      final asset = project.assets.single;
      expect(asset.crop, isNotNull);
      expect(asset.width, lessThan(640));
      expect(asset.height, lessThan(480));
      final item = project.items.single;
      expect(item.sizeConfirmed, isTrue);
      expect(item.pageIndex, 0);
      final working = await assets.resolve(asset.workingPath);
      final workingBefore = await working.readAsBytes();
      final before = project.toJson();
      final exporter = DocumentExporter(assets);
      final pdf = await exporter.generate(
        ExportPlan(project, ExportProfile()),
        root,
      );
      final pdfBytes = await File(pdf.files.single).readAsBytes();
      expect(String.fromCharCodes(pdfBytes.take(5)), '%PDF-');
      final png = await exporter.generate(
        ExportPlan(project, ExportProfile(format: ExportFormat.png)),
        root,
      );
      final raster = img.decodePng(await File(png.files.single).readAsBytes())!;
      expect((raster.width, raster.height), (2480, 3508));
      final center = raster.getPixel(
        ((item.x + item.width / 2) / 25.4 * 300).round(),
        ((item.y + item.height / 2) / 25.4 * 300).round(),
      );
      expect(center.r, closeTo(235, 5));
      expect(center.g, closeTo(233, 5));
      expect(center.b, closeTo(228, 5));
      expect(await working.readAsBytes(), workingBefore);
      expect(
        await (await assets.resolve(asset.originalPath)).readAsBytes(),
        bytes,
      );
      expect((await projects.get(project.id)).toJson(), before);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('a refused boundary cannot become a confirmed printable crop', () async {
    final bytes = _cardPhoto();
    final report = await importAndArrange('البطاقة التموينية.png', bytes);
    expect(report.cropped, 0);
    expect(report.notDetected, 1);
    final project = await projects.get(report.project.id);
    expect(project.assets.single.crop, isNull);
    expect(project.items.single.sizeConfirmed, isFalse);
    expect(
      () => ExportPlan(project, ExportProfile()),
      throwsA(isA<ValidationException>()),
    );
    final exports = Directory('${root.path}/$exportDirectoryName');
    expect(await exports.exists(), isFalse);
    expect(
      await (await assets.resolve(
        project.assets.single.originalPath,
      )).readAsBytes(),
      bytes,
    );
  });
}
