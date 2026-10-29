import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan_id/application/project_service.dart';
import 'package:scan_id/domain/arrangement.dart';
import 'package:scan_id/domain/crop_draft.dart';
import 'package:scan_id/domain/document_edits.dart';
import 'package:scan_id/domain/document_kind.dart';
import 'package:scan_id/domain/export_plan.dart';
import 'package:scan_id/domain/geometry.dart';
import 'package:scan_id/domain/project.dart';
import 'package:scan_id/domain/validation.dart';
import 'package:scan_id/export/document_exporter.dart';
import 'package:scan_id/persistence/local_asset_repository.dart';
import 'package:scan_id/persistence/local_image_editor.dart';
import 'package:scan_id/persistence/local_project_repository.dart';

// A synthetic rectangle exercises the local crop/export path without mocks.
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
    'synthetic intake, manual crop/size choice, persistence and A4 export stay connected',
    () async {
      final bytes = _cardPhoto();
      final report = await importAndArrange('scan.png', bytes);
      expect(service.smartRecognitionEnabled, isFalse);
      expect(service.multiDocumentSegmentationEnabled, isFalse);
      expect(report.cropped, 0);
      expect(report.notDetected, 1);
      expect(report.project.assets.single.crop, isNull);
      expect(report.project.items.single.documentKind, DocumentKind.unknown);
      expect(report.project.items.single.sizeConfirmed, isFalse);
      expect(report.project.items.single.pageIndex, isNull);

      // This is an explicit human crop, not an automated boundary result.
      final source = report.project.assets.single;
      final opened = await service.imageEditor!.open(source);
      final manualRecipe = CropDraft(
        corners: [
          Point2(.14, .21),
          Point2(.86, .21),
          Point2(.86, .81),
          Point2(.14, .81),
        ],
      ).toRecipe(opened.width, opened.height);
      final manuallyCropped = await service.applyManualCrop(
        report.project,
        source,
        manualRecipe,
      );
      expect(manuallyCropped.assets.single.userAuthoredCrop, isTrue);
      expect(manuallyCropped.assets.single.crop, isNotNull);

      final manuallySelected = DocumentEdits.setKind(
        manuallyCropped,
        manuallyCropped.items.single.id,
        DocumentKind.other,
      );
      final arranged = arrangeDocuments(manuallySelected).result;
      final project = await projects.save(arranged);
      expect(
        (await projects.get(project.id)).toJson(),
        project.toJson(),
        reason: 'the committed project round-trips through local persistence',
      );
      final asset = project.assets.single;
      expect(asset.crop, isNotNull);
      expect(asset.width, lessThan(640));
      expect(asset.height, lessThan(480));
      final item = project.items.single;
      expect(item.documentKind, DocumentKind.other);
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

  test(
    'a human crop does not infer type or confirm a printable catalog size',
    () async {
      final bytes = _cardPhoto();
      final report = await importAndArrange('capture.png', bytes);
      expect(report.cropped, 0);
      expect(report.notDetected, 1);
      expect(report.project.assets.single.crop, isNull);
      final source = report.project.assets.single;
      final opened = await service.imageEditor!.open(source);
      final recipe = CropDraft(
        corners: [
          Point2(.14, .21),
          Point2(.86, .21),
          Point2(.86, .81),
          Point2(.14, .81),
        ],
      ).toRecipe(opened.width, opened.height);
      final cropped = await service.applyManualCrop(
        report.project,
        source,
        recipe,
      );
      final project = await projects.get(cropped.id);
      expect(project.assets.single.crop, isNotNull);
      expect(project.assets.single.userAuthoredCrop, isTrue);
      expect(project.items.single.documentKind, DocumentKind.unknown);
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
    },
  );
}
